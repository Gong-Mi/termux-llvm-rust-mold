# llvm-rust-system 构建配方（BUILD.md）

本包**不带源码**，带的是"怎么编出来的"。以下足以从零复现同一套工具链。

## 这套工具链是什么

| 组件 | 版本 | 说明 |
|---|---|---|
| LLVM / clang / lld | 23.1.3 (PGO) | 三树 PGO：插桩树 → 自举训练树 → profile-use 树；53 个后端目标全开 |
| Rust / cargo | 1.100.0-nightly (6eeff9a52, 2026-09-23) | **在设备上原生构建**（host=target=aarch64-linux-android），由本包的 clang 编译 |
| mold | 2.42.1 (8ac708c3) | 由**自举的 cargo/rustc** 编译；含 Cortex-A53 erratum 843419 实现 + Arm64 TLS p_align 修补 |
| libLLVM | 23.1.3 | **单一全目标构建**，clang 与 rustc 共用同一份 |

自举链：本包的 clang(树C PGO) → 本包 rustc → 本包 mold。
所有二进制：`aarch64-linux-android`，链接本包 `lib/libLLVM.so.23.1`。

## 0. 环境要点（先看这条，省一轮返工）

* 重型编译钉小核：`taskset -c 0-5`（大核留给交互），并 `termux-wake-lock`。
* `$PREFIX/lib` 里可能同时存在多份同版本 libLLVM；**运行时按 soname 先命中的那份生效**。
  本包把全目标那份装成 `libLLVM.so.23.1` 并把 `libLLVM.so` 重指到它，避免
  `cannot locate symbol LLVMInitializeAMDGPU*`。
* **`LD_LIBRARY_PATH` 整体优先于 RUNPATH**，且**绝不能**把 LLVM 构建树的 `lib/`
  放进去（里面有 libclang-cpp，宿主编译器会因此丢 target 注册：
  `clang -cc1as: error: unknown target triple 'unknown'`）。要暴露 LLVM 就用
  只含 `libLLVM*.so*` 的**影子目录**放在最前。
* **显式设 `RUSTFLAGS` 会替换（不是合并）`~/.cargo/config.toml` 的 target rustflags**，
  `-Wl,-rpath=$PREFIX/lib` 必须自己带上，否则产物运行时 `library "libz.so.1" not found`。
* 沙箱可能注入 `LD_PRELOAD=libpython3.14.so`：跑新链接的程序一律用 `env -u LD_PRELOAD`。
* `/tmp` 不可写，临时文件放 scratch 目录。

## 1. LLVM（三树 PGO）

```bash
# 树 A（插桩）→ 训练（跑一次完整构建产生 profraw）→ 合并 → 树 C（profile-use）
cmake -S llvm-project/llvm -B build-pgouse -G Ninja \
  -DCMAKE_C_COMPILER=$PREFIX/bin/clang-23 -DCMAKE_CXX_COMPILER=$PREFIX/bin/clang++-23 \
  -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
  -DLLVM_TARGETS_TO_BUILD=all -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON -DCLANG_LINK_CLANG_DYLIB=ON \
  -DLLVM_PROFDATA_FILE=<merged.profdata>
```

要点与坑：

* **PCH 身份**：`CLANG_LINK_CLANG_DYLIB=ON` 时驱动逻辑（版本串、PCH 校验）在
  `libclang-cpp.so`。换了加载到的那份，所有 `*.pch` 立即失效；`.pch` 是**每条目标边的显式输入**，
  删一个会级联重编。重装缺文件而不是重跑 cmake。
* 构建树 host 工具需要树内**全后端** `libLLVM`（否则 `invalid symbol LLVMInitializeAMDGPUTarget`），
  而树自己的 clang 必须搭配树的 `libclang-cpp` —— 用「影子目录 + 两阶段 ninja」：
  阶段一 `LD_LIBRARY_PATH=$SHIM:$PREFIX/lib ninja -k0`（`$SHIM` 为树 lib 的 `*.so*` 但**排除** `libclang-cpp*`），
  阶段二 `LD_LIBRARY_PATH=$TREE/lib:$PREFIX/lib ninja`。阶段一非 0 属预期，只看阶段二。
* compiler-rt 在 Android 上需要 `COMPILER_RT_USE_BUILTINS_LIBRARY=ON`（源码默认对 Android 为 OFF）：
  `compiler-rt/CMakeLists.txt` 里 `if (FUCHSIA OR ANDROID)`。
* 判据：`llvm-config --targets-built | wc -l`（全目标是几十，AArch64-only 是 5）。

