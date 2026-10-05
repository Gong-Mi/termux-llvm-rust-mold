llvm-rust-system 23.1.3+rust1.100.0nightly+mold2.42.1-8

- 下载: 428M (448435740 bytes)
- sha256: `dbfd62afd50ddf5f9ab16ce9c6297de58723af609b68b8e0e19c7d7100ed0144`
- 校验: 下载 `.sha256` 后 `sha256sum -c`
- 安装: `apt install -y ./llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-8_aarch64.deb`（不要用 dpkg -i，apt 会自动移除冲突的官方包）
- 回滚见 README

## 相对 `-3` 的变化

- **整套工具链自举**：rustc/cargo 由本包的 clang 在设备上**原生构建**（stage2，`rustc 1.100.0-nightly (6eeff9a52, 2026-09-23) (built from a source tarball)`），mold 再由**自举的 cargo/rustc** 编译（`2.42.1 (8ac708c3)`）—— 链路：本包 clang → 本包 rustc → 本包 mold。
- **单一 libLLVM**：`lib/libLLVM.so.23.1` 换成**全目标**构建（159 MB，53 后端），并把 `libLLVM.so` 重指到它（此前指向旧的 `23.1.0-rc1`）。clang 与 rustc 现在共用同一份，`cannot locate symbol LLVMInitializeAMDGPU*` 不再出现。
- **mold 带 Cortex-A53 erratum 843419 实现**：上游 mold 把 `--fix-cortex-a53-843419`（clang 对每个 arm64 链接都传）归入 "ignored for compatibility"，**接受但忽略**；本包实现之（识别器逐条 port lld 判据 + 站点改写 + 补丁体），并保留 `ld.mold -> mold`，使 `clang -fuse-ld=mold` 默认路径就命中。
- **包内不带源码**：无独立 rust-src 组件，也不含 rustc-dev 附带的 crate 源码；只保留 `rustc_private` 需要的 `librustc_driver*.so`/`.rmeta`。源码用 `rustc-nightly-src.tar.xz` 按配方自取。
- **包内带构建配方**：`$PREFIX/share/doc/llvm-rust-system/BUILD.md`（三树 PGO、设备上原生 rust stage2、mold 843419 实现与验收、打包与装后核对，以及一路踩过的坑）。

## 升级注意

- 若旧版本曾把 `$PREFIX/lib/rustlib/src/rust`（或 `rustc-src/rust`）做成**指向包外路径的符号链接**，dpkg 拆包会顺着链接写出去。`-8` 不再带这些路径，升级后它们会被移除；如需确认，用 `readlink -f` 核对（`dpkg -V` 不校验符号链接）。
- `-7`/`-8` 均不回带 rust-src；需要源码请按 `BUILD.md` 自取。
- 已知限制：mold 的 843419 补丁体放在可执行节尾部，`.text` 超过 ±128 MiB 分支范围时够不到站点（真实 Android 二进制够不着；仅 lld 的 `large`/`large2` 合成向量会触发）。
