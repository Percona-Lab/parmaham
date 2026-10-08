"""MySQL (Percona Server, Oracle MySQL) metrics for the Parma Ham dashboard.
mariadb/dashboard_collector.py builds on this module.

Interface used by dashboard/parmaham_dashboard.py, the same for every database:
    Collector(cnf_path).info()    -> dict, static-ish facts (refreshed rarely):
                                     engine, version, version_comment, datadir,
                                     settings ([label, value, format] rows for the
                                     Environment table; format "bytes" or None),
                                     bench_db, bench_db_size_bytes, warehouses,
                                     last_purge
    Collector(cnf_path).sample()  -> dict of counters/gauges for one sample
    RATES / GAUGES                -> which sample keys are per-second rates and
                                     which are gauges
    PROCESS                       -> label of the server processes in procmem.py
    LABELS                        -> chart titles and series names, overriding
                                     the dashboard defaults (which are MySQL's)

Sample keys every database provides (the dashboard derives NOPM, TPM, hit
ratio and dirty share from them); a database without an exact equivalent
maps the closest metric and names it in LABELS:
    db_uptime, db_qps, db_tps, db_rows_read/inserted/updated/deleted,
    db_data_read_bytes, db_data_written_bytes, db_redo_written_bytes,
    db_checkpoint_age_bytes, db_bp_read_requests, db_bp_disk_reads,
    db_bp_pages_total/dirty/free, db_threads_running, db_threads_connected,
    db_history_list_length, db_row_lock_waits, db_new_orders
"""

import subprocess

BENCH_DB = "tpcc"
# Server process name; its memory is reported by procmem.py
PROCESS = "mysqld"
CLIENT = "mysql"

# Counters converted to per-second rates by the dashboard: key -> status vars summed
RATES = {
    "db_qps": ["Questions"],
    "db_tps": ["Com_commit", "Com_rollback"],
    "db_rows_read": ["Innodb_rows_read"],
    "db_rows_inserted": ["Innodb_rows_inserted"],
    "db_rows_updated": ["Innodb_rows_updated"],
    "db_rows_deleted": ["Innodb_rows_deleted"],
    "db_data_read_bytes": ["Innodb_data_read"],
    "db_data_written_bytes": ["Innodb_data_written"],
    "db_redo_written_bytes": ["Innodb_os_log_written"],
    "db_bp_read_requests": ["Innodb_buffer_pool_read_requests"],
    "db_bp_disk_reads": ["Innodb_buffer_pool_reads"],
    "db_row_lock_waits": ["Innodb_row_lock_waits"],
    "db_new_orders": ["pmh_new_orders"],
}

GAUGES = {
    "db_threads_running": "Threads_running",
    "db_threads_connected": "Threads_connected",
    "db_history_list_length": "pmh_history_list_length",
    "db_bp_pages_dirty": "Innodb_buffer_pool_pages_dirty",
    "db_bp_pages_total": "Innodb_buffer_pool_pages_total",
    "db_bp_pages_free": "Innodb_buffer_pool_pages_free",
}

# the dashboard's defaults are MySQL's names
LABELS = {}

SAMPLE_SQL = f"""
SHOW GLOBAL STATUS;
SELECT 'pmh_new_orders', COALESCE(SUM(d_next_o_id), 0) FROM `{BENCH_DB}`.district;
SELECT 'pmh_history_list_length', `count` FROM information_schema.innodb_metrics
 WHERE name = 'trx_rseg_history_len';
"""

INFO_VARS = [
    "version", "version_comment", "datadir", "innodb_buffer_pool_size",
    "innodb_redo_log_capacity", "innodb_log_file_size", "innodb_flush_log_at_trx_commit",
    "innodb_flush_method", "innodb_io_capacity", "innodb_io_capacity_max",
    "max_connections", "log_bin", "transaction_isolation",
]


