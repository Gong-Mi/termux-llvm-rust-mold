#!/usr/bin/env bash
# 用我们自己构建的 mold（含 843419 实现）链接 mold 本身，并在真机跑起来 + 扫残留。
set -u
PREFIX=/data/data/com.termux/files/usr
C=/data/data/com.termux/files/home/llvm-termux/build-pgouse
# 关键：让 clang 的 -fuse-ld=mold 找到**我们自己的** mold（不是 $PREFIX 里那个）
export PATH=/data/data/com.termux/files/home/mold/target/release:$C/bin:$PREFIX/bin:/system/bin
export LD_LIBRARY_PATH=$C/lib:$PREFIX/lib
export CC=$C/bin/clang CXX=$C/bin/clang++
export RUSTFLAGS="-C linker=$C/bin/clang -C link-arg=-fuse-ld=mold"
L=/data/data/com.termux/files/home/termux-llvm-rust-mold/selflink-mold.log
cd /data/data/com.termux/files/home/mold || exit 1
echo "### mold 链接 mold (self-link) $(date '+%F %T')" > $L
echo "--- which mold: $(command -v mold)" >> $L
cargo build --release -p mold-cli >> $L 2>&1
rc=$?
printf 'SELFLINK_BUILD_EXIT=%s\n' "$rc" >> $L
if [ $rc -ne 0 ]; then echo '--- 尾 30 行 ---' >> $L; tail -30 $L >> $L; exit $rc; fi

echo "=== 产物 ===" >> $L
ls -la target/release/mold >> $L 2>&1
sha256sum target/release/mold >> $L
echo "=== 自链接产物能否运行 ===" >> $L
env -u LD_PRELOAD -u LD_LIBRARY_PATH ./target/release/mold --version >> $L 2>&1; echo "VERSION_RC=$?" >> $L
env -u LD_PRELOAD -u LD_LIBRARY_PATH ./target/release/mold --help >/dev/null 2>&1; echo "HELP_RC=$?" >> $L
echo "=== .text 残留 843419 扫描（mold 自链接 vs lld 链接备份）===" >> $L
python3 /data/data/com.termux/files/home/.hermes/cache/scratch/scanelf843.py \
    target/release/mold \
    /data/data/com.termux/files/home/termux-llvm-rust-mold/mold-lldlinked-backup >> $L 2>&1
echo "=== 用自链接的 mold 再链一个测试对象 ===" >> $L
cd /data/data/com.termux/files/home/.hermes/cache/scratch/acc843 || exit 1
env -u LD_PRELOAD -u LD_LIBRARY_PATH /data/data/com.termux/files/home/mold/target/release/mold \
    -m aarch64linux -z separate-code --fix-cortex-a53-843419 \
    aarch64-cortex-a53-843419-recognize.o -o self_recognize.mold >> $L 2>&1
echo "LINK_RC=$?" >> $L
env -u LD_PRELOAD -u LD_LIBRARY_PATH /data/data/com.termux/files/home/llvm-termux/build-pgouse/bin/llvm-objdump --no-print-imm-hex -d \
    self_recognize.mold 2>/dev/null | grep -c '\tb\t' >> $L 2>&1
python3 /data/data/com.termux/files/home/.hermes/cache/scratch/scanelf843.py self_recognize.mold >> $L 2>&1
echo "=== 完成 $(date '+%F %T') ===" >> $L
exit 0
