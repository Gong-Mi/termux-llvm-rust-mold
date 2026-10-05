#!/data/data/com.termux/files/usr/bin/bash
# rust 准备 1/2：取与已装 rustc 完全同版本的编译器源码，落到 ~/rust-latest-llvm231
# （= $PREFIX/lib/rustlib/rustc-src/rust 那条断链的目标），并校验。
set -euo pipefail
DATE=2026-09-24          # = 已装 rustc 1.100.0-nightly (0d38a8426 2026-09-24)
SRC=~/rust-latest-llvm231
DL=~/rust-src-dl
URL=https://static.rust-lang.org/dist/$DATE/rustc-nightly-src.tar.xz
LOG=~/termux-llvm-rust-mold/rust-src-prep.log
mkdir -p "$DL"
exec > >(tee -a "$LOG") 2>&1
echo "### rust 源码准备 $(date '+%F %T')"

if [ -f "$DL/rustc-nightly-src.tar.xz" ]; then
  echo "已存在下载，跳过"
else
  echo "=== 1/4 下载 ==="
  curl -fL --progress-bar -o "$DL/rustc-nightly-src.tar.xz" "$URL"
fi
echo "  大小: $(stat -c '%s' "$DL/rustc-nightly-src.tar.xz") bytes"

echo "=== 2/4 校验（官方 .sha256）==="
if curl -fsSL -o "$DL/src.sha256" "$URL.sha256"; then
  cat "$DL/src.sha256"
  (cd "$DL" && sha256sum -c <(sed "s|rustc-nightly-src.tar.xz|$DL/rustc-nightly-src.tar.xz|" src.sha256))
else
  echo "  （无官方 .sha256，记录本地 sha）"; sha256sum "$DL/rustc-nightly-src.tar.xz"
fi

echo "=== 3/4 解包 ==="
if [ -e "$SRC" ]; then echo "  $SRC 已存在，先移开"; mv "$SRC" "$SRC.old.$$"; fi
tar -xf "$DL/rustc-nightly-src.tar.xz" -C "$DL"
TOP=$(find "$DL" -maxdepth 1 -type d -name 'rustc-nightly-src*' | head -1)
[ -n "$TOP" ] || { echo "找不到解包出的顶层目录"; exit 1; }
mv "$TOP" "$SRC"

echo "=== 4/4 验收 ==="
echo "  源码根: $SRC"
ls "$SRC" | head -12
echo
echo "  x.py            : $([ -f "$SRC/x.py" ] && echo 有 || echo 缺)"
echo "  compiler/       : $(ls "$SRC/compiler" 2>/dev/null | wc -l) 个条目"
echo "  library/std     : $([ -f "$SRC/library/std/src/lib.rs" ] && echo 有 || echo 缺)"
echo "  vendor tarball  : $(ls -d "$SRC"/vendor 2>/dev/null | wc -l)（0 = 需联网取依赖）"
echo "  src/llvm-project: $([ -d "$SRC/src/llvm-project" ] && echo 在 || echo 不在)"
echo "  version 文件    : $(cat "$SRC/src/version" 2>/dev/null)"
echo
echo "  rustc-src 符号链接是否修活: $(readlink -f $PREFIX/lib/rustlib/rustc-src/rust)"
du -sh "$SRC"
echo "=== 完成 $(date '+%F %T') ==="
