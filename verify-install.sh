#!/data/data/com.termux/files/usr/bin/bash
# 装完 llvm-rust-system -5 之后的完整验收（统一 LLVM + 自举 mold）
set -uo pipefail
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
S=$HOME/rust-latest-llvm231
ST2=$S/build/aarch64-linux-android/stage2
SCR=/data/data/com.termux/files/home/.hermes/cache/scratch
pass=0; fail=0
ok(){ printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }

echo "=== 1) 包完整性 ==="
if dpkg -V llvm-rust-system >/dev/null 2>&1; then ok "dpkg -V 干净"; else no "dpkg -V 有差异：$(dpkg -V llvm-rust-system 2>&1 | head -3)"; fi
dpkg -l llvm-rust-system | tail -1 | sed 's/^/     /'

echo "=== 2) LLVM 统一性 ==="
echo "     libLLVM.so -> $(readlink $PREFIX/lib/libLLVM.so)"
echo "     libLLVM.so.23.1: $(stat -c '%s' $PREFIX/lib/libLLVM.so.23.1) bytes ($(( $(stat -c '%s' $PREFIX/lib/libLLVM.so.23.1) / 1048576 )) MB)"
n=$(grep -ac LLVMInitializeAMDGPUAsmPrinter $PREFIX/lib/libLLVM.so.23.1 2>/dev/null || echo 0)
[ "${n:-0}" -gt 0 ] && ok "全目标（含 AMDGPU 符号 $n 处）" || no "仍是 AArch64-only（AMDGPU 符号 0 处）"
[ "$(readlink $PREFIX/lib/libLLVM.so)" = "libLLVM.so.23.1" ] && ok "libLLVM.so 不再指向旧的 rc1" || no "libLLVM.so 仍指向 $(readlink $PREFIX/lib/libLLVM.so)"

echo "=== 3) mold ==="
echo "     $($PREFIX/bin/mold --version 2>&1)"
m=$(sha256sum $PREFIX/bin/mold | cut -c1-16)
echo "     sha256(前16)=$m   期望 6a85b2b02293b840（自举版）"
[ "$m" = "6a85b2b02293b840" ] && ok "装的是自举版 mold" || no "不是自举版（$m）"
[ "$(readlink $PREFIX/bin/ld.mold)" = "mold" ] && ok "ld.mold -> mold（clang -fuse-ld=mold 会命中它）" || no "ld.mold 链接异常"
[ "$(grep -ac 'cortex-a53-843419' $PREFIX/bin/mold)" -ge 4 ] && ok "内含 843419 实现" || no "缺 843419 实现标记"

echo "=== 4) clang 仍可用（新 libLLVM 下）==="
printf '#include <condition_variable>\n#include <cstdio>\nint main(){std::condition_variable c; printf("clang+c++ ok\\n");}\n' > $SCR/inst_cxx.cpp
if $PREFIX/bin/clang++ $SCR/inst_cxx.cpp -o $SCR/inst_cxx 2>/dev/null && $SCR/inst_cxx | grep -q ok; then
  ok "clang++ 编译并运行 C++（含 libc++ 头）"
else no "clang++ 失败：$( $PREFIX/bin/clang++ $SCR/inst_cxx.cpp -o $SCR/inst_cxx 2>&1 | head -2)"; fi

echo "=== 5) 已装 rustc ==="
$PREFIX/bin/rustc --version 2>&1 | sed 's/^/     /'
printf 'fn main(){println!("installed rustc ok");}\n' > $SCR/inst_rs.rs
if $PREFIX/bin/rustc $SCR/inst_rs.rs -o $SCR/inst_rs 2>/dev/null && $SCR/inst_rs | grep -q ok; then ok "已装 rustc 编译并运行"; else no "已装 rustc 失败"; fi

echo "=== 6) 我们自举的 stage2 rustc（不再需要影子目录）==="
if env -u LD_PRELOAD LD_LIBRARY_PATH=$ST2/lib:$PREFIX/lib $ST2/bin/rustc -vV >/dev/null 2>&1; then
  ok "stage2 rustc 只用 \$PREFIX/lib 就能跑（LLVM 已统一）"
else
  no "stage2 rustc 起不来：$(env -u LD_PRELOAD LD_LIBRARY_PATH=$ST2/lib:$PREFIX/lib $ST2/bin/rustc -vV 2>&1 | head -2)"
fi

echo "=== 7) clang 默认链 Android 二进制（843419 生效）==="
cd /data/data/com.termux/files/home/.hermes/cache/scratch/acc843 2>/dev/null || exit 1
$PREFIX/bin/clang --target=aarch64-linux-android30 -fuse-ld=mold -nostdlib -pie -Wl,-e,_start \
  aarch64-cortex-a53-843419-recognize.o -o $SCR/inst_recognize 2>&1 | grep -E 'patching|error' | head -3 | sed 's/^/     /'
if python3 $SCR/scanelf843.py $SCR/inst_recognize 2>/dev/null | grep -q '0  ✅'; then ok "链出的产物 .text 无 erratum 残留"; else no "产物仍有残留"; fi

echo
echo "===== 通过 $pass 项，失败 $fail 项 ====="
