# termux-llvm-rust-mold

Termux（aarch64）自举工具链**三合一包**：一个 `.deb` 同时提供

| 组件 | 版本 | 说明 |
|---|---|---|
| LLVM / Clang / LLD / MLIR / compiler-rt | 23.1.3 | PGO 构建（IR 插桩自举训练，profile `llvm-23.1.pgo.profdata`，9441 runs） |
| Rust | 1.100.0-nightly (rustc `0d38a8426` 2026-09-24, cargo `98a09e7e7` 2026-09-21) | stage2 自举，动态链接本包 `libLLVM.so.23.1` |
| mold | 2.42.1 (`6fc6e191`, 2026-09-23) | MIT；`mold` + `ld.mold` + `mold-wrapper.so` |

包名 `llvm-rust-system`，`Architecture: aarch64`。
下载 **约 306 MiB**，安装后 **约 2.44 GB**（8045 个文件）。

安装时**替换**官方包：`clang`、`lld`、`llvm`、`libllvm`、`rust`、`libcompiler-rt`、`mold`
（control 里 `Conflicts/Replaces/Provides` 全占）。这不是 Termux 官方仓库的包。

---

## 安装

```bash
# 方式一：脚本（自动下载最新版 + 校验 sha256 + apt 安装）
curl -fsSL https://raw.githubusercontent.com/Gong-Mi/termux-llvm-rust-mold/main/install.sh | bash

# 方式二：手动
TAG=23.1.3-rust1.100.0-mold2.42.1-2
DEB=llvm-rust-system_23.1.3+rust1.100.0nightly+mold2.42.1-2_aarch64.deb
BASE=https://github.com/Gong-Mi/termux-llvm-rust-mold/releases/download/v$TAG
curl -LO $BASE/$DEB
curl -LO $BASE/$DEB.sha256
sha256sum -c $DEB.sha256
apt install -y ./$DEB      # 用 apt 而不是 dpkg -i，让它自动移除冲突的官方包
```

安装后核对：

```bash
dpkg -V llvm-rust-system          # 无输出 = 文件与包记录一致
dpkg -l llvm-rust-system | tail -1
clang --version | head -1         # 23.1.3
rustc -vV | tail -1               # LLVM version: 23.1.3
mold --version
ls $PREFIX/share/doc/llvm-rust-system/copyright
```

## 卸载 / 回滚

```bash
apt remove llvm-rust-system
apt install clang lld llvm libllvm rust libcompiler-rt mold   # 装回官方包
```

本仓库另有一个 release `rollback-official-21.1.8`，里面是官方仓库当时的 6 个 `.deb`
（`clang` / `lld` / `llvm` / `libllvm` / `libcompiler-rt` 21.1.8-3 与 `rust` 1.98.1），
断网或官方源不可用时可直接回滚：

```bash
BASE=https://github.com/Gong-Mi/termux-llvm-rust-mold/releases/download/rollback-official-21.1.8
curl -LO $BASE/sha256sums.txt
for f in clang lld llvm libllvm libcompiler-rt; do curl -LO $BASE/${f}_21.1.8-3_aarch64.deb; done
curl -LO $BASE/rust_1.98.1_aarch64.deb
sha256sum -c sha256sums.txt
apt remove llvm-rust-system
dpkg -i clang_21.1.8-3_aarch64.deb lld_21.1.8-3_aarch64.deb llvm_21.1.8-3_aarch64.deb \
        libllvm_21.1.8-3_aarch64.deb libcompiler-rt_21.1.8-3_aarch64.deb rust_1.98.1_aarch64.deb
```

## 仓库内容

```
install.sh                  一键安装（取最新 release + sha256 校验 + apt install）
tools/publish-release.sh    发布新版本：<deb> → tag + release + asset + 远端核对
tools/prune-releases.sh     只保留最近 N 个版本 release，旧的连 tag 一起删
packaging/repack-with-license.sh  在已有 .deb 数据层上注入 share/doc 许可、升版本号
packaging/copyright         随包安装的许可/来源文件（DEP-5 格式）
```

