llvm-rust-system 23.1.3+rust1.100.0nightly+mold2.42.1-10

- 下载: 452M
- sha256: 见同目录 `.deb.sha256`（下载后 `sha256sum -c` 校验）
- 安装: `apt install -y ./llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-10_aarch64.deb`（不要用 dpkg -i，apt 会自动移除冲突的官方包）
- 回滚见 README

## 相对 `-8` 的变化

- **clang 换成全目标构建**：由本仓库源码构建（`LLVM_TARGETS_TO_BUILD=all`）并走正规 `cmake --install`
  装出，rpath 由 CMake 写为 `$ORIGIN/../lib`（**没有**任何二进制改写）。`clang --print-targets` = **52 个**
  （此前 5 个，只有 AArch64 家族）。
- **各 ABI 的 compiler-rt builtins**：用本工具链自己的 clang 逐 ABI 编出
  `lib/clang/23/lib/linux/libclang_rt.builtins-{aarch64,arm,i686,x86_64,riscv64}-android.a`。
- **跨 ABI 编译/链接可用**（实测，纯 clang 默认行为）：

| 目标 | 只编译 | 链接可执行 |
|---|---|---|
| `aarch64-linux-android30` | ✅ | ✅（并可运行） |
| `armv7a-linux-androideabi24/30` | ✅ | ✅（需装下面的多 ABI 依赖） |
| `i686-linux-android30` | ✅ | ✅ |
| `x86_64-linux-android30` | ✅ | ✅ |
| `riscv64-linux-android30` | ✅ | ❌（多 ABI 依赖里没有 riscv64 目录） |

  跨 ABI 链接依赖 Termux 自己的多 ABI 包（**不在本包内**，请自行安装）：

  ```bash
  pkg install ndk-multilib ndk-multilib-native-static ndk-multilib-native-stubs
  ```

  它们把各 ABI 的 sysroot 件（libc.so / libunwind.a / crtbegin_* / libc++_shared.so，各 27 项）装到
  `$PREFIX/<triple>/lib`，正是本包 clang 驱动补丁本来就在搜的路径，装完即生效。

## 已知边界

- **本机（Android 17）跑不了 32 位产物**：`abilist32` 为空、`zygote64`，系统已移除 32 位支持；
  编/链不受影响，产物可拿到 32 位支持的设备上运行。
- **rust 仍只有 aarch64 的 std**：`rustc --target=armv7-linux-androideabi` 会报 `can't find crate for std`
  （Rust 自己的 std 需逐目标构建，尚未随包发布）。C/C++ 的跨 ABI 已经可用。
- `riscv64` 只能编译、不能链接（见上表）。
- mold 的跨 ABI 无需改动：`mold --help` 里 `elf32-littlearm`/`armelf_linux_eabi` 都在，
  走 `clang -fuse-ld=mold` 实链 armv7 可得到 `ELF 32-bit LSB pie executable, ARM, EABI5`。
