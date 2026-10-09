"""OrioleDB metrics for the Parma Ham dashboard, built on the PostgreSQL
collector (postgresql/dashboard_collector.py has the metric mapping).

OrioleDB tables keep their pages in OrioleDB's own buffer pool and old row
versions in undo logs, so some PostgreSQL statistics cover only what is still
stored the PostgreSQL way (system catalogs): the shared buffer chart, and
dead tuples, which OrioleDB tables do not have. The labels say so.
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
    "bp": "Shared buffers (catalogs; tables use OrioleDB's pool)",
    "hll_history": "Dead tuples (heap tables only; OrioleDB uses undo)",
})
# where orioledb/database-install.sh builds OrioleDB
STAMP_GLOB = "/opt/orioledb/*/PARMAHAM_ORIOLEDB_VERSION"


class Collector(_pg.Collector):
    name = "OrioleDB"
    psql_globs = [("/opt/orioledb/*/bin/psql", r"/orioledb/(\d+)/")] + _pg.PSQL_GLOBS

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
