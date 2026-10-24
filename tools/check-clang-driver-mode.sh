#!/data/data/com.termux/files/usr/bin/sh
# 检查 clang++ 是否仍在 C++ driver mode（shell wrapper/shim 丢掉 argv[0] 时会退化成 C）。
#
# 症状：C++ 一旦用到异常/RTTI（throw、std::runtime_error、dynamic_cast），链接就报
#   undefined symbol: __gxx_personality_v0 / __cxa_throw / std::runtime_error::...
# 因为 C driver mode 的链接行里没有 -lc++_shared；而 `-c`、`-E`、纯算术程序全都正常，
# 所以很容易被误判成"库缺失/包坏了"。
#
# 反例（错）：
#   #!/bin/sh
#   exec /data/data/com.termux/files/usr/bin/clang-24 "$@"        # argv[0] 变 clang-24 -> C 模式
# 正例：
#   exec /data/data/com.termux/files/usr/bin/clang-24 --driver-mode=g++ "$@"
#
# 用法：sh tools/check-clang-driver-mode.sh    # rc=0 全过，rc=1 有失败项
set -u

tmp="${TMPDIR:-$PREFIX/tmp}"
d=$(mktemp -d "$tmp/clangxx-check.XXXXXX") || { echo "FAIL: mktemp"; exit 2; }
trap 'rm -rf "$d"' EXIT
fail=0
say() { printf '%s\n' "$*"; }

printf '#include <stdexcept>\nint main(){ throw std::runtime_error("x"); }\n' >"$d/t.cpp"
printf 'int main(void){ return 0; }\n' >"$d/t.c"

say "== clang++ 链接行是否带 -lc++_shared（C++ driver mode 的标志）"
if clang++ -### "$d/t.cpp" -o "$d/t.out" >"$d/link.txt" 2>&1 && grep -q -- '-lc++_shared' "$d/link.txt"; then
  say "PASS: clang++ 链接行含 -lc++_shared"
else
  say "FAIL: clang++ 链接行没有 -lc++_shared —— driver mode 退化成 C"
  fail=1
fi

say "== C 驱动不应带 -lc++_shared"
if clang -### "$d/t.c" -o "$d/c.out" >"$d/clink.txt" 2>&1 && ! grep -q -- '-lc++_shared' "$d/clink.txt"; then
  say "PASS: clang 链接行不含 -lc++_shared"
else
  say "FAIL: clang 链接行异常"
  fail=1
fi

say "== 真实 C++ 异常程序链接（不额外传 -lc++_shared）"
if clang++ "$d/t.cpp" -o "$d/t" >"$d/real.txt" 2>&1; then
  say "PASS: 链接成功（运行时会因程序主动 throw 而退出码非 0，属正常）"
else
  say "FAIL: 链接失败，尾部输出："
  tail -6 "$d/real.txt" | sed 's/^/    /'
  fail=1
fi

say "== 解析链"
say "  which clang++ : $(command -v clang++ 2>/dev/null || echo '(none)')"
say "  readlink -f   : $(readlink -f "$(command -v clang++ 2>/dev/null)" 2>/dev/null || echo '(n/a)')"
if head -1 "$(command -v clang++ 2>/dev/null)" 2>/dev/null | grep -q '^#!'; then
  say "  注意：clang++ 是脚本 wrapper，必须自己保住 driver mode（见 packaging/BUILD.md §1d）"
fi

if [ "$fail" -eq 0 ]; then say "ALL PASS: clang/clang++ driver mode 正常"; else say "FAILED: 见上面 FAIL 行"; fi
exit "$fail"
