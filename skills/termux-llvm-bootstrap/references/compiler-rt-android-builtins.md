# compiler-rt Android Builtins Library Fix

## Problem

When building compiler-rt shared sanitizer runtimes (asan, hwasan, ubsan,
ubsan_standalone) on Android/Termux, the link fails with missing symbols:

```
undefined reference to `__aarch64_swp1_acq' / `__aarch64_ldadd8_relax' /
`__aarch64_cas8_acq_rel' ...        (AArch64 LSE atomic helpers)
undefined reference to `__extendsftf2'
undefined reference to `__extenddftf2'
undefined reference to `__dynamic_cast'
undefined reference to `typeinfo for std::type_info'
undefined reference to `__cxa_begin_catch'
undefined reference to `__gxx_personality_v0'
```

Two different symbol families fail for two different reasons:

- **builtins** (`__aarch64_{cas,swp,ldadd}*`, `__extendsftf2`, ...): normally
  resolved from libgcc (`-lgcc`), which Android does not have.
- **C++ ABI** (`__dynamic_cast`, typeinfo, `__cxa_begin_catch`,
  `__gxx_personality_v0`): on Android these are provided at LOAD time by the
  host process (libc++_shared or static libc++ inside the app), so they must
  be allowed to stay undefined at link time.

## Root Cause

`COMPILER_RT_USE_BUILTINS_LIBRARY` defaults to OFF outside Fuchsia, and the
shared sanitizer link carries `-Wl,-z,defs` (injected by HandleLLVMOptions,
which `llvm/runtimes/CMakeLists.txt` includes).  With `-nodefaultlibs
-nostdlib++`, neither family resolves, and `-z,defs` (no undefined symbols)
rejects the C++ ABI ones.

## Fix (one source change fixes both halves)

In `compiler-rt/CMakeLists.txt`:

```cmake
set(DEFAULT_COMPILER_RT_USE_BUILTINS_LIBRARY OFF)
if (FUCHSIA OR ANDROID)
  set(DEFAULT_COMPILER_RT_USE_BUILTINS_LIBRARY ON)
endif()
```

With builtins ON:
- the in-tree `libclang_rt.builtins.a` is appended to every shared runtime
  link (symbol family 1 resolved at link time);
- compiler-rt strips `-Wl,-z,defs` from `CMAKE_SHARED_LINKER_FLAGS` (its own
  CMakeLists does the `string(REPLACE ...)` right after the builtins option
  is read) — family 2 stays undefined by design and the link succeeds.

## Applying to an already-configured build tree

The option is CACHED; changing the source default does not touch existing
build dirs.  The runtimes sub-build cache lives at
`<build>/runtimes/runtimes-bins` (its `CMAKE_HOME_DIRECTORY` is
`llvm-project/runtimes`; individual runtimes build under `compiler-rt/`
inside it).  Reconfigure the option in place, then verify the REGENERATED
link command before building anything:

```bash
cd <build>/runtimes/runtimes-bins
cmake -U COMPILER_RT_USE_BUILTINS_LIBRARY .
grep 'COMPILER_RT_USE_BUILTINS_LIBRARY:' CMakeCache.txt     # :BOOL=ON
# resolve the exact target spec if the bare name is not accepted:
ninja -t targets all | grep 'libclang_rt.ubsan_standalone-aarch64-android\.so:'
ninja -t commands <that-target> | tail -1 | grep -c 'Wl,-z,defs'   # 0
# and the archive appears at the link tail:
#   ...libclang_rt.builtins-aarch64-android.a && :
```

Then build the shared targets and check:
- `llvm-nm <so> | grep __aarch64_` — full symtab lists them as LOCAL (`t`);
  `llvm-nm -D --defined-only` will NOT list them (not exported).  Checking
  `.dynsym` for statically-linked-in archive members is a false negative.
- `llvm-readelf -d <so> | grep NEEDED` — libc/libdl/liblog (+libm for asan).
- C++ ABI symbols remain `U` — expected on Android.

A full build drives this through the parent graph (`ninja` includes
`runtimes/all`); the parent's runtimes-build stamp re-runs `cmake --build .`
in `runtimes/runtimes-bins`, which picks up the reconfigured cache.  If only
the sub-build is being repaired by hand, finish it there and let the parent
re-run write its stamps.

## Verification

After the patch, shared sanitizer runtimes link without errors:
```bash
find <build>/lib/clang/23/lib -name '*asan*.so' -o -name '*hwasan*.so'
```
On Android the runtimes install under the flat `lib/clang/<ver>/lib/linux/`
directory (no per-triple subdir).  The static sanitizer libraries (.a) are
unaffected.

## Why Not Disable Shared Sanitizers?

`-DCOMPILER_RT_BUILD_SHARED_ASAN=OFF` removes functionality; Android ASan
defaults to shared mode, so `-fsanitize=address` would stop working with the
default driver behavior.  The builtins fix is the correct solution.

## Prior Art

Fuchsia has the same requirement (Bionic-derived libc, no libgcc, builtins
provides the soft-float helpers).  The condition was `if (FUCHSIA)`;
`OR ANDROID` follows the same pattern.

## Session History

- Stage-1 bootstrap: discovered.  `-DRUNTIMES_<triple>_COMPILER_RT_USE_BUILTINS_LIBRARY=ON`
  on the command line did not reach the builtins sub-build (separate
  ExternalProject); the source patch was adopted as the reliable mechanism.
- Full / self-bootstrap build (release/23.x): proven that the flip fixes BOTH
  halves (builtins archive linked in; `-z,defs` dropped) for asan and
  ubsan_standalone; the `cmake -U` in-place reconfigure recipe above is the
  validated way to apply it to a tree configured with the old default.
