# Stage2 → Rust/Mold Closure Verification

Post-build verification sequence for the LLVM→Rust→cargo→mold single-libLLVM
closure on Termux/Android aarch64.

## 1. LLVM Stage2 Toolbox

```bash
# Core binaries exist and run
$BUILD/bin/clang --version
$BUILD/bin/lld --version
$BUILD/bin/llvm-config --version

# Compile and run a test program (use $PREFIX/tmp, NOT /tmp — permission denied)
echo 'int main(){return 0;}' | $BUILD/bin/clang -x c - -o $PREFIX/tmp/test_s2
$PREFIX/tmp/test_s2 && echo "OK"
```

## 2. libLLVM SONAME Symlink

Rust's `llvm-config --link-shared` expects SONAME `libLLVM-23-rc1.so`.
The build tree produces `libLLVM.so.23.1-rc1`. Create symlinks:

```bash
ln -sf libLLVM.so.23.1-rc1 $BUILD/lib/libLLVM-23-rc1.so
ln -sf libLLVM.so.23.1-rc1 $PREFIX/lib/libLLVM-23-rc1.so

# Verify llvm-config now works
$BUILD/bin/llvm-config --link-shared --libs aarch64
```

Without this, Rust stage2 build fails at `rustc_llvm/build.rs:197`:
```
llvm-config: error: libLLVM-23-rc1.so is missing
```

## 3. Rust Stage2

```bash
# rustc exists
build/<triple>/stage2/bin/rustc --version

# cargo is in stage2-tools-bin (NOT stage2/bin — easy to miss)
build/<triple>/stage2-tools-bin/cargo --version

# Verify dynamic link to stage2 LLVM
readelf -d build/<triple>/stage2/lib/librustc_driver-*.so | grep NEEDED
# Must show: libLLVM.so.23.1-rc1
# If it shows nothing LLVM-related, rustc statically linked — wrong
```

## 4. Mold

mold 2.41.0 builds with stage2 clang, no patches needed:

```bash
cd ~/mold-src && rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_C_COMPILER=$BUILD/bin/clang \
         -DCMAKE_CXX_COMPILER=$BUILD/bin/clang++ \
         -DCMAKE_BUILD_TYPE=Release -DMOLD_LTO=OFF
make -j8   # ~5 min on 8 cores

# Verify
./mold --version
echo 'int main(){return 0;}' | $BUILD/bin/clang -x c - -fuse-ld=$PWD/mold -o $PREFIX/tmp/test_mold
$PREFIX/tmp/test_mold && echo "mold link OK"
```

mold does NOT link libLLVM — it's standalone (libz, libzstd, libc++_shared).

## 5. TLS Acceptance Test

Verifies the lld PT_TLS p_align patch. System clang 23.1 produces broken TLS
(crash on thread access); stage2 clang with the patch produces correct output.

```c
// $PREFIX/tmp/tls_test.c
#include <stdio.h>
#include <pthread.h>
__thread int tls_var = 42;
void *worker(void *arg) {
    tls_var = 99;
    printf("thread tls_var=%d\n", tls_var);
    return NULL;
}
int main() {
    printf("main tls_var=%d\n", tls_var);
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    pthread_join(t, NULL);
    printf("main after join tls_var=%d\n", tls_var);
    return (tls_var == 42) ? 0 : 1;
}
```

Expected output (exit 0):
```
main tls_var=42
thread tls_var=99
main after join tls_var=42
```

If TLS is broken: crash (SIGABRT/SIGSEGV) or main tls_var corrupted after
thread join (exit 1).

## 6. Full Tool Verification Table (2026-07-28)

All verified with stage2 build (LLVM 23.1.0-rc1, commit f56641e5bbea):

| Tool | Test | Result |
|------|------|--------|
| clang | C compile+run | ✅ |
| clang++ | C++20 STL/thread/mutex/unique_ptr | ✅ |
| TLS | pthread __thread isolation | ✅ exit 0 |
| mold | link test via -fuse-ld | ✅ |
| ld.lld | --version | ✅ LLD 23.1.0 |
| wasm-ld | --version | ✅ LLD 23.1.0 |
| llvm-ar | rcs + t (archive) | ✅ |
| llvm-nm | symbol listing | ✅ T foo, T bar |
| llvm-objdump | -d disassembly | ✅ elf64-littleaarch64 |
| llvm-readelf | -h ELF header | ✅ ELF64 |
| llvm-strip | strip .o | ✅ |
| llvm-cov | --version | ✅ |
| llvm-dwarfdump | --version | ✅ |
| llc | IR→aarch64 obj (-mtriple=aarch64-linux-android) | ✅ |
| opt | -O2 IR optimize | ✅ |
| llvm-mc | asm→obj (mov x0, #42) | ✅ |
| clangd | --version | ✅ 23.1.0-rc1 |
| clang-tidy | --version | ✅ |
| clang-format | pipe format | ✅ |
| llvm-config | --version --targets-built --shared-mode | ✅ 10 targets, shared |
| rustc | --version | ✅ 1.99.0-nightly |
| cargo | init + build --release | ✅ |

## 7. Rust Smoke Test Program

```rust
// Exercises: HashMap, Arc, thread, enum, match, closure, iterator
use std::collections::HashMap;
use std::sync::Arc;
use std::thread;

fn main() {
    let mut map: HashMap<String, i64> = HashMap::new();
    for i in 0..10 { map.insert(format!("key_{}", i), i * i); }
    let shared = Arc::new(map);
    let mut handles = vec![];
    for i in 0..4 {
        let s = Arc::clone(&shared);
        handles.push(thread::spawn(move || {
            s.get(&format!("key_{}", i)).copied().unwrap_or(-1)
        }));
    }
    let results: Vec<i64> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    assert_eq!(results, vec![0, 1, 4, 9]);

    let v: Vec<i32> = (1..=20).filter(|x| x % 3 == 0).map(|x| x * x).collect();
    assert_eq!(v, vec![9, 36, 81, 144, 225, 324]);

    #[derive(Debug)]
    enum Shape { Circle(f64), Rect(f64, f64) }
    for s in &[Shape::Circle(1.0), Shape::Rect(2.0, 3.0)] {
        match s {
            Shape::Circle(r) => println!("circle area={:.2}", std::f64::consts::PI * r * r),
            Shape::Rect(w, h) => println!("rect area={:.2}", w * h),
        }
    }
    println!("ALL OK");
}
```

## 8. Post-Install Verification

```bash
dpkg --verify llvm-rust-system   # must print nothing
clang --version | head -1        # 23.1.0-rc1
rustc --version                  # 1.99.0-nightly
cargo --version                  # 1.99.0-nightly
mold --version                   # 2.41.0
echo 'int main(){return 0;}' | clang -x c - -o $PREFIX/tmp/smoke && $PREFIX/tmp/smoke
echo 'fn main(){println!("ok")}' > $PREFIX/tmp/s.rs && rustc $PREFIX/tmp/s.rs -o $PREFIX/tmp/s && $PREFIX/tmp/s
```

## 9. /tmp Permission Note

Android/Termux: `/tmp` may be permission-denied for output files. Always use
`$PREFIX/tmp` for test binaries. This is NOT an LLVM bug.
