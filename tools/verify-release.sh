#!/data/data/com.termux/files/usr/bin/bash
# 发布验货：对一个 release（或本地 .deb）做结构与内容检查
#   usage: verify-release.sh [tag] [--deb PATH] [--extract] [--smoke] [--keep]
#
# 默认从 GitHub 取最新 release 并**全量下载**后检查（发布前在 Wi-Fi 上跑）。
# 判定分级：✗ = 会让下载者装坏/装不上（exit 非 0）；! = 与说明不符或已知不可用（仅提示）。
#
# 覆盖的坑（都真的踩过）：
#   - .sha256 里是构建机绝对路径 → 下载者 `sha256sum -c` 必然失败
#   - md5sums 条数与载荷常规文件数不一致 → 有文件没记录
#   - 绝对路径软链 → 换机器就是断链
#   - 缺 share/doc/*/copyright → 再分发缺许可
#   - release note 承诺跨 ABI rust-std / per-ABI wrapper，包里没有
#   - 缺 LLVMgold.so → mold 走 LTO 直接报 "could not open plugin file"
#   - 包内 llvm-bolt 在 AArch64 上 abort
set -euo pipefail

REPO=Gong-Mi/termux-llvm-rust-mold
PKG=llvm-rust-system
PREFIX_DIR=./data/data/com.termux/files/usr
WORK=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}/verify-release
TAG=""
DEB=""
DO_EXTRACT=0
DO_SMOKE=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --deb)     DEB=${2:-}; [ -n "$DEB" ] || { echo "--deb 需要路径" >&2; exit 1; }; shift 2 ;;
    --extract) DO_EXTRACT=1; shift ;;
    --smoke)   DO_SMOKE=1; shift ;;
    --keep)    KEEP=1; shift ;;
    -*)        echo "未知参数: $1" >&2; exit 1 ;;
    *)         TAG=$1; shift ;;
  esac
done

FAIL=0
WARN=0
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  ! $*"; WARN=$((WARN + 1)); }
ok()   { echo "  ✓ $*"; }
die()  { echo "错误: $*" >&2; exit 2; }

command -v dpkg-deb >/dev/null || die "需要 dpkg-deb"
command -v sha256sum >/dev/null || die "需要 sha256sum"

