#!/data/data/com.termux/files/usr/bin/bash
# 发布一个新的 llvm-rust-system 版本到 GitHub Releases
#   usage: publish-release.sh <deb 路径> [--dry-run]
# tag 规则: v<pkg、ver 里的 + 换成 ->，例 v23.1.3-rust1.100.0-mold2.42.1-2
set -euo pipefail

REPO=Gong-Mi/termux-llvm-rust-mold
DEB=${1:-}
[ -n "$DEB" ] || { echo "用法: publish-release.sh <deb 路径> [--dry-run]" >&2; exit 1; }
[ -f "$DEB" ] || { echo "找不到: $DEB" >&2; exit 1; }
DEB=$(readlink -f "$DEB")
BASE=$(basename "$DEB")
DIR=$(dirname "$DEB")

VER=$(printf '%s' "$BASE" | sed -nE 's/^[^_]+_(.+)_aarch64\.deb$/\1/p')
[ -n "$VER" ] || { echo "文件名不符合 <pkg>_<ver>_aarch64.deb: $BASE" >&2; exit 1; }
TAG="v$(printf '%s' "$VER" | tr '+' '-')"

echo "=== 目标 ==="
echo "  repo   : $REPO"
echo "  包     : $BASE"
echo "  版本   : $VER"
echo "  tag    : $TAG"
echo "  大小   : $(du -h "$DEB" | cut -f1)  ($(stat -c '%s' "$DEB") bytes)"

if [ ! -f "$DIR/$BASE.sha256" ]; then
  echo "=== 生成 $BASE.sha256 ==="
  (cd "$DIR" && sha256sum "$BASE" > "$BASE.sha256")
fi
SHA=$(cut -d' ' -f1 < "$DIR/$BASE.sha256")
echo "=== sha256 ==="
echo "  $SHA"

if [ "${2:-}" = "--dry-run" ]; then
  echo "=== dry-run: 不发布 ==="
  exit 0
fi

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "tag $TAG 已存在，改为上传/覆盖 asset"
  gh release upload "$TAG" -R "$REPO" --clobber "$DEB" "$DIR/$BASE.sha256"
else
  gh release create "$TAG" -R "$REPO" \
     --title "llvm-rust-system $VER" \
     --notes "llvm-rust-system $VER

- 下载: $(du -h "$DEB" | cut -f1) ($(stat -c '%s' "$DEB") bytes)
- sha256: \`$SHA\`
- 校验: 下载 \`.sha256\` 后 \`sha256sum -c\`
- 安装: \`apt install -y ./$BASE\`（不要用 dpkg -i，apt 会自动移除冲突的官方包）
- 回滚见 README" \
     "$DEB" "$DIR/$BASE.sha256"
fi

echo "=== 核对远端 asset ==="
gh release view "$TAG" -R "$REPO" --json tagName,assets \
  -q '.tagName, (.assets[] | "  \(.name)  \(.size) bytes  digest=\(.digest // "n/a")")'
echo "本地 sha256: $SHA"
echo "=== DONE: https://github.com/$REPO/releases/tag/$TAG ==="
