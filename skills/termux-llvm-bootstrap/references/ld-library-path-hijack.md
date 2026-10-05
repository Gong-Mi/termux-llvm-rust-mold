# LD_LIBRARY_PATH Build-Tree Hijack

## Symptom

Freshly-built stage1 clang appears to have broken DEFAULT_SYSROOT (no
sysroot include paths), prints the wrong version string (old commit hash),
and the runtimes sub-build fails with `pthread.h not found`.

## Root Cause

A persisted shell environment variable `LD_LIBRARY_PATH=$PREFIX/lib`
overrides DT_RUNPATH.  The loader resolves NEEDED libraries from
`$PREFIX/lib` FIRST, where an older copy of the same SONAME libraries
(`libLLVM.so.23.1-rc1`, `libclang-cpp.so.23.1-rc1`) exists from a
previous manual install.

Since LD_LIBRARY_PATH takes priority over RUNPATH, the freshly-built
clang binary loads the OLD libclang-cpp (which has DEFAULT_SYSROOT=""
baked in) instead of the new one (which has DEFAULT_SYSROOT correctly
set).  This causes:

- No sysroot include paths → `pthread.h` not found by builtins sub-build
- Wrong version string (old repo/commit hash)
- All build-time tools (tblgen, etc.) running against old libLLVM code

## Detection

```bash
# Check if LD_LIBRARY_PATH is set and points to $PREFIX/lib
echo $LD_LIBRARY_PATH

# Check which library the binary actually loads
readelf -d build-stage1/bin/clang-23 | grep RUNPATH
# RUNPATH should be: $ORIGIN/../lib:build-stage1/lib

# Check version string — if it shows old repo, hijack is happening
build-stage1/bin/clang --version | head -1
# Should show the current repo/branch, not Gong-Mi/llvm-termux
```

## Fix

### Option A: Ordered LD_LIBRARY_PATH (preferred for build-time)

```bash
# Build-lib FIRST, then $PREFIX/lib as fallback
export LD_LIBRARY_PATH=$BUILD/lib:$PREFIX/lib
ninja -j4
```

This ensures build-time tools resolve their own freshly-built libraries.

**Caveat when resuming a tree that was partly built by the INSTALLED compiler:**
the same ordering also swaps the `libclang-cpp.so.<ver>` that compiler loads,
which changes its identity and invalidates every existing `cmake_pch.hxx.pch`
(`error: PCH file ... built from a different branch`). Those `.pch` files are
explicit inputs of thousands of object edges, so this is not a cheap mistake.
Exclude `libclang-cpp*` from the prepended directory and split the run into two
phases — see SKILL.md "Compiler identity: libclang-cpp, PCH, and the shim".

### Option B: Bake $PREFIX/lib into RUNPATH

Add `-Wl,-rpath,$PREFIX/lib` to `CMAKE_EXE_LINKER_FLAGS` and
`CMAKE_SHARED_LINKER_FLAGS`.  Then no LD_LIBRARY_PATH is needed at all.

```cmake
-DCMAKE_EXE_LINKER_FLAGS="-L/system/lib64 -L$PREFIX/lib -lc++_shared -Wl,-rpath,$PREFIX/lib"
```

## Why Not Just `unset LD_LIBRARY_PATH`?

If you unset LD_LIBRARY_PATH entirely, the build-tree tools can't find
`libc++_shared.so` (which is only in $PREFIX/lib).  The RUNPATH only has
`$ORIGIN/../lib:build/lib` — neither contains libc++_shared.so.

The ordered approach (build-lib FIRST) fixes both:
- Build tools get the NEW libLLVM/libclang-cpp (from build/lib)
- libc++_shared.so is still resolved (from $PREFIX/lib as fallback)

## How It Was Discovered (2026-07-26)

A full stage1 build completed successfully, but the resulting clang
printed the wrong version string and had no sysroot include paths.  The
build appeared clean — no compile errors, no link errors.  Only after
checking `readelf -d` on the binary and noticing the LD_LIBRARY_PATH
env was it clear that ALL build-time tools were loading old libraries
from $PREFIX/lib.  The entire stage1 build was polluted.

The fix required wiping build-stage1 and rebuilding from scratch with
correct LD_LIBRARY_PATH ordering.