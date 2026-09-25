#!/data/data/com.termux/files/usr/bin/bash
# 安装 termux-llvm-rust-mold 最新版（或指定 tag）
#   usage: install.sh [tag]        例: install.sh v23.1.3-rust1.100.0-mold2.42.1-2
# 流程: 校验环境 → 取 release asset → sha256 校验 → apt install ./deb → 安装后核对
set -euo pipefail

REPO=Gong-Mi/termux-llvm-rust-mold
TAG=${1:-}
TMP=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}/llvm-rust-mold-install
PKG=llvm-rust-system

die() { echo "错误: $*" >&2; exit 1; }

echo "=== 0/5 环境检查 ==="
[ -n "${PREFIX:-}" ] || die "不是 Termux 环境（\$PREFIX 未设置）"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "本包只有 aarch64/arm64 版本，当前架构 $(uname -m)" ;;
esac
command -v curl >/dev/null || die "缺少 curl：pkg install curl"
command -v apt  >/dev/null || die "缺少 apt"
echo "  架构 $(uname -m)  PREFIX=$PREFIX"

echo "=== 1/5 查询 release ==="
if [ -n "$TAG" ]; then
  URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
else
  URL="https://api.github.com/repos/$REPO/releases/latest"
fi
JSON=$(curl -fsSL "$URL") || die "取 release 信息失败（网络/代理？）"
TAG_NAME=$(printf '%s' "$JSON" | grep -m1 '"tag_name"' | sed 's/.*: *"\(.*\)",*/\1/')
[ -n "$TAG_NAME" ] || die "release 里没有 tag_name（tag 不存在？）"
ASSET=$(printf '%s' "$JSON" \
        | grep -o "https://[^\"]*_aarch64\.deb" | head -1)
[ -n "$ASSET" ] || die "该 release 没有 *_aarch64.deb"
DEB=$(basename "$ASSET")
echo "  tag=$TAG_NAME"
echo "  包=$DEB"

echo "=== 2/5 下载 ==="
rm -rf "$TMP"; mkdir -p "$TMP"
curl -fL --progress-bar -o "$TMP/$DEB" "$ASSET"
curl -fsSL -o "$TMP/$DEB.sha256" "$ASSET.sha256" || echo "  （release 未提供 .sha256，跳过校验）"

echo "=== 3/5 校验 sha256 ==="
if [ -f "$TMP/$DEB.sha256" ]; then
  (cd "$TMP" && sha256sum -c "$DEB.sha256")
else
  echo "  未校验：$(sha256sum "$TMP/$DEB" | cut -d' ' -f1)"
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
