"""MariaDB metrics for the Parma Ham dashboard, built on the MySQL collector
(mysql/dashboard_collector.py describes the interface).

Differences from MySQL:
  * MariaDB has no Innodb_rows_* counters: row operations come from the
    server's Handler_* counters (read requests of every kind, writes, updates,
    deletes), which count the same row-level work at the storage engine API.
  * Checkpoint age and the undo history length are status variables.
  * The redo log is sized with innodb_log_file_size.
"""

import importlib.util
import os

_spec = importlib.util.spec_from_file_location(
    "pmh_collector_mysql_base",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mysql", "dashboard_collector.py"))
_mysql = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mysql)

BENCH_DB = _mysql.BENCH_DB
PROCESS = "mariadbd"

RATES = dict(_mysql.RATES)
RATES.update({
    "db_rows_read": ["Handler_read_first", "Handler_read_key", "Handler_read_last", "Handler_read_next",
                     "Handler_read_prev", "Handler_read_rnd", "Handler_read_rnd_next"],
    "db_rows_inserted": ["Handler_write"],
    "db_rows_updated": ["Handler_update"],
    "db_rows_deleted": ["Handler_delete"],
})
GAUGES = dict(_mysql.GAUGES, db_history_list_length="Innodb_history_list_length")

LABELS = {
    "rows": "Row operations (handler)",
    "rows_read": "Read requests",
}

SAMPLE_SQL = f"""
SHOW GLOBAL STATUS;
SELECT 'pmh_new_orders', COALESCE(SUM(d_next_o_id), 0) FROM `{BENCH_DB}`.district;
"""


class Collector(_mysql.Collector):
    name = "MariaDB"
    client = "mariadb"
    sample_sql = SAMPLE_SQL
    rates = RATES
    gauges = GAUGES

    def checkpoint_age(self, num):
        return num("Innodb_checkpoint_age")

    def settings(self, v):
        rows = super().settings(v)
        for r in rows:
            if r[0] == "Redo log capacity":
                r[1] = v.get("innodb_log_file_size")
        return rows

    def engine_name(self, v):
        return self.name
