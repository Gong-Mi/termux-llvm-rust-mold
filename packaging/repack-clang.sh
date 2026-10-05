#!/data/data/com.termux/files/usr/bin/bash
# 用**源码构建并正规 install 出来的** LLVM（树C → DESTDIR 暂存前缀，rpath 由 CMake 写为
# $ORIGIN/../lib）替换 base deb 里的 clang 家族与 libclang-cpp，并合入资源目录。
# 不改任何二进制：所有产物都来自 `cmake --install`。
#   用法: repack-clang.sh <base.deb> <new-version> [outdir]
set -uo pipefail
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
BASE=${1:?用法: repack-clang.sh <base.deb> <new-version> [outdir]}
NEWVER=${2:?需要新版本号}
OUT=${3:-$HOME/toolchain-deb-out}
SRC=${SRC:-$HOME/llvm-install-stage$PREFIX}     # 源码 install 出的树
STAGE=${STAGE:-$HOME/toolchain-clang-stage}
TARGET=$OUT/llvm-rust-system_${NEWVER}_aarch64.deb
LOG=$HOME/termux-llvm-rust-mold/clang-repack.log
die(){ echo "错误: $*" >&2; exit 1; }

[ -x "$SRC/bin/clang-23" ] || die "暂存前缀里没有 clang-23（先跑 run-install-treeC.sh）"