## 2. Rust（设备上原生 stage2）

```bash
# 源码要与已装 rustc 同 commit（rustc -vV 给出 date/commit）
curl -fLO https://static.rust-lang.org/dist/<date>/rustc-nightly-src.tar.xz
# 解开后落到 $PREFIX/lib/rustlib/rustc-src/rust 指向的位置（自带 vendor/，依赖免联网）
```

补丁（Termux `packages/rust/` 那套，本包用其中的 0001/0002/0003/0004/0005/0007/0008 与
`force-allow-edit-vendor`）：

* **打补丁前必须替换占位符**：`@TERMUX_PKG_API_LEVEL@` → `30`（与本工具链默认 android target 一致）、
  `@TERMUX_PREFIX@` → 真实前缀。裸打会把占位符写进源码。
* **"是否已应用"用 `patch --dry-run --reverse` 判定**，不要用 grep 标记——假阳性会**静默跳过**必需补丁。
* 上游补丁的上下文会随 nightly 漂移（如 0009 的 import 行）：按 tarball 里的**原始文件**重生成，
  不要用 fuzz 硬打。
* 本包另加了三条本地补丁：`library/std` 与 `library/sysroot` 的
  `[lints.cargo] unused_dependencies = "allow"`（cargo 清单 lint 误报，保留 `build.warnings=deny` 才有意义）、
  `compiler/rustc/src/main.rs` 的 `#![cfg_attr(not(target_os="android"), expect(unused_crate_dependencies))]`。

`bootstrap.toml` 关键项：

```toml
change-id = "ignore"
profile = "dist"
[llvm]  download-ci-llvm = false ; link-shared = true
[build] build/host/target = "aarch64-linux-android"
        rustc = "$PREFIX/bin/rustc" ; cargo = "$PREFIX/bin/cargo"   # 否则会去下载不存在的 android 版 stage0
        tools = ["cargo","rustdoc","rustfmt"] ; allocator = "system"  # [rust] jemalloc 已弃用且会 panic
[install] prefix = "$HOME/rust-stage2-prefix"                        # 暂存，不写 $PREFIX
[target.aarch64-linux-android]
        llvm-config = "<构建树>/bin/llvm-config"   # 必须与要链接的 libLLVM 同源（$PREFIX/bin/llvm-config 可能指向旧版）
        cc/cxx/linker = "API30 wrapper"           # 见下
        ar/ranlib = "$PREFIX/bin/llvm-ar|ranlib" ; profiler = true
```

**API30 wrapper（必需）**：cc-rs/rust 传 `--target=aarch64-linux-android`（不带 API 级别），
clang 按默认低 API 选 bionic 头，而按 API 30 构建的 libc++ 会引用仅在 API≥30 声明的
`pthread_cond_clockwait` → `error: use of undeclared identifier`。wrapper 把该 target 改写成
`-android30`，并同时导出 `CC_/CXX_aarch64_linux_android`（否则 `~/.cargo/config.toml` 里的值会赢）。

构建环境（Termux 的 `RUST_LIBDIR` 手法，适配原生）：

```bash
LIBDIR=$HOME/rust-build/_lib
ln -sf <树>/lib/libLLVM.so.23.1 $LIBDIR/{libLLVM.so.23.1,libLLVM.so,libLLVM-23.so}   # llvm-config --link-shared 要 libLLVM-23.so
ln -sf $PREFIX/lib/libc++_shared.so $LIBDIR/ ; ln -sf $PREFIX/lib/libandroid-execinfo.so $LIBDIR/
$PREFIX/bin/clang -c syncfs.c -o syncfs.o && $PREFIX/bin/llvm-ar rcu $LIBDIR/libsyncfs.a syncfs.o
export LD_LIBRARY_PATH=$LIBDIR:$PREFIX/lib          # 不含任何构建树的 lib/
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-L$LIBDIR -C link-arg=-lc++_shared \
  -C link-arg=-l:libsyncfs.a -C link-arg=-landroid-execinfo -C link-arg=-Wl,--enable-new-dtags \
  -C link-arg=-Wl,-rpath=$PREFIX/lib -C link-arg=-fuse-ld=mold"
taskset -c 0-5 nice -n 5 python3 x.py check --stage 1 library/std   # 几分钟验接线
taskset -c 0-5 nice -n 5 python3 x.py build --stage 2               # 约 20 分钟（8 核）
taskset -c 0-5 nice -n 5 python3 x.py dist  --stage 2               # 出 rustc/cargo/rust-std/rustc-dev/rustfmt
```

