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
SIZE=$(stat -c '%s' "$DEB")
MIB=$(( SIZE / 1048576 ))

VER=$(printf '%s' "$BASE" | sed -nE 's/^[^_]+_(.+)_aarch64\.deb$/\1/p')
[ -n "$VER" ] || { echo "文件名不符合 <pkg>_<ver>_aarch64.deb: $BASE" >&2; exit 1; }
TAG="v$(printf '%s' "$VER" | tr '+' '-')"

echo "=== 目标 ==="
echo "  repo   : $REPO"
echo "  包     : $BASE"
echo "  版本   : $VER"
echo "  tag    : $TAG"
echo "  大小   : ${MIB} MiB  (${SIZE} bytes)"

# .sha256 一律用 basename 重新生成。
# 构建阶段留下的那份常是 `sha256sum <绝对路径>` 的产物，直接上传会让下载者的
# `sha256sum -c` 去找构建机路径而失败（-3 就是这么发出去的），也会让构建机自检误验旧文件。
SUM="$DIR/$BASE.sha256"
if [ -f "$SUM" ] && [ "$(awk 'NF>=2{print $2; exit}' "$SUM")" != "$BASE" ]; then
  echo "=== 旧的 $BASE.sha256 不是 basename 形式，重建 ==="
  echo "  (旧内容: $(head -1 "$SUM"))"
fi
SHA=$(sha256sum "$DEB" | awk '{print $1}')
printf '%s  %s\n' "$SHA" "$BASE" > "$SUM"
[ "$(wc -l < "$SUM")" -eq 1 ] && [ "$(awk '{print NF}' "$SUM")" -eq 2 ] && [ "$(awk '{print $2}' "$SUM")" = "$BASE" ] \
  || { echo "生成的 .sha256 形状不对: $(cat "$SUM")" >&2; exit 1; }
echo "=== sha256 ==="
echo "  $SHA"

if [ "${2:-}" = "--dry-run" ]; then
  echo "=== dry-run: 不发布 ==="
  exit 0
fi

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "tag $TAG 已存在，改为上传/覆盖 asset"
  gh release upload "$TAG" -R "$REPO" --clobber "$DEB" "$SUM"
else
  gh release create "$TAG" -R "$REPO" \
     --title "llvm-rust-system $VER" \
     --notes "llvm-rust-system $VER

- 下载: ${MIB} MiB (${SIZE} bytes)
- sha256: \`$SHA\`
- 校验: 下载 \`.sha256\` 后 \`sha256sum -c\`
- 安装: \`apt install -y ./$BASE\`（不要用 dpkg -i，apt 会自动移除冲突的官方包）
- 发布前验货: \`tools/verify-release.sh $TAG --extract --smoke\`
- 回滚见 README" \
     "$DEB" "$SUM"
fi

echo "=== 核对远端 asset（不一致就失败）==="
LIST=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[] | [.name, (.size|tostring), (.digest // "n/a")] | @tsv')
while IFS=$'\t' read -r name size digest; do
  [ -n "$name" ] || continue
  case "$name" in
    "$BASE")
      if [ "$size" != "$SIZE" ]; then echo "  ✗ 远端大小 $size != 本地 $SIZE" >&2; exit 1; fi
      case "$digest" in
        "sha256:$SHA") echo "  ✓ $name  $size bytes  digest 一致" ;;
        n/a)           echo "  ! $name  digest 不可用（API 未返回），仅核对了大小" ;;
        *)             echo "  ✗ 远端 digest $digest != sha256:$SHA" >&2; exit 1 ;;
      esac
      ;;
    "$BASE.sha256")
      [ "$size" = "$(stat -c '%s' "$SUM")" ] || { echo "  ✗ .sha256 大小不符" >&2; exit 1; }
      ;;
  esac
done <<EOF
$LIST
EOF
# 远端 .sha256 的内容也读回来核对一次（防 --clobber 上传错文件）
REMOTE_SHA=$(curl -fsSL "https://github.com/$REPO/releases/download/$TAG/$BASE.sha256" 2>/dev/null | awk 'NF>=2{print $1; exit}')
[ "$REMOTE_SHA" = "$SHA" ] || { echo "  ✗ 远端 .sha256 内容是 '$REMOTE_SHA'，与本地 $SHA 不符" >&2; exit 1; }
echo "  ✓ 远端 .sha256 内容一致"
echo "=== DONE: https://github.com/$REPO/releases/tag/$TAG ==="
