#!/data/data/com.termux/files/usr/bin/bash
# 发布 -8：先建草稿 → 重试式上传 assets → 全部成功才 publish。
# （gh release create 一次带大文件时，428MB 上传中途停滞会被 GitHub 以 HTTP 408 掐掉，
#   且失败后草稿会被回收；分开重试更稳。）
set -uo pipefail
cd "$HOME/termux-llvm-rust-mold" || exit 1
TAG=v23.1.3-rust1.100.0nightly-mold2.42.1-8
VER=23.1.3+rust1.100.0nightly+mold2.42.1-8
D=$HOME/toolchain-deb-out/llvm-rust-system_${VER}_aarch64.deb
NOTES=packaging/release-notes-8.md
LOG=$HOME/termux-llvm-rust-mold/release-8.log
{
echo "### 发布 $TAG  $(date '+%F %T')"
echo "  deb: $(stat -c '%s' $D) bytes"

# 1) 草稿（不带 assets）
if ! gh release view "$TAG" >/dev/null 2>&1; then
  echo "--- 1) 建草稿 release"
  gh release create "$TAG" --draft --title "llvm-rust-system $VER" --notes-file "$NOTES" 2>&1 | tail -2
else
  echo "--- 1) release 已存在，编辑为草稿并更新正文"
  gh release edit "$TAG" --draft --notes-file "$NOTES" >/dev/null 2>&1
fi

# 2) 重试式上传
up() {  # $1=文件
  local f="$1" n=0
  while [ $n -lt 6 ]; do
    n=$((n+1))
    echo "--- 2) 上传 $(basename "$f") 第 $n 次  $(date '+%H:%M:%S')"
    if gh release upload "$TAG" "$f" --clobber 2>&1 | tail -1; then
      # 校验远端已有且大小一致
      remote=$(gh release view "$TAG" --json assets -q ".assets[] | select(.name==\"$(basename "$f")\") | .size" 2>/dev/null)
      if [ -n "$remote" ] && [ "$remote" = "$(stat -c '%s' "$f")" ]; then
        echo "    ✅ 远端 $(basename "$f") = $remote bytes"; return 0
      fi
      echo "    远端大小不符（remote=${remote:-空}），重试"
    fi
    sleep 10
  done
  return 1
}
up "$D.sha256" || { echo "❌ sha256 上传失败"; exit 1; }
up "$D"        || { echo "❌ deb 上传失败（重试 6 次仍不稳），release 保持草稿"; exit 1; }

# 3) 发布
echo "--- 3) publish"
gh release edit "$TAG" --draft=false --latest 2>&1 | tail -2
gh release view "$TAG" --json name,isDraft,isPrerelease,assets -q '"  \(.name)  draft=\(.isDraft) pre=\(.isPrerelease)", (.assets[] | "  asset: \(.name)  \(.size) B")'
echo "### DONE $(date '+%F %T')"
} 2>&1 | tee "$LOG"
