# Three-tree PGO on Termux/Android AArch64

The rebuild is three configured trees sharing one source checkout:

| Tree | Host compiler | Key flag | Role |
|---|---|---|---|
| `build-instr` | system clang | `-DLLVM_BUILD_INSTRUMENTED=IR` | instrumented clang that trains |
| `build-pgotrain` | `build-instr` clang | none (stays uninstrumented) | training build, writes `.profraw` |
| `build-pgouse` | installed clang | `-DLLVM_PROFDATA_FILE=<abs>` | final, profile-use build |

tree B (training) is **at least ~4x slower** than tree C (profile-use): its
compiler is instrumented and writes a profile file per process. Budget the runs
accordingly and do not read a slow training stage as a hang.

## Training env (tree B)

Export both variables for configure AND ninja — children inherit them:

```bash
export LD_LIBRARY_PATH=$HOME/llvm-termux/build-instr/lib:$PREFIX/lib   # tree A lib FIRST
unset LLVM_PROFILE_FILE_SECONDS 2>/dev/null
export LLVM_PROFILE_FILE=$HOME/llvm-termux/pgo/raw/llvm-%m-%p.profraw
```

`%m` (module signature) + `%p` (pid) gives one file per compiler process. Use a
dedicated raw directory; a full build produces 20k+ files.

Driver (`run-treeB.sh` shape): `termux-wake-lock`, start
`scripts/memwatch.py <log> <csv>` in the background, `cd $BUILD && ninja -j8 >
$LOG 2>&1`, then append `STAGE_TREEB_EXIT=$rc` to the log. A resume attempt gets
its OWN log file and exit marker (`..._r2`, `..._r3`) — never append to the
previous attempt's log.

## Profile-use config (tree C)

```bash
env -u LD_LIBRARY_PATH bash configure-llvm.sh \
    $HOME/llvm-termux/build-pgouse $PREFIX/bin/clang-23 $PREFIX/bin/clang++-23 \
    -DLLVM_PROFDATA_FILE=$HOME/llvm-termux/pgo/llvm-23.1.pgo.profdata
```

- Use an **absolute** path; verify after configure with
  `grep -E 'CMAKE_C_COMPILER:|LLVM_PROFDATA_FILE' <build>/CMakeCache.txt`.
- The installed host compiler needs no `LD_LIBRARY_PATH` for itself, but this
  tree's own intermediate host tools and its own clang do. Plain `ninja` on it
  dies at the first build-tree host tool with
  `cannot locate symbol LLVMInitializeAMDGPUTarget`, and the naive
  `$BUILD/lib:$PREFIX/lib` fix breaks PCH validation. Use the shim + two-phase
  recipe in SKILL.md, "Compiler identity: libclang-cpp, PCH, and the shim".
- Prove the profile reaches the compiler from the GENERATED commands, not the
  log: `ninja -t commands | grep -c 'fprofile-instr-use'` (thousands on a full
  graph). Ninja prints progress lines only, never the flag, so grepping the build
  log returns 0 on a perfectly profile-driven build.

## Merging (raw -> profdata)

Two stages, resumable:

```bash
PART=$HOME/llvm-termux/pgo/partials; PF=$HOME/llvm-termux/build-instr/bin/llvm-profdata
cd $HOME/llvm-termux/pgo/raw
ls -1 > $PART/filelist.txt
split -l 2000 -d -a 3 $PART/filelist.txt $PART/batch-
for b in $PART/batch-[0-9][0-9][0-9]; do
  out="$b.profdata"; [ -s "$out" ] && continue
  $PF merge -sparse --num-threads=8 @"$b" -o "$out"
done
ls -1 $PART/batch-*.profdata > $PART/partial-list.txt
$PF merge -sparse --num-threads=8 @$PART/partial-list.txt -o $HOME/llvm-termux/pgo/llvm-23.1.pgo.profdata
```

`build-instr/bin/llvm-profdata` needs
the same `LD_LIBRARY_PATH=$HOME/llvm-termux/build-instr/lib:$PREFIX/lib` as the
tree it came from.

### Retrying a failed batch

A batch that aborts (exit 134, no stderr) is out of memory, typically because it
caught the largest files. Re-split just that batch:

