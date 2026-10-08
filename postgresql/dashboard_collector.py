"""PostgreSQL metrics for the Parma Ham dashboard
(mysql/dashboard_collector.py describes the interface).

PostgreSQL has no exact counterpart for some InnoDB metrics; the dashboard
shows the closest equivalent under PostgreSQL's own name (LABELS):

  dashboard metric        MySQL / InnoDB                PostgreSQL
  ----------------------  ----------------------------  -----------------------------------------
  queries/s               Questions                     pg_stat_statements calls (top-level
                                                        statements); commits if not installed
  transactions/s          Com_commit + Com_rollback     xact_commit + xact_rollback
  rows read               Innodb_rows_read              tup_returned (rows scanned / index entries)
  rows ins/upd/del        Innodb_rows_*                 tup_inserted / tup_updated / tup_deleted
  data read/written       Innodb_data_read/written      pg_stat_io read/write+extend bytes (relations)
  redo written            Innodb_os_log_written         WAL generated (LSN advance)
  checkpoint age          current - checkpoint LSN      current LSN - last checkpoint's redo LSN
  buffer pool hit ratio   read requests vs disk reads   blks_hit vs blks_read (shared buffers; a
                                                        "read" may still come from the OS cache)
  buffer pool pages       pages total/dirty/free        pg_buffercache_summary(): buffers
  threads running         Threads_running               client backends in state active
  threads connected       Threads_connected             client backends
  history list length     undo log not yet purged       dead tuples not yet vacuumed (n_dead_tup)
  row lock waits          Innodb_row_lock_waits (rate)  sessions waiting on a lock now (gauge)
"""

import glob
import os
import re
import subprocess

BENCH_DB = "tpcc"
# label of the procmem.py group with every postgres process of the service
PROCESS = "postgres"

RATES = {
    "db_qps": None, "db_tps": None,
    "db_rows_read": None, "db_rows_inserted": None, "db_rows_updated": None, "db_rows_deleted": None,
    "db_data_read_bytes": None, "db_data_written_bytes": None, "db_redo_written_bytes": None,
    "db_bp_read_requests": None, "db_bp_disk_reads": None, "db_new_orders": None,
}
GAUGES = {
    "db_threads_running": None, "db_threads_connected": None, "db_history_list_length": None,
    "db_bp_pages_dirty": None, "db_bp_pages_total": None, "db_bp_pages_free": None,
    "db_row_lock_waits": None,
}

LABELS = {
    "qps": "Transactions & statements",
    "qps_qps": "Statements/s",
    "rows": "Tuple operations",
    "rows_read": "Returned",
    "thr": "Connections",
    "thr_running": "Active",
    "bp": "Shared buffers",
    "bp_dirty": "Dirty buffers",
    "bp_free": "Unused buffers",
    "redo": "WAL",
    "redo_written": "WAL written/s",
    "redo_age": "WAL since checkpoint start",
    "hll": "Dead tuples & lock waits",
    "hll_history": "Dead tuples (not yet vacuumed)",
    "hll_locks": "Sessions waiting on locks",
    "history_short": "dead tuples",
    "pmem_note": "all postgres processes; PSS shares out shared buffers",
}

SETTINGS = [
    # pg_settings name, label
    ("shared_buffers", "Shared buffers"),
    ("effective_cache_size", "Effective cache size"),
    ("max_wal_size", "Max WAL size"),
    ("checkpoint_timeout", "Checkpoint timeout"),
    ("synchronous_commit", "Synchronous commit"),
    ("wal_level", "WAL level"),
    ("archive_mode", "WAL archiving"),
    ("random_page_cost", "Random page cost"),
    ("effective_io_concurrency", "IO concurrency"),
    ("io_method", "IO method"),
    ("autovacuum", "Autovacuum"),
    ("default_transaction_isolation", "Isolation"),
    ("max_connections", "Max connections"),
]
UNIT_BYTES = {"B": 1, "kB": 1024, "8kB": 8192, "MB": 1048576, "GB": 1073741824}


def find_psql():
    """The newest psql binary: Debian's /usr/bin/psql is a Perl wrapper that
    would otherwise start on every sample."""
    found = glob.glob("/usr/lib/postgresql/*/bin/psql") + glob.glob("/usr/pgsql-*/bin/psql")
    found.sort(key=lambda p: int(re.search(r"(\d+)", p.split("postgresql/")[-1].split("pgsql-")[-1]).group(1)))
    return found[-1] if found else "psql"


