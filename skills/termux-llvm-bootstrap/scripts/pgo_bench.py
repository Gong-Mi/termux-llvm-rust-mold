# pgo_bench.py — compiler-throughput A/B: training tree (no PGO) vs profile-use tree
#
# Both arms run the SAME command from the profile-use tree's compile_commands.json;
# only the compiler binary path is swapped, so the difference measured is the
# compiler binary's own build (with vs without -fprofile-instr-use).
#
#   usage: pgo_bench.py [cpu] [pairs] [comma,separated,basenames]
#
# Handling that matters:
#   * -Xclang -include-pch ... is stripped — those PCHs record the identity of the
#     compiler that built them and abort the compile under a different one
#   * -o / -MF are redirected into a scratch dir: NEVER overwrite objects the
#     build tree still owns
#   * PAIRED sampling: inside one repetition the two arms run back-to-back and the
#     RATIO is formed per pair; the reported figure is the MEDIAN of those ratios.
#     Do NOT keep "the minimum per arm" — drift then lets one arm sample a cool run
#     and the other a hot one, which biases the answer in a direction nobody can see.
#   * primary metric is os.wait4 rusage (user+sys) CPU seconds, NOT wall time: a
#     preempted sample shows wall >> cpu, so samples with wall > cpu*1.15 are
#     discarded and counted. CPU seconds are still frequency-dependent (the same
#     work costs more CPU seconds at a lower clock) — pairing, not metric choice, is
#     what makes this drift-resistant.
#   * LD_PRELOAD is deliberately absent: a sandbox-injected preload makes freshly
#     built binaries fail at exec and pollutes the timings.
#
# Report the median with its quartile interval. A lone per-file extreme that does
# not reproduce on a second run is method noise, not a finding. State the boundary:
# this measures the COMPILER's throughput, not the runtime speed of code it produces.
import json, os, shlex, sys, tempfile, time

ROOT = os.path.expanduser("~/llvm-termux")
SRC = os.path.expanduser("~/llvm-project")
CC = {
    "B_noPGO": f"{ROOT}/build-pgotrain/bin/clang++",
    "C_PGO":   f"{ROOT}/build-pgouse/bin/clang++",
}
LIBS = {
    "B_noPGO": f"{ROOT}/build-pgotrain/lib",
    "C_PGO":   f"{ROOT}/build-pgouse/lib",
}
PREFIX = "/data/data/com.termux/files/usr"
CPU = int(sys.argv[1]) if len(sys.argv) > 1 else 7
PAIRS = int(sys.argv[2]) if len(sys.argv) > 2 else 5

FILES = [
    f"{SRC}/llvm/lib/Target/X86/X86ISelLowering.cpp",
    f"{SRC}/llvm/lib/Target/AArch64/AArch64ISelLowering.cpp",
    f"{SRC}/llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp",
    f"{SRC}/llvm/lib/CodeGen/SelectionDAG/DAGCombiner.cpp",
    f"{SRC}/clang/lib/Sema/SemaOpenMP.cpp",
    f"{SRC}/clang/lib/Sema/SemaExpr.cpp",
]

# optional 3rd arg: subset of basenames, for re-checking outliers with more pairs
if len(sys.argv) > 3 and sys.argv[3].strip():
    want = {x.strip() for x in sys.argv[3].split(",") if x.strip()}
    FILES = [f for f in FILES if os.path.basename(f) in want]
    print(f"[subset] {[os.path.basename(f) for f in FILES]}")

entries = {e["file"]: e for e in json.load(open(f"{ROOT}/build-pgouse/compile_commands.json"))}
tmpdir = tempfile.mkdtemp(prefix="pgobench_", dir=os.path.expanduser("~/.hermes/cache/scratch"))


def rewrite(cmd, cc, outpath, dpath):
    t = shlex.split(cmd)
    if "-include-pch" in t:                      # drop -Xclang -include-pch -Xclang P
        i = t.index("-include-pch")              #      -Xclang -include -Xclang H
        del t[i - 1:i + 7]
    t = [x for x in t if x != "-Winvalid-pch"]
    t[0] = cc
    if "-o" in t:
        t[t.index("-o") + 1] = outpath
    if "-MF" in t:
        t[t.index("-MF") + 1] = dpath
    return t


def run(t, env, cwd):
    t0 = time.perf_counter()
    pid = os.fork()
    if pid == 0:
        try:
            os.sched_setaffinity(0, {CPU})
            os.chdir(cwd)
            os.execve(t[0], t, env)
        except Exception:
            os._exit(127)
    _, status, ru = os.wait4(pid, 0)
    wall = time.perf_counter() - t0
    return (os.waitstatus_to_exitcode(status), wall, ru.ru_utime + ru.ru_stime)


def median(xs):
    s = sorted(xs); n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


print(f"\nCPU pinned = cpu{CPU}, pairs = {PAIRS} — arms paired back-to-back inside each repetition\n")
hdr = f"{'source':<28}{'B CPU(s)':>10}{'C CPU(s)':>10}{'median x':>10}{'quartiles':>20}{'dropped':>9}"
print(hdr)
print("-" * len(hdr))
all_ratios = []
for f in FILES:
    e = entries[f]
    base = os.path.basename(f)
    per = {"B_noPGO": [], "C_PGO": []}
    ratios, dropped = [], 0
    for _ in range(PAIRS):
        got = {}
        for name in ("B_noPGO", "C_PGO"):
            env = {
                "PATH": f"{PREFIX}/bin:/system/bin",
                "HOME": os.path.expanduser("~"),
                "LD_LIBRARY_PATH": f"{LIBS[name]}:{PREFIX}/lib",
                "TMPDIR": tmpdir,
            }
            t = rewrite(e["command"], CC[name],
                        f"{tmpdir}/{name}_{base}.o", f"{tmpdir}/{name}_{base}.d")
            rc, wall, cpu = run(t, env, e["directory"])
            if rc != 0:
                print(f"  !! {base} [{name}] rc={rc}")
                break
            if wall > cpu * 1.15:            # preempted: wall >> cpu
                dropped += 1
                break
            got[name] = cpu
        if len(got) == 2:
            per["B_noPGO"].append(got["B_noPGO"])
            per["C_PGO"].append(got["C_PGO"])
            ratios.append(got["B_noPGO"] / got["C_PGO"])
    if not ratios:
        print(f"{base:<28}  (no valid pair)")
        continue
    b, c = median(per["B_noPGO"]), median(per["C_PGO"])
    q = sorted(ratios)
    all_ratios.append(median(ratios))
    print(f"{base:<28}{b:>10.2f}{c:>10.2f}{median(ratios):>9.3f}x"
          f"   [{q[0]:.3f}, {q[-1]:.3f}]{dropped:>8}")
print("-" * len(hdr))
print(f"{'OVERALL median ratio':<28}{'':>10}{'':>10}{median(all_ratios):>9.3f}x"
      f"   (n={len(all_ratios)} files)")
print("\n(>1.0x = the profile-use compiler is faster; narrow quartiles = stable answer)")
