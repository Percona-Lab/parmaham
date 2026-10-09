"""OrioleDB metrics for the Parma Ham dashboard, built on the PostgreSQL
collector (postgresql/dashboard_collector.py has the metric mapping).

OrioleDB tables keep their pages in OrioleDB's own buffer pool, old row
versions in undo logs, and do their own I/O, so several PostgreSQL statistics
do not see them. Where OrioleDB has its own figure the collector uses it:

  dashboard metric     PostgreSQL                   OrioleDB
  -------------------  ---------------------------  ------------------------------------------
  buffer pool pages    pg_buffercache (shared)      orioledb_page_stats(), pool "main"
                                                    (orioledb.main_buffers)
  buffer hit ratio     blks_hit vs blks_read        not reported (None: no line)
  MVCC backlog         dead tuples (n_dead_tup)     undo log size in bytes, orioledb_undo_size()
                                                    (n_dead_tup only grows: no vacuum runs)
  rows read            tup_returned                 index lookups + rows read by sequential
                                                    scans (OrioleDB counts index scans, but
                                                    not the rows they fetch)
  data files r/w       pg_stat_io                   not counted (None)

Statements, transactions, rows written, connections, WAL and checkpoint
age are the PostgreSQL figures, which OrioleDB maintains.
"""

import glob
import importlib.util
import os

_spec = importlib.util.spec_from_file_location(
    "pmh_collector_postgresql_base",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "postgresql", "dashboard_collector.py"))
_pg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pg)

BENCH_DB = _pg.BENCH_DB
PROCESS = "postgres"
RATES = _pg.RATES
GAUGES = _pg.GAUGES
LABELS = dict(_pg.LABELS, **{
    "bp": "OrioleDB buffer pool",
    "bp_hit": "Hit ratio (not reported)",
    "rows_read": "Index lookups + rows scanned",
    "hll": "Undo log & lock waits",
    "hll_history": "Undo log size (bytes)",
    "history_short": "undo bytes",
    "data_written": "Data files written (not counted)",
})
# the OrioleDB figures that replace PostgreSQL's (see above)
ORIOLE_SQL = """
SELECT p.all_pages, p.dirty_pages, p.free_pages,
       (SELECT COALESCE(sum(undo_size), 0) FROM orioledb_undo_size()),
       (SELECT COALESCE(sum(idx_scan), 0) + COALESCE(sum(seq_tup_read), 0) FROM pg_stat_user_tables)
  FROM orioledb_page_stats() p WHERE p.pool_name = 'main'"""
# where orioledb/database-install.sh builds OrioleDB
STAMP_GLOB = "/opt/orioledb/*/PARMAHAM_ORIOLEDB_VERSION"


class Collector(_pg.Collector):
    name = "OrioleDB"
    psql_globs = [("/opt/orioledb/*/bin/psql", r"/orioledb/(\d+)/")] + _pg.PSQL_GLOBS

    def sample(self):
        s = super().sample()
        if "orioledb" in (self.features or {}).get("extensions", ()):
            row = self._query(ORIOLE_SQL)[0]
            total, dirty, free, undo, reads = (float(x) for x in row)
            s.update(db_bp_pages_total=total, db_bp_pages_dirty=dirty, db_bp_pages_free=free,
                     db_history_list_length=undo, db_rows_read=reads)
        # not reported for OrioleDB tables: no line rather than a misleading figure
        s.update(db_bp_read_requests=None, db_bp_disk_reads=None,
                 db_data_read_bytes=None, db_data_written_bytes=None)
        return s

    def info(self):
        info = super().info()
        release = None
        for path in sorted(glob.glob(STAMP_GLOB)):
            try:
                with open(path) as f:
                    release = f.read().strip()
            except OSError:
                pass
        try:
            ext = self._query("SELECT extversion FROM pg_extension WHERE extname = 'orioledb'")
            extversion = ext[0][0] if ext else None
        except _pg.subprocess.CalledProcessError:
            extversion = None
        parts = [p for p in (release and f"OrioleDB {release}", extversion and f"extension {extversion}",
                             info.get("version_comment")) if p]
        info["version_comment"] = " · ".join(parts)
        info["settings"].insert(0, ["Default table access method", self.setting("default_table_access_method"), None])
        main = self.setting("orioledb.main_buffers", unit=True)
        if main:
            info["settings"].insert(1, ["OrioleDB buffer pool", main, "bytes"])
        return info

    def setting(self, name, unit=False):
        try:
            rows = self._query(f"SELECT setting, COALESCE(unit, '') FROM pg_settings WHERE name = '{name}'")
        except _pg.subprocess.CalledProcessError:
            return None
        if not rows:
            return None
        value, u = rows[0]
        if unit and u in _pg.UNIT_BYTES:
            return int(float(value) * _pg.UNIT_BYTES[u])
        return value
