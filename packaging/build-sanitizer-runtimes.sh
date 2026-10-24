#!/data/data/com.termux/files/usr/bin/bash
# 构建 compiler-rt 的 **sanitizer 运行时**（ubsan / asan / lsan / hwasan / stats）
# 并装进工具链的资源目录。
#
# 为什么需要这一步：联合包只装 compiler-rt 的 builtins/fuzzer/profile，
# `clang -fsanitize=undefined` 会报
#   ld.lld: error: cannot open .../lib/clang/<ver>/lib/linux/libclang_rt.ubsan_standalone-aarch64-android.so
# 官方 libcompiler-rt 包带这些运行时，本包 Provides: libcompiler-rt 就必须自己带齐。
#
# 用法:
#   build-sanitizer-runtimes.sh [compiler-rt 源码目录] [暂存目录]
# 环境变量:
#   CLANG=clang 的绝对路径（默认 $PREFIX/bin/clang-24）
#   TARGET=目标三元组（默认 aarch64-unknown-linux-android24）
#   BUILD=构建目录（默认 $HOME/llvm-crt-build）
#   JOBS=并行度（默认 nproc）
set -euo pipefail
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
SRC=${1:-$HOME/llvm-src-24/compiler-rt}
STAGE=${2:-$HOME/llvm-sanitizers-stage}
CLANG=${CLANG:-$PREFIX/bin/clang-24}
CLANGXX=${CLANGXX:-$PREFIX/bin/clang++}
TARGET=${TARGET:-aarch64-unknown-linux-android24}
BUILD=${BUILD:-$HOME/llvm-crt-build}
JOBS=${JOBS:-$(nproc)}

[ -f "$SRC/CMakeLists.txt" ] || { echo "错误: 找不到 compiler-rt 源码: $SRC" >&2; exit 1; }
[ -x "$CLANG" ] || { echo "错误: 找不到 clang: $CLANG" >&2; exit 1; }
RES=$("$CLANG" -print-resource-dir)
VER=$(basename "$RES")
echo "clang=$CLANG  version=$("$CLANG" --version | head -1)"
echo "resource-dir=$RES  (clang/$VER)  target=$TARGET  jobs=$JOBS"

cmake -G Ninja -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CLANG" \
  -DCMAKE_CXX_COMPILER="$CLANGXX" \
  -DCMAKE_ASM_COMPILER="$CLANG" \
  -DCMAKE_C_COMPILER_TARGET="$TARGET" \
  -DCMAKE_CXX_COMPILER_TARGET="$TARGET" \
  -DLLVM_CONFIG_PATH="$PREFIX/bin/llvm-config" \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
  -DCOMPILER_RT_BUILD_SANITIZERS=ON \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
  -DCOMPILER_RT_INSTALL_PATH="$RES"

ninja -C "$BUILD" -j"$JOBS"

# 只装 sanitizer 一族：builtins/profile 由 LLVM 主构建提供，不要覆盖。
DESTDIR="$STAGE" cmake --install "$BUILD" >/dev/null
SRCDIR="$STAGE$RES/lib/linux"
[ -d "$SRCDIR" ] || { echo "错误: 暂存目录里没有 $SRCDIR" >&2; exit 1; }

# 资源目录里可能没有 lib/linux（本包 -5 就是这种情况），先建。
mkdir -p "$RES/lib/linux"
n=0
for f in "$SRCDIR"/libclang_rt.{asan,asan_cxx,asan_static,asan-preinit,hwasan,hwasan_cxx,hwasan-preinit,lsan,stats,stats_client,ubsan_minimal,ubsan_standalone,ubsan_standalone_cxx,ubsan_loop_detect}-*-android.*; do
  [ -e "$f" ] || continue
  install -m 644 "$f" "$RES/lib/linux/$(basename "$f")"
  n=$((n + 1))
done
echo "装入 $n 个 sanitizer 运行时 → $RES/lib/linux/"

# 判据：能链接 + 能真实报错，缺一不可。
TMP=$(mktemp -d "$HOME/.hermes/cache/scratch/crt-smoke.XXXXXX" 2>/dev/null || mktemp -d)
printf '#include <stdio.h>\nint f(int a,int b){return a*b;}\nint main(void){volatile int a=0x7fffffff,b=2;printf("%%d\\n",f(a,b));return 0;}\n' > "$TMP/t.c"
"$CLANG" -fsanitize=undefined -O1 "$TMP/t.c" -o "$TMP/t_u"
"$TMP/t_u" 2>"$TMP/u.err" >/dev/null || true
grep -q "runtime error: signed integer overflow" "$TMP/u.err" \
  || { echo "错误: UBSan 冒烟未报错 → 运行时没接上" >&2; cat "$TMP/u.err" >&2; exit 1; }
echo "✅ UBSan 冒烟：链接成功且真实报 signed integer overflow"

printf 'int main(void){int *p=(int*)8; *p=1; return 0;}\n' > "$TMP/a.c"
"$CLANG" -fsanitize=address -O1 "$TMP/a.c" -o "$TMP/t_a"
"$TMP/t_a" 2>"$TMP/a.err" >/dev/null || true
grep -q "AddressSanitizer" "$TMP/a.err" \
  || { echo "错误: ASan 冒烟未报错 → 运行时没接上" >&2; cat "$TMP/a.err" >&2; exit 1; }
echo "✅ ASan 冒烟：链接成功且真实报 AddressSanitizer 错误"
echo "完成。打包时把 $RES/lib/linux/ 下的 libclang_rt.{ubsan,asan,...}-*-android.* 合入 deb 即可。"