```bash
cd $HOME/llvm-termux/pgo/raw
cdir=$PART/chunks-$idx; rm -rf "$cdir"; mkdir -p "$cdir"
split -l 500 -d -a 3 $PART/batch-003 $cdir/c-
for c in $cdir/c-*; do
  $PF merge -sparse --num-threads=4 @"$c" -o "$c.profdata" || echo "CHUNK_FAIL $c"
done
ls -1 $cdir/c-*.profdata > $cdir/chunk-list.txt
$PF merge -sparse --num-threads=8 @$cdir/chunk-list.txt -o $PART/batch-003.profdata
rm -rf "$cdir"
```

Lower `--num-threads` for the chunk pass; fewer threads, smaller peak.

## Verification

```bash
$PF show llvm-23.1.pgo.profdata | head -6      # level=IR, Total functions:, Total count:
$PF show --all-functions llvm-23.1.pgo.profdata | grep -c '  Hash:'
sha256sum llvm-23.1.pgo.profdata
```

Sanity numbers for a full clang+lld+mlir+compiler-rt training run: ~48k
functions, ~700k blocks. A merged size in the tens of MB with those counts is
normal; the raw set being hundreds of GB is also normal — most of it is the
same module recorded once per compiler process and collapses under `-sparse`.

## Proving the payoff (A/B on compiler throughput)

"The profile is consumed" is not "it got faster". A tree whose commands all
carry `-fprofile-instr-use` proves the flag reached the driver and nothing more;
the benefit is a separate measurement, and it is the number the user will ask
for.

The training tree IS the control arm: same source checkout, same configure
flags, same code — the only difference is that its binaries were built WITHOUT
the profile. Identify the arms by counting the flag in the GENERATED commands,
never by trusting the tree names:

```bash
python3 -c '
import json,sys
for t in sys.argv[1:]:
    d = json.load(open(t + "/compile_commands.json"))
    print(t, sum("fprofile-instr-use" in e["command"] for e in d), "/", len(d))
' build-pgotrain build-pgouse
```

Expect `0/N` for the training tree and ~`N/N` for the profile-use tree. Do NOT
A/B against an installed toolchain package — vendor and self-built packages are
often PGO'd themselves, so that comparison measures nothing.

Harness (`scripts/pgo_bench.py`): read the profile-use tree's
`compile_commands.json`, take the heaviest translation units, and for each run
the SAME command with only the compiler path swapped.

- delete `-Xclang -include-pch -Xclang <pch> -Xclang -include -Xclang <hdr>` and
  `-Winvalid-pch` — the PCH records the identity of whichever compiler built it
  and aborts the compile under a different one;
- redirect `-o` and `-MF` into a scratch dir; never let a benchmark overwrite
  objects the build tree still owns;
- **pair the arms inside each repetition** (B then C back-to-back) and take the
  **median of the per-pair ratios**. Do NOT keep "the minimum per arm": across
  repetitions the clock drifts, and independent minima let one arm sample a cool
  run and the other a hot one — a bias in a direction nothing in the output
  reveals;
- primary metric is `os.wait4` rusage (user+sys) CPU seconds, and samples with
  `wall > cpu * 1.15` are discarded as preempted (a busy device produced
  wall 17.6 s against cpu 10.9 s for the same compile). CPU seconds are NOT
  frequency-invariant either — the same work costs more CPU seconds at a lower
  clock — so drift resistance comes from the pairing, not from the metric;
- report a quartile interval beside every figure. A lone per-file extreme that
  does not reproduce at a different pin or repetition count is method noise, not
  a finding: an apparent 1.37x collapsed to ~1.18x on re-measurement.

Measured on this device (aarch64, 8 cores, 4 heavy TUs × 5 pairs, pinned, PCH
stripped, paired design): median ratio **1.194x** in favour of the profile-use
compiler, every file inside **1.18–1.21x**, quartiles ~±0.04. Treat ~1.15–1.2x
(10–20%) as the expected order of magnitude for a self-built, workload-matched
profile on this class of device, not a promise. Earlier "1.178x / 1.09–1.37x"
figures came from the biased independent-minimum design and are superseded.

Boundary to state alongside the number: this measures the COMPILER BINARY's
throughput. It says nothing about how fast the code it produces runs — that is a
different benchmark. Report the two as separate claims, and never present the
unmeasured one as known.
