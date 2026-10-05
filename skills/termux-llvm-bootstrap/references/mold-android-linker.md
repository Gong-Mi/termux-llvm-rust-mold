# mold x Android: what works, what silently does not

Reach for this before concluding "mold has no Android support" — it does have
some, the defects are narrow, and all three are checkable in minutes.

## What mold already owns

- The bionic-only relocation format: `--pack-dyn-relocs=android[+relr]`
  APS2-encodes the dynamic relocations (`src/chunks/reldyn.rs`), retypes
  `.rel(a).dyn` to `SHT_ANDROID_REL/RELA`, and swaps in `DT_ANDROID_REL(A)(SZ)`;
  the `relr` half adds `DT_ANDROID_RELR*`. It is documented in `docs/mold.1`
  as the configuration most Android system binaries use.
- The Termux TLS rule (see SKILL.md, "Mold with Stage2 Clang").

Driven by clang on arm64, mold's output is field-equivalent to lld's on the
same objects: `ET_DYN`, `PT_LOAD p_align = 16384`, `DT_ANDROID_RELA` + `RELR`,
`GNU_RELRO`, `PT_INTERP = /system/bin/linker64`, `DF_1_PIE` + `NOW`. Only
`GNU_STACK p_align` (1 vs 0) differs — cosmetic. So the useful question is not
"does mold support Android" but "which Android-default FLAGS does mold accept
and ignore", below.

## The loader's acceptance checks (for ANY linker's output)

| Requirement | What the loader does when violated |
|---|---|
| executables are PIE (`ET_DYN`) | `error: <path>: Android only supports position-independent executables (-fPIE)` |
| `PT_TLS.p_align >= 64` on arm64 | `error: <path>: executable's TLS segment is underaligned: alignment is N (skew 0), needs to be at least 64 for ARM64 Bionic` |
| `PT_INTERP` names the platform loader | never started |
| 16 KB segment alignment | enforced only on 16 KB-page kernels — read `getconf PAGE_SIZE` (or `os.sysconf('SC_PAGE_SIZE')`) before calling it a defect; a 4 KB-page device runs 4 KB-aligned images fine |

Packed relocations are **not** a gate: bionic loads plain `RELA` and APS2
equally, so `--pack-dyn-relocs` is a size/startup knob. The failure people hit
when invoking mold directly is simply `ET_EXEC` — mold's `-m aarch64linux`
default without `-pie`. Driving it through clang supplies `-pie`, the interp,
the 16 KB max-page-size and the packed-reloc flag, which is why the normal
path needs none of this reasoning.

Probe a candidate with `scripts/elf-android-check.py <file>`.

## A flag accepted in silence is worse than a rejected one

mold's cmdline parser swallows several GNU flags inside an explicitly
`// Ignored for compatibility.` chain, and **two of them are Android-default**:
`--fix-cortex-a53-843419` and `--fix-cortex-a53-835769`. `src/` contains no
implementation and `--help` omits them. lld implements `--fix-cortex-a53-843419`
(plus `--fix-cortex-a8`), and **clang passes the 843419 flag on every arm64
link line**, so a mold-linked arm64 Android binary is silently unpatched for
the erratum on Cortex-A53.

Rule: before trusting any third-party linker with Android output, take every
flag the driver actually passes (the `-###` tail line) and check it against the
linker's `--help`. "Accepted" proves nothing about "implemented".

Reproduce the gap in five commands, using lld's own vector as the oracle:

```bash
llvm-mc -filetype=obj -triple=aarch64 \
  lld/test/ELF/aarch64-cortex-a53-843419-recognize.s -o rec.o
ld.lld --fix-cortex-a53-843419 -z separate-code rec.o -o by_lld
mold  -m aarch64linux --fix-cortex-a53-843419 -z separate-code rec.o -o by_mold
llvm-objdump --no-print-imm-hex -d by_lld  | grep -A4 '<t3_ff8_ldr>:'
llvm-objdump --no-print-imm-hex -d by_mold | grep -A4 '<t3_ff8_ldr>:'
```

lld rewrites the erratum slot in place to `b <__CortexA53843419_...>` and
defines a patch symbol per site; mold leaves the triggering load/store and
defines none. Any fix must be accepted against the full vector set — the 11
`lld/test/ELF/aarch64-cortex-a53-843419*.s` files (recognize, address, large,
large2, nopatch, thunk, thunk-align, thunk-range, thunk-relocation-crash,
tlsrelax, abs-mapsyms).

## Implementing the 843419 workaround in mold (our fork)

The patch lives in `src/target/arm64_errata.rs` (recogniser + code ranges) plus
hooks in `passes.rs`, `driver.rs`, `cmdline.rs`, `context.rs`. Shape of it, and
the reasons it is shaped that way:

- **Recogniser = lld's `AArch64ErrataFix` predicates, ported literally**: the
  page-anchored windows (page offsets `0xff8`/`0xffc` only), the three- and
  four-instruction sequence shapes, and the `$x`/`$d` mapping symbols that
  delimit code from literal pools. A "look for ADRP near a page boundary"
  approximation finds sites lld does not and misses sites it does.
- **Patch bodies are appended to the END of the last executable output
  section.** Appending there cannot move any existing site, so the placement
  needs NO address fixpoint — that single property removes lld's whole
  re-scan/iterate loop. Then rewrite the site instruction into `b <patch>`.
- **The displaced instruction is copied out of the already-relocated output**,
  after `copy_chunks` and after offsets are final. The body is therefore
  `[relocated instruction][b back to site+4]` and no relocation has to be
  re-run for it — not even when the site carries a TLS IE relocation, which is
  the case lld needs a four-way relocation dance for.
