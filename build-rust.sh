#!/data/data/com.termux/files/usr/bin/bash
# 在设备上原生构建 rustc（stage1/stage2）。环境接线完全照 Termux 的做法，但：
#   * 原生构建（host=target=aarch64-linux-android），stage0 = 已装 rustc（同版本）
#   * llvm-config 指向树 C（23.1.3 PGO），不是 $PREFIX 里那个 23.1.0-rc1
#   * linker 可选：LINKER=mold（默认，用我们打过 843419 补丁的 mold）或 lld
#
#   usage: build-rust.sh [check|build|dist]      # 默认 check（低成本的接线校验）
#          MODE=build JOBS=6 LINKER=lld build-rust.sh
set -uo pipefail

MODE=${1:-check}
SRC=${RUST_SRC:-$HOME/rust-latest-llvm231}
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
C=$HOME/llvm-termux/build-pgouse
OURMOLD=$HOME/termux-llvm-rust-mold/mold-843419
LINKER=${LINKER:-mold}
JOBS=${JOBS:-6}
CORES=${CORES:-0-5}                       # 重活钉小核，大核留给交互
LIBDIR=$HOME/rust-build/_lib
LOGDIR=$HOME/rust-build/logs
mkdir -p "$LIBDIR" "$LOGDIR"
LOG=$LOGDIR/rust-$MODE-$(date +%Y%m%d-%H%M%S).log

case "$LINKER" in
  mold) LDARG="-fuse-ld=$OURMOLD"; [ -x "$OURMOLD" ] || { echo "缺 mold: $OURMOLD"; exit 1; } ;;
  lld)  LDARG="-fuse-ld=lld" ;;
  *)    echo "LINKER 只能是 mold|lld"; exit 1 ;;
esac

