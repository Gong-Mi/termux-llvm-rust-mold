#!/usr/bin/env python3
"""Pin a build/merge process tree to one core cluster.

usage: pin-build-cores.py [N] [match_substr]

Picks the N cores with the LOWEST cpufreq max (on a 2-prime + 6-mid SoC that is
the 6-core mid cluster, leaving the prime cores to the system) and applies the
mask to every thread of the matched processes and their descendants.

CRITICAL: the SUPERVISOR (ninja) must be matched, not just the compilers.
sched_setaffinity is inherited, so a pinned ninja pins every compiler it will
ever spawn; a matcher that only finds the compilers alive right now silently
stops working as they are replaced by children of the still-unpinned ninja.
ninja's own cmdline ("ninja -j8") carries no build path, so a "cmdline contains
<build dir>" rule never matches it -- hence the explicit supervisor check.

Hazard: do not put the build-path substring in the very command line that runs
this script. The invoking shell's cmdline embeds the command text, so it matches
itself, becomes a root, and everything that shell later spawns inherits the mask.

Verify on the device afterwards (the summary line is NOT acceptance):
    awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -x ninja)/status
    ps -eLo psr,comm | awk '$1>=<lowest prime core> && $2 ~ /clang|ninja|ld.lld/'
"""
import os, glob, sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 6
MATCH = sys.argv[2] if len(sys.argv) > 2 else "llvm-termux/build"
SUPERVISORS = {"ninja"}


def cpu_freq(i):
    try:
        return int(open(f"/sys/devices/system/cpu/cpu{i}/cpufreq/cpuinfo_max_freq").read().strip())
    except Exception:
        return None


freqs = {i: cpu_freq(i) for i in range(os.cpu_count() or 8)}
small = sorted([i for i, v in freqs.items() if v], key=lambda i: freqs[i])[:N]
mask = set(small)

parents, cmds = {}, {}
for d in glob.glob("/proc/[0-9]*"):
    pid = int(os.path.basename(d))
    try:
        parents[pid] = int(open(d + "/stat").read().rsplit(")", 1)[1].split()[1])
    except Exception:
        continue
    try:
        cmds[pid] = open(d + "/cmdline", "rb").read().replace(b"\0", b" ").decode()
    except Exception:
        cmds[pid] = ""

children = {}
for pid, pp in parents.items():
    children.setdefault(pp, []).append(pid)


def is_supervisor(c):
    first = c.strip().split(" ")[0] if c.strip() else ""
    return os.path.basename(first) in SUPERVISORS


roots = {pid for pid, c in cmds.items() if MATCH in c or is_supervisor(c)}
seen, stack = set(), list(roots)
while stack:
    p = stack.pop()
    if p in seen:
        continue
    seen.add(p)
    stack.extend(children.get(p, []))

n = 0
for p in seen:
    if not os.path.exists(f"/proc/{p}/task"):
        continue
    for t in os.listdir(f"/proc/{p}/task"):
        try:
            os.sched_setaffinity(int(t), mask)
            n += 1
        except Exception:
            pass

# Report the supervisor's resulting affinity: the pin only holds if IT is
# restricted, since later-spawned children inherit from it.
allowed = "(no supervisor matched)"
for r in sorted(roots):
    try:
        for line in open(f"/proc/{r}/status"):
            if line.startswith("Cpus_allowed_list"):
                allowed = line.split()[1]
                break
    except Exception:
        continue
    break

print("small cores:", small, "| roots:", len(roots), "| pinned:", len(seen),
      "procs,", n, "threads | supervisor Cpus_allowed_list:", allowed)
