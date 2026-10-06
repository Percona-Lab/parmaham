#!/usr/bin/env python3
"""Parma Ham dashboard: a small, dependency-free web server.

Serves static/index.html and a JSON API with node information, benchmark
status and results, and real-time OS (including pressure stall information)
and database metrics sampled every few seconds and kept in memory.

Configuration comes from /etc/parmaham/parmaham.conf (shell KEY=value
syntax); state written by the benchmark scripts is read from
/var/lib/parmaham.
"""

import collections
import importlib.util
import json
import os
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
PMH_HOME = os.environ.get("PMH_HOME", os.path.dirname(HERE))
PMH_ETC = os.environ.get("PMH_ETC", "/etc/parmaham")
PMH_STATE = os.environ.get("PMH_STATE", "/var/lib/parmaham")
STATIC = os.path.join(HERE, "static")


# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
def read_shell_conf(path):
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                parts = shlex.split(value, comments=True)
                conf[key.strip()] = parts[0] if parts else ""
    except OSError:
        pass
    return conf


def load_config():
    conf = read_shell_conf(os.path.join(PMH_HOME, "config", "parmaham.conf.defaults"))
    conf.update(read_shell_conf(os.path.join(PMH_ETC, "parmaham.conf")))
    return conf


CONF = load_config()


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_file(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


# ---------------------------------------------------------------------------
# database collector plug-in: <PMH_HOME>/<PMH_DB>/dashboard_collector.py
# ---------------------------------------------------------------------------
def load_db_collector():
    db = CONF.get("PMH_DB", "mysql")
    path = os.path.join(PMH_HOME, db, "dashboard_collector.py")
    spec = importlib.util.spec_from_file_location(f"pmh_collector_{db}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    cnf = os.path.join(cred_dir, "db.cnf") if cred_dir else os.path.join(PMH_ETC, f"{db}-monitor.cnf")
    return module, module.Collector(cnf)


# ---------------------------------------------------------------------------
# OS metrics from /proc
# ---------------------------------------------------------------------------
CPU_FIELDS = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"]


def os_counters():
    """Raw cumulative counters and gauges for one sample."""
    s = {}
    with open("/proc/stat") as f:
        for line in f:
            parts = line.split()
            if parts[0] == "cpu":
                vals = [int(v) for v in parts[1:9]]
                for name, v in zip(CPU_FIELDS, vals):
                    s["cpu_" + name] = v
                s["cpu_total"] = sum(vals)
            elif parts[0] == "ctxt":
                s["ctx_switches"] = int(parts[1])
            elif parts[0] == "procs_running":
                s["procs_running"] = int(parts[1])
            elif parts[0] == "procs_blocked":
                s["procs_blocked"] = int(parts[1])

    load = read_file("/proc/loadavg").split()
    s["load1"], s["load5"], s["load15"] = (float(x) for x in load[:3])

    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            mem[k] = int(v.split()[0]) * 1024
    s["mem_total"] = mem.get("MemTotal", 0)
    s["mem_available"] = mem.get("MemAvailable", 0)
    s["mem_used"] = s["mem_total"] - s["mem_available"]
    s["mem_cached"] = mem.get("Cached", 0) + mem.get("Buffers", 0)
    s["mem_dirty"] = mem.get("Dirty", 0)
    s["swap_used"] = mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)

    vm = {}
    with open("/proc/vmstat") as f:
        for line in f:
            k, v = line.split()
            vm[k] = int(v)
    s["swap_in_pages"] = vm.get("pswpin", 0)
    s["swap_out_pages"] = vm.get("pswpout", 0)
    s["major_faults"] = vm.get("pgmajfault", 0)

    # disks: whole devices only (no partitions, loop or ram devices)
    disks = {}
    with open("/proc/diskstats") as f:
        for line in f:
            p = line.split()
            name = p[2]
            if name.startswith(("loop", "ram", "zram", "sr", "fd")):
                continue
            if not os.path.exists(f"/sys/block/{name}") or os.path.exists(f"/sys/block/{name}/partition"):
                continue
            holders = f"/sys/block/{name}/holders"
            if os.path.isdir(holders) and os.listdir(holders):
                continue  # used by dm/md: the upper device is counted instead
            disks[name] = {
                "reads": int(p[3]), "read_bytes": int(p[5]) * 512,
                "writes": int(p[7]), "write_bytes": int(p[9]) * 512,
                "busy_ms": int(p[12]),
            }
    s["disks"] = disks

    rx = tx = 0
    with open("/proc/net/dev") as f:
        for line in f.readlines()[2:]:
            name, data = line.split(":", 1)
            name = name.strip()
            if name == "lo" or name.startswith(("veth", "docker", "virbr", "br-")):
                continue
            d = data.split()
            rx += int(d[0])
            tx += int(d[8])
    s["net_rx_bytes"], s["net_tx_bytes"] = rx, tx

    # pressure stall information: cumulative stall time in microseconds
    for res in ("cpu", "memory", "io"):
        for line in read_file(f"/proc/pressure/{res}").splitlines():
            parts = line.split()
            kind = parts[0]
            fields = dict(x.split("=") for x in parts[1:])
            s[f"psi_{res}_{kind}_total"] = int(fields["total"])
            s[f"psi_{res}_{kind}_avg10"] = float(fields["avg10"])
    return s


def os_derived(prev, cur, dt):
    """Convert two raw samples into the values shown on the dashboard."""
    out = {}
    tot = cur["cpu_total"] - prev["cpu_total"] or 1
    for name in CPU_FIELDS:
        out["cpu_" + name] = 100.0 * (cur["cpu_" + name] - prev["cpu_" + name]) / tot
    out["cpu_busy"] = 100.0 - out["cpu_idle"] - out["cpu_iowait"]
    out["ctx_switches"] = (cur["ctx_switches"] - prev["ctx_switches"]) / dt
    for k in ("procs_running", "procs_blocked", "load1", "load5", "load15",
              "mem_total", "mem_used", "mem_available", "mem_cached", "mem_dirty", "swap_used"):
        out[k] = cur[k]
    for k in ("swap_in_pages", "swap_out_pages", "major_faults", "net_rx_bytes", "net_tx_bytes"):
        out[k] = max(0, cur[k] - prev[k]) / dt

    reads = writes = rbytes = wbytes = 0
    util = 0.0
    per_disk = {}
    for name, d in cur["disks"].items():
        p = prev["disks"].get(name)
        if not p:
            continue
        r = (d["reads"] - p["reads"]) / dt
        w = (d["writes"] - p["writes"]) / dt
        rb = (d["read_bytes"] - p["read_bytes"]) / dt
        wb = (d["write_bytes"] - p["write_bytes"]) / dt
        u = min(100.0, (d["busy_ms"] - p["busy_ms"]) / (dt * 10.0))
        per_disk[name] = {"r": r, "w": w, "rb": rb, "wb": wb, "util": u}
        reads += r; writes += w; rbytes += rb; wbytes += wb
        util = max(util, u)
    out.update(disk_reads=reads, disk_writes=writes, disk_read_bytes=rbytes,
               disk_write_bytes=wbytes, disk_util_max=util)
    out["disks"] = per_disk

    # PSI: share of wall time with stalled tasks over the sample interval
    for res in ("cpu", "memory", "io"):
        for kind in ("some", "full"):
            key = f"psi_{res}_{kind}_total"
            if key in cur and key in prev:
                out[f"psi_{res}_{kind}"] = min(100.0, (cur[key] - prev[key]) / (dt * 1e4))
    return out


# ---------------------------------------------------------------------------
# node information (collected once at start, cheap to refresh)
# ---------------------------------------------------------------------------
def node_info():
    info = {"hostname": socket.gethostname(), "kernel": platform.release(), "arch": platform.machine()}
    try:  # primary IPv4 address (no packet is sent for a UDP connect)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))
            info["ip"] = s.getsockname()[0]
    except OSError:
        info["ip"] = None
    osr = {}
    for line in read_file("/etc/os-release").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            osr[k] = v.strip('"')
    info["os"] = osr.get("PRETTY_NAME", "Linux")

    cpu = {}
    try:
        for item in json.loads(run(["lscpu", "-J"]) or "{}").get("lscpu", []):
            cpu[item["field"].rstrip(":")] = item["data"]
    except ValueError:
        pass
    info["cpu_model"] = cpu.get("Model name") or "unknown"
    info["cpus"] = os.cpu_count()
    info["sockets"] = cpu.get("Socket(s)")
    info["cores_per_socket"] = cpu.get("Core(s) per socket")
    info["threads_per_core"] = cpu.get("Thread(s) per core")
    info["numa_nodes"] = cpu.get("NUMA node(s)")
    info["cpu_mhz_max"] = cpu.get("CPU max MHz")
    info["l3_cache"] = cpu.get("L3 cache")
    info["virtualization"] = run(["systemd-detect-virt"]) or "none"
    vendor = read_file("/sys/class/dmi/id/sys_vendor")
    product = read_file("/sys/class/dmi/id/product_name")
    info["system"] = " ".join(x for x in (vendor, product) if x) or None

    with open("/proc/meminfo") as f:
        info["mem_total"] = int(f.readline().split()[1]) * 1024

    disks = []
    try:
        for d in json.loads(run(["lsblk", "-J", "-d", "-b", "-o", "NAME,SIZE,MODEL,ROTA,TRAN,TYPE"]) or "{}").get("blockdevices", []):
            if d.get("type") != "disk":
                continue
            disks.append({"name": d["name"], "size": int(d.get("size") or 0),
                          "model": (d.get("model") or "").strip(),
                          "rotational": d.get("rota") in (True, "1", 1),
                          "transport": d.get("tran")})
    except ValueError:
        pass
    info["disks"] = disks

    nics = []
    for name in sorted(os.listdir("/sys/class/net")):
        if name == "lo" or name.startswith(("veth", "docker", "virbr", "br-")):
            continue
        speed = read_file(f"/sys/class/net/{name}/speed")
        nics.append({"name": name, "speed_mbps": int(speed) if speed.lstrip("-").isdigit() and int(speed) > 0 else None})
    info["nics"] = nics
    info["boot_time"] = time.time() - float(read_file("/proc/uptime").split()[0])
    info["psi_available"] = os.path.exists("/proc/pressure/cpu")
    return info


def filesystem_info(path):
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    src = fstype = ""
    out = run(["findmnt", "-n", "-o", "SOURCE,FSTYPE", "-T", path])
    if out:
        parts = out.split()
        src, fstype = parts[0], parts[1] if len(parts) > 1 else ""
    return {"path": path, "device": src, "fstype": fstype,
            "size": st.f_blocks * st.f_frsize, "free": st.f_bavail * st.f_frsize}


# ---------------------------------------------------------------------------
# process memory written by procmem.py (parmaham-procmem.service)
# ---------------------------------------------------------------------------
PROCMEM_FILE = os.environ.get("PMH_PROCMEM", "/run/parmaham/procmem.json")


def db_process_memory(name, max_age):
    data = read_json(PROCMEM_FILE)
    if not data or time.time() - data.get("t", 0) > max_age:
        return {}
    p = data.get("procs", {}).get(name)
    if not p:
        return {}
    out = {"proc_vsz": p.get("vsz"), "proc_rss": p.get("rss")}
    if "pss" in p:
        out["proc_pss_swap"] = p["pss"] + p.get("swap_pss", 0)
    return {k: v for k, v in out.items() if v is not None}


# ---------------------------------------------------------------------------
# long-term history: 1-minute averages, kept for ROLLUP_HOURS and persisted
# as JSON lines so the history survives restarts
# ---------------------------------------------------------------------------
ROLLUP_SEC = 60


class Rollup:
    def __init__(self, path, hours):
        self.path = path
        self.keep = hours * 3600
        self.points = collections.deque()
        self.bucket = None
        self.pending = []
        self.lines = 0
        self.load()

    def load(self):
        if not self.path:
            return
        cutoff = time.time() - self.keep
        try:
            with open(self.path) as f:
                for line in f:
                    try:
                        p = json.loads(line)
                    except ValueError:
                        continue
                    if p.get("t", 0) > cutoff:
                        self.points.append(p)
        except OSError:
            pass
        self.compact()

    def compact(self):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                for p in self.points:
                    f.write(json.dumps(p, separators=(",", ":")) + "\n")
            os.replace(tmp, self.path)
            self.lines = len(self.points)
        except OSError as e:
            print(f"warning: cannot write {self.path}: {e}", file=sys.stderr)
            self.path = None

    def add(self, point):
        bucket = int(point["t"] // ROLLUP_SEC)
        if self.bucket is not None and bucket != self.bucket and self.pending:
            self.flush()
        self.bucket = bucket
        self.pending.append(point)

    def flush(self):
        sums, counts = {}, {}
        for p in self.pending:
            for k, v in p.items():
                if k != "t" and isinstance(v, (int, float)):
                    sums[k] = sums.get(k, 0) + v
                    counts[k] = counts.get(k, 0) + 1
        avg = {k: round(sums[k] / counts[k], 3) for k in sums}
        avg["t"] = self.bucket * ROLLUP_SEC + ROLLUP_SEC / 2
        self.pending = []
        self.points.append(avg)
        cutoff = time.time() - self.keep
        while self.points and self.points[0]["t"] < cutoff:
            self.points.popleft()
        if self.path:
            try:
                with open(self.path, "a") as f:
                    f.write(json.dumps(avg, separators=(",", ":")) + "\n")
                self.lines += 1
            except OSError:
                pass
            if self.lines > 2 * len(self.points) + 60:
                self.compact()


# ---------------------------------------------------------------------------
# sampler thread
# ---------------------------------------------------------------------------
class Sampler(threading.Thread):
    def __init__(self, interval, history_min, rollup_hours):
        super().__init__(daemon=True)
        self.interval = interval
        self.samples = collections.deque(maxlen=int(history_min * 60 / interval) + 1)
        state_dir = os.environ.get("STATE_DIRECTORY")
        self.rollup = Rollup(os.path.join(state_dir, "rollup.jsonl") if state_dir else None, rollup_hours)
        self.lock = threading.Lock()
        self.db_module, self.db = load_db_collector()
        self.db_info = {}
        self.db_info_at = 0
        self.db_error = None
        self.node = node_info()

    def refresh_db_info(self):
        try:
            self.db_info = self.db.info()
            self.db_info["error"] = None
        except Exception as e:  # noqa: BLE001 - shown on the dashboard
            msg = (getattr(e, "stderr", None) or str(e)).strip()
            self.db_info = dict(self.db_info, error=msg[:300])
        self.db_info_at = time.time()

    def run(self):
        prev_os = prev_db = None
        prev_t = None
        while True:
            t0 = time.time()
            try:
                cur_os = os_counters()
            except Exception:  # noqa: BLE001
                traceback.print_exc()
                cur_os = None
            try:
                cur_db = self.db.sample()
                self.db_error = None
            except Exception as e:  # noqa: BLE001
                cur_db = None
                self.db_error = (getattr(e, "stderr", None) or str(e)).strip()[:300]
            if prev_t is not None:
                dt = t0 - prev_t
                point = {"t": round(t0, 1)}
                if cur_os and prev_os:
                    point.update(os_derived(prev_os, cur_os, dt))
                if cur_db and prev_db:
                    for key in self.db_module.RATES:
                        point[key] = max(0.0, (cur_db[key] - prev_db[key]) / dt)
                    for key in self.db_module.GAUGES:
                        point[key] = cur_db[key]
                    point["db_checkpoint_age_bytes"] = cur_db.get("db_checkpoint_age_bytes", 0)
                    point["nopm"] = point.pop("db_new_orders") * 60
                    point["tpm"] = point["db_tps"] * 60
                    req = point["db_bp_read_requests"]
                    point["db_bp_hit_pct"] = 100.0 * (1 - point["db_bp_disk_reads"] / req) if req else 100.0
                    total = point["db_bp_pages_total"]
                    point["db_bp_dirty_pct"] = 100.0 * point["db_bp_pages_dirty"] / total if total else 0
                    point["db_up"] = 1
                elif cur_db is None:
                    point["db_up"] = 0
                point.update(db_process_memory(getattr(self.db_module, "PROCESS", ""), 3 * self.interval))
                point = {k: (round(v, 3) if isinstance(v, float) else v) for k, v in point.items()}
                if "disks" in point:
                    point["disks"] = {n: {k: round(v, 2) for k, v in d.items()} for n, d in point["disks"].items()}
                with self.lock:
                    self.samples.append(point)
                    self.rollup.add(point)
            prev_os, prev_db, prev_t = cur_os, cur_db, t0
            # refresh every 5 minutes, or every 30 s while the database is unreachable
            if time.time() - self.db_info_at > (30 if self.db_info.get("error") else 300):
                self.refresh_db_info()
            time.sleep(max(0.5, self.interval - (time.time() - t0)))

    def series(self, since):
        with self.lock:
            return [p for p in self.samples if p["t"] > since]

    def rollup_series(self, since):
        with self.lock:
            return [p for p in self.rollup.points if p["t"] > since]


# ---------------------------------------------------------------------------
# benchmark state written by the shell scripts
# ---------------------------------------------------------------------------
def read_results(limit):
    path = os.path.join(PMH_STATE, "results.jsonl")
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            # read enough of the tail for `limit` lines (~250 bytes each)
            f.seek(max(0, size - limit * 400))
            lines = f.read().decode(errors="replace").splitlines()
    except OSError:
        return []
    out = []
    for line in lines[-limit:]:
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def results_summary():
    path = os.path.join(PMH_STATE, "results.jsonl")
    count = ok = 0
    first = None
    try:
        with open(path) as f:
            for line in f:
                count += 1
                if '"ok": true' in line:
                    ok += 1
                if first is None:
                    try:
                        first = json.loads(line).get("started_at")
                    except ValueError:
                        pass
    except OSError:
        pass
    return {"runs": count, "ok": ok, "first_started_at": first}


def service_state(unit):
    return run(["systemctl", "is-active", unit]) or "unknown"


def service_since(unit):
    out = run(["systemctl", "show", unit, "-P", "ActiveEnterTimestamp"])
    return out or None


def timer_next(unit):
    """Epoch seconds of the timer's next run (monotonic timers included)."""
    try:
        timers = json.loads(run(["systemctl", "list-timers", "--all", "--output=json", unit]) or "[]")
        nxt = timers[0].get("next") if timers else None
        return nxt / 1e6 if nxt else None
    except (ValueError, TypeError, AttributeError):
        return None


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
SAMPLER = None
SUMMARY_CACHE = {"t": 0, "v": None}  # "t": (mtime, size) of results.jsonl


class Handler(BaseHTTPRequestHandler):
    server_version = "ParmaHam"

    def log_message(self, fmt, *args):  # keep the journal quiet
        pass

    def send_json(self, obj, status=200):
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        url = urlparse(self.path)
        q = parse_qs(url.query)
        try:
            if url.path in ("/", "/index.html"):
                self.send_file(os.path.join(STATIC, "index.html"), "text/html; charset=utf-8")
            elif url.path == "/api/info":
                self.send_json(api_info())
            elif url.path == "/api/status":
                self.send_json(api_status())
            elif url.path == "/api/metrics":
                since = float(q.get("since", ["0"])[0])
                if q.get("res", [""])[0] == str(ROLLUP_SEC):
                    self.send_json({"interval": ROLLUP_SEC, "now": time.time(),
                                    "samples": SAMPLER.rollup_series(since)})
                else:
                    self.send_json({"interval": SAMPLER.interval, "now": time.time(),
                                    "samples": SAMPLER.series(since)})
            elif url.path == "/api/results":
                limit = min(5000, int(q.get("limit", ["500"])[0]))
                self.send_json({"results": read_results(limit)})
            elif url.path == "/healthz":
                self.send_json({"ok": True})
            else:
                self.send_error(404)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            self.send_json({"error": str(e)}, 500)


def api_info():
    datadir = SAMPLER.db_info.get("datadir") or "/"
    conf_keys = ["WAREHOUSES", "CAPACITY_VU", "CAPACITY_RAMPUP", "CAPACITY_DURATION",
                 "WORKLOAD_PERCENT", "WORKLOAD_VU", "WORKLOAD_RAMPUP", "WORKLOAD_DURATION",
                 "WORKLOAD_SLEEP", "PURGE_RETENTION_HOURS", "PURGE_INTERVAL_MIN", "HAMMERDB_VERSION"]
    conf = load_config()
    return {
        "node": SAMPLER.node,
        "filesystem": filesystem_info(datadir.rstrip("/") or "/"),
        "db": SAMPLER.db_info,
        "config": {k: conf.get(k) for k in conf_keys},
        "schema": read_json(os.path.join(PMH_STATE, "schema.json")),
        "capacity": read_json(os.path.join(PMH_STATE, "capacity.json")),
        "interval": SAMPLER.interval,
        "db_process": getattr(SAMPLER.db_module, "PROCESS", None),
    }


def api_status():
    now = time.time()
    try:
        st = os.stat(os.path.join(PMH_STATE, "results.jsonl"))
        key = (st.st_mtime, st.st_size)
    except OSError:
        key = None
    if key != SUMMARY_CACHE["t"]:
        SUMMARY_CACHE["v"] = results_summary()
        SUMMARY_CACHE["t"] = key
    last = read_results(1)
    last_ok = [r for r in read_results(50) if r.get("ok")]
    return {
        "now": now,
        "status": read_json(os.path.join(PMH_STATE, "status.json"), {"state": "not installed"}),
        "last_result": last[-1] if last else None,
        "last_ok_result": last_ok[-1] if last_ok else None,
        "summary": SUMMARY_CACHE["v"],
        "services": {
            "workload": service_state("parmaham-workload.service"),
            "workload_since": service_since("parmaham-workload.service"),
            "purge_timer": service_state("parmaham-purge.timer"),
            "purge_next": timer_next("parmaham-purge.timer"),
        },
        "purge": SAMPLER.db_info.get("last_purge"),
        "db_error": SAMPLER.db_error,
        "uptime_sec": now - SAMPLER.node["boot_time"],
    }


def main():
    global SAMPLER
    interval = float(CONF.get("DASHBOARD_INTERVAL", 5))
    history = float(CONF.get("DASHBOARD_HISTORY_MIN", 60))
    bind = CONF.get("DASHBOARD_BIND", "0.0.0.0")
    port = int(os.environ.get("DASHBOARD_PORT", CONF.get("DASHBOARD_PORT", 80)))
    if not shutil.which("mysql") and CONF.get("PMH_DB", "mysql") == "mysql":
        print("warning: mysql client not found, database metrics unavailable", file=sys.stderr)
    rollup_hours = float(CONF.get("DASHBOARD_ROLLUP_HOURS", 24))
    SAMPLER = Sampler(interval, history, rollup_hours)
    SAMPLER.refresh_db_info()
    SAMPLER.start()
    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    print(f"Parma Ham dashboard listening on http://{bind}:{port}/", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
