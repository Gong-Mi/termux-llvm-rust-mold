---
name: termux-llvm-bootstrap
description: "LLVM 23.1 stage1 bootstrap on Termux/Android AArch64: one libLLVM.so closure, LD_LIBRARY_PATH ordering, compiler-rt builtins, PCH config, rpath, and runtime sub-build pitfalls."
triggers:
  - "LLVM stage1 bootstrap Termux"
  - "构建 LLVM 23 自举"
  - "single libLLVM.so closure"
  - "LLVM 动态库闭包"
  - "compiler-rt builtins sub-build failure"
  - "cannot open libclang_rt.builtins.a"
  - "stage handoff build-tree clang resource dir"
  - "pause or resume a running ninja build"
  - "暂停 ninja 构建"
  - "LD_LIBRARY_PATH 劫持构建工具"
  - "DEFAULT_SYSROOT not working in build-tree clang"
  - "PCH 关闭"
  - "PCH built from a different branch"
  - "cc1as unknown target triple"
  - "libclang-cpp 编译器身份 / 树内 host 工具缺 libLLVM"
  - "ExternalProject stamp 缓存坏 configure"
  - "PGO 收益验证 / 编译器吞吐 A-B"
  - "clang 编 cpp 报 std::__ndk1 undefined（用了 C 驱动而不是 clang++）"
  - "mold 对安卓的支持 / A53 erratum 未修补 / mold -flto 无效"
  - "验证链接器产出的 ELF 安卓能不能用"
  - "ccache 加速 LLVM 编译"
  - "在设备上原生构建 rustc stage2 / rust 自举"
  - "pthread_cond_clockwait 未声明 / rust 链接 --target 缺 API 级别"
  - "cannot locate symbol LLVMInitializeAMDGPU* (rustc 运行时)"
  - "RUSTFLAGS 覆盖 cargo config 的 rustflags"
  - "x.py 报 stage0 checksum 缺失 aarch64-linux-android"
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [termux, android, llvm, bootstrap, stage1, dylib]
    related_skills: [termux-llvm-build, termux-llvm-patch-workflow, termux-llvm-dpkg-packaging]
---

# Termux LLVM Bootstrap

Building LLVM 23.1 from source on Termux/Android aarch64, producing a single
`libLLVM.so` closure usable by Rust, cargo, and mold.

## When to Use

- Building/rebuilding LLVM, clang, lld or compiler-rt on-device (stage1 or
  stage2), including PGO training/profile-use trees and ccache.
- A build-tree host tool, PCH, `clang -cc1as`, or a freshly built runtime fails
  for reasons that smell like a library-selection problem (`llvm-config`,
  `libLLVM`, `libclang-cpp`, `LD_LIBRARY_PATH`, `LD_PRELOAD`).
- Bootstrapping the rest of the toolchain on the result: native rustc stage2,
  then mold (with the Cortex-A53 843419 workaround).
- Packaging or repacking the toolchain as a `.deb` and verifying an installed
  one — including single-artifact repacks of a published base package.
- Planning long on-device builds: pinning to the mid cluster, wake locks,
  memory watch, pause/resume, and what counts as acceptance afterwards.

## Core Principle: One libLLVM.so

All tools (clang, lld, llvm-config, rustc, mold) link the SAME `libLLVM.so`.
Key CMake flags:

```
-DLLVM_BUILD_LLVM_DYLIB=ON
-DLLVM_LINK_LLVM_DYLIB=ON
-DCLANG_LINK_CLANG_DYLIB=ON
```

**One libLLVM also means one INSTALLED libLLVM.** Version agreement is not
enough: the prefix can hold several builds of the same version, and the
unversioned `libLLVM.so` symlink can point at an old `-rc1` while
`libLLVM.so.<ver>` is the good one — so consumers resolve a version they never
chose. Anything built against a FULL-target `libLLVM` then aborts at run time
(`cannot locate symbol LLVMInitializeAMDGPUAsmPrinter`) when it finds an
AArch64-only `libLLVM.so.<ver>` with the same name. Install the build you
actually want at `$PREFIX/lib/libLLVM.so.<ver>` and repoint the unversioned
symlink at it; a self-built rustc then runs with nothing but `$PREFIX/lib` on
the loader path, and clang/rustc stop using different copies.

## LD_LIBRARY_PATH Ordering (CRITICAL)

A persisted `LD_LIBRARY_PATH=$PREFIX/lib` from a previous session causes
freshly-built stage1 tools to load OLD system libraries instead of the
new build tree libs.  LD_LIBRARY_PATH takes priority over DT_RUNPATH.

**Symptom**: build-tree clang shows wrong version string, DEFAULT_SYSROOT
appears non-functional, runtimes sub-build fails with `pthread.h not found`.

**Detection**:
```bash
echo $LD_LIBRARY_PATH
# If it starts with $PREFIX/lib (not build/lib), old libs are hijacking
```

**Fix**: Always order build-lib FIRST:
```bash
export LD_LIBRARY_PATH=$BUILD/lib:$PREFIX/lib
ninja -j4
```

Or bake `$PREFIX/lib` into RUNPATH via `-Wl,-rpath,$PREFIX/lib` in linker flags,
then no LD_LIBRARY_PATH is needed.

**Do NOT `env -u LD_LIBRARY_PATH` to build** (previously recommended here):
sandboxed Termux sessions may inject `LD_PRELOAD=libpython3.14.so`
(check `env | grep -E 'LD_PRELOAD|LD_LIBRARY'`). With no search path, the
preload fails and EVERY host tool dies. MLIR host tools (e.g.
`mlir-linalg-ods-yaml-gen`) also have NO `$PREFIX/lib` in RUNPATH (unlike
llvm-tblgen, which does) — they cannot even find `libc++_shared.so` without
`LD_LIBRARY_PATH`. `env -u` is only safe when the session has no LD_PRELOAD
and every tool's RUNPATH carries `$PREFIX/lib`.

