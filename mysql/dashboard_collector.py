"""MySQL / Percona Server metrics for the Parma Ham dashboard.

Interface used by dashboard/parmaham_dashboard.py:
    Collector(cnf_path).info()    -> dict, static-ish facts (refreshed rarely)
    Collector(cnf_path).sample()  -> dict of counters/gauges for one sample
    RATES / GAUGES                -> which sample keys are per-second rates
"""

import subprocess

BENCH_DB = "tpcc"
# Server process name; its memory is reported by procmem.py
PROCESS = "mysqld"

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

SAMPLE_SQL = f"""
SHOW GLOBAL STATUS;
SELECT 'pmh_new_orders', COALESCE(SUM(d_next_o_id), 0) FROM `{BENCH_DB}`.district;
SELECT 'pmh_history_list_length', `count` FROM information_schema.innodb_metrics
 WHERE name = 'trx_rseg_history_len';
"""

INFO_VARS = [
    "version", "version_comment", "datadir", "innodb_buffer_pool_size",
    "innodb_redo_log_capacity", "innodb_flush_log_at_trx_commit",
    "innodb_flush_method", "innodb_io_capacity", "innodb_io_capacity_max",
    "max_connections", "log_bin", "transaction_isolation",
]


class Collector:
    name = "Percona Server for MySQL"

    def __init__(self, cnf_path):
        self.cnf_path = cnf_path

    def _query(self, sql, timeout=20):
        out = subprocess.run(
            ["mysql", f"--defaults-extra-file={self.cnf_path}", "-NB", "-e", sql],
            capture_output=True, text=True, timeout=timeout, check=True,
        ).stdout
        rows = []
        for line in out.splitlines():
            rows.append(line.split("\t"))
        return rows

    def sample(self):
        status = {}
        for row in self._query(SAMPLE_SQL):
            if len(row) == 2:
                status[row[0]] = row[1]

        def num(name):
            try:
                return float(status.get(name, 0))
            except ValueError:
                return 0.0

        s = {"db_up": 1, "db_uptime": num("Uptime")}
        for key, names in RATES.items():
            s[key] = sum(num(n) for n in names)
        for key, name in GAUGES.items():
            s[key] = num(name)
        cur, ckpt = num("Innodb_redo_log_current_lsn"), num("Innodb_redo_log_checkpoint_lsn")
        s["db_checkpoint_age_bytes"] = max(0.0, cur - ckpt) if cur else 0.0
        return s

    def info(self):
        info = {"engine": self.name}
        names = ",".join(f"'{v}'" for v in INFO_VARS)
        for name, value in self._query(
                f"SELECT variable_name, variable_value FROM performance_schema.global_variables "
                f"WHERE variable_name IN ({names})"):
            info[name] = value
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
