# CMake Cache, Regen, and Stale Build-Tree Pitfalls

Condensed from a real debugging session (2026-09-05, LLVM 23.1 stage1
restart on Termux/Android 16).

## 1. LD_PRELOAD masquerading as a binary dependency

Symptom:
```
CANNOT LINK EXECUTABLE ".../bin/mlir-linalg-ods-yaml-gen":
library "libpython3.14.so" not found: needed by main executable
```
but `readelf -d <binary>` shows only 5 clean NEEDED entries
(libc++_shared / libc / libLLVM / libm / libdl) and no libpython anywhere
in the closure.

Cause: the SESSION environment carries `LD_PRELOAD=libpython3.14.so`
(injected by terminal sandbox tooling; `env | grep -E 'LD_PRELOAD|LD_LIBRARY'`
shows it alongside `LD_LIBRARY_PATH=$PREFIX/lib`). Bionic resolves the
preload against the search path; when `LD_LIBRARY_PATH` is unset
(`env -u LD_LIBRARY_PATH ninja` — the old anti-hijack advice), the preload
dies and bionic phrases it as "needed by main executable".

Complication: MLIR host tools have a DIFFERENT RUNPATH from llvm-tblgen:
- `bin/llvm-tblgen` RUNPATH contains `...:/data/data/com.termux/files/usr/lib`
- `bin/mlir-linalg-ods-yaml-gen` RUNPATH does NOT (`$ORIGIN/../lib:...:<build>/lib` only)

So tblgen tools survive without LD_LIBRARY_PATH and the build gets ~1200
targets in before the first MLIR host tool exec fails.

Fix: build with the build tree FIRST, prefix second:
```bash
LD_LIBRARY_PATH=$BUILD/lib:$PREFIX/lib ninja -j4
```
This both keeps build-tree libs ahead of old installed ones (the original
hijack concern) and gives the preloaded libpython a resolution path.

Diagnostic rule of thumb: "needed by main executable" + clean readelf =
check the environment (LD_PRELOAD), not the ELF.

## 2. sed'ing CMakeCache.txt destroys the cache

Editing `CMAKE_*_COMPILER` / tool paths directly in CMakeCache.txt makes
the next regen print:
```
You have changed variables that require your cache to be deleted.
Configure will be re-run and you may have to reset some variables.
The following variables have changed:
CMAKE_ASM_COMPILER= ...
```
CMake then DELETES CMakeCache.txt and re-runs configure with the DEFAULT
generator. In the session this silently switched the build dir from Ninja
to Unix Makefiles (CMakeFiles/Makefile2 got written; rules.ninja never
came back). Recovery cost: full reconfigure; all recorded LLVM option
cache entries gone.

Correct move when the recorded toolchain path no longer exists: symlink the
missing tools AT the recorded path (see SKILL.md "CMake Cache and Regen
Pitfalls"). Command lines in regenerated build.ninja stay identical, so
ninja does no spurious work. Verify the symlink works by running
`<old>/bin/clang --version` before invoking ninja.

Relative symlink depth trap: links created in `build-stage1/bin/` pointing
to `../build-stage1-rc1/bin/x` resolve to
`build-stage1/build-stage1-rc1/bin/x` (broken). Use `../../`.

## 3. Recovering when rules.ninja is gone

`ninja` fails at parse time:
```
ninja: error: build.ninja:35: loading 'CMakeFiles/rules.ninja': No such file or directory
```
The RERUN_CMAKE rule cannot fire because ninja never finishes parsing.
Run the regen step manually (command is embedded in build.ninja):
```bash
cmake --regenerate-during-build -S <src>/llvm -B <build>
```
On success it rewrites build.ninja + CMakeFiles/rules.ninja and normal
incremental builds resume.

## 4. Anchoring a stale build tree

Build dirs record their source commit at configure time; a branch rebase
or re-create leaves them stranded. To decide "resume vs reconfigure":

```bash
cat build/include/llvm/Support/VCSRevision.h   # #define LLVM_REVISION "<sha>"
build/bin/clang --version                       # sha + LLVM version suffix
ls build/lib/libLLVM.so*                        # soname carries version
```

- `git merge-base --is-ancestor <sha> HEAD` fails → build is from a
  rewritten branch; treat as foreign.
- Soname/version suffix differs (`libLLVM.so.23.1-rc1` built tree vs final
  `23.1.0` source) → version bump changes generated headers everywhere;
  incremental reuse is impossible, full rebuild guaranteed.

Preserve, don't delete: `mv build-stage2 build-stage2-rc1`. A foreign-but-
complete tree still has value (reference artifacts, install-base recovery).

## 5. ExternalProject stamps cache a FAILED configure

An aborted sub-project configure is remembered by its **stamp**, not by its
cache: while `runtimes/<proj>-stamps/<proj>-configure` exists the configure step
is skipped on every later run, however broken its result.

Signatures of the broken state:

- `runtimes/<proj>-bins/CMakeCache.txt` has no `CMAKE_C_COMPILER_WORKS` — a good
  tree carries `:UNINITIALIZED=ON`
- the configure log says `The C compiler identification is unknown` and
  `Detecting C compiler ABI info - failed`
- the generated `build.ninja` is missing its real targets (an all-but-empty
  graph), so the sub-build reports `ninja: no work to do` and produces nothing

Downstream symptom in a runtimes build:
`Failed to find source files for aarch64 builtin library`, because the missing
builtins target never writes
`lib/clang/<ver>/lib/linux/clang_rt.builtins-<arch>-<os>.sources.txt`.

Fix: force a clean reconfigure by deleting the bins dir AND the stamps dir
(`rm -rf runtimes/{builtins,runtimes}-{bins,stamps}` and the
`*-clobber-stamp` files). Two traps while deleting:

- `*-patch-info.txt` / `*-update-info.txt` / `*-source_dirinfo.txt` are written
  by CMake at TOP-LEVEL configure time and are ninja inputs with **no
generating rule** — delete them and ninja refuses to parse
  (`missing and no known rule to make it`). Reinstate them from a healthy tree
  of the same source checkout (`cmp` to confirm byte equality) instead of
  re-running cmake: a top-level re-run regenerates `build.ninja`, and any
  changed command line cascades into a full PCH-driven rebuild.
- the clobber step runs `cmake -E touch <bins>/CMakeCache.txt`, and `cmake -E
touch` does **not** create directories: `mkdir -p` the bins dirs first or the
  step fails with `cmake -E touch: failed to update ...`.
