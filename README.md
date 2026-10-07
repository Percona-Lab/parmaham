# Parma Ham — Permanent HammerDB Benchmark Runner

Parma Ham runs [HammerDB](https://www.hammerdb.com/) TPROC-C continuously, for
days, weeks or months, at a controlled share of what the machine can do. Use it
for demos, and to see how an environment behaves over a long period: whether
performance drifts, stalls or degrades over time.

Each supported database lives in its own directory. The first one is
**Percona Server for MySQL 9.7** (`mysql/`).

```
parmaham/
├── common/lib.sh                  shared shell helpers (config, HammerDB install/run, status)
├── config/                        defaults + example /etc/parmaham/parmaham.conf
├── dashboard/                     public web dashboard (Python standard library only)
└── mysql/                         Percona Server for MySQL
    ├── database-install.sh        install + tune Percona Server for this node
    ├── database-generate.sh       build the TPROC-C schema (default 200 warehouses)
    ├── compute-capacity.sh        measure sustainable throughput (64 VU, 15 + 30 min)
    ├── install-workload.sh        permanent workload service at N% of capacity
    ├── install-hammerdb-purge.sh  timer that deletes benchmark data older than 24h
    ├── dashboard_collector.py     database metrics for the dashboard
    └── lib/                       HammerDB Tcl scripts, purge SQL, service loop
```

## Quick start

On a fresh Ubuntu 22.04/24.04, Debian 12 or RHEL/Rocky/Alma 9 machine (x86_64),
as root:

```bash
git clone https://github.com/Percona-Lab/parmaham.git
cd parmaham

mysql/database-install.sh                  # Percona Server 9.7 LTS, tuned to this node
mysql/database-generate.sh                 # 200 warehouses
mysql/compute-capacity.sh --background     # ~46 minutes: journalctl -fu parmaham-capacity
mysql/install-workload.sh                  # run at 50% of capacity, forever
mysql/install-hammerdb-purge.sh            # keep only the last 24h of new data
dashboard/install-dashboard.sh             # http://<host>/
```

Each step prints the next one. Every script supports `--help`.

> Put the database on the storage you want to test *before* running
> `database-install.sh`: mount it at `/var/lib/mysql`.

## What each step does

### `database-install.sh`

* Adds the Percona repository with `percona-release enable-only ps-97-lts`
  (configurable with `--repo`) and installs `percona-server-server`.
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

### `database-generate.sh [--warehouses 200] [--vu N] [--partition true] [--force]`

* Downloads HammerDB 6.0 into `/opt/parmaham/hammerdb` and builds the schema.
* HammerDB's MySQL driver needs Oracle's `libmysqlclient.so.24`; Percona's client
  library is not symbol-compatible. The script therefore takes that one library
  from the MySQL 8.4 minimal tarball and keeps it private to HammerDB.
* Builds `history` with HammerDB's invisible primary key option and widens it to
  `BIGINT`. A permanent run would otherwise exhaust `INT`, and the purge job needs
  the key.

### `compute-capacity.sh [--vu 64] [--rampup 15] [--duration 30] [--background]`

* Runs HammerDB unthrottled and saves the result (NOPM, TPM, virtual users) to
  `/var/lib/parmaham/capacity.json`.
* If the workload service is running, the script stops it for the measurement
  and starts it again afterwards; the workload then uses the new capacity.
* `--background` runs the measurement as the systemd unit `parmaham-capacity`,
  so it survives a closed SSH session.

### `install-workload.sh [--percent 50] [--vu N] [--rampup 1] [--duration 60] [--sleep 0]`

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

Because watermarks start at installation, the first rows are deleted one
retention period after the purge is installed.

### `dashboard/install-dashboard.sh [--port 80] [--bind 0.0.0.0]`

Runs a public dashboard with no login, by design. It shows:

* **Benchmark:** state, progress of the current iteration, target and capacity,
  live NOPM/TPM against the target, the result of every run, and recent runs.
* **Database:** transactions and queries, InnoDB row operations, threads, buffer
  pool, redo log and checkpoint age, undo history length, row lock waits, and
  `mysqld` memory (VSZ, RSS, and PSS + SwapPSS on one chart), and space on
  the volume that holds the data directory.
* **HammerDB execution:** a summary of the last completed run, plus a live
  tail of the current run's HammerDB log (switchable to the last completed run).
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
* **Processes:** CPU in use (cores) for `mysqld` and HammerDB, plus memory
  (VSZ, RSS, PSS + SwapPSS) for each. HammerDB covers every process in the
  workload and capacity services (`hammerdbcli` with one thread per virtual
  user, plus the loop script and log filter) and any `hammerdbcli` started by
  hand.
* **Operating system:** pressure stall information (CPU, memory and IO
  `some`/`full`), CPU breakdown including steal, load and run queue, memory and
  swap, disk IOPS, throughput and utilization, network, context switches and
  major faults.
* **Environment:** hardware (CPU model and topology, NUMA, memory, disks, NICs,
  virtualization and system vendor), OS and kernel, and the database
  configuration and data directory filesystem.

Implementation notes:

* Written in plain Python 3 with one static HTML page. It uses no third-party
  packages and loads nothing from a CDN, so it works on isolated networks.
* Metrics are sampled every 5 s; the 5m, 15m and 1h views use those samples
  (kept in memory for 1 h).
* The 3h and 24h views use 1-minute averages kept for 24 h. They are saved in
  `/var/lib/parmaham-dashboard`, so history survives restarts and reboots.
* PSS and SwapPSS need ptrace access to `mysqld`. A separate helper,
  `parmaham-procmem.service`, reads them; it has `CAP_SYS_PTRACE` but no
  network access, so the public dashboard needs no privileges.
* Runs as a systemd `DynamicUser` with a read-only filesystem view. The
  monitoring credentials are passed in with `LoadCredential`.
* JSON API: `/api/info`, `/api/status`, `/api/metrics?since=<epoch>`,
  `/api/results?limit=N`.

## Files and services

| Path | Contents |
|------|----------|
| `/etc/parmaham/parmaham.conf` | settings (all defaults: `config/parmaham.conf.defaults`); flags passed to scripts are saved here |
| `/etc/parmaham/mysql-*.cnf` | MySQL credentials (admin 0600, bench 0640 root:parmaham, monitor 0600) |
| `/opt/parmaham` | installed copy of this repository plus HammerDB |
| `/var/lib/parmaham` | `capacity.json`, `schema.json`, `status.json`, `results.jsonl` (one line per run), `pace-correction` |
| `/var/log/parmaham` | `generate.log`, `capacity*.log`, `runs/run-*.log` (newest 200); HammerDB echoes the database password, which is masked before it is written |

| Unit | Purpose |
|------|---------|
| `parmaham-workload.service` | the permanent HammerDB loop (user `parmaham`) |
| `parmaham-purge.timer` / `.service` | periodic purge |
| `parmaham-dashboard.service` | dashboard |
| `parmaham-procmem.service` | reads `mysqld` and HammerDB CPU and memory (VSZ/RSS/PSS) for the dashboard |
| `parmaham-capacity.service` | transient, `compute-capacity.sh --background` |
| `parmaham-thp.service` | disables transparent huge pages at boot |

Useful commands:

```bash
journalctl -fu parmaham-workload          # follow the benchmark
tail -n 5 /var/lib/parmaham/results.jsonl # latest results
systemctl list-timers parmaham-purge.timer
mysql/install-workload.sh --percent 70    # change the load level (restarts the loop)
```

## Adding another database

Create a directory named after the database, with the same five scripts and a
`dashboard_collector.py` that provides a `Collector` class with `info()` and
`sample()` plus the `RATES`/`GAUGES` maps (see `mysql/dashboard_collector.py`).
Then set `PMH_DB=<dir>` in `/etc/parmaham/parmaham.conf`. The workload loop,
status files and dashboard do not depend on the database.

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

Not tested yet: Debian 12, aarch64, and multi-day runs.

## License

Apache License 2.0, see [LICENSE](LICENSE).
