# Rust stage2 built natively on-device (Termux/Android aarch64)

Use this when the toolchain must be self-hosted: our PGO clang builds rustc,
our rustc builds mold. Termux's own recipe cannot be copied — it cross-builds
from x86_64 with the NDK and an x86_64 rustup stage0; here the bootstrap
compiler is the INSTALLED aarch64-linux-android rustc and nothing is cross.

## 1. Source: exactly the version the stage0 reports

```bash
rustc -vV                     # commit-hash + commit-date decide the tarball
# rustc 1.100.0-nightly (0d38a8426 2026-09-24)
curl -fL -o rustc-nightly-src.tar.xz \
  https://static.rust-lang.org/dist/2026-09-24/rustc-nightly-src.tar.xz
curl -fsSL -o src.sha256  <same URL>.sha256 && sha256sum -c <(...)
```

The extracted tree must land where `$PREFIX/lib/rustlib/rustc-src/rust` points
(check with `readlink` — it is often a dangling link to
`~/rust-latest-llvm231`), which also repairs that component. The nightly source
tarball ships `vendor/`, so dependencies need no network. Note
`bootstrap.example.toml` and `src/version` (must equal the stage0's version).

## 2. Patch series: substitute placeholders, prove "already applied"

Termux's `packages/rust/` patch set (fetch the raw files into
`packaging/rust-patches/`) is the reference. Two rules decide whether the
series works:

- **Substitute build-time placeholders BEFORE applying.**
  `@TERMUX_PKG_API_LEVEL@` (here `30`, matching the toolchain's default android
target) and `@TERMUX_PREFIX@` (the real `$PREFIX`). Applying them raw writes
  the literal placeholders into the source.