mkdir -p "$WORK"
cleanup() { if [ "$KEEP" = 1 ]; then echo "保留工作目录: $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

echo "=== 0/6 取包 ==="
REMOTE_BODY=""
REMOTE_DIGEST=""
REMOTE_SUM=""
TAG_NAME=""
if [ -n "$DEB" ]; then
  [ -f "$DEB" ] || die "找不到 $DEB"
  DEB=$(readlink -f "$DEB")
  ok "本地包: $DEB"
else
  command -v gh >/dev/null || die "远模式需要 gh（或用 --deb 验本地文件）"
  if [ -n "$TAG" ]; then
    line=$(gh api "repos/$REPO/releases/tags/$TAG" --jq '[(.tag_name), (.body // ""), (.assets[]|select(.name|endswith("_aarch64.deb"))|.browser_download_url), (.assets[]|select(.name|endswith("_aarch64.deb"))|.name), (.assets[]|select(.name|endswith("_aarch64.deb"))|(.digest // "n/a"))] | @tsv' 2>/dev/null) \
      || die "取 release $TAG 失败"
  else
    line=$(gh api "repos/$REPO/releases/latest" --jq '[(.tag_name), (.body // ""), (.assets[]|select(.name|endswith("_aarch64.deb"))|.browser_download_url), (.assets[]|select(.name|endswith("_aarch64.deb"))|.name), (.assets[]|select(.name|endswith("_aarch64.deb"))|(.digest // "n/a"))] | @tsv' 2>/dev/null) \
      || die "取 latest release 失败"
  fi
  TAG_NAME=$(printf '%s' "$line" | cut -f1)
  REMOTE_BODY=$(printf '%s' "$line" | cut -f2)
  URL=$(printf '%s' "$line" | cut -f3)
  NAME=$(printf '%s' "$line" | cut -f4)
  REMOTE_DIGEST=$(printf '%s' "$line" | cut -f5)
  [ -n "$URL" ] || die "release $TAG_NAME 里没有 ${PKG}_*_aarch64.deb"
  echo "  tag : $TAG_NAME"
  echo "  包  : $NAME"
  DEB="$WORK/$NAME"
  if [ -t 1 ]; then PB="--progress-bar"; else PB="-sS"; fi
  curl -fL "$PB" -o "$DEB" "$URL"
fi
SIZE=$(stat -c '%s' "$DEB")
NAME=$(basename "$DEB")
echo "  大小: $SIZE bytes  ($((SIZE / 1048576)) MiB)"

echo "=== 1/6 sha256 一致性 ==="
LOCAL_SHA=$(sha256sum "$DEB" | awk '{print $1}')
echo "  本地实算: $LOCAL_SHA"
if [ -z "$TAG_NAME" ]; then
  warn "本地模式：跳过 .sha256 asset / GitHub digest / release body 比对"
else
  SUM_URL="https://github.com/$REPO/releases/download/$TAG_NAME/$NAME.sha256"
  REMOTE_SUM=$(curl -fsSL "$SUM_URL" 2>/dev/null | awk 'NF>=2 {print $1; exit}' | tr 'A-Z' 'a-z' || true)
  [ -n "$REMOTE_SUM" ] || bad "无法下载 $NAME.sha256"
  if [ -n "$REMOTE_SUM" ]; then
    [ "$REMOTE_SUM" = "$LOCAL_SHA" ] && ok ".sha256 asset 与本地实算一致" || bad ".sha256 asset=$REMOTE_SUM != 本地 $LOCAL_SHA"
  fi
  case "$REMOTE_DIGEST" in
    "sha256:$LOCAL_SHA") ok "GitHub API digest 一致" ;;
    n/a)                 warn "GitHub API 未返回 digest，只能依赖 .sha256" ;;
    *)                   bad "GitHub digest=$REMOTE_DIGEST != sha256:$LOCAL_SHA" ;;
  esac
  BODY_SHA=$(printf '%s' "$REMOTE_BODY" | grep -oE '\b[0-9a-f]{64}\b' | head -1 || true)
  if [ -z "$BODY_SHA" ]; then
    warn "release body 里没有 sha256"
  elif [ "$BODY_SHA" = "$LOCAL_SHA" ]; then
    ok "release body 的 sha256 一致"
  else
    bad "release body sha256=$BODY_SHA != 本地 $LOCAL_SHA"
  fi
  # 说明里的下载大小（形如 "356 MiB" / "371885752 bytes"）与实际比对
  BODY_MIB=$(printf '%s' "$REMOTE_BODY" | grep -oE '[0-9]+ MiB' | head -1 | awk '{print $1}' || true)
  if [ -n "$BODY_MIB" ]; then
    REAL_MIB=$((SIZE / 1048576))
    [ "$BODY_MIB" = "$REAL_MIB" ] && ok "说明里的下载大小一致（${REAL_MIB} MiB）" || warn "说明写 ${BODY_MIB} MiB，实际 $((SIZE / 1048576)) MiB ($SIZE bytes)"
  fi
fi

echo "=== 2/6 包结构与 control ==="
LIST="$WORK/list.txt"
dpkg-deb -c "$DEB" > "$LIST" || die "dpkg-deb -c 失败（ar/xz 结构损坏？）"
CTRL="$WORK/ctrl"
rm -rf "$CTRL"
mkdir -p "$CTRL"
dpkg-deb -e "$DEB" "$CTRL" || die "dpkg-deb -e 失败（control 解不出来）"
GOT_PKG=$(dpkg-deb -f "$DEB" Package)
VER=$(dpkg-deb -f "$DEB" Version)
ARCH=$(dpkg-deb -f "$DEB" Architecture)
[ "$GOT_PKG" = "$PKG" ] || bad "Package=$GOT_PKG != $PKG"
[ "$ARCH" = "aarch64" ] || bad "Architecture=$ARCH != aarch64"
echo "  $GOT_PKG $VER ($ARCH)"
if [ -n "$TAG_NAME" ]; then
  A=$(printf '%s' "$TAG_NAME" | sed 's/^v//' | tr '+' '-')
  B=$(printf '%s' "$VER" | tr '+' '-')
  [ "$A" = "$B" ] || warn "tag($A) 与 Version($B) 规范不一致"
fi
for f in clang lld llvm libllvm rust libcompiler-rt mold; do
  dpkg-deb -f "$DEB" Conflicts | grep -qw -- "$f" || bad "Conflicts 缺 $f（替换官方包不安全）"
  dpkg-deb -f "$DEB" Replaces | grep -qw -- "$f" || bad "Replaces 缺 $f"
done
dpkg-deb -f "$DEB" Depends | grep -qw -- "libc++" || bad "Depends 缺 libc++（libc++_shared.so 来源）"

