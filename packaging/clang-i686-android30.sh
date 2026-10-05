#!/data/data/com.termux/files/usr/bin/bash
# 强制 i686 目标的 wrapper：**无条件**注入 --target=i686-linux-android30（并丢弃外来的 --target=）。
# 为什么必须"强制"：rustc 链接 std dylib 时只传 -march=… **不传 --target=**，
# 若只做"改写"，裸 clang 会用默认 aarch64 emulation → 报
# "…symbols.o is incompatible with aarch64linux"。
args=()
for a in "$@"; do
  case "$a" in
    --target=*) ;;
    *) args+=("$a") ;;
  esac
done
exec /data/data/com.termux/files/usr/bin/clang --target=i686-linux-android30 "${args[@]}"