def read_cnf(path):
    conf = {}
    with open(path) as f:
        for line in f:
            key, sep, value = line.strip().partition("=")
            if sep:
                conf[key] = value
    return conf


class Collector:
    name = "PostgreSQL"

    def __init__(self, cnf_path):
        self.cnf_path = cnf_path
        self.features = None   # detected by info(): version, extensions
        self.client = find_psql()

    def _query(self, sql, db=BENCH_DB, timeout=20):
        cnf = read_cnf(self.cnf_path)
        env = dict(os.environ, PGPASSWORD=cnf.get("password", ""), PGCONNECT_TIMEOUT="10",
                   PGAPPNAME="parmaham-dashboard")
        out = subprocess.run(
            [self.client, "-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-h", cnf.get("host", "localhost"),
             "-p", cnf.get("port", "5432"), "-U", cnf.get("user", ""), "-d", db, "-c", sql],
            capture_output=True, text=True, timeout=timeout, check=True, env=env,
        ).stdout
        return [line.split("\t") for line in out.splitlines()]

    def detect(self):
        """Server version and the optional extensions in the benchmark database."""
        f = {"db": BENCH_DB}
        try:
            # district is readable once database-generate.sh granted access
            rows = self._query("SELECT current_setting('server_version_num'), "
                               "(SELECT string_agg(extname, ',') FROM pg_extension), "
                               "CASE WHEN to_regclass('public.district') IS NULL THEN false "
                               "ELSE has_table_privilege('public.district', 'SELECT') END")
        except subprocess.CalledProcessError:
            # no benchmark database yet
            f["db"] = "postgres"
            rows = self._query("SELECT current_setting('server_version_num'), '', false", db="postgres")
        f["version_num"] = int(rows[0][0])
        f["extensions"] = set((rows[0][1] or "").split(","))
        f["schema"] = rows[0][2] == "t"
        self.features = f
        return f

    def sample_sql(self):
        f = self.features or self.detect()
        v = f["version_num"]
        if v >= 180000:
            io = ("SELECT COALESCE(sum(read_bytes), 0), COALESCE(sum(write_bytes) + sum(extend_bytes), 0) "
                  "FROM pg_stat_io WHERE object IN ('relation', 'temp relation')")
        elif v >= 160000:
            io = ("SELECT COALESCE(sum(reads * op_bytes), 0), COALESCE(sum((writes + extends) * op_bytes), 0) "
                  "FROM pg_stat_io WHERE object IN ('relation', 'temp relation')")
        else:
            io = "SELECT sum(blks_read) * current_setting('block_size')::bigint, 0 FROM pg_stat_database"
        if "pg_buffercache" in f["extensions"] and v >= 160000:
            bufs = "SELECT buffers_used + buffers_unused, buffers_dirty, buffers_unused FROM pg_buffercache_summary()"
        else:
            bufs = "SELECT 0, 0, 0"
        if "pg_stat_statements" in f["extensions"]:
            stmts = "SELECT COALESCE(sum(calls), 0) FROM pg_stat_statements"
        else:
            stmts = "SELECT sum(xact_commit) FROM pg_stat_database"
        orders = "SELECT COALESCE(sum(d_next_o_id), 0) FROM district" if f["schema"] else "SELECT 0"
        dead = "SELECT COALESCE(sum(n_dead_tup), 0) FROM pg_stat_user_tables"
        return f"""
WITH d AS (SELECT sum(xact_commit + xact_rollback) AS xact, sum(tup_returned) AS ret,
                  sum(tup_inserted) AS ins, sum(tup_updated) AS upd, sum(tup_deleted) AS del,
                  sum(blks_hit) AS hit, sum(blks_read) AS rd FROM pg_stat_database),
     a AS (SELECT count(*) FILTER (WHERE state = 'active' AND pid <> pg_backend_pid()) AS active,
                  count(*) AS conn, count(*) FILTER (WHERE wait_event_type = 'Lock') AS lockw
             FROM pg_stat_activity WHERE backend_type = 'client backend'),
     io AS ({io}), b AS ({bufs}), w AS (
           SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') AS lsn,
                  pg_wal_lsn_diff(pg_current_wal_lsn(), (pg_control_checkpoint()).redo_lsn) AS age)
SELECT d.xact, ({stmts}), d.ret, d.ins, d.upd, d.del, io.*, w.lsn, w.age, d.hit + d.rd, d.rd,
       b.*, a.active, a.conn, ({dead}), a.lockw, ({orders}),
       extract(epoch FROM now() - pg_postmaster_start_time())
  FROM d, a, io, b, w"""

    def sample(self):
        try:
            row = self._query(self.sample_sql(), db=(self.features or {}).get("db", BENCH_DB))[0]
        except subprocess.CalledProcessError:
            self.features = None  # schema built or dropped since: detect again
            raise
        keys = ["db_tps", "db_qps", "db_rows_read", "db_rows_inserted", "db_rows_updated", "db_rows_deleted",
                "db_data_read_bytes", "db_data_written_bytes", "db_redo_written_bytes", "db_checkpoint_age_bytes",
                "db_bp_read_requests", "db_bp_disk_reads", "db_bp_pages_total", "db_bp_pages_dirty",
                "db_bp_pages_free", "db_threads_running", "db_threads_connected", "db_history_list_length",
                "db_row_lock_waits", "db_new_orders", "db_uptime"]
        s = {"db_up": 1}
        for k, val in zip(keys, row):
            try:
                s[k] = float(val)
            except ValueError:
                s[k] = 0.0
        return s

    def info(self):
        f = self.detect()
        names = ",".join(f"'{n}'" for n, _ in SETTINGS)
        rows = self._query(
            "SELECT name, setting, COALESCE(unit, '') FROM pg_settings "
            f"WHERE name IN ({names}, 'server_version', 'data_directory') "
            "UNION ALL SELECT 'version()', version(), ''", db=f["db"])
        v = {}
        for name, setting, unit in rows:
            if unit in UNIT_BYTES:
                v[name] = (int(float(setting) * UNIT_BYTES[unit]), "bytes")
            elif unit == "s" and int(setting) % 60 == 0:
                v[name] = (f"{int(setting) // 60} min", None)
            elif unit:
                v[name] = (f"{setting} {unit}", None)
            else:
                v[name] = (setting, None)
        # version(): "PostgreSQL 18.6 (...) on x86_64-pc-linux-gnu, compiled by ..."
        platform = v.get("version()", ("", None))[0].partition(" on ")[2].split(",")[0]
        info = {"engine": self.name, "version": v.get("server_version", ("", None))[0],
                "version_comment": platform,
                "datadir": v.get("data_directory", (None, None))[0]}
        info["settings"] = [[label, v[n][0], v[n][1]] for n, label in SETTINGS if n in v]
        ext = sorted(e for e in f["extensions"] if e and e != "plpgsql")
        if ext:
            info["settings"].append(["Extensions", ", ".join(ext), None])
        info["bench_db"] = BENCH_DB
        info["bench_db_size_bytes"] = 0
        info["warehouses"] = None
        info["last_purge"] = None
        if f["schema"]:
            info["bench_db_size_bytes"] = int(self._query(f"SELECT pg_database_size('{BENCH_DB}')")[0][0])
            try:
                info["warehouses"] = int(self._query("SELECT count(*) FROM warehouse")[0][0])
            except (subprocess.CalledProcessError, IndexError, ValueError):
                pass
            try:
                info["last_purge"] = self.last_purge()
            except subprocess.CalledProcessError:
                pass
        return info

    def last_purge(self):
        rows = self._query(
            "SELECT extract(epoch FROM started_at), extract(epoch FROM finished_at - started_at), "
            "retention_hours, orders_deleted, order_line_deleted, history_deleted, COALESCE(note, '') "
            "FROM parmaham_purge_log ORDER BY id DESC LIMIT 1")
        if not rows:
            return None
        r = rows[0]
        return {
            "started_at": float(r[0]),
            "duration_sec": float(r[1]) if r[1] else None,
            "retention_hours": int(r[2]),
            "orders_deleted": int(r[3]),
            "order_line_deleted": int(r[4]),
            "history_deleted": int(r[5]),
            "note": r[6],
        }
