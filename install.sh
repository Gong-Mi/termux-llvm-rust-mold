#!/data/data/com.termux/files/usr/bin/bash
# 安装 termux-llvm-rust-mold 最新版（或指定 tag）
#   usage: install.sh [--check] [tag]
#          --check  只解析并打印将要下载的 release/asset，不下载不安装
#   例:    install.sh                      # 最新版
#          install.sh v23.1.3-rust1.100.0nightly-mold2.42.1-2
# 流程: 校验环境 → 按 asset 名挑 release → sha256 校验 → apt install ./deb → 安装后核对
#
# 注意: 不能只信 releases/latest —— 仓库里还有其它非版本 release（如官方回滚包），
# 那个指针会被最新的 release 抢走。这里按 asset 名 llvm-rust-system_*_aarch64.deb 过滤，
# 并核对下载到的 .deb 的 Package 字段，拒绝装错包。
set -euo pipefail

REPO=Gong-Mi/termux-llvm-rust-mold
PKG=llvm-rust-system
CHECK=0
TAG=""
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -*) echo "未知参数: $a" >&2; exit 1 ;;
    *) TAG="$a" ;;
  esac
done
TMP=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}/llvm-rust-mold-install
API=https://api.github.com/repos/$REPO

die() { echo "错误: $*" >&2; exit 1; }

echo "=== 0/5 环境检查 ==="
[ -n "${PREFIX:-}" ] || die "不是 Termux 环境（\$PREFIX 未设置）"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "本包只有 aarch64/arm64 版本，当前架构 $(uname -m)" ;;
esac
command -v curl     >/dev/null || die "缺少 curl：pkg install curl"
command -v dpkg-deb >/dev/null || die "缺少 dpkg（不应发生）"
echo "  架构 $(uname -m)  PREFIX=$PREFIX"

echo "=== 1/5 解析 release ==="
if [ -n "$TAG" ]; then
  JSON=$(curl -fsSL "$API/releases/tags/$TAG") || die "取 release $TAG 失败（网络/代理？）"
else
  JSON=$(curl -fsSL "$API/releases?per_page=30") || die "取 release 列表失败（网络/代理？）"
fi
# 只认本包命名的 asset；列表按新→旧排序，所以 head -1 即最新版本
ASSET=$(printf '%s' "$JSON" \
        | grep -o "https://[^\"]*/releases/download/[^\"]*/${PKG}_[^\"]*_aarch64\.deb" \
        | head -1 || true)
[ -n "$ASSET" ] || die "没找到 ${PKG}_*_aarch64.deb（tag 写错？release 还没发布？）"
# asset 名从 API 的 name 字段取（URL 里的 + 被编码成 %2B，不能直接 basename）
DEB=$(printf '%s' "$JSON" \
      | grep -o "\"name\": *\"${PKG}_[^\"]*_aarch64\.deb\"" | head -1 \
      | sed -E 's/.*"name": *"([^"]+)".*/\1/' || true)
[ -n "$DEB" ] || die "release 里 asset 名解析失败"
TAG_NAME=$(printf '%s' "$ASSET" | sed -E 's#.*/releases/download/([^/]+)/.*#\1#')
echo "  tag   : $TAG_NAME"
echo "  包    : $DEB"

if [ "$CHECK" = "1" ]; then
  echo "  URL   : $ASSET"
  echo "=== --check: 不下载不安装 ==="
  exit 0
fi

echo "=== 2/5 下载 ==="
rm -rf "$TMP"; mkdir -p "$TMP"
curl -fL --progress-bar -o "$TMP/$DEB" "$ASSET"
if curl -fsSL -o "$TMP/$DEB.sha256" "$ASSET.sha256"; then
  :
else
  echo "  （release 未提供 .sha256，跳过校验）"
fi

echo "=== 3/5 校验 ==="
GOT_PKG=$(dpkg-deb -f "$TMP/$DEB" Package 2>/dev/null || true)
[ "$GOT_PKG" = "$PKG" ] || die "下载到的包是 '${GOT_PKG:-无法识别}'，不是 $PKG，拒绝安装"
echo "  Package 字段: $GOT_PKG ✔"
if [ -f "$TMP/$DEB.sha256" ]; then
  (cd "$TMP" && sha256sum -c "$DEB.sha256") || die "sha256 校验失败，文件可能损坏"
else
  echo "  本地 sha256: $(sha256sum "$TMP/$DEB" | cut -d' ' -f1)"
fi

echo "=== 4/5 apt install ./$DEB ==="
echo "  说明：用 apt 而不是 dpkg -i，apt 会自动移除冲突的官方包"
echo "        (clang lld llvm libllvm rust libcompiler-rt mold)"
apt install -y "$TMP/$DEB"

echo "=== 5/5 安装后核对 ==="
dpkg -V "$PKG" && echo "  dpkg -V: 干净"
dpkg -l "$PKG" | tail -1
echo "  clang : $(clang --version | head -1)"
echo "  rustc : $(rustc -vV | head -1) / LLVM $(rustc -vV | sed -n 's/^LLVM version: //p')"
echo "  cargo : $(cargo --version)"
echo "  mold  : $(mold --version)"
echo "  许可  : $(ls $PREFIX/share/doc/$PKG/copyright)"
echo
echo "完成。回滚见 README 的 卸载/回滚 一节。"