**Bionic's misleading error**: `CANNOT LINK EXECUTABLE "...": library
"libpython3.14.so" not found: needed by main executable` while `readelf -d`
shows NO such NEEDED entry = the dependency comes from the ENVIRONMENT
(LD_PRELOAD), not the binary. Don't burn time decoding .dynamic by hand;
check the environment first.

See `references/ld-library-path-hijack.md` for full diagnosis and
`references/cmake-cache-and-regen-pitfalls.md` for cache corruption and
stale-build-tree anchoring.

## Compiler identity: libclang-cpp, PCH, and the shim

With `CLANG_LINK_CLANG_DYLIB=ON` the **whole driver** — version string,
repository revision, PCH validation — lives in `libclang-cpp.so.<ver>`, not in
the thin `clang-23` binary. The library a compiler process *loads* therefore
defines its identity:

- installed `$PREFIX/bin/clang-23` + `$PREFIX/lib/libclang-cpp.so.23.1`
  reports the installed revision (e.g. `e3f9cdcbe52a`)
- the same binary with the tree's lib dir first reports the TREE revision
  (e.g. `d31e5ec408f0`)

Cheapest detector for "which libLLVM is this driver actually using":
`clang --print-targets | wc -l`, plus `llvm-config --targets-built`. A tree
configured with `LLVM_TARGETS_TO_BUILD=all` (plus experimental targets) lists
dozens of targets; an AArch64-only install lists 5 (the aarch64/arm64 family).
Five means the driver is resolving someone else's `libLLVM`, not that the build
dropped targets — so this one command is also the construction acceptance for an
all-targets build.

Consequences when resuming a **partially built** tree:

- every `cmake_pch.hxx.pch` records the identity that built it; swap the loaded
  `libclang-cpp` and every PCH-using TU fails with
  `error: PCH file ... built from a different branch (...) than the compiler (...)`
- `.pch` is an **explicit input** of each object edge, so deleting one to force
  a rebuild recompiles every dependent edge. Measure first:
  `grep -c 'cmake_pch.hxx.pch' <build>/build.ninja` (6125 edges in a full tree).
- regenerating `build.ninja` (top-level `cmake` re-run) carries the same hazard:
  any changed command line cascades into the same mass rebuild. Reinstate
  missing CMake-generated files by hand rather than re-running cmake.

Three requirements conflict and one `LD_LIBRARY_PATH` cannot satisfy all:

1. main build keeps the **installed** `libclang-cpp` (PCH identity)
2. build-tree host tools need the tree's full-backend `libLLVM`
   (`mlir-irdl-to-cpp` etc. — otherwise
   `cannot locate symbol LLVMInitializeAMDGPUTarget`)
3. the tree's **own** clang (builtins/runtimes sub-builds) must pair with the
   tree's `libclang-cpp`; old `libclang-cpp` + new `libLLVM` gives
   `clang -cc1as: error: unknown target triple 'unknown'`

Resolution — shim directory + two phases:

```bash
# shim: the tree's *.so* EXCEPT libclang-cpp*
SHIM=$HOME/llvm-termux/libshim; rm -rf "$SHIM"; mkdir -p "$SHIM"
for f in "$BUILD"/lib/*.so*; do
  b=$(basename "$f"); case "$b" in libclang-cpp*) continue;; esac
  ln -sf "$f" "$SHIM/$b"
done

# phase 1 — main graph; -k0 rides past the expected ExternalProject failures
LD_LIBRARY_PATH=$SHIM:$PREFIX/lib ninja -j8 -k0 > "$LOG1" 2>&1
# phase 2 — externals only; no PCH edge is left, so tree-first is now safe
LD_LIBRARY_PATH=$BUILD/lib:$PREFIX/lib ninja -j8 > "$LOG2" 2>&1
```

Phase 1 exits non-zero **by design** (the runtimes/builtins steps cannot succeed
under the shim). Gate on phase 2 reaching `Completed 'runtimes'` and exiting 0,
never on phase 1.

Pre-flight the fix (four cheap checks, all must pass): the previously failing
host tool runs (`<tree>/bin/<tool> --help`); the installed compiler still
reports its own revision; a trivial `.S` assembles under BOTH environments;
the tree's clang links a trivial program.

## compiler-rt: Android Builtins Library

compiler-rt's `COMPILER_RT_USE_BUILTINS_LIBRARY` defaults to OFF for
Android, but should be ON (like Fuchsia).  Shared sanitizer runtimes
(asan, hwasan, ubsan) link with `-nodefaultlibs -Wl,-z,defs` by default.
Two symbol families fail for two different reasons: builtins symbols
(`__aarch64_{cas,swp,ldadd}*`, `__extendsftf2`) need the in-tree
`libclang_rt.builtins.a` linked in (Android has no libgcc), while C++ ABI
symbols (`__dynamic_cast`, typeinfo, `__cxa_begin_catch`) are resolved at
load time by the host process and must be allowed to stay undefined.  One
flip fixes both: with builtins ON, compiler-rt links the archive into each
shared runtime AND strips `-Wl,-z,defs` from `CMAKE_SHARED_LINKER_FLAGS`
itself (`HandleLLVMOptions`, included by `llvm/runtimes`, is where
`-z,defs` enters the build).

**Source patch** (`compiler-rt/CMakeLists.txt` line 319):
```diff
 set(DEFAULT_COMPILER_RT_USE_BUILTINS_LIBRARY OFF)
-if (FUCHSIA)
+if (FUCHSIA OR ANDROID)
   set(DEFAULT_COMPILER_RT_USE_BUILTINS_LIBRARY ON)
 endif()
```

Without this, every shared sanitizer library fails to link with:
```
undefined reference to `__extendsftf2'
undefined reference to `__dynamic_cast'
undefined reference to `typeinfo for std::type_info'
```

**Applying it to an ALREADY-configured tree**: the option is CACHED, so the
new source default changes nothing until the runtimes sub-build re-reads it.
Reconfigure in place, then verify the regenerated link command BEFORE
building anything:

```bash
cd <build>/runtimes/runtimes-bins
cmake -U COMPILER_RT_USE_BUILTINS_LIBRARY .     # CMakeCache then shows :BOOL=ON
ninja -t commands <path/to/libclang_rt.<x>-aarch64-android.so> | tail -1 \
  | grep -c 'Wl,-z,defs'                        # expect 0; builtins .a at link tail
```

Linked-in builtins archive members land as LOCAL symbols — `llvm-nm -D
--defined-only` will NOT list them; check the full symtab with plain
`llvm-nm`.  The correct `.so` NEEDED set stays libc/libdl/liblog (libm for
asan), with the C++ ABI symbols left `U` on purpose.

See `references/compiler-rt-android-builtins.md` for full explanation.

## PCH Disabling

LLVM 23 uses CMake's `target_precompile_headers`.  The correct variable is
`CMAKE_DISABLE_PRECOMPILE_HEADERS=ON`, NOT `LLVM_ENABLE_PCH=OFF` (which
doesn't exist in LLVM 23).

PCH is controlled by `HandleLLVMOptions.cmake:1339`:
```cmake
if(NOT DEFINED CMAKE_DISABLE_PRECOMPILE_HEADERS)
  # ... PCH on by default
endif()
```

## ccache Integration

```cmake
-DCMAKE_C_COMPILER_LAUNCHER=ccache
-DCMAKE_CXX_COMPILER_LAUNCHER=ccache
```

Termux: `pkg install ccache`.  No wrapper scripts needed — cmake passes
the launcher to every compile command.

## RUNTIMES_* Variable Naming

The passthrough mechanism in `llvm/runtimes/CMakeLists.txt` uses
`append_passthrough_options(${name}_extra_args BUILTINS ${name})` where
`${name}` is the target triple (e.g. `aarch64-unknown-linux-android30`).

Variables must be named with the full triple:
```
-DRUNTIMES_aarch64-unknown-linux-android30_COMPILER_RT_INCLUDE_TESTS=OFF
```

Plain `-DRUNTIMES_COMPILER_RT_INCLUDE_TESTS=OFF` (without triple) does
NOT match the passthrough pattern and is silently ignored.

## Failure Capture and Acceptance Boundaries

Do not diagnose a failed full build from `ninja ... | tail -N`: the actual
`error:` or `FAILED:` command may have scrolled out, leaving only harmless
warnings. Preserve a complete build-local log, then inspect its first failure:

```bash
cd <build>
LD_LIBRARY_PATH=$PWD/lib:$PREFIX/lib ninja -j<jobs> > ninja-full.log 2>&1
```

If a retry later passes the reported source location, the earlier root cause is
unidentified unless that full log proves it. Do not attribute the failure to
trailing warnings.

### Resuming an interrupted stage1 build

A stale `STAGE1_EXIT` marker or an old progress line is not live state. Before
starting another builder, verify the process table with a pattern that cannot
match the inspection shell itself (for example `pgrep -af '[n]inja'`) and read
the final lines of the current log. If no builder is running, resume the same
validated tree incrementally rather than configuring from scratch:

```bash
cd <build>
export LD_LIBRARY_PATH=$PWD/lib:$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
ninja -C "$PWD" -j8 > "$HOME/stage1-build-j8.log" 2>&1
rc=$?
printf 'STAGE1_J8_EXIT=%s\\n' "$rc" >> "$HOME/stage1-build-j8.log"
```

Use a new log for a new attempt. Do not infer a current failure from an
appended historical log, and do not launch a second ninja against the same
build tree. A successful incremental resume must still be checked by its own
exit marker and by inspecting the first new `FAILED:`/`error:` block.

For a live status report, collect these independently: (1) a process check
using a self-excluding pattern, (2) the newest progress line from this
attempt's log, (3) this attempt's exit marker, and (4) the first new
`FAILED:`/`error:` block if it stopped. Do not report an old `STAGE1_EXIT`
marker as a current failure. Ninja's `[x/y]` counter is the current generated
graph/attempt, not necessarily the original full-stage target count; report it
literally rather than converting it to a misleading percentage.

### Pausing and resuming a running build

Pause with `kill -STOP <ninja-pid>` on the NINJA PID ONLY — never the
process group, never the compile children.  Ninja freezes instantly; the
in-flight jobs drain on their own and become zombies until resume (that is
the clean state, not a hang).  Zero compiled work is lost; only wall-clock
elapsed keeps growing.  Log the event so later process-table checks are not
misread:

```bash
kill -STOP <ninja-pid>
printf '# PAUSED_SIGSTOP %s pid=<ninja-pid>\n' "$(date '+%F %T')" >> <build-log>
# resume:
kill -CONT <ninja-pid>
printf '# RESUMED_SIGCONT %s\n' "$(date '+%F %T')" >> <build-log>
```

Do NOT stop the children instead: a resumed ninja waits forever on frozen
children, and one forgotten `SIGCONT` stalls the build with no error.

Pausing the build means pausing its sidecars too: stop the `memwatch.py`
helper (a frozen ninja makes it append an identical row every interval, so the
CSV grows without bound) and release the wake lock (a frozen build needs none).
On resume: `-CONT`, re-apply the core pinning, restart the monitor, re-take the
wake lock — a re-pinned, re-locked build is the only state you can report on
honestly.

A pause only survives as long as the process does. After a reboot or session
teardown the pid is gone, but the tree is still incremental — every compiled
`.o` is on disk, so relaunching the same driver script (with a NEW log and exit
marker) rebuilds only what is missing. Record BOTH resume paths next to the
pause marker (`kill -CONT <pid>` while alive; rerun the driver after a reboot)
so the next session does not rediscover them, and never quote a pid that a
reboot has already invalidated.

Liveness checks: on this Termux setup, `ps ... comm` can show a truncated
exec path for LIVE processes (only zombies show the real basename plus
`<defunct>`), so `ps -eo stat,comm | grep <tool>` yields false negatives
mid-build.  Use a self-excluding `pgrep -af <pattern>`, `ps --ppid
<ninja-pid>`, or `ps -ef`.

Never clean up with `pkill -f <pattern>`: the invoking shell's own command line
contains the pattern text, so the pattern matches that shell and the kill
terminates your own command (and everything it was about to run). `pgrep` first,
then `kill` the PIDs explicitly — and when the pattern is the thing you are
searching for, bracket one character (`[p]attern`) so it cannot match itself.

Keep two acceptance questions separate:

1. **Construction**: expected LLVM artifacts (e.g. `clang`, `lld`,
   `llvm-config`, `libLLVM.so`, selected project tools, compiler-rt builtins)
   exist and run as build-tree tools.
2. **User-program runtime closure**: a program newly linked by build-tree
   clang can find its C++ runtime in the intended execution environment.

A runtime-library search-path failure in the second test does not mean an LLVM
tool or project was omitted from the first.

### Measuring the second question without fooling yourself

Two traps here have produced confidently wrong conclusions:

- **`clang` is not `clang++`.** The C++ stdlib link is emitted by `Gnu.cpp`
  behind `D::CCCIsCXX()`, i.e. `Mode == GXXMode`, set by the **invoked binary
  name** (or `--driver-mode=`), never by the input file's extension — the
  extension picks the LANGUAGE, the mode picks the DEFAULTS. `clang foo.cpp`
  compiles C++ happily and then leaves every `std::__ndk1::...` symbol
  undefined, and `clang -x c++ foo.cpp` behaves identically because `-x` changes
  only the language — that is driver mode, not a broken `-lc++_shared` patch.
  Test C++ closure with the C++ driver: the link line from
  `clang++ -### … | tail -1` must contain `-lc++_shared`, and a bare
  `clang++ … -o out && ./out` must run. Version-suffixed names fall back to the
  same entry (`clang++-23` is a C++ driver), but a plain `clang-23` is not.
- **Clear the injected environment before probing or comparing.** With the
  build tree on `LD_LIBRARY_PATH`, the *installed* clang loads the tree's
  `libclang-cpp` and silently behaves like the tree under test (it starts
  emitting the tree's `-rpath`), so an install-vs-tree comparison measures
  nothing. A sandbox-injected `LD_PRELOAD=libpython3.14.so` additionally makes
  a freshly built binary die with `CANNOT LINK EXECUTABLE` — an environment
  artifact, not a link defect. Use `env -u LD_LIBRARY_PATH -u LD_PRELOAD <cmd>`
  for both the link-line probe and the run.

Never "repair" a driver patch back to `-lc++`: the driver adds
`-L/system/lib64`, where Android's platform `libc++.so` lives (namespace
`std::__1`), so `-lc++` silently binds the wrong library and every `__ndk1`
symbol stays undefined with no missing-library error.

## CMake Cache and Regen Pitfalls

**Never `sed` compiler/tool paths inside `CMakeCache.txt`.** CMake detects
the change, prints `You have changed variables that require your cache to be
deleted`, DELETES the cache, and re-runs configure with the DEFAULT generator
(Unix Makefiles) — the original Ninja generator setting and every cached LLVM
option are lost, and the build dir is effectively corrupted. If the recorded
tool path no longer exists (e.g. an old stage1 dir was gutted), create
SYMLINKS at the recorded paths instead:
```bash
for f in $OLD_STAGE/bin/*; do
  b=$(basename "$f")
  [ -e "$NEW_STAGE/bin/$b" ] || ln -sf "$NEW_STAGE/bin/$b" "$OLD_STAGE/bin/$b"
done
```
Regenerated build.ninja command lines then stay byte-identical and ninja
rebuilds nothing spuriously. (Watch relative-symlink depth: from
`build-stage1/bin` the target needs `../../build-stage1-rc1/bin/$b`.)

**Missing `CMakeFiles/rules.ninja` blocks ninja at parse time** (`include
CMakeFiles/rules.ninja` fails before the RERUN rule can fire). Heal manually:
```bash
cmake --regenerate-during-build -S <src>/llvm -B <build>
```
Once regen succeeds, ninja resumes normal dependency checking.

**Anchor a stale build tree before resuming it.** A build dir remembers its
source commit, not its branch:
```bash
cat <build>/include/llvm/Support/VCSRevision.h      # recorded source sha
<build>/bin/clang --version                          # sha + version suffix
ls <build>/lib/libLLVM.so*                           # soname version
```
Then `git merge-base --is-ancestor <sha> HEAD`. If the sha is not an ancestor
(branch was rebased) or the version suffix differs (`libLLVM.so.23.1-rc1` vs
final `23.1.0`), incremental reuse is impossible — the version bump alone
forces a full rebuild. `mv build-stage2 build-stage2-rc1` to preserve the old
tree and configure a fresh one.

## Install: Bypass the Runtimes Failure + libclang-cpp Staleness

`ninja install` (full) FAILS at the runtimes stage on Termux. The compiler-rt
sanitizer sub-build (`runtimes/runtimes-bins`) does NOT inherit the top-level
`--sysroot` / `-L$PREFIX/lib -L/system/lib64` flags, so linking the shared
sanitizers dies with:

```
ld.lld: error: cannot open crtbegin_so.o: No such file or directory
ld.lld: error: unable to find library -lc / -ldl / -lm / -lpthread
```

This blocks the full install BEFORE the core libs get installed. Do NOT try to
fix runtimes first — install the toolbox per-component and skip runtimes:

```bash
cd build-stage2
ninja install-clang install-lld install-llvm-ar install-llvm-nm \
      install-llvm-objdump install-llvm-readobj install-llvm-config \
      install-clangd install-clang-format install-clang-tidy \
      install-llvm-cov install-llvm-profdata install-llvm-symbolizer \
      install-llvm-dwarfdump install-llvm-mc install-llvm-objcopy \
      install-llvm-strip install-llvm-ranlib install-scan-build
# THEN the critical libs (see below):
ninja install-clang-cpp install-llvm-libraries
```

**libclang-cpp staleness trap (CRITICAL)**: with `CLANG_LINK_CLANG_DYLIB=ON`,
the driver logic (DEFAULT_SYSROOT, the `/system/lib64` fallback in Linux.cpp,
`-lc++_shared`) lives in `libclang-cpp.so.23.1-rc1`, NOT in the thin `clang-23`
binary. A partial/aborted install leaves a NEW `clang-23` binary linked against
the OLD pre-existing `libclang-cpp.so.23.1-rc1` in `$PREFIX/lib`. Result:
installed `clang hello.c` STILL fails `unable to find library -lc` even though
the binary is fresh.

**Detection**:
```bash
strings $PREFIX/lib/libclang-cpp.so.23.1-rc1 | grep 'system/lib64'
# empty output = OLD lib (patch missing); non-empty = new lib
ls -la $PREFIX/lib/libclang-cpp.so.23.1-rc1   # compare date/size vs build tree
```

**Fix**: `ninja install-clang-cpp install-llvm-libraries`, then re-verify the
strings check is non-empty and a bare `clang hello.c && ./a.out` runs.

Sanitizers (asan/tsan/ubsan/hwasan) are NOT installed by this path — only
builtins (`libclang_rt.builtins.a`). That is acceptable for the toolbox
acceptance; sanitizer runtimes need the runtimes sub-build fixed separately.

## Stage2 → Rust/Mold Closure Verification

After stage2 LLVM builds, verify the full dynamic-link closure before packaging.

### libLLVM SONAME Symlink (CRITICAL for Rust)

Rust's `rustc_llvm/build.rs` calls `llvm-config --link-shared --libs`, which
looks for the SONAME `libLLVM-23-rc1.so`. But the build tree produces
`libLLVM.so.23.1-rc1` (versioned filename). Without a symlink:

```
llvm-config: error: libLLVM-23-rc1.so is missing
```

**Fix** (apply to BOTH build tree and $PREFIX/lib):
```bash
ln -sf libLLVM.so.23.1-rc1 $BUILD/lib/libLLVM-23-rc1.so
ln -sf libLLVM.so.23.1-rc1 $PREFIX/lib/libLLVM-23-rc1.so
```

### Cargo Location

cargo is in `stage2-tools-bin/`, NOT `stage2/bin/`:
```
build/<triple>/stage2/bin/rustc          ← rustc
build/<triple>/stage2-tools-bin/cargo    ← cargo (easy to miss)
```

### rustc→libLLVM Closure Check

Verify rustc dynamically links the stage2 LLVM (not static, not system):
```bash
readelf -d build/<triple>/stage2/lib/librustc_driver-*.so | grep NEEDED
# Must show: libLLVM.so.23.1-rc1
```

### Mold with Stage2 Clang

mold's build system changed at 2.42.1 — check which shape the checkout is
BEFORE reaching for the old recipe:

- **≤ 2.41**: CMake project. `cmake .. -DCMAKE_C_COMPILER=$BUILD/bin/clang
  -DCMAKE_CXX_COMPILER=$BUILD/bin/clang++ -DCMAKE_BUILD_TYPE=Release
  -DMOLD_LTO=OFF && make -j8` — ~5 min on 8 cores, standalone binary (no
  libLLVM dependency), no patches needed.
- **≥ 2.42.1**: no `CMakeLists.txt` exists. It is a Cargo workspace — the root
  `mold` crate is the linker library, `arch/*` is one crate per target, `cli`
  carries `[[bin]] name = "mold"`, `tests` the suite. `build.rs` compiles only
  two small C parts through the `cc` crate (`mold-wrapper.so` for `mold -run`,
  `lto-message.c`), so `CC`/`CXX` choose the compiler for those and there is no
  prebuilt-artifact download to trip over. Cargo's default features enable all
  20 targets (the shipped binary advertises ~19 targets / 22 emulations);
  `--no-default-features --features arm64` builds far faster when only the host
  target is wanted. Budget it as a multi-core Rust build of 20 target crates,
  not the old five minutes.

Two traps specific to a Termux host:

- `rust-toolchain.toml` pins `channel = "stable"`. Only rustup reads it — with a
  packaged `rustc`/`cargo` on PATH it is inert, but if a rustup shim shadows
  them the build silently switches toolchain (and may download one). Keep the
  packaged toolchain first in PATH.
- The Termux TLS fix changed language with the rewrite: for ≥ 2.42.1 it patches
  **Rust** — `src/passes.rs`, flooring the output `SHF_TLS` section's `p2align`
  at 6 on Arm64 so the program header inherits `p_align >= 64`. Without it,
  mold-linked executables abort at startup with Bionic's `TLS segment is
  underaligned` (same requirement as the lld patch above, different program).

Pin the checkout to the commit the shipped binary reports (`mold --version`
prints `2.42.1 (<sha>; compatible with GNU ld)`) so the rebuild is the version
the package claims; the nearest tag alone is not it — that string can come from
hundreds of commits past the tag.

### Is mold's Android output actually usable?

Usually yes, and the interesting failures are narrow. Check them in this order
before blaming the linker, or before claiming it has no Android support:

- **mold does accept Android-default flags it never implements — which is why
  our fork implements one of them.** Upstream's `--fix-cortex-a53-843419`
  (clang passes it on every arm64 link line) and `--fix-cortex-a53-835769` sit
  in mold's `// Ignored for compatibility.` chain with no implementation and no
  `--help` entry, while lld implements the 843419 fix — so an upstream-mold
  arm64 Android binary is silently unpatched for the Cortex-A53 erratum. Take
  every flag from the driver's `-###` tail and check it against the linker's
  `--help`: "accepted" says nothing about "implemented".
- **Port a workaround's PREMISES along with its logic.** lld skips a site whose
  relocation is a TLS IE one *because lld's own TLS IE→LE relaxation rewrites
  the ADRP into a MOVZ* and the sequence disappears; mold implements no AArch64
  TLS relaxation at all (its `--relax` covers RISC-V and LoongArch, and the
  arm64 module notes GD→LE relaxation is deliberately absent). Mirroring that
  skip therefore leaves a LIVE erratum in mold's output. Before copying any
  skip/bail-out condition out of the reference implementation, locate the pass
  it depends on in yours.
- **`clang -fuse-ld=mold` execs `ld.mold`, not `mold`.** An unpatched `ld.mold`
  in the installed prefix silently takes the link — that is exactly how a
  "self-linked binary still carries 3 erratum sites" verdict turned out to be
  upstream mold ignoring the flag. Name the path explicitly
  (`-fuse-ld=<abs path>`) and confirm which implementation ran by grepping for a
  string only it has: `grep -ac cortex-a53-843419 <binary>` is 1 in the
  flag-only upstream build and 4 with the implementation.
- **`-flto` + mold links but does not optimize** (it keeps the statically linked
  `libunwind.a` members lld drops — several times the `.text`), and it needs
  `LLVMgold.so` at the driver's own `<bin>/../lib/`, which a tree built without
  binutils' `plugin-api.h` never produces. lld's LTO is in-process and needs no
  plugin, so when LTO matters use lld.
- **Probe the artifact, not your memory of the flags**: PIE is mandatory for
  executables (an `ET_EXEC` image is refused at load), `PT_TLS.p_align >= 64` on
  arm64, and 16 KB segment alignment only matters on 16 KB-page kernels — read
  `getconf PAGE_SIZE` first. Run `scripts/elf-android-check.py <elf>`.

The patch chain reloads `target/release/mold` on every rebuild: after building a
control with the TLS patch reverted, re-apply the patch and rebuild, or a later
packaging step copies the broken-TLS variant. Same source plus same environment
is byte-identical, so a rebuild can be checked against a saved hash. See
`references/mold-android-linker.md` for the erratum reproduction, the 843419
implementation and its acceptance harness, the standalone `LLVMgold.so` recipe,
and the LTO measurements.

### Full Tool Verification Sequence

After stage2 + Rust + mold build, verify ALL tools before packaging:

```bash
S2=$HOME/llvm-project/build-stage2/bin
# Core: clang C, clang++ C++20, TLS pthread test
# LLVM tools: llvm-ar, llvm-nm, llvm-objdump, llvm-readelf, llvm-strip,
#   llvm-cov, llvm-dwarfdump, llc (IR→obj), opt (IR optimize), llvm-mc (assembler)
# Linkers: ld.lld --version, wasm-ld --version, mold --version + link test
# Dev tools: clangd --version, clang-tidy --version, clang-format (pipe test)
# Config: llvm-config --version --targets-built --shared-mode
# Rust: cargo init + build --release (HashMap/Arc/thread/enum/match/closure)
# Closure: readelf -d librustc_driver-*.so | grep NEEDED → libLLVM.so.23.1-rc1
```

All 17 tools verified in session 2026-07-28. See `references/closure-verification.md`.

### Packaging Pitfalls (dpkg-deb)

- **DEBIAN dir permissions**: `mkdir -p` creates mode 700; dpkg-deb requires ≥755.
  Fix: `chmod 755 $STAGE/DEBIAN` before `dpkg-deb --build`.
- **API level migration**: upgrading API24→API30 leaves old
  `lib/clang/23/lib/aarch64-unknown-linux-android24/` that dpkg can't remove
  (directory not empty). Clean manually after install:
  `rm -rf $PREFIX/lib/clang/23/lib/aarch64-unknown-linux-android24`
- **compiler-rt API-suffix symlink (CRITICAL)**: the build produces runtimes
  under `aarch64-unknown-linux-android30/` but clang's driver and cargo/cc-rs
  build scripts look for the **unsuffixed** triple directory
  `aarch64-unknown-linux-android/`. Without a symlink, ANY linking compilation
  (including `cargo install` of crates with C deps) fails:
  `ld.lld: error: cannot open .../aarch64-unknown-linux-android/libclang_rt.builtins.a`.
  Fix (must ship in the .deb):
  `ln -sf aarch64-unknown-linux-android30 $PREFIX/lib/clang/23/lib/aarch64-unknown-linux-android`
- **Large package compression**: 280M .deb takes >2min to compress. Run
  `dpkg-deb --build` in background with notify_on_complete.
- **Ship the toolchain as a set**: Rust stage2 and mold both relink against the
  new `libLLVM`, so the final package carries LLVM + Rust + mold together. When
  those relinks are still pending, finish the LLVM build but leave packaging
  deferred — publishing a LLVM-only deb first produces a package that cannot be
  installed alongside the toolchain it belongs to.
- **Packaging script**: `~/build-toolchain-deb.sh` (7-step: cmake --install,
  compiler-rt+LLVMgold, rust stage2, mold, symlinks, RUNPATH+linker-scripts,
  DEBIAN/control+build).
- **Ship a one-artifact fix by repacking the published base `.deb`** — not by
  rebuilding the whole toolchain, and never by `cp` into `$PREFIX`. Extract the
  data layer (`dpkg-deb --fsys-tarfile base.deb | tar xf - -C $STAGE`), swap the
  file preserving its mode (`stat -c %a` first), guarantee `bin/ld.mold -> mold`,
  reuse the base's `DEBIAN/` control with only Version/Installed-Size rewritten
  (Replaces/Provides/Conflicts verbatim), rebuild with
  `dpkg-deb --build --root-owner-group -Zxz -z6`, then read the file BACK out of
  the built package and compare hashes —
  `tar -xO "./${PREFIX#/}/bin/mold"` piped to `sha256sum` is the only proof the
  swap landed, and exit 0 from the build proves nothing. Other traps:
  `--fsys-tarfile` members are `./`-prefixed relative paths with no leading
  slash; `$PREFIX` already ends in `/usr`, so staged paths are
  `$STAGE$PREFIX/bin/...`; the base's entry count (`dpkg-deb -c | wc -l`) is the
  regression check that nothing else moved; `dpkg -i --no-act` is the dry run.
  Test the swap script against a miniature synthetic base `.deb` before spending
  a 300 MB download and a multi-minute xz.
- **Prove a repacked artifact's effect before installing it.** Extract the new
  `bin/` into a scratch dir, put that dir FIRST on `PATH`, and run the real
  driver path there (`clang --target=<android triple> -fuse-ld=mold ...`) with
  the installed binary as the control arm — the new one must do what the old one
  does not. Installing then is a formality rather than the test.
- **The package must own both `bin/mold` and `bin/ld.mold -> mold`**:
  `clang -fuse-ld=mold` execs `ld.mold`, so a package carrying only `mold` lets
  the driver fall through to whatever `ld.mold` it finds first.
- **Post-install reclaim**: once the .deb is installed and `readelf -d` confirms
  `$PREFIX/bin/clang` and `librustc_driver-*.so` need only `$ORIGIN/../lib`
  libs, every build-stage tree (build-stage1*, build-stage2*, rust `build/`) is
  regenerable — deletable after the deb is verified on disk. See
  git-repo-dedup-and-archival §3a for the full gate list.

### TLS Acceptance Test

The lld TLS patch (PT_TLS p_align) is verified with a pthread `__thread` test.
See `references/closure-verification.md` for the full test program and
verification sequence.

## Rust stage2: native on-device build (host == target == android)

Rust's bootstrap publishes NO prebuilt stage0 for `aarch64-linux-android` as
HOST, so an unconfigured `x.py` dies at once with
`src/stage0 doesn't contain a checksum for dist/<date>/rustc-beta-aarch64-linux-android.tar.xz`.
Point `[build] rustc`/`cargo` at the installed toolchain of the SAME version as
the source tarball, with `host == target == aarch64-linux-android`: a native
build needs no NDK and none of Termux's x86_64-cross machinery. Full recipe,
patch series and scripts: `references/rust-stage2-native-build.md`.

Six rules, each bought with a failed run:

- **The target must carry the API level.** cc-rs and rust pass
  `--target=aarch64-linux-android`; clang then picks a low default API, and the
  installed libc++ (built for API 30) references `pthread_cond_clockwait`, which
  bionic declares only at API >= 30 — `error: use of undeclared identifier`.
  Wrap `cc`/`cxx`/`linker` to rewrite the triple to `-android30`, AND export
  `CC_/CXX_aarch64_linux_android`: `~/.cargo/config.toml` otherwise wins for
  cc-rs and the wrapper never runs.
- **Never put a build tree's `lib/` on `LD_LIBRARY_PATH` for this build.** The
  host clang loads that tree's `libclang-cpp`, loses target registration and
  dies with `clang -cc1as: error: unknown target triple 'unknown'`. Instead
  point `llvm-config` at that tree (rustc_llvm then links its full-target
  `libLLVM`) and expose the LLVM shared objects through a SHADOW DIR containing
  only `libLLVM*.so*`, placed first.
- **LD_LIBRARY_PATH beats RUNPATH outright**, so rpath cannot rescue a runtime
  lookup: RUNPATH order is decided by the linker (observed
  `$PREFIX/lib` before the tree), and a `sort`-looking reorder is not on offer.
  The shadow dir is the only reliable lever for the runtime half.
- **`llvm-config --link-shared --libs` demands `libLLVM-23.so`** while the tree
  only produces `libLLVM.so.23.1` → `llvm-config: error: libLLVM-23.so is
  missing`. Symlink it inside llvm-config's OWN libdir; a shadow dir is not
  consulted for this check.
- **An explicit `RUSTFLAGS` REPLACES `[target.*] rustflags` from
  `~/.cargo/config.toml`** — cargo does not merge them. Drop the rpath and a
  green build still produces a binary that dies with
  `library "libz.so.1" not found` at run time (every rustc/mold here NEEDs
  `libz.so.1`; check `readelf -d` before blaming a linker difference).
- **Rust's own manifest lints are escalated by `build.warnings = deny`.** Fix
  the false positives per manifest with `[lints.cargo] unused_dependencies =
  "allow"` (std's `panic_abort`, sysroot's
  `proc_macro`/`profiler_builtins`/`test` — all referenced only through
  attributes) instead of disarming the setting, and re-derive upstream patch
  premises when the nightly moves: an android `cfg` change can make
  `#![expect(unused_crate_dependencies)]` unfulfilled, and that is a build error
  here.

Validate the wiring in minutes, not hours: `x.py check --stage 1 library/std`
compiles the whole compiler tree without codegen and exercises stage0, the
wrappers, llvm-config and the link flags; with a green check the real
`x.py build --stage 2` finished in ~19 minutes on 8 cores. Running the built
compiler needs its own sysroot lib dir plus the full-target `libLLVM` on the
loader path — gate on compiling AND running a program, then close the loop by
rebuilding mold with the self-built `cargo`/`rustc` and re-running the erratum
residual scan.

## Bootstrap Stage Definitions

| Stage | Definition | Acceptance |
|-------|-----------|------------|
| stage1 | Build LLVM with system compiler | Produces clang, lld, llvm-config |
| stage2 | Build with stage1 (full toolbox) | All projects + runtimes + targets |
| closure | stage2 tools run independently | No LD_LIBRARY_PATH, all bin from build tree |
| repro | stage3 = stage2 rebuilds itself | Binary-identical outputs |

## Stage2 handoff and background-build completion

Stage2 must not reuse a stale tree merely because it contains `CMakeCache.txt`.
If the cache was configured before stage1 existed, CMake can record paths such as
`build-stage1/bin/clang` and later fail with `is not a full path to an existing
compiler tool`. Preserve that tree as an evidence archive and configure a fresh
stage2 directory with the completed stage1 compiler; do not edit compiler paths
inside `CMakeCache.txt`.

For background builds, the supervisor shell's exit status is not sufficient.
Run Ninja with a complete log and append the inner result explicitly:

```bash
export LD_LIBRARY_PATH=$BUILD/lib:$STAGE1/lib:$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
ninja -C "$BUILD" -j8 >> "$HOME/stage2-build-j8.log" 2>&1
rc=$?
printf 'STAGE2_J8_EXIT=%s\\n' "$rc" >> "$HOME/stage2-build-j8.log"
```

For stage2, put the stage2 build libraries first, then stage1 libraries, then
`$PREFIX/lib`; do not derive the stage1 path from `OLDPWD`, which is not stable
in a fresh shell. Acceptance is separate from construction: first require the
inner exit marker to be `0` and inspect the final log, then run build-tree tools
and closure tests.

See `references/stage2-handoff-and-background-build.md` for the observed
failure signature and the validated handoff sequence.

## Stage handoff: seed the build-tree clang resource dir

When the next stage is configured with a previous stage's BUILD-TREE clang
(the self-bootstrap path), that clang resolves its resource dir relative to
its own binary: `<tree>/lib/clang/<ver>/`. A partial tree has `include/` but
no `lib/<triple>/libclang_rt.builtins.a`, so every configure try-compile link
dies:

```text
ld.lld: error: cannot open .../lib/clang/23/lib/<triple>/libclang_rt.builtins.a: No such file or directory
```

Seed it from a known-good resource dir of the same target (installed prefix,
or a tree whose runtimes already built), then gate the handoff on a real
link+run before relaunching configure:

```bash
mkdir -p <tree>/lib/clang/23/lib/<triple>
cp -a $PREFIX/lib/clang/23/lib/<triple>/libclang_rt.{builtins,profile}.a \
      <tree>/lib/clang/23/lib/<triple>/
echo 'int main(){return 0;}' | <tree>/bin/clang-23 -x c - -o $PREFIX/tmp/handoff-test && $PREFIX/tmp/handoff-test
```

- `-c`-only smoke tests never exercise linking, so a tree can look "smoke
  tested" while being unable to link anything. Link+run is the minimum
  handoff gate.
- If configure already failed on this, delete the half-configured build dir
  before reconfiguring; a failed cache is not worth resuming.
- If callers expect `clang++-23` but the tree only carries `clang`/`clang++`
  links, add the symlink (`ln -sf clang-23 <tree>/bin/clang++-23`); the driver
  selects C++ mode from the invoked binary name.
- Verify the handoff was explicit after configure:
  `grep CMAKE_C_COMPILER: <build>/CMakeCache.txt` must name the previous
  stage's build-tree binary, not the system clang.

## Full-graph builds: scope, link throttle, training env

- `ninja` with no target includes `runtimes/all` when `LLVM_ENABLE_RUNTIMES`
  is set — the compiler-rt ExternalProject builds near the end with the
  just-built toolchain. Read scope from the graph (`build all: ...` lists
  `runtimes/all`) instead of assuming.
- Run compiles at full core width; keep link concurrency throttled via
  `LLVM_PARALLEL_LINK_JOBS`. The Ninja generator may place pool definitions
  in `CMakeFiles/rules.ninja` (build.ninja then only carries `pool = ...` on
  rules) — verify depths with
  `grep -A2 '^pool ' <build>/build.ninja <build>/CMakeFiles/rules.ninja`.
- The training tree itself stays uninstrumented (do not pass
  `LLVM_BUILD_INSTRUMENTED` again); profiles come from the instrumented
  compiler that builds it. Export both env vars for configure AND ninja
  (children inherit them): `LD_LIBRARY_PATH` with the previous tree's lib
  first (ordering rule above), and
  `LLVM_PROFILE_FILE=<raw-dir>/llvm-%m-%p.profraw`. Every compiler process
  writes one file — a full build produces thousands, so use a dedicated raw
  dir.
- Long builds: background with a build-local log and an explicit inner exit
  marker; hold `termux-wake-lock`; log MemAvailable next to progress with
  `scripts/memwatch.py` — link stages are the memory peaks where OOM kills
  land.
- **A finished graph still lists the `runtimes`/`builtins` ExternalProject
  steps as pending.** LLVM marks those per-step targets always-dirty, so
  `ninja -n` keeps printing ~7 edges forever after a successful build and a
  re-run "does work" for a few seconds every time. Decide completion from the
  build's own log (`[N/N] Completed 'runtimes'`) plus the exit marker — never
  from a non-empty `ninja -n`, which will make a completed tree look
  unfinished.
- Pin the build — and any later profile-merge — to one core cluster by pinning
  the **supervisor first**: `sched_setaffinity` is inherited, so a pinned
  `ninja` pins every compiler it will ever spawn, while a matcher that only
  finds the compilers alive right now silently stops working as they are
  replaced (the children of an unpinned ninja come back on the full mask).
  Cluster identity comes from `cpufreq/cpuinfo_max_freq` — the N lowest are the
  mid cluster on a 2-prime + 6-mid SoC; the prime cores stay with the system,
  cross-cluster migration costs more than the prime cores add.
- A process matcher must accept the supervisor explicitly: `ninja -j8`'s own
  cmdline contains no build path, so a "cmdline contains <build dir>" rule never
  matches it. Do not put the build path in the command line that *runs* the
  matcher either — the invoking shell's cmdline embeds the command text, so it
  matches itself, becomes a root, and every process that shell later spawns
  inherits the cluster mask.
- Acceptance is the device's own view, not the helper's summary line: read the
  supervisor's `Cpus_allowed_list` and check `ps -eLo psr,comm` shows zero build
  threads on the prime cores. Re-verify after every resume — a `kill -CONT`
  build looks identical whether the pin survived or not.
- The profile-use (final) tree is configured with the **installed** compiler
  plus `-DLLVM_PROFDATA_FILE=<absolute path>`. That compiler needs no
  `LD_LIBRARY_PATH` for ITSELF, but the tree's **own intermediate host tools**
  (`mlir-irdl-to-cpp` and every other build-tree tool ninja execs mid-build) DO:
  without the tree's full-backend `libLLVM` they pick up the installed
  AArch64-only one and die with
  `cannot locate symbol LLVMInitializeAMDGPUTarget`. The naive
  `$BUILD/lib:$PREFIX/lib` fix then breaks PCH validation — use the shim +
  two-phase recipe in "Compiler identity: libclang-cpp, PCH, and the shim".
  Prove the profile is actually consumed — from the GENERATED commands, not
  from the log. Ninja prints progress lines only, never the flag, so
  `grep fprofile-instr-use <build>.log` returns 0 on a perfectly profile-driven
  build. Use `ninja -t commands | grep -c 'fprofile-instr-use'` (thousands of
  hits on a full graph); a tree that silently failed to pick the profile up
  builds identically and silently wastes the whole training run.

## PGO: merging the collected profiles

A full training build emits 20k+ `.profraw` files totaling hundreds of GB. One
`merge` over all of them is not memory-safe or resumable on a phone: merge
~2000 files per batch into `-sparse` partials (skip batches whose partial
already exists), then merge the partials. Pass the file list with a response
file (`@list.txt`); a list of thousands of arguments will not fit `ARG_MAX`.
Always `-sparse`.

- **Glob pitfall**: `for b in "$PART"/batch-*` also matches a previous run's
  `batch-000.profdata` and feeds binary profdata in as a response file
  (`llvm-profdata: Unknown command`). Match `batch-[0-9][0-9][0-9]` exactly.
- **A batch that dies with SIGABRT (exit 134) and empty stderr is an
  allocation failure**, usually the batch that caught the largest files. Lower
  `--num-threads` and re-split only that batch into ~500-file chunks; merge the
  chunks, then the chunk partials into the batch partial. Never restart the run.
- Verify instead of trusting exit 0: `llvm-profdata show <file>` prints the
  instrumentation level, function/block counts and total count. LLVM 23 has no
  `--summary`; plain `show` is the summary.
- Keep the raw set until the merged profile verifies — re-merging is far
  cheaper than re-training.

See `references/pgo-profile-collection.md` for the driver scripts, the
three-tree orchestration, and the throughput A/B harness, and
`scripts/pgo_bench.py` for a runnable benchmark.

"The profile is consumed" and "the compiler got faster" are separate claims.
Reaching for the second one without measuring it is how a whole build session
gets reported as a win on the strength of a grep. The training tree is the
control arm for that measurement — same source, same flags, no profile; never
A/B against an installed package, which is usually PGO'd itself.

Measure it PAIRED: run the two arms back-to-back inside one repetition and take
the MEDIAN of the per-pair ratios, with a quartile interval beside every figure.
Never keep "the minimum per arm" over independent repetitions — clock drift then
lets one arm sample a cool run and the other a hot one, biasing the answer in a
direction the output does not reveal. Score on rusage CPU seconds and discard
samples where wall exceeds cpu by more than ~15% (preemption). A lone extreme
that does not reproduce on a second run is method noise, not a finding.

## References

Read the reference for a phase BEFORE starting that phase — the recipes for
merging profraw batches, pinning the build cluster, seeding the resource dir,
and the always-dirty ExternalProject steps are already worked out here, and
re-deriving them costs a whole session.

- `references/ld-library-path-hijack.md` — LD_LIBRARY_PATH build-tree hijack diagnosis
- `references/compiler-rt-android-builtins.md` — compiler-rt Android builtins library fix
- `references/closure-verification.md` — Stage2→Rust/Mold closure verification sequence and TLS test
- `references/cmake-cache-and-regen-pitfalls.md` — LD_PRELOAD misleading errors, CMakeCache sed corruption, rules.ninja recovery, stale build-tree anchoring
- `references/pgo-profile-collection.md` — three-tree PGO drivers: training env, two-stage profraw merge, SIGABRT batch retry, compiler-throughput A/B
- `references/rust-stage2-native-build.md` — native rustc stage2 on-device: source/patch series + placeholder substitution, API-level wrappers, shadow lib dir, bootstrap.toml, build+acceptance, and folding the result into the installed package
- `references/mold-android-linker.md` — mold's Android gaps (Android-default erratum flags accepted and ignored upstream), the Cortex-A53 843419 implementation + its acceptance harness, standalone LLVMgold recipe, why `-flto` + mold does not optimize
- `scripts/elf-android-check.py` — PIE / PT_TLS p_align / interp / packed-reloc check for a candidate Android ELF
- `scripts/pgo_bench.py` — runnable training-vs-profile-use compiler-throughput benchmark
- `scripts/memwatch.py` — MemAvailable + ninja progress CSV logger for long background builds
- `scripts/pin-build-cores.py` — pin the build's supervisor (and all future children) to the mid cluster