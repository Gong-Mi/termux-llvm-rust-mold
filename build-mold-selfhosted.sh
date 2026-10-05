#!/data/data/com.termux/files/usr/bin/bash
# 自举闭环：用**我们自己建的** rustc + cargo 重新编译 mold，链接器用我们打过 843419 的 mold。
# 链: 我们的 PGO clang(树C) → 我们的 rustc(stage2) → 我们的 mold。
set -uo pipefail
S=$HOME/rust-latest-llvm231
ST2=$S/build/aarch64-linux-android/stage2
ST2TOOLS=$S/build/aarch64-linux-android/stage2-tools-bin
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
LIBDIR=$HOME/rust-build/_lib
OURMOLD=$HOME/termux-llvm-rust-mold/mold-843419
W=$HOME/termux-llvm-rust-mold/packaging
LOG=$HOME/termux-llvm-rust-mold/mold-selfhosted.log

# 我们的 rustc/cargo 需要：自己的 sysroot lib + 影子目录(全目标 libLLVM) + $PREFIX/lib
export PATH=$ST2TOOLS:$ST2/bin:$PREFIX/bin:/system/bin
export LD_LIBRARY_PATH=$ST2/lib:$LIBDIR:$PREFIX/lib
export RUSTC=$ST2/bin/rustc
export CARGO=$ST2TOOLS/cargo
export CC=$W/clang-api30.sh
export CXX=$W/clangxx-api30.sh
# 注意：设了 RUSTFLAGS 就会**替换**掉 ~/.cargo/config.toml 里的 target rustflags
# （cargo 语义：env 覆盖 config），所以 rpath 必须自己带上，否则产物找不到 libz 等。
export RUSTFLAGS="-C linker=$PREFIX/bin/clang -C link-arg=-fuse-ld=$OURMOLD -C link-arg=-Wl,-rpath=$PREFIX/lib -C link-arg=-Wl,--enable-new-dtags"

{
echo "### mold ←(自举 rustc)  $(date '+%F %T')"
echo "--- 工具链自检 ---"
echo "  cargo : $($CARGO --version 2>&1)"
$RUSTC -vV 2>&1 | sed -n '1p;/^host/p'
echo "  sysroot: $($RUSTC --print sysroot 2>&1)"
echo "  RUSTFLAGS: $RUSTFLAGS"
echo "--- 构建 ---"
cd "$HOME/mold" || exit 1
taskset -c 0-5 nice -n 5 $CARGO build --release -p mold-cli
rc=$?
printf 'MOLD_SELFHOSTED_EXIT=%s\n' "$rc" >> /dev/null
echo "MOLD_SELFHOSTED_EXIT=$rc"
if [ $rc -eq 0 ]; then
  echo "--- 产物 ---"
  sha256sum target/release/mold
  ls -la target/release/mold
  echo "--- 运行自检 ---"
  env -u LD_PRELOAD -u LD_LIBRARY_PATH ./target/release/mold --version
  echo "  rc=$?"
  echo "--- 用它链一个测试对象并扫 erratum 残留 ---"
  cd "$HOME/.hermes/cache/scratch/acc843" || exit 1
  env -u LD_PRELOAD -u LD_LIBRARY_PATH "$HOME/mold/target/release/mold" \
      -m aarch64linux -z separate-code --fix-cortex-a53-843419 \
      aarch64-cortex-a53-843419-recognize.o -o sh_recognize.mold 2>&1
  python3 "$HOME/.hermes/cache/scratch/scanelf843.py" sh_recognize.mold
fi
echo "### 结束 $(date '+%F %T')"
} 2>&1 | tee "$LOG"
