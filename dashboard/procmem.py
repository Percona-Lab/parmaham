#!/usr/bin/env python3
"""Memory and CPU usage of named processes, for the Parma Ham dashboard.

Usage: procmem.py OUTPUT_FILE INTERVAL_SEC SPEC [SPEC ...]

SPEC is either a process name (all processes with that name are summed), or
a group "label=unit[,unit...][+name[,name...]]": every process in the
listed systemd services plus processes with the listed names, e.g.
    hammerdb=parmaham-workload.service,parmaham-capacity.service+hammerdbcli

PSS and SwapPSS come from /proc/<pid>/smaps_rollup, which only the process
owner or a ptrace-capable process may read. This helper therefore runs as a
separate service with CAP_SYS_PTRACE and no network access, so the public
dashboard itself needs no privileges. Every interval it writes, atomically:

    {"t": <epoch>, "procs": {"mysqld": {"pid": .., "vsz": .., "rss": ..,
                                        "pss": .., "swap_pss": .., "cpu_sec": ..}}}

Memory values are bytes; cpu_sec is the cumulative user+system CPU time
(all threads). For a group it is the services' cgroup CPU counter, which
includes processes that have already exited.
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


CLK_TCK = os.sysconf("SC_CLK_TCK")


def cpu_seconds(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            # the command name may contain spaces: fields start after ")"
            fields = f.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / CLK_TCK  # utime + stime
    except (OSError, IndexError, ValueError):
        return 0.0


CGROUP_ROOT = "/sys/fs/cgroup/system.slice"


def parse_specs(args):
    """-> list of (label, units, names)"""
    specs = []
    for a in args:
        if "=" in a:
            label, rest = a.split("=", 1)
            units, _, names = rest.partition("+")
            specs.append((label, [u for u in units.split(",") if u], set(n for n in names.split(",") if n)))
        else:
            specs.append((a, [], {a}))
    return specs


def unit_cgroup(unit):
    """cgroup directory of a system service; instances of a template unit
    (postgresql@18-main.service) live in their own slice"""
    if "@" in unit:
        prefix = unit.split("@", 1)[0].replace("-", "\\x2d")
        return f"{CGROUP_ROOT}/system-{prefix}.slice/{unit}"
    return f"{CGROUP_ROOT}/{unit}"


def unit_pids(unit):
    try:
        with open(f"{unit_cgroup(unit)}/cgroup.procs") as f:
            return {int(x) for x in f.read().split()}
    except (OSError, ValueError):
        return set()


def unit_cpu_seconds(unit):
    try:
        with open(f"{unit_cgroup(unit)}/cpu.stat") as f:
            for line in f:
                k, v = line.split()
                if k == "usage_usec":
                    return int(v) / 1e6
    except (OSError, ValueError):
        pass
    return None


def sample(specs):
    comms = {}
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                with open(f"/proc/{pid}/comm") as f:
                    comms[int(pid)] = f.read().strip()
            except OSError:
                pass
    procs = {}
    for label, units, names in specs:
        in_units = set().union(*(unit_pids(u) for u in units)) if units else set()
        pids = in_units | {p for p, c in comms.items() if c in names}
        if not pids:
            continue
        agg = {"pid": min(pids), "count": 0, "cpu_sec": 0.0}
        for pid in pids:
            m = read_kb_fields(f"/proc/{pid}/status", {"VmSize": "vsz", "VmRSS": "rss"})
            if not m:
                continue  # exited meanwhile
            m.update(read_kb_fields(f"/proc/{pid}/smaps_rollup", {"Pss": "pss", "SwapPss": "swap_pss"}))
            agg["count"] += 1
            if pid not in in_units:
                agg["cpu_sec"] += cpu_seconds(pid)
            for k, v in m.items():
                agg[k] = agg.get(k, 0) + v
        for u in units:
            c = unit_cpu_seconds(u)
            if c is not None and unit_pids(u):
                agg["cpu_sec"] += c
        if agg["count"]:
            procs[label] = agg
    return procs


def main():
    out, interval, specs = sys.argv[1], float(sys.argv[2]), parse_specs(sys.argv[3:])
    tmp = out + ".tmp"
    while True:
        t0 = time.time()
        with open(tmp, "w") as f:
            json.dump({"t": round(t0, 1), "procs": sample(specs)}, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, out)
        time.sleep(max(0.5, interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
