#!/data/data/com.termux/files/usr/bin/bash
# 通用发布：先建草稿 → 逐个 asset 重试上传并核对远端大小 → 全部到位才 publish。
#   usage: publish-deb.sh <版本后缀,如 10>
set -uo pipefail
V=${1:?用法: publish-deb.sh <版本后缀>}
cd "$HOME/termux-llvm-rust-mold" || exit 1
VER=23.1.3+rust1.100.0nightly+mold2.42.1-$V
TAG=v$VER
D=$HOME/toolchain-deb-out/llvm-rust-system_${VER}_aarch64.deb
NOTES=packaging/release-notes-$V.md
LOG=$HOME/termux-llvm-rust-mold/release-$V.log
[ -f "$D" ] || { echo "找不到 $D"; exit 1; }
[ -f "$NOTES" ] || NOTES=""
{
echo "### 发布 $TAG  $(date '+%F %T')   deb=$(stat -c '%s' "$D") bytes"
if ! gh release view "$TAG" >/dev/null 2>&1; then
  echo "--- 1) 建草稿"
  gh release create "$TAG" --draft --title "llvm-rust-system $VER" ${NOTES:+--notes-file "$NOTES"} 2>&1 | tail -2
else
  echo "--- 1) 已存在草稿，更新正文"
  gh release edit "$TAG" --draft ${NOTES:+--notes-file "$NOTES"} >/dev/null 2>&1
fi
up() {
  local f="$1" n=0
  while [ $n -lt 6 ]; do
    n=$((n+1)); echo "--- 2) 上传 $(basename "$f") 第 $n 次 $(date '+%H:%M:%S')"
    gh release upload "$TAG" "$f" --clobber 2>&1 | tail -1
    remote=$(gh release view "$TAG" --json assets -q ".assets[] | select(.name==\"$(basename "$f")\") | .size" 2>/dev/null)
    if [ -n "$remote" ] && [ "$remote" = "$(stat -c '%s' "$f")" ]; then
      echo "    ✅ 远端 $(basename "$f") = $remote bytes"; return 0
    fi
    echo "    远端大小不符（${remote:-空}），重试"; sleep 10
  done
  return 1
}
up "$D.sha256" || { echo "❌ sha256 上传失败"; exit 1; }
up "$D"        || { echo "❌ deb 上传失败（保持草稿）"; exit 1; }
echo "--- 3) publish"
gh release edit "$TAG" --draft=false --latest 2>&1 | tail -1
gh release view "$TAG" --json name,isDraft,isPrerelease,assets -q '"  \(.name)  draft=\(.isDraft) pre=\(.isPrerelease)", (.assets[] | "  asset: \(.name)  \(.size) B")'
echo "### DONE $(date '+%F %T')"
} 2>&1 | tee "$LOG"