class Collector:
    name = "MySQL"
    client = CLIENT
    sample_sql = SAMPLE_SQL
    info_vars = INFO_VARS
    rates = RATES
    gauges = GAUGES

    def __init__(self, cnf_path):
        self.cnf_path = cnf_path

    def _query(self, sql, timeout=20):
        out = subprocess.run(
            [self.client, f"--defaults-extra-file={self.cnf_path}", "-NB", "-e", sql],
            capture_output=True, text=True, timeout=timeout, check=True,
        ).stdout
        rows = []
        for line in out.splitlines():
            rows.append(line.split("\t"))
        return rows

    def status(self):
        status = {}
        for row in self._query(self.sample_sql):
            if len(row) == 2:
                status[row[0]] = row[1]
        return status

    def sample(self):
        status = self.status()

        def num(name):
            try:
                return float(status.get(name, 0))
            except ValueError:
                return 0.0

        s = {"db_up": 1, "db_uptime": num("Uptime")}
        for key, names in self.rates.items():
            s[key] = sum(num(n) for n in names)
        for key, name in self.gauges.items():
            s[key] = num(name)
        s["db_checkpoint_age_bytes"] = self.checkpoint_age(num)
        return s

    def checkpoint_age(self, num):
        cur, ckpt = num("Innodb_redo_log_current_lsn"), num("Innodb_redo_log_checkpoint_lsn")
        return max(0.0, cur - ckpt) if cur else 0.0

    def variables(self):
        names = ",".join(f"'{v}'" for v in self.info_vars)
        return {name.lower(): value for name, value in self._query(
            f"SHOW GLOBAL VARIABLES WHERE Variable_name IN ({names})")}

    def settings(self, v):
        """[label, value, format] rows for the dashboard's Environment table."""
        return [
            ["Buffer pool", v.get("innodb_buffer_pool_size"), "bytes"],
            ["Redo log capacity", v.get("innodb_redo_log_capacity"), "bytes"],
            ["Flush log at commit", v.get("innodb_flush_log_at_trx_commit"), None],
            ["Flush method", v.get("innodb_flush_method"), None],
            ["IO capacity", f"{v.get('innodb_io_capacity')} / max {v.get('innodb_io_capacity_max')}", None],
            ["Binary log", v.get("log_bin"), None],
            ["Isolation", v.get("transaction_isolation"), None],
            ["Max connections", v.get("max_connections"), None],
        ]

    def info(self):
        v = self.variables()
        info = {"engine": self.engine_name(v), "version": v.get("version"),
                "version_comment": v.get("version_comment"), "datadir": v.get("datadir")}
        info["settings"] = [r for r in self.settings(v) if r[1] not in (None, "")]
        rows = self._query(
            "SELECT COALESCE(ROUND(SUM(data_length + index_length)), 0), COUNT(*) "
            f"FROM information_schema.tables WHERE table_schema = '{BENCH_DB}'", timeout=120)
        info["bench_db"] = BENCH_DB
        info["bench_db_size_bytes"] = int(rows[0][0]) if rows else 0
        try:
            info["warehouses"] = int(self._query(f"SELECT COUNT(*) FROM `{BENCH_DB}`.warehouse")[0][0])
        except (subprocess.CalledProcessError, IndexError, ValueError):
            info["warehouses"] = None
        try:
            info["last_purge"] = self.last_purge()
        except subprocess.CalledProcessError:
            info["last_purge"] = None
        return info

    def last_purge(self):
        rows = self._query(
            "SELECT UNIX_TIMESTAMP(started_at), "
            "TIMESTAMPDIFF(MICROSECOND, started_at, finished_at) / 1e6, retention_hours, "
            "COALESCE(orders_deleted, 0), COALESCE(order_line_deleted, 0), "
            "COALESCE(history_deleted, 0), COALESCE(note, '') "
            f"FROM `{BENCH_DB}`.parmaham_purge_log ORDER BY id DESC LIMIT 1")
        if not rows:
            return None
        r = rows[0]
        return {
            "started_at": float(r[0]),
            "duration_sec": None if r[1] == "NULL" else float(r[1]),
            "retention_hours": int(r[2]),
            "orders_deleted": int(r[3]),
            "order_line_deleted": int(r[4]),
            "history_deleted": int(r[5]),
            "note": r[6],
        }

    def engine_name(self, v):
        comment = (v.get("version_comment") or "").lower()
        if "percona" in comment:
            return "Percona Server for MySQL"
        return "MySQL Community Server" if "community" in comment else self.name
