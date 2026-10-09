#!/usr/bin/env python3
"""Parma Ham compare: side-by-side view of any two Parma Ham workloads.

Runs on any machine (it needs no database) and serves static/index.html plus
a read-only proxy to the JSON API of the Parma Ham dashboards listed in
/etc/parmaham/compare-hosts, one per line:

    http://192.0.2.10/            MariaDB node
    http://192.0.2.11:8080/       PostgreSQL node

The page only talks to this server, so the remote dashboards need not be
reachable from the viewer's browser, and only listed hosts and read-only API
paths are proxied (the page is public and must not become an open proxy).

API:
    /api/hosts                      configured hosts with name, database, node
                                    and a brief workload status (for the picker)
    /api/h/<n>/<path>?<query>       GET <host n>/api/<path>?<query>, where path
                                    is info, status, metrics, results or lastrun
"""

import json
import os
import re
import shlex
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
PMH_HOME = os.environ.get("PMH_HOME", os.path.dirname(HERE))
PMH_ETC = os.environ.get("PMH_ETC", "/etc/parmaham")
HOSTS_FILE = os.environ.get("PMH_COMPARE_HOSTS", os.path.join(PMH_ETC, "compare-hosts"))
STATIC = {
    "/": (os.path.join(HERE, "static", "index.html"), "text/html; charset=utf-8"),
    "/index.html": (os.path.join(HERE, "static", "index.html"), "text/html; charset=utf-8"),
    # shared with the dashboard
    "/style.css": (os.path.join(PMH_HOME, "dashboard", "static", "style.css"), "text/css; charset=utf-8"),
    "/chart.js": (os.path.join(PMH_HOME, "dashboard", "static", "chart.js"), "text/javascript; charset=utf-8"),
}
API_PATHS = {"info", "status", "metrics", "results", "lastrun"}
QUERY_OK = re.compile(r"^[A-Za-z0-9_=&.%-]*$")
TIMEOUT = 8
# identical requests from several viewers within this many seconds share one
# upstream request
CACHE_SEC = 2.0


def read_conf():
    conf = {}
    for path in (os.path.join(PMH_HOME, "config", "parmaham.conf.defaults"), os.path.join(PMH_ETC, "parmaham.conf")):
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        parts = shlex.split(v, comments=True)
                        conf[k.strip()] = parts[0] if parts else ""
        except OSError:
            pass
    return conf


def read_hosts():
    """[(url, name)] from the hosts file; re-read on every request so edits
    apply without a restart."""
    hosts = []
    try:
        with open(HOSTS_FILE) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                url, _, name = line.partition(" ")
                if not re.match(r"^https?://", url):
                    url = "http://" + url
                hosts.append((url.rstrip("/"), name.strip()))
    except OSError:
        pass
    return hosts


CACHE = {}
CACHE_LOCK = threading.Lock()


def fetch(url):
    """-> (status, body bytes); short-lived cache shared by all viewers"""
    now = time.time()
    with CACHE_LOCK:
        hit = CACHE.get(url)
        if hit and now - hit[0] < CACHE_SEC:
            return hit[1], hit[2]
        if len(CACHE) > 500:
            CACHE.clear()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "parmaham-compare"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            status, body = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, json.dumps({"error": f"HTTP {e.code} from host"}).encode()
    except (urllib.error.URLError, OSError, ValueError) as e:
        reason = getattr(e, "reason", e)
        status, body = 502, json.dumps({"error": f"host not reachable: {reason}"}).encode()
    with CACHE_LOCK:
        CACHE[url] = (now, status, body)
    return status, body


HOST_INFO = {}   # url -> (fetched_at, summary)


def host_summary(url):
    """Name, database and node of a host, refreshed every 5 minutes."""
    hit = HOST_INFO.get(url)
    if hit and time.time() - hit[0] < (300 if hit[1].get("ok") else 30):
        return hit[1]
    status, body = fetch(url + "/api/info")
    out = {"ok": False}
    if status == 200:
        try:
            info = json.loads(body)
            node, db = info.get("node") or {}, info.get("db") or {}
            out = {"ok": True, "hostname": node.get("hostname"), "engine": db.get("engine"),
                   "version": db.get("version"), "cpus": node.get("cpus"), "mem_total": node.get("mem_total"),
                   "warehouses": db.get("warehouses")}
        except ValueError:
            pass
    HOST_INFO[url] = (time.time(), out)
    return out


HOST_STATUS = {}  # url -> (fetched_at, brief status)


def host_status(url):
    """Workload state, target and live throughput of a host, refreshed every
    15 s, for the node picker"""
    hit = HOST_STATUS.get(url)
    if hit and time.time() - hit[0] < 15:
        return hit[1]
    out = None
    status, body = fetch(url + "/api/status")
    if status == 200:
        try:
            d = json.loads(body)
            st, last = d.get("status") or {}, d.get("last_ok_result") or {}
            out = {"state": st.get("state"), "iteration": st.get("iteration"),
                   "target_nopm": st.get("target_nopm"), "target_mode": st.get("target_mode"),
                   "percent": st.get("percent"), "last_nopm": last.get("nopm")}
        except ValueError:
            pass
    HOST_STATUS[url] = (time.time(), out)
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "ParmaHamCompare"

    def log_message(self, fmt, *args):
        pass

    def send_body(self, status, body, ctype, cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, status=200):
        self.send_body(status, json.dumps(obj, separators=(",", ":")).encode(), "application/json")

    def do_GET(self):  # noqa: N802
        url = urlparse(self.path)
        try:
            if url.path in STATIC:
                path, ctype = STATIC[url.path]
                try:
                    with open(path, "rb") as f:
                        self.send_body(200, f.read(), ctype, "no-cache")
                except OSError:
                    self.send_error(404)
            elif url.path == "/api/hosts":
                hosts = []
                for i, (u, name) in enumerate(read_hosts()):
                    s = host_summary(u)
                    hosts.append(dict(s, id=i, url=u, name=name or s.get("hostname") or urlparse(u).hostname,
                                      status=host_status(u) if s.get("ok") else None))
                self.send_json({"hosts": hosts, "now": time.time()})
            elif url.path.startswith("/api/h/"):
                m = re.match(r"^/api/h/(\d+)/([a-z]+)$", url.path)
                hosts = read_hosts()
                if not m or int(m.group(1)) >= len(hosts) or m.group(2) not in API_PATHS \
                        or not QUERY_OK.match(url.query):
                    self.send_json({"error": "unknown host or path"}, 404)
                    return
                target = f"{hosts[int(m.group(1))][0]}/api/{m.group(2)}" + (f"?{url.query}" if url.query else "")
                status, body = fetch(target)
                self.send_body(status, body, "application/json")
            elif url.path == "/healthz":
                self.send_json({"ok": True})
            else:
                self.send_error(404)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    conf = read_conf()
    bind = conf.get("COMPARE_BIND", "0.0.0.0")
    port = int(os.environ.get("COMPARE_PORT", conf.get("COMPARE_PORT", 80)))
    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    print(f"Parma Ham compare listening on http://{bind}:{port}/ ({len(read_hosts())} hosts in {HOSTS_FILE})",
          flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
