#!/usr/bin/env python3
"""elf-android-check.py <elf> [<elf> ...]

Report the Android loader's acceptance checks for one or more ELF files, using
only the stdlib (runs under a Termux python3). Exits non-zero if any hard
requirement fails.

  * executable must be PIE (ET_DYN)      -> loader refuses ET_EXEC outright
  * PT_TLS.p_align >= 64 on arm64        -> bionic aborts at startup otherwise
  * PT_INTERP present and named          -> dynamic executables need it
  * 16 KB segment alignment              -> only enforced on 16 KB-page kernels
  * DT_TEXTREL present                   -> never expected on Android
  * DT_ANDROID_RELA / DT_RELR            -> informational, NOT a requirement
"""
import os
import struct
import sys

PT_LOAD, PT_DYNAMIC, PT_INTERP, PT_TLS = 1, 2, 3, 7
MACH = {183: "aarch64", 40: "arm", 62: "x86_64", 3: "i386"}
DYNTAG = {
    0x16: "TEXTREL", 0x1E: "FLAGS", 0x6FFFFFFB: "FLAGS_1",
    0x23: "RELRSZ", 0x24: "RELR", 0x25: "RELRENT",
    0x6000000F: "ANDROID_REL", 0x60000010: "ANDROID_RELSZ",
    0x60000011: "ANDROID_RELA", 0x60000012: "ANDROID_RELASZ",
}
DF_1_PIE = 0x08000000


def parse(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        raise SystemExit(f"{path}: not an ELF file")
    if data[4] != 2:
        raise SystemExit(f"{path}: 32-bit ELF not handled")
    e_type, e_machine = struct.unpack_from("<HH", data, 0x10)
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        p_offset, = struct.unpack_from("<Q", data, off + 0x08)
        p_filesz, = struct.unpack_from("<Q", data, off + 0x20)
        p_align, = struct.unpack_from("<Q", data, off + 0x30)
        phdrs.append((p_type, p_offset, p_filesz, p_align))
    dyn = {}
    for p_type, off, size, _ in phdrs:
        if p_type != PT_DYNAMIC:
            continue
        for j in range(0, size, 16):
            tag, val = struct.unpack_from("<qQ", data, off + j)
            dyn[tag] = val
            if tag == 0:
                break
    interp = ""
    for p_type, off, size, _ in phdrs:
        if p_type == PT_INTERP:
            interp = data[off:off + size].rstrip(b"\0").decode("utf-8", "replace")
    return e_type, e_machine, phdrs, dyn, interp


def check(path, page_size):
    e_type, e_machine, phdrs, dyn, interp = parse(path)
    load_aligns = sorted({a for t, _, _, a in phdrs if t == PT_LOAD})
    tls_aligns = sorted({a for t, _, _, a in phdrs if t == PT_TLS})
    arch = MACH.get(e_machine, hex(e_machine))
    exec_like = e_type == 3 and (interp or dyn.get(0x6FFFFFFB, 0) & DF_1_PIE)
    dynamic_exe = e_type == 2 or bool(interp)
    print(f"=== {path} ===")
    print(f"  type      {'ET_DYN' if e_type == 3 else 'ET_EXEC' if e_type == 2 else e_type}"
          f"  machine={arch}")
    print(f"  PT_LOAD   p_align={load_aligns}")
    print(f"  PT_TLS    p_align={tls_aligns or '(absent)'}")
    print(f"  PT_INTERP {interp or '(absent)'}")
    tags = [name for tag, name in DYNTAG.items() if tag in dyn]
    print(f"  dynamic   {' '.join(sorted(tags)) or '(none of interest)'}")
    print(f"  page size this device={page_size} 16KB-aligned={'yes' if 16384 in load_aligns else 'no'}")

    failures = []
    if dynamic_exe and e_type == 2:
        failures.append("ET_EXEC: Android only loads PIE executables")
    if not dynamic_exe and not exec_like and e_type == 3:
        print("  note      shared library, no PIE expectation")
    if arch == "aarch64" and tls_aligns and min(tls_aligns) < 64:
        failures.append(
            f"PT_TLS p_align={min(tls_aligns)} < 64: bionic refuses to load")
    if dynamic_exe and not interp and e_type == 2:
        failures.append("static executable: only valid with -static, else missing PT_INTERP")
    if "TEXTREL" in tags:
        failures.append("DT_TEXTREL present: never expected on Android")
    if page_size == 16384 and 16384 not in load_aligns:
        failures.append("16 KB-page device but PT_LOAD not 16 KB aligned")

    if "ANDROID_RELA" in tags or "RELR" in tags:
        print("  info      packed relocations present (optional; bionic accepts plain RELA too)")
    if failures:
        for f in failures:
            print(f"  FAIL      {f}")
    else:
        print("  OK        satisfies the Android loader checks")
    print()
    return not failures


def main(argv):
    if not argv:
        raise SystemExit(__doc__)
    page = os.sysconf("SC_PAGE_SIZE")
    ok = all(check(p, page) for p in argv)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
