#!/data/data/com.termux/files/usr/bin/bash
# 发布链路回归测试（不需要网络、不需要 gh）
#   1) install.sh 的 check_sha256 能接受「绝对路径」形状的 .sha256（-3 实际发出去的那种）
#   2) 载荷内容不符时必须失败
#   3) publish-release.sh --dry-run 会把绝对路径 .sha256 重建成 basename 形式
#   4) 已经是 basename 形式时保持幂等
#
#   usage: tools/test-publish-chain.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
BASE_TMP=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
T=$(mktemp -d "$BASE_TMP/publish-chain.XXXXXX") || { echo "mktemp 失败" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

PASS=0
FAILED=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAILED=$((FAILED + 1)); }

echo "=== 1/4 install.sh: 绝对路径 .sha256 仍按哈希校验 ==="
DEB="$T/llvm-rust-system_9.9.9_aarch64.deb"
head -c 65536 /dev/urandom > "$DEB"
SHA=$(sha256sum "$DEB" | awk '{print $1}')
printf '%s  %s\n' "$SHA" "/data/data/com.termux/files/home/toolchain-deb-out/$(basename "$DEB")" > "$T/abs.sha256"
if out=$( ( export LLVMRM_SOURCE_ONLY=1; . "$HERE/install.sh"; check_sha256 "$DEB" "$T/abs.sha256" ) 2>&1 ); then
  pass "校验通过：$out"
else
  fail "绝对路径 .sha256 被拒：$out"
fi

echo "=== 2/4 install.sh: 内容被改动必须失败 ==="
cp "$DEB" "$T/bad.deb"
printf 'X' | dd of="$T/bad.deb" bs=1 seek=100 conv=notrunc 2>/dev/null
if ( export LLVMRM_SOURCE_ONLY=1; . "$HERE/install.sh"; check_sha256 "$T/bad.deb" "$T/abs.sha256" ) >/dev/null 2>&1; then
  fail "被改动过的 .deb 竟然通过了校验"
else
  pass "哈希不符时校验失败"
fi

echo "=== 3/4 publish-release.sh: 重建 basename .sha256 ==="
mkdir -p "$T/pub"
cp "$DEB" "$T/pub/"
printf '%s  %s\n' "$SHA" "/data/data/com.termux/files/home/toolchain-deb-out/llvm-rust-system_9.9.9_aarch64.deb" > "$T/pub/llvm-rust-system_9.9.9_aarch64.deb.sha256"
if bash "$HERE/tools/publish-release.sh" "$T/pub/llvm-rust-system_9.9.9_aarch64.deb" --dry-run > "$T/pub.log" 2>&1; then
  SUM="$T/pub/llvm-rust-system_9.9.9_aarch64.deb.sha256"
  [ "$(awk '{print NF}' "$SUM")" = "2" ] && pass ".sha256 只有两列" || fail ".sha256 列数不对: $(cat "$SUM")"
  [ "$(awk '{print $2}' "$SUM")" = "llvm-rust-system_9.9.9_aarch64.deb" ] \
    && pass ".sha256 第二列是 basename（不再是构建机绝对路径）" \
    || fail ".sha256 仍然是 $(awk '{print $2}' "$SUM")"
  [ "$(awk '{print $1}' "$SUM")" = "$SHA" ] && pass ".sha256 哈希与文件一致" || fail ".sha256 哈希不对"
  grep -q '不是 basename 形式' "$T/pub.log" && pass "日志提示了旧格式重建" || fail "日志没提示旧格式"
else
  fail "publish-release.sh --dry-run 跑失败: $(tail -3 "$T/pub.log")"
fi

echo "=== 4/4 publish-release.sh: 重复跑保持幂等 ==="
BEFORE=$(cat "$T/pub/llvm-rust-system_9.9.9_aarch64.deb.sha256")
if bash "$HERE/tools/publish-release.sh" "$T/pub/llvm-rust-system_9.9.9_aarch64.deb" --dry-run > "$T/pub2.log" 2>&1; then
  [ "$(cat "$T/pub/llvm-rust-system_9.9.9_aarch64.deb.sha256")" = "$BEFORE" ] && pass "第二次运行 .sha256 不变" || fail "第二次运行改了 .sha256"
  grep -q '不是 basename 形式' "$T/pub2.log" && fail "第二次仍报旧格式（不该）" || pass "第二次不再报旧格式"
else
  fail "第二次 dry-run 失败: $(tail -3 "$T/pub2.log")"
fi

echo
echo "=== 汇总: PASS=$PASS FAIL=$FAILED ==="
[ "$FAILED" -eq 0 ]
