#!/data/data/com.termux/files/usr/bin/bash
# 通用 Android API30 wrapper：把 rust/cc-rs 传的各种 *-linux-android*（不带 API 级别）
# 统一提升为 -android30，与按 API30 构建的 libc++ 头/bionic 头一致。
# （aarch64 专版见 clang-api30.sh；本版覆盖 armv7a/i686/x86_64。）
args=()
for a in "$@"; do
  case "$a" in
    --target=armv7-linux-androideabi|--target=armv7a-linux-androideabi|--target=arm-linux-androideabi)
      a="--target=armv7a-linux-androideabi30" ;;
    --target=i686-linux-android)   a="--target=i686-linux-android30" ;;
    --target=x86_64-linux-android) a="--target=x86_64-linux-android30" ;;
    --target=aarch64-linux-android|--target=aarch64-unknown-linux-android)
      a="--target=aarch64-linux-android30" ;;
  esac
  args+=("$a")
done
exec /data/data/com.termux/files/usr/bin/clang "${args[@]}"