echo "=== 3/6 载荷清单 ==="
REG=$(awk '$1 ~ /^-/ {c++} END {print c + 0}' "$LIST")
DIRS=$(awk '$1 ~ /^d/ {c++} END {print c + 0}' "$LIST")
LINKS=$(awk '$1 ~ /^l/ {c++} END {print c + 0}' "$LIST")
echo "  常规文件 $REG / 目录 $DIRS / 符号链接 $LINKS"
SUMN=0
[ -f "$CTRL/md5sums" ] && SUMN=$(wc -l < "$CTRL/md5sums")
if [ "$SUMN" -eq 0 ]; then
  warn "包里没有 md5sums（dpkg -V 将无法校验文件内容）"
elif [ "$SUMN" -ne "$REG" ]; then
  bad "md5sums $SUMN 行 != 常规文件 $REG 个"
else
  ok "md5sums 覆盖全部 $REG 个常规文件"
fi
if [ -f "$CTRL/md5sums" ] && awk '$0 ~ /  \// {found = 1} END {exit !found}' "$CTRL/md5sums"; then
  bad "md5sums 里出现绝对路径条目"
fi

MISSING=0
# $1 是相对 $PREFIX 的路径；$6 == 完整路径才算存在（含 symlink 成员）
has_path() { awk -v p="$PREFIX_DIR/$1" '$1 ~ /^[-l]/ && $6 == p {found = 1} END {exit !found}' "$LIST"; }
for f in bin/clang bin/clang++ bin/cc bin/clang-24 bin/lld bin/ld.lld bin/rustc bin/rustdoc bin/cargo bin/mold \
         lib/libLLVM.so.24.0git lib/libLLVM.so.23.1-rc1 lib/libclang-cpp.so.24.0git \
         share/doc/$PKG/provenance.json; do
  has_path "$f" || { bad "缺 $f"; MISSING=$((MISSING + 1)); }
done
awk -v dir="$PREFIX_DIR/lib" '$1 ~ /^[-l]/ && index($6, dir "/librustc_driver-") == 1 && $6 ~ /\.so$/ {f = 1} END {exit !f}' "$LIST" \
  || bad "缺 lib/librustc_driver-<hash>.so（rustc 运行时依赖）"
[ "$MISSING" = 0 ] && ok "关键文件齐全"

echo "=== 4/6 符号链接 / 许可 / 能力件 ==="
ABS=$(awk '$1 ~ /^l/ && $8 ~ /^\// {print "    " $6 " -> " $8}' "$LIST")
if [ -n "$ABS" ]; then
  bad "绝对路径软链（装到别的机器就是断链）:"
  echo "$ABS"
else
  ok "无绝对路径软链"
fi
if has_path "share/doc/$PKG/copyright"; then
  ok "随包带了 share/doc/$PKG/copyright"
else
  bad "缺 share/doc/$PKG/copyright（LLVM Apache-2.0 WITH LLVM-exception、Rust MIT/Apache 需要随包分发许可）"
fi
for f in share/doc/rust/COPYRIGHT.html share/doc/rust/COPYRIGHT-library.html share/doc/cargo/LICENSE-MIT share/doc/cargo/LICENSE-APACHE; do
  has_path "$f" || warn "缺 $f（rust/cargo 许可与版权文件）"
done
if has_path "lib/LLVMgold.so"; then
  ok "lib/LLVMgold.so 在包内（mold + LTO 需要）"
else
  bad "缺 lib/LLVMgold.so → clang -flto -fuse-ld=mold 会报 'could not open plugin file'"
fi
if has_path "lib/mold-wrapper.so"; then
  ok "lib/mold-wrapper.so 在包内"
else
  bad "缺 lib/mold-wrapper.so（README 承诺 mold + ld.mold + mold-wrapper.so）"
fi
if has_path "bin/llvm-bolt"; then
  warn "包内含 llvm-bolt；AArch64 上实测 abort（LLVM ERROR: annotation value out of range），确认是否要发"
fi

for t in armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
  awk -v d="$PREFIX_DIR/lib/rustlib/$t/lib/" '$1 ~ /^[-l]/ && index($6, d) == 1 {f = 1} END {exit !f}' "$LIST" \
    || bad "缺跨 ABI rust-std: $t"
done
# 跨 ABI 链接还要求每个架构的 compiler-rt builtins（-11 有 5 个 ABI，-3 只剩 aarch64）
for b in arm i686 x86_64; do
  awk -v re="lib/clang/[0-9]+/lib/linux/libclang_rt\\.builtins-$b-android\\.a$" '$1 ~ /^-/ && $6 ~ re {f = 1} END {exit !f}' "$LIST" \
    || bad "缺跨 ABI compiler-rt: libclang_rt.builtins-$b-android.a（换架构链接会报 cannot open ...builtins.a）"
