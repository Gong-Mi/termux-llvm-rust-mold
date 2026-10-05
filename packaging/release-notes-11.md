llvm-rust-system 23.1.3+rust1.100.0nightly+mold2.42.1-11

- 下载: 500M
- sha256: 见同目录 `.deb.sha256`（下载后 `sha256sum -c` 校验）
- 安装: `apt install -y ./llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-11_aarch64.deb`（不要用 dpkg -i，apt 会自动移除冲突的官方包）
- 回滚见 README

## 相对 `-10` 的变化：Rust 也能跨 ABI 了

- **新增 rust-std**：`armv7-linux-androideabi` / `i686-linux-android` / `x86_64-linux-android`
  三个目标的 std（各 42 项，装在 `$PREFIX/lib/rustlib/<triple>/lib`）。
  aarch64 是宿主，随 rustc 一起装。
- **新增 per-ABI linker wrapper**（`$PREFIX/bin/`，NDK 与 rust 两种命名都提供）：

  ```
  armv7-linux-androideabi-clang   armv7a-linux-androideabi30-clang
  i686-linux-android-clang        i686-linux-android30-clang
  x86_64-linux-android-clang      x86_64-linux-android30-clang
  （各带 -clang++ 版本）
  ```

  它们**无条件注入 `--target=<abi>30`**。这不是可有可无的糖：rustc 链接 std dylib 时
  只传 `-march=…`、**不传 `--target=`**，只做"改写 target"的 wrapper 在这里不起作用，
  裸 clang 会用默认的 aarch64 emulation 报
  `…symbols.o is incompatible with aarch64linux`。
- **用法**（详见包内 `share/doc/llvm-rust-system/RUST-CROSS-ABI.md`）：

  ```bash
  rustc --target=armv7-linux-androideabi -C linker=armv7-linux-androideabi-clang hello.rs -o hello_arm

  # cargo 写进 ~/.cargo/config.toml：
  # [target.armv7-linux-androideabi]
  # linker = "armv7-linux-androideabi-clang"
  ```

  实测（本机，不带 `--sysroot`，直接用包内 linker）：

  | 目标 | 结果 |
  |---|---|
  | `aarch64-linux-android` | ✅ 编链 **且本机可运行** |
  | `armv7-linux-androideabi` | ✅ `ELF 32-bit LSB pie executable, ARM, EABI5` |
  | `i686-linux-android` | ✅ `ELF 32-bit LSB pie executable, Intel i386` |
  | `x86_64-linux-android` | ✅ `ELF 64-bit LSB pie executable, x86-64` |

- `control` 增加 `Recommends: ndk-multilib, ndk-multilib-native-static, ndk-multilib-native-stubs, ndk-sysroot`
  （跨 ABI 链接需要系统侧的多 ABI sysroot；不在本包内，故用 Recommends 不用 Depends）。

## 已知边界

- **32 位产物本机跑不了**：本机 `abilist32` 为空、`zygote64`、sdk 37，Android 17 已移除 32 位支持；
  编/链完全正常，请拿到 32 位设备/模拟器上运行。
- **riscv64 只能编译不能链接**：多 ABI 依赖里没有 riscv64 目录（rust 侧也没出该目标 std）。
- 链接 32 位目标前记得 `pkg install ndk-multilib ndk-multilib-native-static ndk-multilib-native-stubs`。
