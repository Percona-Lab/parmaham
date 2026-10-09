"""pgrust metrics for the Parma Ham dashboard, built on the PostgreSQL
collector (postgresql/dashboard_collector.py has the metric mapping).

pgrust speaks PostgreSQL's protocol and SQL and provides its statistics
views and functions, plus ports of pg_stat_statements and pg_buffercache, so
the PostgreSQL mapping applies unchanged. It is one process with many threads.
"""

import importlib.util
import os

_spec = importlib.util.spec_from_file_location(
    "pmh_collector_postgresql_base",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "postgresql", "dashboard_collector.py"))
_pg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pg)

BENCH_DB = _pg.BENCH_DB
PROCESS = "pgrust"
RATES = _pg.RATES
GAUGES = _pg.GAUGES
LABELS = dict(_pg.LABELS, pmem_note="one process; PSS includes swapped-out share")


class Collector(_pg.Collector):
    name = "pgrust"

    def info(self):
        info = super().info()
        # version(): "PostgreSQL 18.6 (pgrust 0.3)"
        try:
            v = self._query("SELECT version()")[0][0]
            info["version_comment"] = v
        except (_pg.subprocess.CalledProcessError, IndexError):
            pass
        return info
