"""seekdb metrics for the Parma Ham dashboard (mysql/dashboard_collector.py
describes the interface; this module reuses its query and purge code).

seekdb (OceanBase) keeps almost nothing in SHOW GLOBAL STATUS and has no
system statistics table (OceanBase's sysstat views are removed), so the
figures come from its own views. Where there is no equivalent the value is
None and the dashboard draws no line:

  dashboard metric      MySQL                       seekdb
  --------------------  --------------------------  -----------------------------------------------
  queries/s             Questions                   plan cache accesses (__all_virtual_plan_cache_stat):
                                                    every statement, including those inside procedures
  transactions/s        Com_commit + Com_rollback   procedure executions in the plan cache
                                                    (V$OB_PLAN_CACHE_PLAN_STAT, OBJECT_TYPE
                                                    PROCEDURE; each HammerDB transaction is one
                                                    procedure call)
  rows read             Innodb_rows_read            not reported (seekdb counts no rows processed
                                                    or buffer gets for statements in procedures)
  rows ins/upd/del      Innodb_rows_*               V$DML_STATS
  redo written          Innodb_os_log_written       redo log end LSN (V$OB_LOG_STAT), bytes
  checkpoint age        current - checkpoint LSN    log disk in use (V$OB_SERVER_STAT)
  buffer pool pages     pages total/dirty/free      memstore (OceanBase's in-memory write buffer):
                                                    used vs its automatic limit, half the memory
                                                    limit on small nodes
  buffer hit ratio      read requests / disk reads  not reported (the KV cache counts no misses)
  history list length   undo not yet purged         memstore used, bytes (row versions not yet
                                                    frozen and compacted)
  row lock waits        Innodb_row_lock_waits       sessions waiting on a row lock now
                                                    (__all_virtual_lock_wait_stat), a gauge
  threads               Threads_running/connected   V$OB_SESSION, active / all
  data read/written     Innodb_data_*               not reported
"""

import importlib.util
import os
import subprocess
import time

_spec = importlib.util.spec_from_file_location(
    "pmh_collector_mysql_base",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mysql", "dashboard_collector.py"))
_mysql = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mysql)

BENCH_DB = _mysql.BENCH_DB
PROCESS = "seekdb"
# seekdb's base directory (database-install.sh): data and redo
DATADIR = "/var/lib/seekdb"

RATES = {k: None for k in ("db_qps", "db_tps", "db_rows_read", "db_rows_inserted", "db_rows_updated",
                           "db_rows_deleted", "db_data_read_bytes", "db_data_written_bytes",
                           "db_redo_written_bytes", "db_bp_read_requests", "db_bp_disk_reads", "db_new_orders")}
GAUGES = {k: None for k in ("db_threads_running", "db_threads_connected", "db_history_list_length",
                            "db_bp_pages_dirty", "db_bp_pages_total", "db_bp_pages_free", "db_row_lock_waits")}

LABELS = {
    "qps": "Transactions & statements",
    "qps_tps": "Procedure calls/s",
    "qps_qps": "Statements/s (incl. in procedures)",
    "rows": "Row operations",
    "rows_read": "Read (not reported)",
    "thr": "Sessions",
    "thr_running": "Active",
    "bp": "Memstore (write buffer)",
    "bp_hit": "Hit ratio (not reported)",
    "bp_dirty": "Used (% of limit)",
    "bp_free": "Free (% of limit)",
    "redo": "Redo log",
    "redo_age": "Log disk in use",
    "hll": "Memstore & lock waits",
    "hll_history": "Memstore used (bytes)",
    "hll_locks": "Sessions waiting on row locks",
    "history_short": "memstore bytes",
    "data_written": "Data files written (not reported)",
}

SAMPLE_SQL = f"""
SELECT 'stmts', COALESCE(SUM(access_count), 0) FROM oceanbase.__all_virtual_plan_cache_stat;
SELECT 'calls', COALESCE(SUM(executions), 0) FROM oceanbase.V$OB_PLAN_CACHE_PLAN_STAT
 WHERE object_type = 'PROCEDURE';
SELECT 'ins', COALESCE(SUM(ins), 0) FROM oceanbase.V$DML_STATS;
SELECT 'upd', COALESCE(SUM(upd), 0) FROM oceanbase.V$DML_STATS;
SELECT 'del', COALESCE(SUM(del), 0) FROM oceanbase.V$DML_STATS;
SELECT 'redo', COALESCE(SUM(end_lsn), 0) FROM oceanbase.V$OB_LOG_STAT;
SELECT 'log_disk', log_disk_in_use FROM oceanbase.V$OB_SERVER_STAT;
SELECT 'memory_limit', memory_limit FROM oceanbase.V$OB_SERVER_STAT;
SELECT 'start_us', start_service_time FROM oceanbase.V$OB_SERVER_STAT;
SELECT 'memstore', COALESCE(SUM(mem_used), 0) FROM oceanbase.__all_virtual_tablet_memstore_info;
SELECT 'sessions', COUNT(*) FROM oceanbase.V$OB_SESSION;
SELECT 'active', COALESCE(SUM(state = 'ACTIVE'), 0) - 1 FROM oceanbase.V$OB_SESSION;
SELECT 'lock_waits', COUNT(*) FROM oceanbase.__all_virtual_lock_wait_stat;
SELECT 'new_orders', COALESCE(SUM(d_next_o_id), 0) FROM `{BENCH_DB}`.district;
"""