## 为什么自己做

- Termux 官方仓库的 `llvm`/`clang` 是 release 构型，没有 PGO；自行构建可用 `-fprofile-use` 拿到本机热点。
- Rust 官方不提供可在 `aarch64-linux-android` 宿主上直接用的 stage0 预编译产物，aarch64 上的 rustc 只能本地自举（本包走的是 stage2）。
- mold 与 LLVM 版本需要联动（LTO 需要匹配的 `LLVMgold.so`），三件套打包在一起才不会错配。

## 构建来源（可复现性）

| 组件 | 上游 | commit |
|---|---|---|
| LLVM/Clang/LLD/MLIR/compiler-rt 23.1.3 | https://github.com/llvm/llvm-project `release/23.x` | `e3f9cdcbe52a91c2dfe3b03b5cf3973aade7b969` |
| Rust 1.100.0-nightly | https://github.com/rust-lang/rust | rustc `0d38a842626a6e3b70e2c1efd76a8f22d2556d73` |
| mold 2.42.1 | https://github.com/rui314/mold | `6fc6e1916f383ea3ea319e12d3df4daee33267d9` |

附加的 Termux 兼容补丁（3 个，都是 LLVM 侧）：

1. `lld` TLS 对齐（Android Bionic 要求 TLS `p_align=64`，AArch64 默认 8）
2. `clang` 在 Android 目标上用 `-lc++_shared` 而不是 `-lc++`（`clang/lib/Driver/ToolChain.cpp`）
3. ARM NEON f16mm 例外（当前为空补丁，占位）

其它已知处理：
- LLVM 工具 RUNPATH 统一为 `$ORIGIN/../lib`（clang/libLLVM），避免构建树路径泄漏；
- 链接器脚本（cmake 生成的 `libc++.so` 文本文件）换成真实符号链接；
- Rust `librustc_driver.so` 的 SONAME 用 patchelf 修正为文件名（Android linker 按文件名解析 `NEEDED`，没有 ldconfig）；
- `libLLVM.so.23.1-rc1` 与 `libLLVM.so.23.1` 共存，旧的 23.1.0rc1 工具仍可用；
- BOLT **未包含**：AArch64 上 `llvm-bolt` 运行时在 `initSizeMap` 崩溃，上游用 `DISABLE_LLVM_LINK_LLVM_DYLIB` 静态链接才可用，官方不修，本地不复现。

## 兼容性与风险

- 仅 **aarch64**（arm64）Termux，`$PREFIX=/data/data/com.termux/files/usr`，clang 默认目标 `aarch64-unknown-linux-android30`。
- 依赖：`libc++ libffi libxml2 ncurses zlib zstd libedit openssl libcurl`（apt 会自动装）。
- 本包替换系统包，`pkg upgrade` 时官方 `clang`/`rust` 若被重新安装会与本包冲突（`Conflicts` 会拦下）。想长期保留自定义工具链，建议 `apt-mark manual llvm-rust-system` 并留意 `apt upgrade` 的输出。
- 未在其它 Android 版本/ROM 上验证，仅作者自用设备（MTK 平台，Android 17）实测。
- 二进制来自作者本机自举构建，不是 Termux 官方产物；**不要**拿本包的构建问题给 termux-packages 提 issue。

## 许可

包内 `$PREFIX/share/doc/llvm-rust-system/copyright` 含全部许可全文：

- LLVM / Clang / LLD / MLIR / compiler-rt：Apache-2.0 WITH LLVM-exception
- Rust：MIT / Apache-2.0 双许可
- mold：MIT (c) 2023 Rui Ueyama

本仓库的脚本与文档：见 `LICENSE`。

## 版本策略

每个 release 一个 tag，asset 里挂 `.deb` + `.sha256`。每个包约 306 MiB，
仓库只保留最近 2–3 个版本，旧 asset 单独删除（tag 保留）。
