#!/data/data/com.termux/files/usr/bin/bash
# build-mold.sh — 用"自举链"编译 mold 2.42.1(commit 6fc6e191)：
#   CC/CXX = tree C 的 clang/clang++（刚 PGO 构建出的那套）
#   rustc/cargo = $PREFIX 里的 1.100.0-nightly（本包）
#   linker = tree C 的 clang 驱动 + 它的 ld.lld
# tree C 的 bin 放 PATH 最前，使 clang/ld.lld/llvm-* 全部来自自建工具链。
# 2026-10-05 pandora.
set -u
PREFIX=/data/data/com.termux/files/usr
H=/data/data/com.termux/files/home
C=$H/llvm-termux/build-pgouse
MOLD=$H/mold
LOG=$H/termux-llvm-rust-mold/mold-build.log

export PATH=$C/bin:$PREFIX/bin:/system/bin
export LD_LIBRARY_PATH=$C/lib:$PREFIX/lib
export CC=$C/bin/clang
export CXX=$C/bin/clang++
export RUSTFLAGS="-C linker=$C/bin/clang -C link-arg=-fuse-ld=lld"
export CARGO_TERM_COLOR=never

termux-wake-lock 2>/dev/null

{
  echo "### chain identities $(date '+%F %T')"
  echo "rustc : $(rustc -vV | tr '\n' ' ')"
  echo "cargo : $(cargo -V)"
  echo "clang : $(clang --version | head -1)"
  echo "ld.lld: $(which ld.lld)"
  echo "CC=$CC  CXX=$CXX"
  echo "RUSTFLAGS=$RUSTFLAGS"
  echo
} > "$LOG"

cd "$MOLD"
cargo build --release -p mold-cli >> "$LOG" 2>&1
rc=$?

printf 'MOLD_BUILD_EXIT=%s\n' "$rc" >> "$LOG"
termux-wake-unlock 2>/dev/null
exit "$rc"