PARAMS = ["cpu_count", "freeze_trigger_percentage", "_memstore_limit_percentage", "log_disk_size",
          "datafile_size", "enable_major_freeze", "major_freeze_duty_time"]


class Collector(_mysql.Collector):
    name = "seekdb"
    client = "mysql"

    def status(self):
        out = {}
        for row in self._query(SAMPLE_SQL):
            if len(row) == 2:
                out[row[0]] = row[1]
        return out

    def sample(self):
        st = self.status()

        def num(name):
            try:
                return float(st.get(name))
            except (TypeError, ValueError):
                return None

        memory_limit, memstore = num("memory_limit"), num("memstore")
        # automatic memstore limit (_memstore_limit_percentage = 0): half of
        # the memory limit on nodes with up to 8 GB
        limit = memory_limit / 2 if memory_limit else None
        start = num("start_us")
        s = {
            "db_up": 1,
            "db_uptime": time.time() - start / 1e6 if start else 0,
            "db_qps": num("stmts"), "db_tps": num("calls"),
            "db_rows_read": None,
            "db_rows_inserted": num("ins"), "db_rows_updated": num("upd"), "db_rows_deleted": num("del"),
            "db_redo_written_bytes": num("redo"), "db_checkpoint_age_bytes": num("log_disk") or 0,
            "db_data_read_bytes": None, "db_data_written_bytes": None,
            "db_bp_read_requests": None, "db_bp_disk_reads": None,
            "db_bp_pages_total": limit, "db_bp_pages_dirty": memstore,
            "db_bp_pages_free": max(0.0, limit - memstore) if limit and memstore is not None else None,
            "db_history_list_length": memstore,
            "db_threads_connected": num("sessions"), "db_threads_running": max(0.0, num("active") or 0),
            "db_row_lock_waits": num("lock_waits"),
            "db_new_orders": num("new_orders") or 0,
        }
        return s

    def info(self):
        v = self.variables()
        info = {"engine": self.name, "version": v.get("version"), "version_comment": v.get("version_comment"),
                "datadir": DATADIR}
        names = ",".join(f"'{p}'" for p in PARAMS)
        params = dict(self._query(f"SELECT name, value FROM oceanbase.V$OB_PARAMETERS WHERE name IN ({names})"))
        srv = self._query("SELECT memory_limit, log_disk_capacity, data_disk_capacity, data_disk_in_use "
                          "FROM oceanbase.V$OB_SERVER_STAT")
        mem, log_cap, data_cap, data_used = (srv[0] + [None] * 4)[:4] if srv else (None,) * 4
        pct = params.get("_memstore_limit_percentage")
        info["settings"] = [r for r in [
            ["Memory limit", mem, "bytes"],
            ["Memstore limit", (f"{pct}% of memory" if pct not in (None, "0") else "automatic (half the memory limit)"), None],
            ["Freeze trigger", f"{params.get('freeze_trigger_percentage')}% of the memstore limit"
             if params.get("freeze_trigger_percentage") else None, None],
            ["CPUs", params.get("cpu_count"), None],
            ["Log disk", log_cap, "bytes"],
            ["Data disk", data_cap, "bytes"],
            ["Major compaction", f"daily at {params.get('major_freeze_duty_time')}"
             if params.get("enable_major_freeze") == "True" else "off", None],
            ["Isolation", v.get("transaction_isolation"), None],
        ] if r[1] not in (None, "")]
        info["bench_db"] = BENCH_DB
        info["bench_db_size_bytes"] = int(data_used) if data_used and data_used.isdigit() else 0
        try:
            info["warehouses"] = int(self._query(f"SELECT COUNT(*) FROM `{BENCH_DB}`.warehouse")[0][0])
        except (subprocess.CalledProcessError, IndexError, ValueError):
            info["warehouses"] = None
        try:
            info["last_purge"] = self.last_purge()
        except subprocess.CalledProcessError:
            info["last_purge"] = None
        return info
