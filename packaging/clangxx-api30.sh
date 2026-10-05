#!/data/data/com.termux/files/usr/bin/bash
# C++ 驱动器包装
# rust 的 cc-rs / bootstrap 传的 --target=aarch64-linux-android 不带 API 级别，
# clang 会按默认（低）API 选 bionic 头，与按 API 30 构建的 libc++ 头不一致
# （典型症状：pthread_cond_clockwait 未声明）。本 wrapper 把 target 提升到 -android30，
# 与我们 clang 的默认目标（aarch64-unknown-linux-android30）一致。
args=()
for a in "$@"; do
  case "$a" in
    --target=aarch64-linux-android|--target=aarch64-unknown-linux-android|--target=aarch64-linux-android2[0-9])
      args+=("--target=aarch64-linux-android30") ;;
    *) args+=("$a") ;;
  esac
done
exec /data/data/com.termux/files/usr/bin/clang++ "${args[@]}"