- **Skip only the JUMP26 case** (a site that is already a branch to a patch).
  Do NOT skip TLS IE sites: see the premise rule in SKILL.md — the skip is only
  sound for a linker that also implements TLS IE→LE relaxation.
- **Known limit: an executable section larger than ±128 MiB of branch range.**
  Append-at-the-end then cannot reach the site, and the fix degrades to a
  warning plus a skip. lld solves this by inserting patch slabs every
  thunk-range and iterating addresses to a fixpoint — implement that only if it
  is ever needed; it is reachable through the synthetic `large`/`large2`
  vectors, never through a real Android binary.

### Acceptance harness (run it before believing any of the above)

Per vector, link it FOUR ways — each linker with and without the flag — and
judge on the produced ELF, never on the linker's own message:

```
for v in recognize address large large2 nopatch thunk thunk-align tlsrelax abs-mapsyms; do
  <linker> -m aarch64linux -z separate-code [--fix-cortex-a53-843419] $v.o -o $v.{nf,fx}.<linker>
done
```

- **Scan the output for residual patterns** with the recogniser predicates
  (both the 3- and 4-instruction shapes). A fix that reports "patched 1 site"
  while the output still holds the pattern has written nothing — that is the
  failure mode a count-only check hides. Unpatched control must be non-zero,
  patched must be zero.
- **Normalise before comparing two linkers.** The erratum criterion is a
  page-relative offset, so the two outputs legitimately hold DIFFERENT site
  sets when their layouts differ: subtract each artifact's own `.text` base and
  compare the relative sets. Comparing absolute addresses reports a difference
  that is not there.
- **lld's `--verbose` count is not its patch count.** It reports the sites it
  DETECTED, including ones it then skips, so "lld 5 vs mold 4" can be two
  linkers patching the same things. Cross-check with the residual scan before
  calling a count mismatch a defect.
- **Do not execute the linked objects.** These are `-nostdlib` test fragments
  with no exit path; running one to "check it works" hangs the shell. Inspect
  the ELF (disassembly, section headers, residual scan) instead.
- **Finish on a real workload, not on the vectors.** Self-link mold itself
  (~61 MB, TLS, real `.text`): with the implementation the link reports the
  sites and the produced binary scans clean AND runs; the upstream binary on the
  identical command leaves the patterns in place. The vectors can pass while a
  real link still regresses, and the A/B on a real binary is what proves the fix
  is actually in the path that runs.

## `-flto` + mold: needs a plugin, then does not optimize

- clang computes the plugin path from its own lib dir
  (`<driver>/../lib/LLVMgold.so`). A tree built without binutils'
  `plugin-api.h` never produces it, and the link dies with
  `mold: fatal: could not open plugin file: dlopen failed: library ".../lib/LLVMgold.so" not found`.
  lld needs no plugin — its LTO is in-process — so `-flto -fuse-ld=lld` works
  on a tree that has no LLVMgold at all.
- Building it standalone beats reconfiguring the tree (a top-level cmake re-run
  risks regenerating `build.ninja` and mass-rebuilding every PCH user): compile
  `llvm/tools/gold/gold-plugin.cpp` with the tree's clang against the tree's
  `libLLVM`, `-shared`. Two traps: copy `plugin-api.h` **alone** into a scratch
  include dir (putting binutils' whole include dir on the line breaks libc++'s
  header order and `<cinttypes>` fails), and write a real version script
  (`{ global: onload; local: *; };`) because LLVM's shipped `gold.exports`
  contains only the bare token `onload`, which lld rejects as a script.
- The plugin resolves `libLLVM.so.<ver>` at dlopen time through the loader's
  namespace, not its own RUNPATH: if a same-named AArch64-only copy shadows the
  full-target one, dlopen dies with
  `cannot locate symbol LLVMInitializeAMDGPUTargetInfo`. Same namespace trap as
  the build-tree host tools; put the full-target lib dir first, and ship the
  plugin beside the libLLVM it was linked against.
- **The result is unoptimized.** With the identical plugin and inputs,
  `-plugin-opt=save-temps` shows both linkers emitting a byte-comparable
  `.lto.o` (matching section lists, equal `.text*` sums), yet mold's final
  `.text` is several times lld's and it carries ~160 statically-linked
  `libunwind.a` members that lld discards. `--gc-sections` does not explain it
  (lld's LTO figure is unchanged by it, and lld non-LTO equals mold non-LTO).
  The plugin did identical work, so do not blame it. Until mold's `lto.rs` link
  ordering is read and understood, treat `-flto` + mold as "links, equals no
  optimization" and use lld whenever LTO is wanted.

## Rebuild determinism and the stale-artifact trap

- Two independent builds of the same source + environment are byte-identical,
  patched and unpatched alike, so a rebuild can be validated against a saved
  hash instead of a fresh judgement call.
- Building a control by reverting the source patch leaves the CONTROL binary at
  `target/release/mold`; the patched build only exists wherever you saved it
  aside. Re-apply the patch to the working tree and rebuild before shipping, or
  the broken-TLS variant is what the next step copies.
- Prove the TLS patch instead of asserting it: rebuild once with `src/passes.rs`
  reverted, link a `__thread` program, and confirm `PT_TLS.p_align` drops to a
  small value and the binary aborts at startup; restore, rebuild, confirm 64 and
  a clean run. A passing test alone does not show a patch is load-bearing.
- `mold -run <compile command>` needs `mold-wrapper.so` beside the mold binary;
  a bare `mold -o out a.cpp` is nonsense (it is a linker: `-m` missing, no
  compilation), and a hand-written link line must include `-pie` itself.