done
# sanitizer 运行时：-5 只带 builtins/fuzzer/profile，`clang -fsanitize=undefined|address`
# 会报 cannot open .../lib/clang/<ver>/lib/linux/libclang_rt.ubsan_standalone-<arch>-android.so。
# 本包 Provides: libcompiler-rt，就必须自己带齐（用 packaging/build-sanitizer-runtimes.sh 编）。
for r in ubsan_standalone ubsan_minimal asan; do
  awk -v re="lib/clang/[0-9]+/lib/linux/libclang_rt\\.${r}-aarch64-android\\.so$" '$1 ~ /^-/ && $6 ~ re {f = 1} END {exit !f}' "$LIST" \
    || bad "缺 sanitizer 运行时 libclang_rt.${r}-aarch64-android.so（-fsanitize=undefined/address 会链接失败）"
done
if awk -v re="lib/clang/[0-9]+/lib/linux/libclang_rt\\.ubsan_standalone-aarch64-android\\.so$" '$1 ~ /^-/ && $6 ~ re {f = 1} END {exit !f}' "$LIST"; then
  ok "包内带 sanitizer 运行时（ubsan_standalone / ubsan_minimal / asan）"
fi
for w in armv7-linux-androideabi-clang armv7a-linux-androideabi30-clang i686-linux-android-clang \
         i686-linux-android30-clang x86_64-linux-android-clang x86_64-linux-android30-clang; do
  has_path "bin/$w" || bad "缺 per-ABI linker wrapper: bin/$w"
done

echo "=== 5/6 解包校验 ==="
if [ "$DO_EXTRACT" = 1 ]; then
  STAGE="$WORK/stage"
  rm -rf "$STAGE"
  dpkg-deb -x "$DEB" "$STAGE"
  if [ "$SUMN" -gt 0 ]; then
    if ( cd "$STAGE/$PREFIX_DIR" && md5sum -c --quiet "$CTRL/md5sums" ); then
      ok "解包后 md5sum -c 全部通过（$SUMN 项）"
    else
      bad "解包后 md5sum -c 有失败项"
    fi
  fi
else
  echo "  （跳过；加 --extract 做全量 md5 校验）"
fi

echo "=== 6/6 冒烟（从解包目录跑，不安装）==="
if [ "$DO_SMOKE" = 1 ]; then
  STAGE="$WORK/stage"
  [ -d "$STAGE" ] || dpkg-deb -x "$DEB" "$STAGE"
  P="$STAGE/$PREFIX_DIR"
  (
    export LD_LIBRARY_PATH="$P/lib:${PREFIX:-/data/data/com.termux/files/usr}/lib"
    export PATH="$P/bin:$PATH"
    echo "  clang : $("$P/bin/clang-24" --version | head -1)"
    echo "  rustc : $("$P/bin/rustc" -vV | head -1)"
    echo "  cargo : $("$P/bin/cargo" --version)"
    echo "  mold  : $("$P/bin/mold" --version)"
    printf '#include <pthread.h>\nstatic __thread int v;\nvoid *f(void*a){v=(int)(long)a;return 0;}\nint main(void){pthread_t t;pthread_create(&t,0,f,(void*)7);pthread_join(t,0);return v!=0;}\n' > "$WORK/tls.c"
    for ld in default mold; do
      out="$WORK/tls_$ld"
      if [ "$ld" = mold ]; then extra="-fuse-ld=mold"; else extra=""; fi
      if "$P/bin/clang" -fno-emulated-tls $extra "$WORK/tls.c" -lpthread -o "$out" 2>"$WORK/ld.log"; then
        ALIGN=$("$P/bin/llvm-readelf" -lW "$out" | awk '/^ *TLS/ {print $NF}')
        if [ "$ALIGN" = "0x40" ]; then echo "  TLS($ld): PT_TLS align=$ALIGN ✓"; else bad "TLS($ld): PT_TLS align=$ALIGN != 0x40"; fi
        "$out" && echo "  TLS($ld): 运行通过" || bad "TLS($ld): 运行失败"
      else
        bad "TLS($ld): 链接失败（$(head -1 "$WORK/ld.log")）"
      fi
    done
  ) || bad "冒烟子壳失败"
else
  echo "  （跳过；加 --smoke 跑 clang/rustc/cargo/mold + TLS 探针）"
fi

echo
echo "=== 汇总: FAIL=$FAIL  WARN=$WARN ==="
if [ "$FAIL" -ne 0 ]; then
  echo "验货不通过：先修上面的 ✗ 再发。"
  exit 1
fi
echo "验货通过${WARN:+（有 $WARN 条提示）}。"
