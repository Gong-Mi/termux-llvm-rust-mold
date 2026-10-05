#!/data/data/com.termux/files/usr/bin/bash
# 把「自举 rust」的 dist 组件折进 llvm-rust-system 的 base deb，产出新 deb（只在暂存区操作）。
#   用法: build-deb-rust.sh <base.deb> <new-version> [outdir]
#
# 已踩过的坑（都在这里规避）：
#   1) /tmp 在本环境不可写 → 所有临时文件放 scratch
#   2) tarball 里的组件根在**第 3 层**（<top>/<component>/lib|bin）；判不出必须报错退出，
#      绝不能让空的 comp 退化成绝对路径（曾把宿主 /etc 抄进暂存区）
#   3) 「陈旧文件」的**新集必须取自 tarball 内容**，不能取自叠加后的暂存区 ——
#      否则旧文件在两边都有，永远算出 0，旧 hash 的 librustc_driver 等会留成死重量
set -uo pipefail
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
BASE=${1:?用法: build-deb-rust.sh <base.deb> <new-version> [outdir]}
NEWVER=${2:?需要新版本号}
OUT=${3:-$HOME/toolchain-deb-out}
DIST=$HOME/rust-latest-llvm231/build/dist
STAGE=${STAGE:-$HOME/toolchain-rust-stage}
WORK=$HOME/.hermes/cache/scratch/rustdeb-$$; mkdir -p "$WORK"
LOG=$HOME/termux-llvm-rust-mold/rust-deb.log
TARGET=$OUT/llvm-rust-system_${NEWVER}_aarch64.deb
# 必须覆盖 $PREFIX/lib 下的 rust 动态库，否则 base 里旧 hash 命名的那份会作为死重量留下
RUSTSCOPE='rustlib|bin/rustc|bin/cargo|bin/rustdoc|bin/rustfmt|bin/cargo-fmt|lib/librustc_driver-|lib/libstd-|lib/libtest-|lib/libproc_macro-|lib/libpanic_abort-|lib/libpanic_unwind-|share/doc/rust'
die(){ echo "错误: $*" >&2; exit 1; }

