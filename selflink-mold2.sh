#!/usr/bin/env bash
# 自链接 v2：显式用**我们自己**的 mold（含 843419 实现），验证真二进制上的效果。
set -u
PREFIX=/data/data/com.termux/files/usr
C=/data/data/com.termux/files/home/llvm-termux/build-pgouse
OURMOLD=/data/data/com.termux/files/home/termux-llvm-rust-mold/mold-843419
export PATH=$C/bin:$PREFIX/bin:/system/bin
export LD_LIBRARY_PATH=$C/lib:$PREFIX/lib
export CC=$C/bin/clang CXX=$C/bin/clang++
export RUSTFLAGS="-C linker=$C/bin/clang -C link-arg=-fuse-ld=$OURMOLD"
L=/data/data/com.termux/files/home/termux-llvm-rust-mold/selflink-mold2.log
cd /data/data/com.termux/files/home/mold || exit 1
echo "### self-link v2（用自己的 mold）$(date '+%F %T')" > $L
echo "--- 用哪个 mold: $OURMOLD （$(grep -ac cortex-a53-843419 "$OURMOLD") 处实现标记）" >> $L
env -u LD_PRELOAD -u LD_LIBRARY_PATH $C/bin/clang -### --target=aarch64-linux-android30 -fuse-ld=$OURMOLD -o /dev/null -x c /dev/null 2>&1 | tr ' ' '\n' | grep -E 'mold|843419' >> $L
cargo build --release -p mold-cli >> $L 2>&1
rc=$?
printf 'SELFLINK2_BUILD_EXIT=%s\n' "$rc" >> $L
if [ $rc -ne 0 ]; then tail -30 $L >> $L; exit $rc; fi

echo "=== 产物 ===" >> $L
sha256sum target/release/mold >> $L
ls -la target/release/mold >> $L
echo "=== 能否运行 ===" >> $L
env -u LD_PRELOAD -u LD_LIBRARY_PATH ./target/release/mold --version >> $L 2>&1; echo "VERSION_RC=$?" >> $L
echo "=== .text 残留 843419 扫描 ===" >> $L
python3 /data/data/com.termux/files/home/.hermes/cache/scratch/scanelf843.py \
    target/release/mold \
    /data/data/com.termux/files/home/termux-llvm-rust-mold/mold-lldlinked-backup >> $L 2>&1
echo "=== link map 里 mold 报的 patching 数 ===" >> $L
grep -c 'patching' $L >> $L
grep 'patching' $L | head -3 >> $L
echo "=== 完成 $(date '+%F %T') ===" >> $L
exit 0
