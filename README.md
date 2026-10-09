# Parma Ham — Permanent HammerDB Benchmark Runner

Parma Ham runs [HammerDB](https://www.hammerdb.com/) TPROC-C continuously, for
days, weeks or months, at a controlled share of what the machine can do. Use it
for demos, and to see how an environment behaves over a long period: whether
performance drifts, stalls or degrades over time.

Every node gets a public dashboard, and a separate compare page shows any two
nodes side by side, for example the same workload on MariaDB and on
PostgreSQL. See [CHANGELOG.md](CHANGELOG.md) for what changed recently.

Supported databases, one per node, each in its own directory:

| Directory | Database | Default version |
|-----------|----------|-----------------|
| `mysql/` | **Percona Server for MySQL** (default) or **Oracle MySQL Community Server** (`--flavor community`) | Percona Server 9.7 LTS; MySQL 9.7 LTS or the newest Innovation release (`--repo mysql-innovation`, 26.7) |
| `mariadb/` | **MariaDB Server** (MariaDB Foundation repository) | 13.0 (`--version 12.3` or `11.8` for an LTS release) |
| `postgresql/` | **PostgreSQL** (PostgreSQL community repository, PGDG) | 18 |
| `orioledb/` | **OrioleDB** (PostgreSQL with OrioleDB's patches and storage engine, built from source) | beta19 on PostgreSQL 18 |
| `pgrust/` | **pgrust** (PostgreSQL rewritten in Rust; experimental, not production ready) | 0.3 |

```
parmaham/
├── common/                        everything that works the same for every database
│   ├── lib.sh                     shared shell helpers (config, HammerDB install/run, status)
│   ├── database-generate.sh       build the TPROC-C schema (default 200 warehouses)
│   ├── compute-capacity.sh        measure sustainable throughput (64 VU, 15 + 30 min)
│   ├── install-workload.sh        permanent workload service at N% of capacity
│   ├── install-hammerdb-purge.sh  timer that deletes benchmark data older than 24h
│   ├── workload-loop.sh, purge.sh the workload and purge services
│   └── hdb-*.tcl                  HammerDB build and run scripts
├── config/                        defaults + example /etc/parmaham/parmaham.conf
├── dashboard/                     public web dashboard (Python standard library only);
│                                  static/chart.js and style.css are shared with compare/
├── compare/                       side-by-side comparison of two Parma Ham hosts
├── mysql/  mariadb/  postgresql/  one directory per database
├── orioledb/  pgrust/             (orioledb/ and pgrust/ build on postgresql/lib):
│   ├── database-install.sh        install + tune the database server for this node
│   ├── database-generate.sh ...   links to the common scripts
│   ├── dashboard_collector.py     database metrics for the dashboard
│   └── lib/                       plug-in (db.sh), HammerDB settings (hdb-db.tcl), purge SQL
```

## Quick start

On a fresh Ubuntu 22.04/24.04, Debian 12 or RHEL/Rocky/Alma 9 machine (x86_64),
as root. Pick the database directory, here `mysql/`:

```bash
git clone https://github.com/Percona-Lab/parmaham.git
cd parmaham

DB=mysql                                   # or mariadb, postgresql, orioledb, pgrust
$DB/database-install.sh                    # install the server, tuned to this node
$DB/database-generate.sh                   # 200 warehouses
$DB/compute-capacity.sh --background       # ~46 minutes: journalctl -fu parmaham-capacity
$DB/install-workload.sh                    # run at 50% of capacity, forever
$DB/install-hammerdb-purge.sh              # keep only the last 24h of new data
dashboard/install-dashboard.sh             # http://<host>/
```

To compare nodes, run the compare page on any machine that can reach their
dashboards (a 1 GB VM is enough):

```bash
compare/install-compare.sh --add http://<node-1>/ --name "MariaDB"
compare/install-compare.sh --add http://<node-2>/ --name "PostgreSQL"      # http://<this-host>/
```

Each step prints the next one. Every script supports `--help`. Only the
install script differs per database; the other four are the same scripts
(`common/`) run for the database of the directory they are started from.
`database-install.sh` records the database in `/etc/parmaham/parmaham.conf`
(`PMH_DB`), and the scripts refuse to run for a different database on the
same node.

> Put the database on the storage you want to test *before* running
> `database-install.sh`: mount it at the data directory (`/var/lib/mysql`,
> or `/var/lib/postgresql` for PostgreSQL).

## What each step does

### `mysql/database-install.sh [--flavor percona|community] [--repo REPO]`

* Percona Server (default): adds the Percona repository with
  `percona-release enable-only ps-97-lts` (configurable with `--repo`) and
  installs `percona-server-server`.
* `--flavor community`: adds Oracle's repository from repo.mysql.com for one
  release series, `mysql-9.7-lts` by default or `--repo mysql-innovation` for
  the newest Innovation release (26.7 at the time of writing), and installs
  `mysql-community-server`.
* Generates a random root password and stores it in `/etc/parmaham/mysql-admin.cnf`,
  which is also linked from `/root/.my.cnf`.
* Writes `zz-parmaham.cnf` with settings sized for the node:
  * buffer pool: 60% of RAM (`--buffer-pool-pct`), leaving room for HammerDB on the same host
  * redo log capacity: ¼ of the buffer pool, between 1 and 32 GB
  * I/O capacity: chosen from the data disk type (NVMe, SSD or HDD)
  * I/O threads: chosen from the CPU count
  * NUMA interleave: on when the node has more than one NUMA node
* Durable by default (`innodb_flush_log_at_trx_commit=1`). The binary log is
  **off** by default so a run lasting months cannot fill the disk; enable it
  with `--binlog 1`, which sets a 6h expiry.
* Sets `vm.swappiness=1` and disables transparent huge pages.
* Creates two MySQL accounts:
  * `hammerdb`: owns the `tpcc` schema.
  * `parmaham_mon`: read-only statistics account for the dashboard.

Re-running the script keeps the installation and only regenerates the tuning.

### `mariadb/database-install.sh [--version 13.0]`

* Adds the MariaDB Foundation repository for the release series
  (`mariadb_repo_setup`) and installs `mariadb-server`.
* `root@localhost` keeps unix socket authentication and also gets a random
  password, stored in `/etc/parmaham/mariadb-admin.cnf` (linked from `/root/.my.cnf`).
* The same sizing and options as MySQL (`--buffer-pool-pct`, `--binlog`,
  `--flush-log-at-trx-commit`), with MariaDB's names: the redo log is sized
  with `innodb_log_file_size`, and `innodb_flush_method` (deprecated, data
  files use O_DIRECT already) and `innodb_numa_interleave` are not set.
* The same `hammerdb` and `parmaham_mon` accounts.

### `postgresql/database-install.sh [--version 18] [--shared-buffers-pct 25] [--synchronous-commit on|off]`

* Adds the PostgreSQL community repository (PGDG) and installs
  `postgresql-18` (RHEL: `postgresql18-server` and `-contrib`, plus `initdb`).
* Sets a random password for the `postgres` superuser, stored in
  `/etc/parmaham/postgresql-admin.cnf`: HammerDB uses it to create the
  benchmark user and database.
* Writes `conf.d/zz-parmaham.conf` (RHEL: included from `postgresql.conf`):
  * `shared_buffers`: 25% of RAM (`--shared-buffers-pct`); PostgreSQL also
    relies on the page cache, and HammerDB runs on the same node
  * `max_wal_size`: twice `shared_buffers`, between 2 and 64 GB, with 15-minute
    checkpoints spread over 90% of the interval (the counterpart of the redo log capacity)
  * `random_page_cost` and `effective_io_concurrency` chosen from the disk type
  * `max_connections = 300`, `autovacuum_vacuum_cost_limit = 2000` so
    autovacuum keeps up for months, `track_io_timing`, and `pg_stat_statements`
    (statement counts for the dashboard)
* Durable by default (`synchronous_commit = on`); WAL archiving stays off.
* The same OS settings as MySQL, and two roles: `hammerdb` (owns the `tpcc`
  database) and `parmaham_mon` (member of `pg_monitor`, read-only).

### `orioledb/database-install.sh [--version beta19] [--pg-major 18]`

* Builds PostgreSQL with OrioleDB's patches (the patch set the release pins in
  `.pgtags`, `patches18_3` for beta19) and the `orioledb` extension from source
  into `/opt/orioledb/<major>`, without debug options. About 5 minutes on 2 vCPUs;
  the log is `/var/log/parmaham/orioledb-build.log`. Debian and Ubuntu only.
* Creates the cluster in `/var/lib/orioledb/<major>/data` with the C locale
  (OrioleDB tables need ICU, C, POSIX or builtin collations) and runs it as
  `orioledb.service`.
* Every table HammerDB creates is an OrioleDB table:
  `default_table_access_method = 'orioledb'`, with the extension created in
  `template1`.
* The same tuning as PostgreSQL, except that the memory PostgreSQL would give
  `shared_buffers` goes to OrioleDB's own buffer pool (`orioledb.main_buffers`,
  25% of RAM); `shared_buffers` keeps 256 MB for the system catalogs.