{
echo "### rust $MODE  $(date '+%F %T')  linker=$LINKER jobs=$JOBS cores=$CORES"
echo "### 源码 $SRC   version=$(cat "$SRC/src/version" 2>/dev/null)"

# 1) 影子库目录：照 Termux，避免用 -L$PREFIX/lib
echo "--- 1) 影子库目录 $LIBDIR"
# 关键：影子目录里只放 LLVM 动态库与少数运行时库，**绝不能**把 $C/lib 整体加进来 ——
# 里面有 libclang-cpp，宿主编译器 clang 一旦加载到它就会丢掉 target 注册
# （症状：clang -cc1as: error: unknown target triple 'unknown'）。
ln -sf "$C/lib/libLLVM.so.23.1" "$LIBDIR/libLLVM.so.23.1"
ln -sf "$C/lib/libLLVM.so.23.1" "$LIBDIR/libLLVM.so"
ln -sf "$C/lib/libLLVM.so.23.1" "$LIBDIR/libLLVM-23.1.so"
ln -sf "$C/lib/libLLVM.so.23.1" "$LIBDIR/libLLVM-23.so"
ln -sf "$PREFIX/lib/libc++_shared.so" "$LIBDIR/libc++_shared.so"
ln -sf "$PREFIX/lib/libandroid-execinfo.so" "$LIBDIR/libandroid-execinfo.so"
# 系统 libc/libdl 的真实路径（不要硬编码 NDK 布局）
ls -d "$PREFIX"/lib/libc.so "$PREFIX"/lib/libdl.so 2>/dev/null | while read -r f; do ln -sf "$f" "$LIBDIR/$(basename "$f")"; done
ls -la "$LIBDIR" | sed 's/^/    /'

# 2) libsyncfs.a（rust 1.79 起链 rustc 时会缺 syncfs 符号）
echo "--- 2) 编译 libsyncfs.a"
cd "$LIBDIR" || exit 1
"$PREFIX/bin/clang" -c "$HOME/termux-llvm-rust-mold/packaging/rust-patches/syncfs.c" -o syncfs.o && \
  "$PREFIX/bin/llvm-ar" rcu "$LIBDIR/libsyncfs.a" syncfs.o && echo "    libsyncfs.a ok"

# 3) 目标 RUSTFLAGS（host==target，所以这一个变量同时覆盖 host/target 产物）
# rpath 必须把 $C/lib 放**在 $PREFIX/lib 之前**：
#   我们按树 C 的 llvm-config 构建，rustc_driver 会引用全目标 LLVM 的符号
#   （如 LLVMInitializeAMDGPUAsmPrinter）；而 $PREFIX/lib/libLLVM.so.23.1（77 MB）是
#   AArch64-only 的，运行时若先命中它 → "CANNOT LINK EXECUTABLE: cannot locate symbol"。
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-L$LIBDIR -C link-arg=-lc++_shared -C link-arg=-l:libsyncfs.a -C link-arg=-landroid-execinfo -C link-arg=-Wl,--enable-new-dtags -C link-arg=-Wl,-rpath=$C/lib -C link-arg=-Wl,-rpath=$PREFIX/lib -C link-arg=$LDARG"
echo "--- 3) RUSTFLAGS=$CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS"

# 3b) 让 cc-rs（rustc_llvm / libc 等 crate 用）也走 API30 wrapper；
#     否则 ~/.cargo/config.toml 里的 CC_aarch64_linux_android=clang 会赢，
#     编 C++ 时 target 不带 API 级别 → libc++ 头与 bionic 头不一致。
export CC_aarch64_linux_android="$HOME/termux-llvm-rust-mold/packaging/clang-api30.sh"
export CXX_aarch64_linux_android="$HOME/termux-llvm-rust-mold/packaging/clangxx-api30.sh"
export AR_aarch64_linux_android="$PREFIX/bin/llvm-ar"
echo "--- 3b) cc-rs 用 wrapper: $CXX_aarch64_linux_android"

# 4) 落配置
cp -f "$HOME/termux-llvm-rust-mold/bootstrap.toml" "$SRC/config.toml"
echo "--- 4) config.toml 已就位"

# 5) 跑 x.py
cd "$SRC" || exit 1
export PATH="$PREFIX/bin:/system/bin:$PATH"
# 注意两件事（都实测过）：
#  1) 不能把 $C/lib（树 C 构建树）放进 LD_LIBRARY_PATH —— 里面有 libclang-cpp，
#     宿主编译器 clang 加载到它就会丢 target 注册：
#     "clang -cc1as: error: unknown target triple 'unknown'"。
#  2) 但**必须**让运行时找到**全目标**的 libLLVM：我们按树 C 的 llvm-config 构建，
#     rustc_driver 会引用 LLVMInitializeAMDGPU* 等符号，而 $PREFIX/lib/libLLVM.so.23.1
#     是 AArch64-only 的。且 LD_LIBRARY_PATH 整体优先于 RUNPATH，光靠 rpath 不够
#     （实测 RUNPATH 顺序是 $PREFIX/lib 在前）。
#     → 用只含 libLLVM*.so* 的影子目录放在最前面，两头都满足。
export LD_LIBRARY_PATH="$LIBDIR:$PREFIX/lib"
export TERMUX_PKG_API_LEVEL=${TERMUX_PKG_API_LEVEL:-30}
case "$MODE" in
  check) CMD=(python3 x.py check --stage 1 library/std) ;;
  build) CMD=(python3 x.py build --stage 2) ;;
  dist)  CMD=(python3 x.py dist --stage 2) ;;
  *) echo "MODE 只能是 check|build|dist"; exit 1 ;;
esac
echo "--- 5) 执行: ${CMD[*]} -j $JOBS   (taskset -c $CORES)"
taskset -c "$CORES" nice -n 5 "${CMD[@]}" -j "$JOBS"
rc=$?
echo "RUST_${MODE^^}_EXIT=$rc"
echo "### 结束 $(date '+%F %T')"
exit $rc
} 2>&1 | tee "$LOG"