（`llvm-config: error: libLLVM-23.so is missing` 就在构建树的 `lib/` 里补同名符号链接。）

## 3. mold

```bash
cargo build --release -p mold-cli     # 2.42.1 起是纯 Cargo 工作区，无 CMakeLists
```

* Arm64 TLS：`src/passes.rs` 把输出 `SHF_TLS` 节的 `p2align` 下限设为 6（Bionic 要求 `PT_TLS.p_align >= 64`）。
* Cortex-A53 erratum 843419：`src/target/arm64_errata.rs`（识别器，逐条 port lld 判据）+ `passes.rs`/`driver.rs`/
  `cmdline.rs`/`context.rs` 挂钩；补丁体追加到最后一个可执行节尾部（**不需要** lld 那套地址收敛迭代），
  站点改写为 `b <patch>`，被挪走的指令直接复制**已重定位**的字节（连 TLS IE 位点都不需要重定位搬迁）。
* **只跳过 JUMP26 位点，不要跳过 TLS IE 位点**：lld 跳过它是因为 lld 自己会把该序列 relax 成 MOVZ，
  而 mold 的 AArch64 没有任何 TLS 松弛（`--relax` 只覆盖 RISC-V/LoongArch）→ 照抄跳过 = 把活的 erratum留在产物里。
* 已知限制：可执行节超过 ±128 MiB 分支范围时，追加式放置够不到站点（只出现在 lld 的
  `large`/`large2` 合成向量里，真实 Android 二进制够不着）。
* 验收：11 个 `lld/test/ELF/aarch64-cortex-a53-843419*.s` 各以「有/无补丁 × 两个链接器」四路链接，
  用独立扫描器数**残留模式**（不是数链接器的自报），并把两侧按各自 `.text` 基址归一化后再比位点集合；
  最后在**真实二进制**上收尾（用本包的 mold 自链接 mold：报告实际位点数、产物跑得起来、残留为 0）。

## 4. 打包与安装

```bash
# 在已发布 base deb 上换件重打（推荐：单件修复 / 自举化）
bash packaging/repack-mold.sh <base.deb> <新版本> <mold二进制> <outdir>        # 换 mold（可选 LLVM_SO= 一起统一 libLLVM）
bash build-deb-rust.sh <base.deb> <新版本> <outdir>                          # 折入自举 rust（本脚本：默认不带 rust-src）
apt install ./llvm-rust-system_<版本>_aarch64.deb
```

`build-deb-rust.sh` 里已固化的教训：

* 「陈旧文件」的**新集必须取自 tarball 内容**，不能取自叠加后的暂存区（否则旧 hash 命名的
  payload——例如 92 MB 的旧 `librustc_driver-<hash>.so`——会静默留下）。
* 陈旧范围必须覆盖 `$PREFIX/lib/librustc_driver-*.so`、`libstd-*`、`share/doc/rust`，
  不只是 `lib/rustlib/**`。
* tarball 里组件根在**第 3 层**（`<top>/<component>/lib|bin`）；判不出必须报错退出——
  空的组件目录会让 `"$comp/etc"` 退化成宿主 `/etc`。
* **base 数据层里指向暂存区之外的符号链接**会让 dpkg 拆包时"顺链写出去"（本包历史上
  `lib/rustlib/src/rust -> $HOME/...` 就导致文件被写进构建树）。脚本会预检并列出这些链接。
* 打包命令：`dpkg-deb --build --root-owner-group -Zxz -z6`（xz/级别 6/多线程）。

## 5. 装后验收

```bash
dpkg -V llvm-rust-system
mold --version ; grep -ac cortex-a53-843419 $PREFIX/bin/mold      # 上游 flag-only 版是 1，带实现是 4
rustc -vV ; cargo --version ; rustfmt --version
env -u LD_PRELOAD sh -c 'echo "fn main(){println!(\"ok\")}" > /tmp/x.rs 2>/dev/null || true'
# 关键：默认路径也要生效 —— clang 自动传 --fix-cortex-a53-843419，且 -fuse-ld=mold 解析的是 ld.mold
clang --target=aarch64-linux-android30 -fuse-ld=mold <对象> -o out   # 应出现 patching N，产物残留 0
```

* `clang -fuse-ld=mold` 找的是 **`ld.mold`**（不是 `mold`）——包里两个名字都要有，否则会落到系统里
  那份"接受但忽略该 flag"的上游 mold 上，静默不补 erratum。
* `dpkg -V` **不校验符号链接**（symlink 无 md5），涉及链接的布局要另用 `readlink -f` 核对。
