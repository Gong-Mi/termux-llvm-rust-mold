#!/data/data/com.termux/files/usr/bin/bash
# 在已发布包（默认 -10）的数据层上追加：① 三个 ABI 的 rust-std；② per-ABI clang wrapper
# （NDK 与 rust 两种命名，rustc/cc-rs 都能找）；③ 用法文档；④ Recommends。产出 -11。
set -uo pipefail
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
H=$HOME
BASE=${1:-$H/toolchain-deb-out/llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-10_aarch64.deb}
NEWVER=${2:-23.1.3+rust1.100.0nightly+mold2.42.1-11}
OUT=${3:-$H/toolchain-deb-out}
STD=${4:-$H/rust-std-stage$PREFIX/lib/rustlib}
W=$H/termux-llvm-rust-mold/packaging
STAGE=$H/toolchain-ruststd-stage
TARGET=${OUT}/llvm-rust-system_${NEWVER}_aarch64.deb
P=${STAGE}${PREFIX}

echo "=== 0/6 输入 ==="
echo "  base  : $BASE"
[ -f "$BASE" ] || { echo "找不到 base"; exit 1; }
echo "  newver: $NEWVER"
echo "  std 来源: $STD"
for a in armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
  [ -d "$STD/$a/lib" ] || { echo "缺 $STD/$a/lib（先跑 run-ruststd-loop.sh）"; exit 1; }
  printf '    %-26s %s 项\n' "$a" "$(ls "$STD/$a/lib" | wc -l)"
done

echo "=== 1/6 解包 ==="
rm -rf "$STAGE"; mkdir -p "$STAGE"
dpkg-deb -R "$BASE" "$STAGE" || exit 1
echo "  文件数: $(find "$STAGE" -type f | wc -l)"

echo "=== 2/6 追加 rust-std ==="
for a in armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
  mkdir -p "$P/lib/rustlib/$a"
  rm -rf "$P/lib/rustlib/$a/lib"
  cp -a "$STD/$a/lib" "$P/lib/rustlib/$a/lib"
  printf '  %-26s → %s 项\n' "$a" "$(ls "$P/lib/rustlib/$a/lib" | wc -l)"
done

echo "=== 3/6 追加 per-ABI clang wrapper（NDK + rust 两种命名）==="
mkdir -p "$P/bin"
declare -A TGT=( [armv7a]=armv7a-linux-androideabi30 [i686]=i686-linux-android30 [x86_64]=x86_64-linux-android30 )
declare -A RUSTT=( [armv7a]=armv7-linux-androideabi [i686]=i686-linux-android [x86_64]=x86_64-linux-android )
for abi in armv7a i686 x86_64; do
  for name in "${TGT[$abi]}-clang" "${RUSTT[$abi]}-clang"; do
    cat > "$P/bin/$name" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# 强制 ${RUSTT[$abi]} 目标（无条件注入 --target=；rustc 链接 std dylib 时不传 --target=）
args=(); for a in "\$@"; do case "\$a" in --target=*) ;; *) args+=("\$a");; esac; done
exec ${PREFIX}/bin/clang --target=${TGT[$abi]} "\${args[@]}"
EOF
    chmod 700 "$P/bin/$name"
  done
  # C++ 版（cc-rs 的 CXX）
  name="${RUSTT[$abi]}-clang++"
  cat > "$P/bin/$name" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
args=(); for a in "\$@"; do case "\$a" in --target=*) ;; *) args+=("\$a");; esac; done
exec ${PREFIX}/bin/clang++ --target=${TGT[$abi]} "\${args[@]}"
EOF
  chmod 700 "$P/bin/$name"
done
ls -1 "$P/bin" | grep -E 'clang(\+\+)?$' | sed 's/^/    /'

echo "=== 4/6 用法文档 ==="
mkdir -p "$P/share/doc/llvm-rust-system"
cat > "$P/share/doc/llvm-rust-system/RUST-CROSS-ABI.md" <<'EOF'
# 用本包做跨 ABI 的 Rust 编译

本包内含 4 个 Android ABI 的 rust-std：aarch64 / armv7 / i686 / x86_64
（aarch64-linux-android 是宿主，随 rustc 一起装）。

rustc 默认用 `cc` 当链接器（在本机就是 aarch64 的），所以**跨 ABI 时必须指定 linker**
——包内已按 NDK 与 rust 两种命名装好强制目标的 wrapper：

| 目标三元组 | 建议 linker |
|---|---|
| armv7-linux-androideabi | `armv7-linux-androideabi-clang`（或 `armv7a-linux-androideabi30-clang`） |
| i686-linux-android      | `i686-linux-android-clang` |
| x86_64-linux-android    | `x86_64-linux-android-clang` |

一次性用法：

    rustc --target=armv7-linux-androideabi \
          -C linker=armv7-linux-androideabi-clang \
          hello.rs -o hello_arm

cargo 用环境变量（推荐写进 `~/.cargo/config.toml`）：

    [target.armv7-linux-androideabi]
    linker = "armv7-linux-androideabi-clang"

链接 32 位目标还需要系统侧的多 ABI sysroot（本包的 Recommends）：

    pkg install ndk-multilib ndk-multilib-native-static ndk-multilib-native-stubs

注意：本机（Android 17）已移除 32 位支持（`abilist32` 为空），armv7/i686 产物
**能编能链但不能在本机运行**，请拿到 32 位设备/模拟器上跑。aarch64 产物本机可跑。
EOF

echo "=== 5/6 重写 control ==="
SIZE=$(du -sk "$STAGE" | cut -f1)
{
  echo "Package: llvm-rust-system"
  echo "Version: $NEWVER"
  echo "Maintainer: $(dpkg-deb -f "$BASE" Maintainer)"
  echo "Architecture: aarch64"; echo "Section: devel"; echo "Priority: optional"
  echo "Homepage: https://github.com/Gong-Mi/termux-llvm-rust-mold"
  echo "Installed-Size: $SIZE"
  for f in Replaces Provides Depends Conflicts; do
    v=$(dpkg-deb -f "$BASE" "$f" 2>/dev/null || true); [ -n "$v" ] && echo "$f: $v"
  done
  echo "Recommends: ndk-multilib, ndk-multilib-native-static, ndk-multilib-native-stubs, ndk-sysroot"
  echo "Description: $(dpkg-deb -f "$BASE" Description | head -1 | sed 's/^Description: //')"
  dpkg-deb -f "$BASE" Description | tail -n +2 | sed 's/^ / /'
  echo " Also ships rust-std for armv7/i686/x86_64 and per-ABI target-forcing clang wrappers."
} > "$STAGE/DEBIAN/control"

echo "=== 6/6 构建 (xz -6) ==="
mkdir -p "$OUT"; rm -f "$TARGET" "$TARGET.sha256"
time DPKG_DEB_THREADS_MAX=${DPKG_DEB_THREADS_MAX:-4} dpkg-deb --build --root-owner-group -Zxz -z6 "$STAGE" "$TARGET"
sha256sum "$TARGET" | tee "$TARGET.sha256"
echo "包内文件数: $(dpkg-deb -c "$TARGET" | wc -l)"
echo "=== 回读：包内 rustlib 与 linker 脚本 ==="
dpkg-deb -c "$TARGET" | grep -cE 'lib/rustlib/(armv7-linux-androideabi|i686-linux-android|x86_64-linux-android)/lib/' | sed 's/^/  rust-std 条目: /'
dpkg-deb -c "$TARGET" | grep -oE 'bin/[a-z0-9_]+-clang\+\?' | sort -u | sed 's/^/  /'
echo "=== DONE: $TARGET $(date '+%F %T') ==="
