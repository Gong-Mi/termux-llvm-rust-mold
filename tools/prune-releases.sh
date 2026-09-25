#!/data/data/com.termux/files/usr/bin/bash
# 只保留最近 N 个版本 release，删除更旧的（tag 一并删）
#   usage: prune-releases.sh [N=3] [--dry-run]
# 目的: 每个包约 306 MiB，GitHub 仓库总体积建议 < 5 GB
set -euo pipefail

REPO=Gong-Mi/termux-llvm-rust-mold
KEEP=${1:-3}
MODE=${2:-}

echo "=== 当前 release（新 → 旧）==="
gh release list -R "$REPO" --limit 100

TAGS=$(gh release list -R "$REPO" --limit 100 --json tagName,createdAt \
       -q 'sort_by(.createdAt)|reverse|.[].tagName')
KEEP_TAGS=$(printf '%s\n' "$TAGS" | head -n "$KEEP")
DROP_TAGS=$(printf '%s\n' "$TAGS" | tail -n +$((KEEP + 1)))

if [ -z "$DROP_TAGS" ]; then
  echo "=== 无需删除（共 $(printf '%s\n' "$TAGS" | wc -l) 个，保留 $KEEP）==="
  exit 0
fi

echo "=== 保留 ==="
printf '  %s\n' $KEEP_TAGS
echo "=== 待删 ==="
printf '  %s\n' $DROP_TAGS
[ "$MODE" = "--dry-run" ] && { echo "dry-run: 未删除"; exit 0; }

for t in $DROP_TAGS; do
  echo "--- 删除 $t"
  gh release delete "$t" -R "$REPO" --yes --cleanup-tag
done

echo "=== 剩余 ==="
gh release list -R "$REPO" --limit 100
