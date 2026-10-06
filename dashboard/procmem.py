#!/usr/bin/env python3
"""Memory usage of named processes, for the Parma Ham dashboard.

Usage: procmem.py OUTPUT_FILE INTERVAL_SEC NAME [NAME ...]

PSS and SwapPSS come from /proc/<pid>/smaps_rollup, which only the process
owner or a ptrace-capable process may read. This helper therefore runs as a
separate service with CAP_SYS_PTRACE and no network access, so the public
dashboard itself needs no privileges. Every interval it writes, atomically:

    {"t": <epoch>, "procs": {"mysqld": {"pid": .., "vsz": .., "rss": ..,
                                        "pss": .., "swap_pss": ..}}}

Values are bytes; all processes with the same name are summed.
"""

import json
import os
import sys
import time


def read_kb_fields(path, fields):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                key, _, rest = line.partition(":")
                if key in fields:
                    out[fields[key]] = int(rest.split()[0]) * 1024
    except OSError:
        pass
    return out


def sample(names):
    procs = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if comm not in names:
            continue
        m = read_kb_fields(f"/proc/{pid}/status", {"VmSize": "vsz", "VmRSS": "rss"})
        m.update(read_kb_fields(f"/proc/{pid}/smaps_rollup", {"Pss": "pss", "SwapPss": "swap_pss"}))
        agg = procs.setdefault(comm, {"pid": int(pid), "count": 0})
        agg["count"] += 1
        for k, v in m.items():
            agg[k] = agg.get(k, 0) + v
    return procs


def main():
    out, interval, names = sys.argv[1], float(sys.argv[2]), set(sys.argv[3:])
    tmp = out + ".tmp"
    while True:
        t0 = time.time()
        with open(tmp, "w") as f:
            json.dump({"t": round(t0, 1), "procs": sample(names)}, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, out)
        time.sleep(max(0.5, interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
