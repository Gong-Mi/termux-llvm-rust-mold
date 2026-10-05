#!/usr/bin/env python3
"""memwatch.py <ninja-log> <out-csv>

Append one CSV row every 45s: HH:MM:SS, MemAvailable MB, latest ninja [x/y]
progress line read from <ninja-log>. Run in background next to a long ninja
build and stop it when the build ends. Link stages are the memory peaks, so
this CSV is the evidence when deciding whether to reduce -j or link
parallelism.
"""
import re, sys, time

log_path, out_path = sys.argv[1], sys.argv[2]

def mem_avail_mb():
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemAvailable:'):
                    return int(line.split()[1]) // 1024
    except Exception:
        pass
    return -1

def last_progress():
    try:
        with open(log_path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 16384))
            text = f.read().decode('utf-8', 'replace')
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        for l in reversed(lines):
            if re.match(r'^\[\d+/\d+\]', l):
                return l[:140]
        return (lines[-1][:140] if lines else '')
    except Exception as e:
        return f'<err {e}>'

with open(out_path, 'a', buffering=1) as out:
    out.write(f'# memwatch start {time.strftime("%Y-%m-%d %H:%M:%S")}\n')
    while True:
        out.write(f'{time.strftime("%H:%M:%S")},{mem_avail_mb()},{last_progress()}\n')
        time.sleep(45)
