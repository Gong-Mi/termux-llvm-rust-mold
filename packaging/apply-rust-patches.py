#!/usr/bin/env python3
"""apply-rust-patches.py — 把 Termux 的 rust 补丁序列打到本地 rust 源码树。

要点：
  * 补丁里有 Termux 构建期占位符，必须先替换再打（0001 的 @TERMUX_PKG_API_LEVEL@、
    0004 的 @TERMUX_PREFIX@）。写成字面量会污染源码。
  * 是否"已应用"用 `patch --dry-run --reverse` 精确判定（能反向打上就是已应用），
    不靠猜标记——猜标记会假阳性并静默跳过必需补丁。
  * 幂等：可反复执行。

跳过（有原因）：
  * 0006  只抑制一条增量缓存硬链接失败的运行时警告，与构建成败无关
  * 0011  只影响 wasip3 target 的 libdir 断言，本构建不含 wasip3
  * 0009  上游版 hunk#1 的 import 上下文已随版本变化 → 用 local-0009-... 适配版
"""
import os, subprocess, sys, tempfile

SRC = os.environ.get("RUST_SRC", os.path.expanduser("~/rust-latest-llvm231"))
PDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rust-patches")

SUBST = {
    "@TERMUX_PKG_API_LEVEL@": os.environ.get("TERMUX_PKG_API_LEVEL", "30"),
    "@TERMUX_PREFIX@": os.environ.get("PREFIX", "/data/data/com.termux/files/usr"),
}

SERIES = [
    "0001-set-TERMUX_PKG_API_LEVEL.diff",
    "0002-no-signal_handler.patch",
    "0003-link-with-libc++_shared.patch",
    "0004-set-TMPDIR.patch",
    "0005-define-fn-backtrace-getauxval.patch",
    "0007-use-emulated-tls-on-android.patch",
    "0008-cross-compile-error_index_generator.patch",
    "local-0009-always-export-emutls-rust1.100.0.patch",
    "local-0010-rustc-main-expect-android.patch",
    "local-0011-std-allow-unused-dependencies.patch",
    "local-0012-sysroot-allow-unused-dependencies.patch",
    "force-allow-edit-vendor.diff",
]
SKIPPED = {
    "0006-suppress-hard-linking-failed-warning.patch": "只抑制运行时警告，与构建无关",
    "0011-fix-wasip3-libdir-assert.patch": "只影响 wasip3，本构建不含该 target",
    "0009-always-export-emutls.patch": "由 local-0009-... 适配版替代",
}


def target_of(path):
    for ln in open(path, encoding="utf-8", errors="replace"):
        if ln.startswith("+++ "):
            p = ln[4:].split("\t")[0].strip()
            if p.startswith("b/"):
                return p[2:]
    return None


def substituted(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    hits = {k: v for k, v in SUBST.items() if k in txt}
    for k, v in hits.items():
        txt = txt.replace(k, v)
    return txt, hits


def run(patch_text, extra):
    fd, tmp = tempfile.mkstemp(suffix=".patch")
    with os.fdopen(fd, "w") as f:
        f.write(patch_text)
    try:
        return subprocess.run(["patch", "-p1", "--no-backup-if-mismatch"] + extra,
                              cwd=SRC, stdin=open(tmp), capture_output=True, text=True)
    finally:
        os.unlink(tmp)


def main():
    if not os.path.isdir(SRC):
        print(f"错误：找不到 rust 源码树 {SRC}"); return 1
    applied, already, failed = [], [], []
    for name in SERIES:
        p = os.path.join(PDIR, name)
        if not os.path.exists(p):
            failed.append((name, "补丁文件不存在")); continue
        txt, hits = substituted(p)
        tgt = target_of(p)
        note = f"  [替换 {', '.join(hits)}]" if hits else ""
        rv = run(txt, ["--dry-run", "--reverse"])
        if rv.returncode == 0:
            print(f"  ⏭  {name}  （已应用）{note}")
            already.append(name); continue
        r = run(txt, [])
        if r.returncode == 0:
            print(f"  ✅ {name} -> {tgt}{note}")
            applied.append(name)
        else:
            print(f"  ❌ {name} rc={r.returncode}{note}")
            print("".join("      " + l for l in (r.stdout + r.stderr).splitlines(True)))
            failed.append((name, f"rc={r.returncode}"))
    print()
    print(f"应用 {len(applied)}，已是应用态 {len(already)}，失败 {len(failed)}")
    for n, why in SKIPPED.items():
        print(f"  略过 {n}：{why}")
    if failed:
        print("失败明细:", failed); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
