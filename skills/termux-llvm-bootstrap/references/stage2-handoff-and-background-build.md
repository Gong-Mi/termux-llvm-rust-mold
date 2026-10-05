# Stage2 handoff and background build

## Why a stale stage2 tree is unsafe

A stage2 tree configured before stage1 finished can contain a valid-looking
Ninja/CMake graph but point at missing stage1 compilers. The characteristic
failure is:

```text
The CMAKE_C_COMPILER:
  .../build-stage1/bin/clang
is not a full path to an existing compiler tool.
```

Do not repair this by editing `CMakeCache.txt`. Preserve the old tree with a
suffix such as `-rc1`, then configure a new stage2 tree after validating:

```bash
$STAGE1/bin/clang --version
$STAGE1/bin/clang++ --version
$STAGE1/bin/ld.lld --version
$STAGE1/bin/llvm-config --version
```

## Validated Termux handoff

1. Configure stage2 with the completed stage1 compiler and Ninja.
2. Keep the configure output in a separate log.
3. Build incrementally with eight workers and a complete log.
4. Put dynamic-library search paths in this order:

```text
stage2/build/lib → stage1/build/lib → $PREFIX/lib
```

The shell's `OLDPWD` is not a reliable way to locate stage1. Use absolute
paths or variables initialized in the command itself.

Example:

```bash
SRC=$HOME/llvm-project
STAGE1=$SRC/build-stage1
BUILD=$SRC/build-stage2
export LD_LIBRARY_PATH=$BUILD/lib:$STAGE1/lib:$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
ninja -C "$BUILD" -j8 > "$HOME/stage2-build-j8.log" 2>&1
rc=$?
printf 'STAGE2_J8_EXIT=%s\n' "$rc" >> "$HOME/stage2-build-j8.log"
```

A background notification that the wrapper exited normally does not prove
Ninja succeeded. Read the inner marker, confirm no live Ninja remains, inspect
the final log for `FAILED:`/`error:`, and only then verify binaries. The Ninja
`[x/y]` counter is literal progress for that generated graph; it is not a
percentage of the full LLVM project unless the graph definition is known.
