#!/data/data/com.termux/files/usr/bin/bash
# Termux/Android AArch64 LLVM 23.1 stage1 configure (full toolbox, single libLLVM.so)
# Baseline: llvm-project release/23.x + termux/23.x-adaptation patch set
set -e
PREFIX=/data/data/com.termux/files/usr
SYSROOT=/data/data/com.termux/files
SRC=/data/data/com.termux/files/home/llvm-project
BUILD=$SRC/build-stage1

# chronicle#13: C/CXX flags split — no -stdlib in C flags
C_FLAGS="--sysroot=$SYSROOT -femulated-tls"
CXX_FLAGS="--sysroot=$SYSROOT -femulated-tls"
# no libc++.so on Termux — driver adds -lc++, so force -lc++_shared explicitly
# Build-time library resolution: LD_LIBRARY_PATH=$BUILD/lib:$PREFIX/lib ninja
# (build-lib FIRST to avoid old system lib hijack)
LINK_FLAGS="-L/system/lib64 -L$PREFIX/lib -lc++_shared"

cmake -S "$SRC/llvm" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$PREFIX/bin/clang" \
  -DCMAKE_CXX_COMPILER="$PREFIX/bin/clang++" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_FLAGS="$C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LINK_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$LINK_FLAGS" \
  -DCMAKE_MODULE_LINKER_FLAGS="$LINK_FLAGS" \
  -DLLVM_HOST_TRIPLE=aarch64-unknown-linux-android30 \
  -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-android30 \
  -DDEFAULT_SYSROOT="$SYSROOT" \
  -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;mlir" \
  -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
  -DLLVM_TARGETS_TO_BUILD="AArch64;AMDGPU;BPF;LoongArch;NVPTX;RISCV;SPIRV;SystemZ;VE;WebAssembly" \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DCLANG_LINK_CLANG_DYLIB=ON \
  -DLLVM_ENABLE_LLD=ON \
  -DLLVM_TOOL_GOLD_BUILD=ON \
  -DLLVM_BINUTILS_INCDIR="$PREFIX/include" \
  -DLLVM_ENABLE_Z3_SOLVER=OFF \
  -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
  -DRUNTIMES_aarch64-unknown-linux-android30_COMPILER_RT_INCLUDE_TESTS=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=2 \
  -DCLANG_DEFAULT_LINKER=lld \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DRUNTIMES_CMAKE_C_FLAGS="--sysroot=$SYSROOT" \
  -DRUNTIMES_CMAKE_CXX_FLAGS="--sysroot=$SYSROOT" \
  -DRUNTIMES_CMAKE_EXE_LINKER_FLAGS="$LINK_FLAGS" \
  -DRUNTIMES_CMAKE_SHARED_LINKER_FLAGS="$LINK_FLAGS" \
  -DRUNTIMES_COMPILER_RT_INCLUDE_TESTS=OFF