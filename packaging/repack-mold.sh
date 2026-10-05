#!/data/data/com.termux/files/usr/bin/bash
# 在已有 llvm-rust-system .deb 的**数据层**上替换 mold（+ 保证 ld.mold 链接）并升版本。
# 与 repack-with-license.sh 同构：只动被指定的那一组文件与 control 的 Version/Installed-Size，
# 其余二进制/库与 base 逐字节相同。
#
#   usage: repack-mold.sh <base.deb> <new-version> <mold-binary> [out目录]
#   例:    repack-mold.sh \
#            ~/toolchain-deb-out/llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-3_aarch64.deb \
#            23.1.3+rust1.100.0nightly+mold2.42.1-4 \
#            ~/termux-llvm-rust-mold/mold-843419 \
#            ~/toolchain-deb-out
set -euo pipefail
umask 022

BASE=${1:-}
NEWVER=${2:-}
MOLDBIN=${3:-}
OUT=${4:-$(dirname "${BASE:-.}")}

die() { echo "错误: $*" >&2; exit 1; }
[ -n "$BASE" ] && [ -n "$NEWVER" ] && [ -n "$MOLDBIN" ] || die "用法: repack-mold.sh <base.deb> <new-version> <mold-binary> [out目录]"
[ -f "$BASE" ]    || die "找不到 base deb: $BASE"
[ -f "$MOLDBIN" ] || die "找不到 mold 二进制: $MOLDBIN"

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
PKG=$(dpkg-deb -f "$BASE" Package)
[ "$PKG" = "llvm-rust-system" ] || die "base deb 的 Package 是 '$PKG'，不是 llvm-rust-system，拒绝"
ARCH=$(dpkg-deb -f "$BASE" Architecture)
STAGE=${STAGE:-$HOME/toolchain-repack-stage}
JOBS=${DPKG_DEB_THREADS_MAX:-4}
TARGET="$OUT/${PKG}_${NEWVER}_${ARCH}.deb"

echo "=== 0/6 输入 ==="
echo "  base    : $BASE ($(stat -c '%s' "$BASE") bytes, $(dpkg-deb -f "$BASE" Version))"
echo "  newver  : $NEWVER"
echo "  mold    : $MOLDBIN ($(stat -c '%s' "$MOLDBIN") bytes)"
echo "  mold sha: $(sha256sum "$MOLDBIN" | cut -d' ' -f1)"
echo "  输出    : $TARGET"

echo "=== 1/6 解包数据层 ==="
rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 755 "$STAGE"
dpkg-deb --fsys-tarfile "$BASE" | tar xf - -C "$STAGE"
echo "  文件数: $(find "$STAGE" -type f | wc -l)"

OLD="$STAGE$PREFIX/bin/mold"
LINK="$STAGE$PREFIX/bin/ld.mold"
[ -f "$OLD" ] || [ -L "$OLD" ] || die "base deb 里找不到 $PREFIX/bin/mold"

echo "=== 2/6 摸清原有的权限位（照抄，不改包风格）==="
OLD_MODE=$(stat -c '%a' "$OLD")
echo "  旧 mold: $OLD_MODE  $(stat -c '%s' "$OLD") bytes"
echo "  旧 sha : $(sha256sum "$OLD" | cut -d' ' -f1)"

echo "=== 3/6 换 mold ==="
install -m "$OLD_MODE" "$MOLDBIN" "$OLD"
NEW_SHA=$(sha256sum "$OLD" | cut -d' ' -f1)
echo "  新 mold: $OLD_MODE  $(stat -c '%s' "$OLD") bytes"
echo "  新 sha : $NEW_SHA"

echo "=== 4/6 保证 ld.mold 指向 mold（clang -fuse-ld=mold 找的就是这个名字）==="
if [ -L "$LINK" ]; then
  tgt=$(readlink "$LINK")
  echo "  已存在: ld.mold -> $tgt"
  [ "$tgt" = "mold" ] || { rm -f "$LINK"; ln -s mold "$LINK"; echo "  已改为 -> mold"; }
elif [ -e "$LINK" ]; then
  echo "  已存在实体文件 ld.mold（非符号链接），保留不动"
else
  ln -s mold "$LINK"; echo "  新建: ld.mold -> mold"
fi

echo "=== 4b/6 可选：统一 libLLVM（LLVM_SO 指向全目标版时替换）==="
if [ -n "${LLVM_SO:-}" ]; then
  [ -f "$LLVM_SO" ] || die "找不到 LLVM_SO: $LLVM_SO"
  OLDLIB="$STAGE$PREFIX/lib/libLLVM.so.23.1"
  [ -e "$OLDLIB" ] || die "base deb 里没有 $PREFIX/lib/libLLVM.so.23.1"
  echo "  旧: $(stat -c '%s' "$OLDLIB") bytes  sha=$(sha256sum "$OLDLIB" | cut -c1-16)"
  install -m "$(stat -c '%a' "$OLDLIB")" "$LLVM_SO" "$OLDLIB"
  echo "  新: $(stat -c '%s' "$OLDLIB") bytes  sha=$(sha256sum "$OLDLIB" | cut -c1-16)"
  # libLLVM.so 符号链接改为指向我们这份（base 里它指着旧的 rc1）
  ln -sfn libLLVM.so.23.1 "$STAGE$PREFIX/lib/libLLVM.so"
  echo "  libLLVM.so -> $(readlink "$STAGE$PREFIX/lib/libLLVM.so")"
else
  echo "  （未指定 LLVM_SO，保持 base 的 libLLVM）"
fi

echo "=== 5/6 重写 control（只改 Version / Installed-Size）==="
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
  # 跨 ABI（armv7a/i686/x86_64）链接需要系统自带的多 ABI sysroot 包；不在本包内 → 用 Recommends
  echo "Recommends: ndk-multilib, ndk-multilib-native-static, ndk-multilib-native-stubs, ndk-sysroot"
  echo "Description: $(dpkg-deb -f "$BASE" Description | head -1 | sed 's/^Description: //')"
  dpkg-deb -f "$BASE" Description | tail -n +2 | sed 's/^ / /'
  echo " mold carries the Cortex-A53 erratum 843419 workaround;"
  echo " the binary is built from the termux/arm64 patch series."
} > "$STAGE/DEBIAN/control"

echo "=== 6/6 构建 (xz -6) ==="
mkdir -p "$OUT"
rm -f "$TARGET" "$TARGET.sha256"
time DPKG_DEB_THREADS_MAX="$JOBS" dpkg-deb --build --root-owner-group -Zxz -z6 "$STAGE" "$TARGET"
sha256sum "$TARGET" | tee "$TARGET.sha256"
echo "包内文件数: $(dpkg-deb -c "$TARGET" | wc -l)"

echo "=== 回读验收：包里的 mold 就是输入的那个 ==="
IN_DEB=$(dpkg-deb --fsys-tarfile "$TARGET" | tar -xO "./${PREFIX#/}/bin/mold" | sha256sum | cut -d' ' -f1)
echo "  期望 sha: $NEW_SHA"
echo "  包内 sha: $IN_DEB"
[ "$IN_DEB" = "$NEW_SHA" ] || die "包内 mold 与输入不一致！"
echo "  ✔ 一致"
echo "  包内 ld.mold: $(dpkg-deb --fsys-tarfile "$TARGET" | tar -tvf - "./${PREFIX#/}/bin/ld.mold" 2>/dev/null | head -1)"
echo "  Version: $(dpkg-deb -f "$TARGET" Version)"
echo "=== DONE: $TARGET ==="