{
echo "### 换 clang（源码 install 产物）  $(date '+%F %T')"
PKG=$(dpkg-deb -f "$BASE" Package); ARCH=$(dpkg-deb -f "$BASE" Architecture)
[ "$PKG" = "llvm-rust-system" ] || die "base 不是 llvm-rust-system（$PKG）"

echo "=== 1/5 解 base 数据层 ==="
rm -rf "$STAGE"; mkdir -p "$STAGE"
dpkg-deb --fsys-tarfile "$BASE" | tar xf - -C "$STAGE"
echo "  文件数: $(find "$STAGE" -type f | wc -l)"

echo "=== 2/5 换 clang 家族 + libclang-cpp（保留 base 的其余工具）==="
# 先记下 base 里 clang 家族的链接关系，换完照原样补回
# 注意必须含 clang-23 本体：漏了它只换符号链接，编译器仍是 base 的 5 目标版
for n in clang-23 clang clang++ clang-cl clang-cpp clang++-23; do
  src="$SRC/bin/$n"
  [ -e "$src" ] || continue
  dst="$STAGE$PREFIX/bin/$n"
  mode=$(stat -c '%a' "$dst" 2>/dev/null || echo 700)
  if [ -L "$src" ]; then
    ln -sfn "$(readlink "$src")" "$dst"; echo "  ✅ bin/$n -> $(readlink "$src")（符号链接，源码树原样）"
  else
    install -m "$mode" "$src" "$dst"; echo "  ✅ bin/$n（$(stat -c '%s' "$src") B，rpath=$($PREFIX/bin/llvm-readelf -d "$src" | grep -oE 'runpath: \[[^]]*\]' | head -1)）"
  fi
done
for n in libclang-cpp.so.23.1; do
  src="$SRC/lib/$n"; dst="$STAGE$PREFIX/lib/$n"
  [ -e "$src" ] || continue
  install -m "$(stat -c '%a' "$dst" 2>/dev/null || echo 700)" "$src" "$dst"
  echo "  ✅ lib/$n（$(stat -c '%s' "$src") B，rpath=$($PREFIX/bin/llvm-readelf -d "$src" | grep -oE 'runpath: \[[^]]*\]' | head -1)）"
done
ln -sfn libclang-cpp.so.23.1 "$STAGE$PREFIX/lib/libclang-cpp.so"

echo "=== 3/5 合入资源目录（不删 base 的三元目录/符号链接）==="
before=$(find "$STAGE$PREFIX/lib/clang/23" -mindepth 1 2>/dev/null | wc -l)
( cd "$SRC/lib/clang/23" && tar cf - . ) | ( cd "$STAGE$PREFIX/lib/clang/23" && tar xf - )
after=$(find "$STAGE$PREFIX/lib/clang/23" -mindepth 1 2>/dev/null | wc -l)
echo "  clang/23 条目 $before -> $after（合入，未删）"
echo "  linux/ 下的 builtins: $(ls "$STAGE$PREFIX/lib/clang/23/lib/linux/" 2>/dev/null | grep -c builtins) 个"

echo "=== 3b/5 合入逐 ABI builtins（多目标循环编出来的）==="
BF=${BUILTINS_FROM:-$HOME/llvm-builtins-stage$PREFIX/lib/linux}
if [ -d "$BF" ]; then
  n=0
  for a in "$BF"/libclang_rt.builtins-*-android.a; do
    [ -e "$a" ] || continue
    install -m "$(stat -c '%a' "$a")" "$a" "$STAGE$PREFIX/lib/clang/23/lib/linux/$(basename "$a")"
    n=$((n+1)); echo "  ✅ $(basename "$a")（$(stat -c '%s' "$a") B）"
  done
  echo "  合计 $n 份；linux/ 下现有 builtins: $(ls "$STAGE$PREFIX/lib/clang/23/lib/linux/" | grep -c builtins)"
else
  echo "  ⚠ 未找到 $BF（先跑 run-builtins-loop.sh）"
fi

echo "=== 4/5 暂存区验收（跑起来才算）==="
SL=$STAGE$PREFIX/lib:$PREFIX/lib
# 探针必须放在暂存树**之外**：写成 $STAGE/t.c 会变成包根 /t.c，安装时 dpkg 往只读的
# 文件系统根写 → 整个安装中断（本条是实测踩过的）
WORK=$HOME/.hermes/cache/scratch/clangrepack-$$; mkdir -p "$WORK"
printf 'int f(int x){return x+1;}\n' > "$WORK/t.c"
echo "  clang 版本: $(env -u LD_PRELOAD LD_LIBRARY_PATH=$SL $STAGE$PREFIX/bin/clang-23 --version 2>&1 | head -1)"
echo "  目标数: $(env -u LD_PRELOAD LD_LIBRARY_PATH=$SL $STAGE$PREFIX/bin/clang-23 --print-targets 2>/dev/null | grep -cE '^\s+[a-z0-9_]+ +-')"
env -u LD_PRELOAD LD_LIBRARY_PATH=$SL $STAGE$PREFIX/bin/clang-23 --target=armv7a-linux-androideabi24 -c "$WORK/t.c" -o "$WORK/t.o" 2>&1 | head -2
echo "  armv7 产物: $(file -b "$WORK/t.o" 2>/dev/null)"

echo "=== 4b/5 守卫：包内不得有 data/ 与 DEBIAN 之外的路径 ==="
stray=$(cd "$STAGE" && ls -A | grep -vxE 'DEBIAN|data' | tr '\n' ' ')
if [ -n "$stray" ]; then echo "  ❌ 暂存区根有杂项: $stray"; ls -la "$STAGE" | head; die "包根混入非 data/ 路径（安装会失败）"; fi
echo "  ✅ 干净（暂存区根只有 data/ 与 DEBIAN）"

echo "=== 5/5 重建 deb ==="
mkdir -p "$STAGE/DEBIAN"; chmod 755 "$STAGE/DEBIAN"
dpkg-deb -e "$BASE" "$STAGE/DEBIAN"
SIZE=$(du -sk "$STAGE" | cut -f1)
{
  echo "Package: $PKG"; echo "Version: $NEWVER"
  echo "Maintainer: $(dpkg-deb -f "$BASE" Maintainer)"
  echo "Architecture: $ARCH"; echo "Section: devel"; echo "Priority: optional"
  echo "Homepage: https://github.com/Gong-Mi/termux-llvm-rust-mold"
  echo "Installed-Size: $SIZE"
  for f in Replaces Provides Depends Conflicts; do
    v=$(dpkg-deb -f "$BASE" "$f" 2>/dev/null || true); [ -n "$v" ] && echo "$f: $v"
  done
  echo "Description: $(dpkg-deb -f "$BASE" Description | head -1 | sed 's/^Description: //')"
  dpkg-deb -f "$BASE" Description | tail -n +2 | sed 's/^ / /'
  echo " clang here is the all-targets PGO build installed from source (rpath \$ORIGIN/../lib),"
  echo " so armv7a/x86_64/i686 compile targets are available again."
} > "$STAGE/DEBIAN/control"

mkdir -p "$OUT"; rm -f "$TARGET" "$TARGET.sha256"
time DPKG_DEB_THREADS_MAX=${DPKG_DEB_THREADS_MAX:-4} dpkg-deb --build --root-owner-group -Zxz -z6 "$STAGE" "$TARGET"
sha256sum "$TARGET" | tee "$TARGET.sha256"
echo "包内文件数: $(dpkg-deb -c "$TARGET" | wc -l)"
echo "=== 回读：包内 clang-23 与暂存一致？ ==="
IN=$(dpkg-deb --fsys-tarfile "$TARGET" | tar -xO "./${PREFIX#/}/bin/clang-23" 2>/dev/null | sha256sum | cut -c1-32)
echo "  暂存=$(sha256sum $STAGE$PREFIX/bin/clang-23 | cut -c1-32)  包内=$IN"
[ "$IN" = "$(sha256sum $STAGE$PREFIX/bin/clang-23 | cut -c1-32)" ] && echo "  ✔ 一致" || echo "  ❌ 不一致"
echo "=== DONE: $TARGET $(date '+%F %T') ==="
} 2>&1 | tee "$LOG"