{
echo "### 折入自举 rust  $(date '+%F %T')"
PKG=$(dpkg-deb -f "$BASE" Package); ARCH=$(dpkg-deb -f "$BASE" Architecture)
[ "$PKG" = "llvm-rust-system" ] || die "base 不是 llvm-rust-system（$PKG）"

echo "=== 1/6 解 base 数据层 ==="
rm -rf "$STAGE"; mkdir -p "$STAGE"
dpkg-deb --fsys-tarfile "$BASE" | tar xf - -C "$STAGE"
echo "  文件数: $(find "$STAGE" -type f | wc -l)"

echo "=== 1b/6 预检：base 数据层里指向**暂存区之外**的符号链接 ==="
# dpkg 拆包遇到「包描述为目录、现场是符号链接」时会**顺着链接写**（不是替换）。
# 上一版包就因 src/rust -> $HOME/... 把 rust-src 文件写进了家目录树。这里先暴露出来。
OUTSIDE=$(find "$STAGE" -type l 2>/dev/null | while read -r l; do
  tgt=$(readlink "$l"); real=$(readlink -f "$l" 2>/dev/null || true)
  case "$tgt" in /*) abs="$tgt";; *) abs="$(dirname "$l")/$tgt";; esac
  case "$(readlink -f "$(dirname "$abs")" 2>/dev/null || dirname "$abs")" in
    "$STAGE"/*) ;;
    *) [ -n "$l" ] && echo "${l#$STAGE}  ->  $tgt" ;;
  esac
done)
if [ -n "$OUTSIDE" ]; then
  echo "  ⚠ 有符号链接指向暂存区之外（安装时会顺链写出去）："
  echo "$OUTSIDE" | head -10 | sed 's/^/      /'
  echo "  （本次铺料会用实体目录覆盖已列出的 rust 路径；其余请人工确认）"
else
  echo "  ✅ 无外指符号链接"
fi

echo "=== 2/6 旧 rust 文件集（取自 base 包清单，权威）==="
dpkg-deb --fsys-tarfile "$BASE" | tar -tf - 2>/dev/null \
  | grep -E "$RUSTSCOPE" | sed 's|^\./|/|' | sort -u > "$WORK/old.txt"
echo "  OLD: $(wc -l < "$WORK/old.txt") 项"

echo "=== 3/6 铺入新组件（同一遍从 tarball 内容算 NEW）==="
: > "$WORK/new.txt"
# 默认不带 rust-src（源码不进包）；需要时 COMPONENTS="... rust-src" 覆盖
COMPONENTS=${COMPONENTS:-"rustc cargo rust-std rustc-dev rustfmt"}
for c in $COMPONENTS; do
  t=$(ls "$DIST"/${c}-nightly*aarch64*.tar.gz "$DIST"/${c}-nightly*.tar.gz 2>/dev/null | head -1)
  [ -n "$t" ] || { echo "  – $c: 无 tarball，跳过"; continue; }
  tmp=$WORK/x-$c; rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xzf "$t" -C "$tmp" || die "解包失败 $t"
  comp=$(find "$tmp" -maxdepth 3 -type d \( -name lib -o -name bin \) | head -1 | xargs -r dirname)
  [ -n "$comp" ] && case "$comp" in "$tmp"/*) ;; *) comp="" ;; esac
  [ -n "$comp" ] || die "判不出组件目录（tarball=$t, comp='$comp'）"

  if [ "$c" = "rust-src" ]; then
    src=$(find "$tmp" -type d -path '*lib/rustlib/src/rust' | head -1)
    [ -n "$src" ] || die "rust-src 里找不到 lib/rustlib/src/rust"
    mkdir -p "$STAGE$PREFIX/lib/rustlib/src"
    rm -rf "$STAGE$PREFIX/lib/rustlib/src/rust"
    cp -a "$src" "$STAGE$PREFIX/lib/rustlib/src/rust"
    ( cd "$src" && find . -mindepth 1 ) | sed "s|^\./|$PREFIX/lib/rustlib/src/rust/|" >> "$WORK/new.txt"
    mkdir -p "$STAGE$PREFIX/lib/rustlib/rustc-src"
    ln -sfn ../src/rust "$STAGE$PREFIX/lib/rustlib/rustc-src/rust"
    echo "$PREFIX/lib/rustlib/rustc-src/rust" >> "$WORK/new.txt"
    echo "  ✅ $c -> lib/rustlib/src/rust（并重指 rustc-src/rust）"
  else
    ( cd "$comp" && find . -mindepth 1 ) | sed "s|^\./|$PREFIX/|" >> "$WORK/new.txt"
    for d in bin lib share etc; do
      [ -e "$comp/$d" ] && cp -a "$comp/$d/." "$STAGE$PREFIX/$d/"
    done
    echo "  ✅ $c （$(find "$comp" -mindepth 1 | wc -l) 项）"
  fi
  rm -rf "$tmp"
done
sort -u "$WORK/new.txt" -o "$WORK/new.txt"
echo "  NEW: $(wc -l < "$WORK/new.txt") 项"

echo "=== 3b/6 剔除源码（rustc-dev 里附带的 crate 源码 / rustc-src），保留 librustc_driver*.so ==="
# rustc-dev 既提供 rustc_private 需要的 librustc_driver*.so，也附带一份 crate 源码
# （lib/rustlib/src/rust/** 与 rustc-src/rust/**）。只丢源码、留驱动：
# 源码不是编译/运行所需，去掉后 rustc_private 工具照常；源码可从 rustc-nightly-src.tar.xz 自取。
if [ "${STRIP_SRC:-1}" = "1" ]; then
  for d in "$STAGE$PREFIX/lib/rustlib/src" "$STAGE$PREFIX/lib/rustlib/rustc-src"; do
    if [ -e "$d" ]; then
      n=$(find "$d" -type f 2>/dev/null | wc -l); b=$(du -sk "$d" 2>/dev/null | cut -f1)
      rm -rf "$d"
      echo "  移除 ${d#$STAGE} （${n} 文件 / ${b} KB）"
    fi
  done
  # 同步把它们从“新集”里去掉 → 旧包里的对应文件会被判为陈旧，升级时删除
  if [ -f "$WORK/new.txt" ]; then
    grep -v -e "$PREFIX/lib/rustlib/src" -e "$PREFIX/lib/rustlib/rustc-src" "$WORK/new.txt" > "$WORK/new.tmp" && mv "$WORK/new.tmp" "$WORK/new.txt"
    echo "  NEW 已剔除源码路径，剩余 $(wc -l < "$WORK/new.txt") 项"
  fi
else
  echo "  （STRIP_SRC=0，保留源码）"
fi

echo "=== 4/6 清陈旧（OLD − NEW = base 提供而新组件不再提供的）==="
comm -23 "$WORK/old.txt" "$WORK/new.txt" > "$WORK/stale.txt"
n=$(wc -l < "$WORK/stale.txt")
echo "  陈旧: $n 项"
if [ "$n" -gt 0 ]; then
  head -5 "$WORK/stale.txt" | sed 's/^/      /'
  bytes=0
  while read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$STAGE$f" ]; then
      bytes=$((bytes + $(stat -c '%s' "$STAGE$f" 2>/dev/null || echo 0)))
      if [ -d "$STAGE$f" ] && [ ! -L "$STAGE$f" ]; then rmdir "$STAGE$f" 2>/dev/null; else rm -f "$STAGE$f"; fi
    fi
  done < "$WORK/stale.txt"
  echo "  已删约 $((bytes / 1048576)) MB"
fi

echo "=== 4b/6 注入构建配方 share/doc/$PKG/BUILD.md ==="
DOCDIR="$STAGE$PREFIX/share/doc/$PKG"
mkdir -p "$DOCDIR"
if [ -f "$HOME/termux-llvm-rust-mold/packaging/BUILD.md" ]; then
  cp -f "$HOME/termux-llvm-rust-mold/packaging/BUILD.md" "$DOCDIR/BUILD.md"
  echo "  ✅ BUILD.md ($(stat -c '%s' "$DOCDIR/BUILD.md") bytes)"
else
  echo "  ⚠ 找不到 packaging/BUILD.md，跳过"
fi

echo "=== 5/6 暂存区验收（跑起来才算）==="
SR=$STAGE$PREFIX/bin/rustc; SC=$STAGE$PREFIX/bin/cargo
echo "  rustc: $(env -u LD_PRELOAD LD_LIBRARY_PATH=$STAGE$PREFIX/lib $SR -vV 2>&1 | sed -n 1p)"
echo "  cargo: $(env -u LD_PRELOAD LD_LIBRARY_PATH=$STAGE$PREFIX/lib $SC --version 2>&1)"
printf 'fn main(){let v:Vec<u32>=(1..=5).collect();println!("staged rust ok sum={}",v.iter().sum::<u32>());}\n' > "$WORK/probe.rs"
# 探针必须去掉沙箱注入的 LD_PRELOAD(libpython3.14.so)，否则链接出的程序一律起不来
if env -u LD_PRELOAD LD_LIBRARY_PATH=$STAGE$PREFIX/lib $SR "$WORK/probe.rs" -o "$WORK/probe" 2>"$WORK/probe.err" \
   && env -u LD_PRELOAD LD_LIBRARY_PATH=$STAGE$PREFIX/lib "$WORK/probe" | grep -q 'sum=15'; then
  echo "  ✅ 暂存 rustc 编译并运行程序成功"
else
  echo "  ❌ 暂存 rustc 失败："; head -5 "$WORK/probe.err" | sed 's/^/      /'
fi
echo "  暂存 rustc sha: $(sha256sum $SR | cut -c1-32)"

echo "=== 6/6 重建 deb ==="
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
  # 跨 ABI（armv7a/i686/x86_64）链接需要系统自带的多 ABI sysroot 包；不在本包内 → 用 Recommends
  echo "Recommends: ndk-multilib, ndk-multilib-native-static, ndk-multilib-native-stubs, ndk-sysroot"
  echo "Description: $(dpkg-deb -f "$BASE" Description | head -1 | sed 's/^Description: //')"
  dpkg-deb -f "$BASE" Description | tail -n +2 | sed 's/^ / /'
  echo " LLVM, Rust and mold are all built by this toolchain's own clang (self-hosted),"
  echo " sharing one full-target libLLVM."
} > "$STAGE/DEBIAN/control"

mkdir -p "$OUT"; rm -f "$TARGET" "$TARGET.sha256"
time DPKG_DEB_THREADS_MAX=${DPKG_DEB_THREADS_MAX:-4} dpkg-deb --build --root-owner-group -Zxz -z6 "$STAGE" "$TARGET"
sha256sum "$TARGET" | tee "$TARGET.sha256"
echo "包内文件数: $(dpkg-deb -c "$TARGET" | wc -l)"
echo "=== 回读验收 ==="
for f in bin/rustc bin/cargo; do
  IN=$(dpkg-deb --fsys-tarfile "$TARGET" | tar -xO "./${PREFIX#/}/$f" 2>/dev/null | sha256sum | cut -c1-32)
  ST=$(sha256sum "$STAGE$PREFIX/$f" | cut -c1-32)
  [ "$IN" = "$ST" ] && echo "  ✔ $f 包内=暂存=$IN" || echo "  ❌ $f 包内=$IN 暂存=$ST"
done
S=$(dpkg-deb --fsys-tarfile "$TARGET" | tar -tf - 2>/dev/null | grep -c 'librustc_driver-f9c2d563' || true)
echo "  旧 driver 残留: $S 处（应为 0）"
rm -rf "$WORK"
echo "=== DONE: $TARGET $(date '+%F %T') ==="
} 2>&1 | tee "$LOG"