* HammerDB's PostgreSQL driver loads the build's `libpq`.

### `pgrust/database-install.sh [--version 0.3]`

* [pgrust](https://github.com/malisper/pgrust) is a rewrite of PostgreSQL 18
  in Rust: one process with threads, wire and SQL compatible, with its own
  ports of contrib modules such as `pg_stat_statements` and `pg_buffercache`.
  Its authors say it is not ready for production, and its JIT and published
  performance numbers target AWS Graviton4, so x86 results are not comparable
  with theirs.
* Downloads the release binary from pgrust.com (checksum verified) into
  `/opt/pgrust`. pgrust has no `initdb` or `psql` of its own: PostgreSQL 18's
  client tools, `initdb` and share files come from PGDG, without a PostgreSQL
  cluster.
* Creates the cluster in `/var/lib/pgrust/data` and runs it as `pgrust.service`,
  with the same tuning as PostgreSQL plus the settings pgrust's quick start asks
  for (`io_method = sync`, a 64 MB stack).
* Debian and Ubuntu only.

### `database-generate.sh [--warehouses 200] [--vu N] [--partition true] [--force]`

* Downloads HammerDB 6.0 into `/opt/parmaham/hammerdb` and builds the schema
  with HammerDB's driver for the database (`mysql`, `maria` or `pg`).
* MySQL: HammerDB's MySQL driver needs Oracle's `libmysqlclient.so.24`;
  Percona's client library is not symbol-compatible. The script therefore takes
  that one library from the MySQL 8.4 minimal tarball and keeps it private to
  HammerDB. MariaDB and PostgreSQL use the client libraries installed with the server.
* MySQL and MariaDB: builds `history` with HammerDB's invisible primary key
  option and widens it to `BIGINT`. A permanent run would otherwise exhaust
  `INT`, and the purge job needs the key.
* PostgreSQL, OrioleDB and pgrust: build with stored procedures
  (`pg_storedprocs`, HammerDB's recommendation for PostgreSQL 11 and later)
  and add a `BIGINT` identity primary key to `history`, which HammerDB creates
  without a key.

### `compute-capacity.sh [--vu 64] [--rampup 15] [--duration 30] [--background]`

* Runs HammerDB unthrottled and saves the result (NOPM, TPM, virtual users) to
  `/var/lib/parmaham/capacity.json`.
* If the workload service is running, the script stops it for the measurement
  and starts it again afterwards; the workload then uses the new capacity.
* `--background` runs the measurement as the systemd unit `parmaham-capacity`,
  so it survives a closed SSH session.

### `install-workload.sh [--percent 50 | --nopm N] [--vu N] [--rampup 1] [--duration 60] [--sleep 0]`

Installs `parmaham-workload.service` (`Restart=always`), which loops forever:

1. warm up for `--rampup` minutes
2. measure for `--duration` minutes and record the result
3. sleep `--sleep` seconds
4. repeat

The configuration is re-read at the start of each iteration. `--stop` stops the
service and `--uninstall` removes it.

**How the load level is held.** HammerDB has no throughput limit, and changing
the number of virtual users does not scale load linearly. Parma Ham instead
injects *pacing* into HammerDB's standard timed driver:

* Each virtual user starts one transaction every *P* milliseconds, where *P* is
  calculated from the target NOPM. New-order is 10 of every 23 transactions in
  the HammerDB mix.
* The schedule is self-correcting. A stall can be caught up by at most 10
  intervals, so it never turns into a burst.
* After each run the pacing is adjusted by the ratio of achieved to target
  throughput (bounded to ±25%), so the long-term average converges on the target.

The transaction mix, schema and result calculation remain standard HammerDB.
`--percent 100` runs unthrottled.

**Fixed target.** `--nopm N` runs at N new orders per minute instead of a
share of the measured capacity, for example to compare nodes at the same
absolute load. It needs no capacity measurement (the virtual users then
default to `CAPACITY_VU`); with one, the dashboard also shows the target as a
share of it, and the script warns when the target is above it. `--percent`
switches back. Options are checked before they are saved, so a rejected
change never reaches the running workload.

### `install-hammerdb-purge.sh [--retention-hours 24] [--interval-min 15] [--run-now]`

HammerDB inserts into `orders`, `order_line` and `history` forever. The purge
job installs stored procedures plus `parmaham-purge.timer`, which deletes data
older than the retention period. It avoids table scans:

* Every run records a watermark: each district's `d_next_o_id` and the current
  maximum `history` id.
* Deletes then use primary-key ranges below the newest watermark that is older
  than the retention period. They are batched per district and run in small
  `READ COMMITTED` transactions next to the running workload.
* The 3,000 orders per district created by the initial load are kept, so the
  data stays consistent with a fresh load.
* Orders that have not been delivered yet are never deleted.
* Purge history is stored in `tpcc.parmaham_purge_log` and shown on the dashboard.
* MySQL and MariaDB use the same stored procedures (`mysql/lib/purge.sql`);
  PostgreSQL, OrioleDB and pgrust use a PL/pgSQL port (`postgresql/lib/purge.sql`)
  whose procedures commit after every batch. Autovacuum reclaims the deleted
  rows (OrioleDB tables reuse space through their undo log instead).

Because watermarks start at installation, the first rows are deleted one
retention period after the purge is installed.

### `dashboard/install-dashboard.sh [--port 80] [--bind 0.0.0.0]`

Runs a public dashboard with no login, by design. It shows:

* **Benchmark:** state, progress of the current iteration, target and capacity,
  live NOPM/TPM against the target, the result of every run, and recent runs.
* **Database:** transactions and queries, row operations, threads, buffer
  pool, redo log and checkpoint age, undo history length, lock waits, and
  space on the volume that holds the data directory. The charts are the same
  for every database; where a database has no exact equivalent the closest
  metric is shown under the database's own name (see below).
* **Last HammerDB execution:** a summary of the last completed run, with a
  **View log** link to its HammerDB log. The run-progress bar at the top has a
  **Live log** link that follows the log of the run in progress.
  * The summary covers the result and % of target, test period, virtual users
    finished/failed, pacing, versions and error lines.
  * It can also show response times per transaction type (calls, average,
    P25, P50, P75, P95, P99 and max) from HammerDB's time profiler. This is off
    by default: HammerDB 6.0 keeps every sample in memory for the whole run
    (about 300 bytes per transaction, roughly 450 MB per hour at 10k NOPM).
    Enable it with `HAMMERDB_TIMEPROFILE=true` in `/etc/parmaham/parmaham.conf`
    on nodes with enough free memory.
  * It includes HammerDB's standard job report: the result lines, database
    version, job ID, the run's HammerDB settings, and a TPM-over-time chart from
    HammerDB's transaction counter (sampled every 10 s). With profiling on, it
    also includes the profiler's own text summary from `hdbxtprofile.log`.
  * Clicking any run in **Recent runs** shows the same summary and the tail of
    that run's log.
* **Processes:** CPU in use (cores) for the database server (`mysqld`,
  `mariadbd`, or every `postgres` process of the service) and HammerDB, plus memory
  (VSZ, RSS, PSS + SwapPSS) for each. Values that cannot all be resident are
  named but not plotted, so they do not flatten the chart: VSZ far above RAM
  plus swap (MariaDB reserves address space for `innodb_buffer_pool_size_max`)
  and RSS above RAM (PostgreSQL's RSS summed over its processes counts shared
  buffers once per process; PSS shares them out correctly). HammerDB covers every process in the
  workload and capacity services (`hammerdbcli` with one thread per virtual
  user, plus the loop script and log filter) and any `hammerdbcli` started by
  hand.
* **Operating system:** pressure stall information (CPU, memory and IO
  `some`/`full`), CPU breakdown, CPU steal on its own chart (the share of CPU
  time the hypervisor gave to other guests, and how many vCPUs that amounts to:
  steady steal means the node does not get all its vCPUs), load and run queue, memory and
  swap usage, swap-in/swap-out rate, disk IOPS, throughput and utilization, network, context switches and
  major faults.
* **Environment:** hardware (CPU model and topology, NUMA, memory, disks, NICs,
  virtualization and system vendor), OS and kernel, and the database
  configuration and data directory filesystem.

Database metrics per database:

| Chart | MySQL | MariaDB | PostgreSQL |
|-------|-------|---------|------------|
| Transactions & queries | `Com_commit` + `Com_rollback`, `Questions` | same | `xact_commit` + `xact_rollback`; statements from `pg_stat_statements` |
| Row operations | `Innodb_rows_*` | `Handler_*` (MariaDB has no `Innodb_rows_*`): read requests, writes, updates, deletes | `tup_returned`, `tup_inserted`, `tup_updated`, `tup_deleted` |
| Threads | `Threads_running`, `Threads_connected` | same | client backends active / connected |
| Buffer pool | hit ratio, dirty and free pages | same | shared buffers: `blks_hit` vs `blks_read` hit ratio, dirty and unused buffers (`pg_buffercache_summary()`) |
| Redo log | `Innodb_os_log_written`, LSN − checkpoint LSN | `Innodb_os_log_written`, `Innodb_checkpoint_age` | WAL written (LSN advance), WAL since the last checkpoint's redo point |
| Undo history & lock waits | history list length, row lock waits/s | same | dead tuples not yet vacuumed (`n_dead_tup`), sessions waiting on a lock |

OrioleDB and pgrust use the PostgreSQL mapping. On OrioleDB, the shared
buffer and dead tuple charts cover only what is still stored the PostgreSQL
way (system catalogs): OrioleDB tables have their own buffer pool and keep
old row versions in undo logs. Each `dashboard_collector.py` documents its mapping. Chart titles and series
names come from the collector's `LABELS`, so each database's metrics appear
under its own names on both the dashboard and the compare page.

Implementation notes:

* Written in plain Python 3 with one static HTML page (`static/index.html`)
  plus `chart.js` and `style.css`, which the compare page shares. It uses no
  third-party packages and loads nothing from a CDN, so it works on isolated networks.
* Metrics are sampled every 5 s; the 5m, 15m and 1h views use those samples
  (kept in memory for 1 h).
* The 3h and 24h views use 1-minute averages kept for 24 h. They are saved in
  `/var/lib/parmaham-dashboard`, so history survives restarts and reboots.
* PSS and SwapPSS need ptrace access to the database server. A separate helper,
  `parmaham-procmem.service`, reads them; it has `CAP_SYS_PTRACE` but no
  network access, so the public dashboard needs no privileges.
* Runs as the unprivileged system user `parmaham-web` with a read-only
  filesystem view. The monitoring credentials are passed in with `LoadCredential`.
* JSON API (read-only; the compare page uses it): `/api/info`, `/api/status`,
  `/api/metrics?since=<epoch>` (5 s samples; add `&res=60` for 1-minute
  averages), `/api/results?limit=N`, `/api/lastrun`, `/api/runlog?name=<log>`,
  `/api/log?which=current|last`.

### `compare/install-compare.sh [--add URL [--name NAME]] [--remove URL] [--list] [--port 80] [--uninstall]`

A second page that shows any two Parma Ham workloads side by side, for
example MariaDB on one node and PostgreSQL on another. It needs no database,
so it can run on a small separate machine (1 GB is plenty; the server uses
about 20 MB), or next to a dashboard on another `--port`.

```bash
compare/install-compare.sh --add http://192.0.2.10/ --name "MariaDB 13.0"
compare/install-compare.sh --add http://192.0.2.11/ --name "PostgreSQL 18"   # http://<host>/
```

* Hosts are listed in `/etc/parmaham/compare-hosts` (`URL [name]` per line);
  `--add`, `--remove` and `--list` edit it, and changes apply without a restart.
* The page picks any two of them (A and B, with a swap button) and a time
  range; the selection is kept in the URL, so a comparison can be shared as a link.
* **Overview:** database and version, hardware, schema, capacity (also per
  vCPU), load level (a share of capacity or a fixed target), target, CPU steal,
  live throughput, last run and target achieved, with a "B vs A" difference column.
* **Charts:** every chart overlays both hosts on one time axis (A blue, B
  orange; dashed lines are targets): throughput and the result of every run,
  efficiency (NOPM per database CPU core, redo/WAL bytes and disk bytes
  written per new order), database, process and operating system metrics.
  Where the two databases measure different things under one name (rows
  read, MVCC backlog, lock waits) the chart is split into one chart per host,
  each with its own axis; otherwise each host's own metric name is shown in the legend.
* **Configuration:** workload settings and each database's settings side by side.
* Both hosts are put on one time grid (5 s buckets up to the 1h view, 1-minute
  averages for 3h and 24h); the charts draw across the occasional bucket in
  which one host has no sample.
* A host that cannot be reached is marked in the host list and in a banner;
  the other host keeps updating.
* The server only proxies the read-only API (`info`, `status`, `metrics`,
  `results`, `lastrun`) of the listed hosts, so the page cannot be used as an
  open proxy and the viewer's browser needs to reach only the compare page.
  Identical requests from several viewers within 2 s share one upstream request.
  Its own API: `/api/hosts` and `/api/h/<n>/<path>`.
* Host clocks should be in sync (NTP): runs are lined up by wall-clock time.
* Runs as `parmaham-compare.service` (user `parmaham-web`), port and address
  from `COMPARE_PORT` / `COMPARE_BIND` in `/etc/parmaham/parmaham.conf`.

## Files and services

| Path | Contents |
|------|----------|
| `/etc/parmaham/parmaham.conf` | settings (all defaults: `config/parmaham.conf.defaults`); flags passed to scripts are saved here |
| `/etc/parmaham/compare-hosts` | hosts shown on the compare page (`URL [name]` per line) |
| `/etc/parmaham/<db>-*.cnf` | database credentials, e.g. `mysql-admin.cnf` (admin 0600, bench 0640 root:parmaham, monitor 0600) |
| `/opt/parmaham` | installed copy of this repository plus HammerDB |
| `/var/lib/parmaham` | `capacity.json`, `schema.json`, `status.json`, `results.jsonl` (one line per run), `pace-correction` |
| `/var/log/parmaham` | `generate.log`, `capacity*.log`, `runs/run-*.log` (newest 200); HammerDB echoes the database password, which is masked before it is written |

| Unit | Purpose |
|------|---------|
| `parmaham-workload.service` | the permanent HammerDB loop (user `parmaham`) |
| `parmaham-purge.timer` / `.service` | periodic purge |
| `parmaham-dashboard.service` | dashboard |
| `parmaham-procmem.service` | reads database server and HammerDB CPU and memory (VSZ/RSS/PSS) for the dashboard |
| `parmaham-capacity.service` | transient, `compute-capacity.sh --background` |
| `parmaham-compare.service` | the compare page (`compare/install-compare.sh`) |
| `parmaham-thp.service` | disables transparent huge pages at boot |

Useful commands:

```bash
journalctl -fu parmaham-workload          # follow the benchmark
tail -n 5 /var/lib/parmaham/results.jsonl # latest results
systemctl list-timers parmaham-purge.timer
mysql/install-workload.sh --percent 70    # change the load level (restarts the loop; use your database's directory)
```

## Upgrading an existing installation

Nodes installed before multi-database support (MySQL only, scripts in `mysql/`)
keep working after an update: the credential files and state keep their names,
and `mysql/lib/workload-loop.sh` and `mysql/lib/purge.sh` remain as small
wrappers for the units that still point at them. To move the units to the new
paths and pick up the new dashboard:

```bash
git pull
mysql/install-workload.sh            # restarts the workload loop (the current iteration is lost)
mysql/install-hammerdb-purge.sh
dashboard/install-dashboard.sh
```

`PMH_DB` defaults to `mysql`, so an existing `/etc/parmaham/parmaham.conf`
needs no change.

## Adding another database

Create a directory named after the database and add it to `PMH_DATABASES` in
`common/lib.sh`. The directory needs:

* `database-install.sh`, which installs and tunes the server, creates the
  benchmark and monitoring accounts, writes `/etc/parmaham/<db>-{admin,bench,monitor}.cnf`
  and calls `claim_database <db>`;
* `lib/db.sh`, the shell plug-in: the functions listed at the top of
  `mysql/lib/db.sh` (service name, SQL as admin and as the benchmark user,
  HammerDB environment, schema fix-ups, purge, process names);
* `lib/hdb-db.tcl`, which selects the HammerDB database and sets the
  connection, credentials and the prefix of HammerDB's settings;
* `dashboard_collector.py` with a `Collector` class (`info()`, `sample()`), the
  `RATES`/`GAUGES` maps, `PROCESS` and optional `LABELS` (see the top of
  `mysql/dashboard_collector.py`). Provide every sample key listed there; where
  the database has no exact equivalent, return the closest metric and name it
  in `LABELS`;
* links to the four common scripts (`ln -s ../common/compute-capacity.sh ...`).

The workload loop, purge timer, status files and dashboard do not depend on
the database.

## Status

The full sequence has been tested end to end on fresh Linode VMs (4 vCPU,
8 GB) running **Ubuntu 24.04** and **Rocky Linux 9** (SELinux enforcing),
with Percona Server 9.7.2 and HammerDB 6.0:

* All install scripts and services ran, and everything came back after a reboot.
* Paced iterations held 98.7% to 100.2% of the target throughput.
* Purges ran alongside the workload without errors.
* After a database outage, the workload recorded a failed run and continued.
* The dashboard rendered without JavaScript errors in light and dark themes
  and at phone width.

Multi-database support was tested on fresh **Ubuntu 24.04** Linode VMs
(2 vCPU, 4 GB) with HammerDB 6.0, 50 warehouses (10 for Percona Server),
a short capacity test (16 VU, 2 + 6 min) and 50% paced iterations:

| Database | Capacity | Paced iterations (% of target) |
|----------|---------:|--------------------------------|
| Oracle MySQL Community Server 26.7.0 (Innovation) | 23,985 NOPM | 99.3% |
| Percona Server for MySQL 9.7.2 (10 warehouses, 8 VU) | 33,660 NOPM | 98.9% |
| MariaDB 13.0.2 | 25,526 NOPM | 98.8%, 100.3% |
| PostgreSQL 18.6 (PGDG) | 42,022 NOPM | 100.2%, 99.6% |

For every database the install, schema build, capacity measurement,
workload service, purge (timer and a forced purge that deleted 74k to 211k
orders next to the running workload) and dashboard worked, with no JavaScript
errors in light and dark themes or at phone width.

The compare page was tested on a 1 GB Linode (Ubuntu 24.04) comparing those
MariaDB, PostgreSQL and Percona Server nodes: host selection, swap, all time
ranges, an unreachable host, and light, dark and phone layouts without
JavaScript errors.

OrioleDB beta19 (PostgreSQL 18.6) and pgrust 0.3 were set up on Ubuntu
26.04 (2 vCPU, 4 GB) for a long-term comparison next to Percona Server and
PostgreSQL; see CHANGELOG.md for results.

Not tested yet: MariaDB and PostgreSQL on RHEL/Rocky (OrioleDB and pgrust
install on Debian and Ubuntu only), Debian 12, aarch64,
and multi-day runs with MariaDB and PostgreSQL.

## License

Apache License 2.0, see [LICENSE](LICENSE).