- **Detect "already applied" by `patch -p1 --dry-run --reverse`, never by
  grepping for a marker string.** Marker guessing produces false positives
  (one patch's "first added line" already existed) and a false positive
  SILENTLY SKIPS a required patch — the build then fails much later with a
  message pointing somewhere else.

Skipped on purpose, with the reason recorded in the applier:
`0006-suppress-hard-linking-failed-warning` (only silences a runtime warning
about the incremental cache; unrelated to the build) and
`0011-fix-wasip3-libdir-assert` (only affects the wasip3 target, which a
native rustc build for android does not produce).

Skipped never means safe: a patch whose CONTEXT drifted must be regenerated
against the pristine file from the tarball (`tar -xOf <tarball> <path>` → diff
→ fix the `--- a/` `+++ b/` headers), not applied with fuzz. Upstream 0009
here needed exactly that (its import-context lines gained
`rustc_span::bug;`/`rustc_structures::CrateType`).

Local patches the series needs on top of Termux's, because they are
consequences of the android cfg changes or of nightly manifest lints:

- `compiler/rustc/src/main.rs`: `#![expect(unused_crate_dependencies)]` becomes
  unfulfilled on android once the signal-handler cfg includes it → gate it
  (`#![cfg_attr(not(target_os = "android"), expect(...))]`).
- `library/std/Cargo.toml` and `library/sysroot/Cargo.toml`:
  `[lints.cargo] unused_dependencies = "allow"` — cargo cannot see deps pulled
  in through attributes / the sysroot link graph.

## 3. bootstrap.toml (the settings that matter)

```toml
change-id = "ignore"
profile = "dist"

[llvm]
download-ci-llvm = false
link-shared = true

[build]
build = "aarch64-linux-android"
host  = ["aarch64-linux-android"]
target = ["aarch64-linux-android"]
rustc = "$PREFIX/bin/rustc"        # stage0: same version as the source
cargo = "$PREFIX/bin/cargo"
python = "python3"
extended = true
tools = ["cargo", "rustdoc", "rustfmt", "src"]
allocator = "system"               # [rust] jemalloc is deprecated

[install]
prefix = "$HOME/rust-stage2-prefix"   # staging: do NOT write into $PREFIX

[rust]
optimize = true
channel = "nightly"
rpath = false
lld = false

[target.aarch64-linux-android]
llvm-config = "<tree>/bin/llvm-config"   # MUST describe the libLLVM you link
cc     = "<wrappers>/clang-api30.sh"
cxx    = "<wrappers>/clangxx-api30.sh"
linker = "<wrappers>/clang-api30.sh"
ar     = "$PREFIX/bin/llvm-ar"
ranlib = "$PREFIX/bin/llvm-ranlib"
profiler = true
```

- **`llvm-config` is a version claim, not a path.** `$PREFIX/bin/llvm-config`
  reported `23.1.0-rc1` while `rustc -vV` said `LLVM version: 23.1.3`; pointing
  bootstrap at it silently builds against a different LLVM than the stage0 was
  built with. Verify with `llvm-config --version` vs `rustc -vV` before
  configuring.
- `[rust] jemalloc = false` is deprecated and PANICS bootstrap
  (`reconcile_jemalloc`) when `[build] allocator` is also set — keep exactly
  one.

## 4. API-level wrappers

```bash
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case "$a" in
    --target=aarch64-linux-android|--target=aarch64-unknown-linux-android|--target=aarch64-linux-android2[0-9])
      args+=("--target=aarch64-linux-android30") ;;
    *) args+=("$a") ;;
  esac
done
exec $PREFIX/bin/clang++ "${args[@]}"      # clang for the C wrapper
```

Cheap proof the wrapper is load-bearing: `#include <condition_variable>`
syntax-only with `--target=aarch64-linux-android` fails before and passes after.

## 5. Build environment (Termux's `RUST_LIBDIR` recipe, adapted)

```bash
LIBDIR=$HOME/rust-build/_lib            # shadow dir: LLVM + a few runtime libs
ln -sf $TREE/lib/libLLVM.so.23.1 $LIBDIR/libLLVM.so.23.1     # full-target build
ln -sf $TREE/lib/libLLVM.so.23.1 $LIBDIR/libLLVM.so
ln -sf $TREE/lib/libLLVM.so.23.1 $LIBDIR/libLLVM-23.so       # llvm-config's name
ln -sf $PREFIX/lib/libc++_shared.so     $LIBDIR/libc++_shared.so
ln -sf $PREFIX/lib/libandroid-execinfo.so $LIBDIR/libandroid-execinfo.so
# rust 1.79+: rustc links against syncfs, absent in bionic
$PREFIX/bin/clang -c syncfs.c -o syncfs.o
$PREFIX/bin/llvm-ar rcu $LIBDIR/libsyncfs.a syncfs.o

export PATH=~/rust-latest-llvm231/build/aarch64-linux-android/stage2-tools-bin:\
$TREE-stage2/bin:$PREFIX/bin:/system/bin
# NOT $TREE/lib — see the libclang-cpp rule in SKILL.md
export LD_LIBRARY_PATH=$LIBDIR:$PREFIX/lib
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-L$LIBDIR -C link-arg=-lc++_shared -C link-arg=-l:libsyncfs.a -C link-arg=-landroid-execinfo -C link-arg=-Wl,--enable-new-dtags -C link-arg=-Wl,-rpath=$PREFIX/lib -C link-arg=-fuse-ld=<mold|lld>"
export CC_aarch64_linux_android=<clang wrapper>
export CXX_aarch64_linux_android=<clang++ wrapper>
taskset -c 0-5 nice -n 5 python3 x.py build --stage 2 -j 6
```

`taskset` pins the supervisor and every child inherits the mask; hold
`termux-wake-lock` for the run.

## 6. Acceptance, in this order

1. `x.py check --stage 1 library/std` → exit 0 is the cheap wiring gate
   (minutes). It builds the compiler tree without codegen.
2. `x.py build --stage 2` → `Build completed successfully`. Artifacts:
   `build/<triple>/stage2/bin/{rustc,rustdoc,rustfmt}` and — easy to miss —
   **cargo in `stage2-tools-bin/`**.
3. Run the built compiler on a program, not just `-vV`:
   `LD_LIBRARY_PATH=build/<triple>/stage2/lib:$LIBDIR:$PREFIX/lib <rustc> hi.rs
   -o hi && ./hi`. Compiling is not enough: the loader must resolve the sysroot
   libs and the full-target libLLVM.
4. Close the self-host loop: rebuild mold with the self-built `cargo`/`rustc`
   (`RUSTC=`/`CARGO=` + the same RUSTFLAGS + `-fuse-ld=` our patched mold), run
   `mold --version`, then link an erratum vector and scan for residual
   patterns. In this session that link reported 11 real 843419 sites in mold's
   own 60 MB binary and the result ran.

## 7. Folding the result into the installed package

- Ship the **self-hosted binary and the full-target `libLLVM` together** with
the full-target LLVM, and repoint `$PREFIX/lib/libLLVM.so` at
  `libLLVM.so.<ver>`; only then does the self-built rustc run with just
  `$PREFIX/lib` (no shadow dir).
- Repack the published base `.deb` (see SKILL.md's packaging bullet) and add
  the libLLVM swap to the same script, optionally: replace
  `$PREFIX/lib/libLLVM.so.23.1`, `ln -sfn libLLVM.so.23.1 libLLVM.so`, rebuild,
  then read both files back out of the package and compare hashes. Expect
  `Installed-Size` to jump by the size difference (~78 MB here) — that number
  is a useful cross-check that the swap really landed.
- Post-install acceptance that catches every regression this work can cause:
  `dpkg -V`, the two swapped file hashes, `mold --version` + a grep for the
  feature it should carry (`grep -ac cortex-a53-843419` is 1 in a flag-only
  build and 4 with the implementation), `clang++` compiling AND running C++
  under the new libLLVM, the installed rustc compiling and running, the
  self-built rustc running with `$PREFIX/lib` only, and finally the driver's
  default path (`clang --target=...-android30 -fuse-ld=mold`) patching an
  erratum vector with zero residual patterns.

### Folding the components into an existing package (repack)

When the published base `.deb` was hand-assembled (no `lib/rustlib/manifest-*`
inside), the dist installer's upgrade path cannot help: it needs a manifest to
uninstall, so it only ADDS. Do the overlay by hand, and treat these four as
mandatory:

- **Compute the NEW file set from the TARBALL contents, not from the stage.**
  `comm -23 old new` with `new` measured on the already-overlaid stage always
yields zero (the stale path is in both sets), so old hash-named payloads
  survive silently — one leftover `librustc_driver-<hash>.so` is ~93 MB of dead
  weight that a size check alone will not flag.
- **The stale scope must include `$PREFIX/lib/librustc_driver-*.so`, `libstd-*`,
  `share/doc/rust`, …**, not just `lib/rustlib/**`: dist components place the
  driver in BOTH `$PREFIX/lib/` and `lib/rustlib/<triple>/lib/`, and only the
  latter sits inside the obvious scope.
- **Assert the component root is inside the extracted dir before copying.**
  It lives at `<tmp>/<top>/<component>/lib|bin` (depth 3); a depth-2 `find`
  returns nothing, and an empty `comp` turns `"$comp/etc"` into the HOST `/etc`
  — which then lands in the stage (device `aconfig_flags.pb`,
  `fs_config_files` and friends appeared under `$PREFIX/etc/` before the
  assertion existed). Always validate with a synthetic run first.
- **Use a scratch dir for temporary files.** `/tmp` is not writable here, and a
  failed `> /tmp/x` redirect silently empties the whole comparison — the run
  then reports "0 stale" and looks healthy.

Run the staged acceptance with `env -u LD_PRELOAD`: the sandbox injects
`libpython3.14.so`, which makes every newly linked program die with
`CANNOT LINK EXECUTABLE ... library "libpython3.14.so" not found`. Without the
`env -u`, a perfectly good toolchain reads as a failed one (and vice versa: the
same trap hides real defects if you "fix" it by ignoring the message).

#### Pre-existing symlinks redirect the unpack (silent, cross-tree)

`dpkg` does NOT replace a symlink when the package ships a directory at that
path: it writes **through** the link. The base package here had
`$PREFIX/lib/rustlib/src/rust -> $HOME/rust-latest-llvm231` (hand-made by an
earlier session) and `rustc-src/rust ->` the same, so installing the rust-src
component silently unpacked tens of MB into the BUILD TREE instead of the
prefix: the layout then contradicts the package's own file list, `dpkg -L`
points at files that physically live elsewhere, and a later
`readlink -f`-based check resolves to a path nobody expects. `dpkg -V` stays
silent because symlinks carry no md5 entry.

Before/during a repack:

- list symlinks in the staged data layer and flag any whose target leaves the
  stage (`find "$STAGE" -type l -exec sh -c 'test -e "$(dirname {})/$(readlink {})" || echo {}' \;`
  is not enough — compare against the resolved path, and check both the base
  and the new layer).
- after installing, verify the resolved paths, not just presence:
  `readlink -f $PREFIX/lib/rustlib/src/rust` must stay inside `$PREFIX`.
- fix on the live system by replacing the symlink with a real directory
  (`rm -f <link>; mkdir -p <dir>; cp -a <stage>/<dir>/. <dir>/`), then re-check
  that the source tree the link used to point at was not modified (mtime + the
  local patch markers, e.g. `grep -c 'lints.cargo' library/std/Cargo.toml`) —
  here the content was identical so the build tree's patches survived, but that
  is a property of the payload, not something to assume.

## Pitfall table (symptom → cause → fix)

| symptom | cause | fix |
|---|---|---|
| `error: use of undeclared identifier 'pthread_cond_clockwait'` | `--target` without API level vs libc++ headers built for API 30 | API-level wrappers as `cc/cxx/linker` + `CC_/CXX_aarch64_linux_android` |
| `clang -cc1as: error: unknown target triple 'unknown'` | a build tree's `lib/` on `LD_LIBRARY_PATH` → host clang loads its `libclang-cpp` | expose only `libLLVM*.so*` through the shadow dir |
| `llvm-config: error: libLLVM-23.so is missing` | tree produces `libLLVM.so.23.1`; `--link-shared` wants the unversioned name in ITS libdir | symlink inside `llvm-config`'s own `--libdir` |
| `cannot locate symbol LLVMInitializeAMDGPUAsmPrinter` | rustc_llvm built against a full-target LLVM, runtime found an AArch64-only `libLLVM.so.<ver>` (LD_LIBRARY_PATH beats RUNPATH) | shadow dir with the full-target lib first |
| `library "libz.so.1" not found` after a green build | explicit `RUSTFLAGS` replaced the config's `-Wl,-rpath` | put rpath + `--enable-new-dtags` in RUSTFLAGS |
| `warnings are denied by build.warnings` on manifest lints | cargo `unused_dependencies` false positives in std/sysroot | per-manifest `[lints.cargo] unused_dependencies = "allow"` |
| `reconcile_jemalloc` panic | `[rust] jemalloc = false` coexists with `[build] allocator` | keep one |
| bootstrap tries to download a stage0 | no `[build] rustc`/`cargo` set | point both at the installed same-version toolchain |
