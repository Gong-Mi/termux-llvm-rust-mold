#!/data/data/com.termux/files/usr/bin/bash
# 取 base deb（带 sha256 校验）→ 用我们的 mold 重打成 -4。不安装。
set -euo pipefail
OUT=/data/data/com.termux/files/home/toolchain-deb-out
BASE=llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-3_aarch64.deb
URL=https://github.com/Gong-Mi/termux-llvm-rust-mold/releases/download/v23.1.3-rust1.100.0nightly-mold2.42.1-3
MOLDBIN=/data/data/com.termux/files/home/termux-llvm-rust-mold/mold-843419
mkdir -p "$OUT"
cd "$OUT"
if [ ! -f "$BASE" ]; then
  echo "=== 下载 base deb ==="
  curl -fL --progress-bar -o "$BASE" "$URL/$BASE"
  curl -fsSL -o "$BASE.sha256" "$URL/$BASE.sha256" || echo "(无 .sha256)"
else
  echo "=== base deb 已存在，跳过下载 ==="
fi
echo "=== 校验 base ==="
if [ -f "$BASE.sha256" ]; then sha256sum -c "$BASE.sha256"; else sha256sum "$BASE"; fi
dpkg-deb -f "$BASE" Package Version
echo
echo "=== 重打（换我们的 mold）==="
bash /data/data/com.termux/files/home/termux-llvm-rust-mold/packaging/repack-mold.sh \
  "$OUT/$BASE" \
  23.1.3+rust1.100.0nightly+mold2.42.1-4 \
  "$MOLDBIN" \
  "$OUT"
