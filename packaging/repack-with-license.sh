#!/data/data/com.termux/files/usr/bin/bash
# 在已有 llvm-rust-system .deb 的数据层上注入许可文件，生成新版本的 .deb。
# 用途: 已经用其它脚本（PGO / Rust 合并包）产出二进制包后，补 share/doc 许可再发布。
#
#   usage: repack-with-license.sh <base.deb> <new-version> <copyright文件> [out目录]
#   例:    repack-with-license.sh \
#            ~/toolchain-deb-out/llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-1_aarch64.deb \
#            23.1.3+rust1.100.0nightly+mold2.42.1-2 \
#            packaging/copyright \
#            ~/toolchain-deb-out
#
# 只动三处: $PREFIX/share/doc/<pkg>/copyright、DEBIAN/control 的 Version/Installed-Size、
# 以及 control 里的一行说明。二进制/库文件与 base 逐字节相同。
set -euo pipefail
umask 022

BASE=${1:-}
NEWVER=${2:-}
DOC=${3:-}
OUT=${4:-$(dirname "${1:-.}")}
[ -n "$BASE" ] && [ -n "$NEWVER" ] && [ -n "$DOC" ] || {
  echo "用法: repack-with-license.sh <base.deb> <new-version> <copyright文件> [out目录]" >&2; exit 1; }
[ -f "$BASE" ] || { echo "找不到 base deb: $BASE" >&2; exit 1; }
[ -f "$DOC" ]  || { echo "找不到 copyright: $DOC" >&2; exit 1; }

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
PKG=$(dpkg-deb -f "$BASE" Package)
ARCH=$(dpkg-deb -f "$BASE" Architecture)
STAGE=${STAGE:-$HOME/toolchain-repack-stage}
JOBS=${DPKG_DEB_THREADS_MAX:-4}
TARGET="$OUT/${PKG}_${NEWVER}_${ARCH}.deb"

echo "=== 0/4 输入 ==="
echo "  base   : $BASE ($(stat -c '%s' "$BASE") bytes)"
echo "  newver : $NEWVER"
echo "  doc    : $DOC ($(stat -c '%s' "$DOC") bytes)"
echo "  输出   : $TARGET"

echo "=== 1/4 解包数据层 ==="
rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 755 "$STAGE"
dpkg-deb --fsys-tarfile "$BASE" | tar xf - -C "$STAGE"
echo "  文件数: $(find "$STAGE" -type f | wc -l)"

echo "=== 2/4 注入 share/doc/$PKG/copyright ==="
install -d -m 755 "$STAGE$PREFIX/share/doc/$PKG"
install -m 644 "$DOC" "$STAGE$PREFIX/share/doc/$PKG/copyright"

echo "=== 3/4 重写 control ==="
mkdir -p "$STAGE/DEBIAN"; chmod 755 "$STAGE/DEBIAN"
dpkg-deb -e "$BASE" "$STAGE/DEBIAN"
SIZE=$(du -sk "$STAGE" | cut -f1)
{
  echo "Package: $PKG"
  echo "Version: $NEWVER"
  echo "Maintainer: $(dpkg-deb -f "$BASE" Maintainer)"
  echo "Architecture: $ARCH"
  echo "Section: devel"
  echo "Priority: optional"
  echo "Homepage: https://github.com/Gong-Mi/termux-llvm-rust-mold"
  echo "Installed-Size: $SIZE"
  for f in Replaces Provides Depends Conflicts; do
    v=$(dpkg-deb -f "$BASE" "$f" 2>/dev/null || true)
    [ -n "$v" ] && echo "$f: $v"
  done
  echo "Description: $(dpkg-deb -f "$BASE" Description | head -1 | sed 's/^Description: //')"
  dpkg-deb -f "$BASE" Description | tail -n +2 | sed 's/^ / /'
  echo " License texts (LLVM Apache-2.0 WITH LLVM-exception, Rust MIT/Apache-2.0,"
  echo " mold MIT) are installed at \$PREFIX/share/doc/$PKG/copyright."
} > "$STAGE/DEBIAN/control"
cat "$STAGE/DEBIAN/control"

echo "=== 4/4 构建 (xz -6, threads=$JOBS) ==="
rm -f "$TARGET" "$TARGET.sha256"
time DPKG_DEB_THREADS_MAX="$JOBS" dpkg-deb --build --root-owner-group -Zxz -z6 "$STAGE" "$TARGET"
sha256sum "$TARGET" | tee "$TARGET.sha256"
echo "包内文件数: $(dpkg-deb -c "$TARGET" | wc -l)"
echo "=== DONE: $TARGET ==="
