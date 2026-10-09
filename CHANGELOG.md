# Changelog

## Fixed NOPM target and CPU steal (2026-10-09)

* `install-workload.sh --nopm N` runs the permanent workload at a fixed number
  of new orders per minute instead of a share of the measured capacity, and
  needs no capacity measurement. `--percent` switches back. Status and results
  record `target_mode` (`percent` or `nopm`) and the target as a share of the
  capacity when there is one; the dashboard and compare page show either.
* `install-workload.sh` checks its options before saving them, so a rejected
  change no longer reaches the running workload's configuration.
* Dashboard and compare page: a CPU steal chart (share of CPU time the
  hypervisor gave to other guests, with the vCPUs that amounts to); the
  compare overview shows the last minute's steal for both hosts.

## OrioleDB and pgrust (2026-10-09)

### New

* **OrioleDB** (`orioledb/`): builds PostgreSQL with OrioleDB's patch set and
  the `orioledb` extension from source (default beta19 on PostgreSQL 18) and
  makes it the default table access method, so the whole HammerDB schema uses
  OrioleDB. Its buffer pool gets the memory PostgreSQL gives `shared_buffers`.
* **pgrust** (`pgrust/`): runs the pgrust release binary (default 0.3), a Rust
  rewrite of PostgreSQL 18, on a cluster created with PGDG PostgreSQL 18's
  `initdb`. pgrust bundles ports of `pg_stat_statements` and `pg_buffercache`,
  so the dashboard shows the same metrics as for PostgreSQL.
* Both reuse the PostgreSQL plug-in: HammerDB's PostgreSQL driver, the
  PL/pgSQL purge and the PostgreSQL dashboard collector.

### Changed

* `postgresql/lib/db.sh` provides the tuning file, admin password and accounts
  as functions (`pg_write_tuning`, `pg_set_admin_password`, `pg_create_accounts`)
  that variants adjust with `PG_PRELOAD` and `pg_extra_conf`. Credential files
  are named after the database directory (`/etc/parmaham/<db>-*.cnf`).
* The PostgreSQL dashboard collector takes the `psql` search path from the
  variant (OrioleDB's is in `/opt/orioledb`).

### Fixed

* Writing the tuning file into the data directory no longer resets the data
  directory's mode to 0755 (PostgreSQL then refuses to start); this affected
  variants that keep `zz-parmaham.conf` in the data directory.
* OrioleDB: adding the `history` key with one `ALTER TABLE` grew a backend
  past the memory of a 4 GB node (OOM-killed at 2.7 GB for 6 million rows);
  the rows are now copied into a keyed table 10 warehouses per transaction
  (76 s for 200 warehouses).
* OrioleDB's service protects only the postmaster from the OOM killer, as
  PostgreSQL's packaging does (`PG_OOM_ADJUST_FILE`); with every backend
  protected, the kernel killed sshd, logind and the monitoring agents instead
  of the runaway backend. pgrust (one process) gets no protection.

## Multi-database support and compare page (2026-10-08, branch `multi-database`)

### New

* **MariaDB** (`mariadb/`): installs MariaDB Server from the MariaDB Foundation
  repository, 13.0 by default (`--version 12.3` or `11.8` for an LTS release),
  with the same sizing as MySQL.
* **PostgreSQL** (`postgresql/`): installs PostgreSQL from the community
  repository (PGDG), 18 by default, tuned for the node (`shared_buffers`,
  `max_wal_size`, checkpoints, autovacuum, `pg_stat_statements`); HammerDB
  runs with stored procedures. A PL/pgSQL purge keeps the database size
  stable as on MySQL.
* **Oracle MySQL Community Server** as a second MySQL flavor:
  `mysql/database-install.sh --flavor community`, from repo.mysql.com,
  `mysql-9.7-lts` or `--repo mysql-innovation` for the newest release (26.7).
  Percona Server stays the default.
* **Compare page** (`compare/install-compare.sh`): any two Parma Ham nodes side
  by side, with an overview and "B vs A" column, overlaid charts, efficiency
  metrics (NOPM per database CPU core, redo/WAL and disk bytes per new order)
  and both configurations. It runs on any small machine and proxies only the
  read-only dashboard API of the hosts listed in `/etc/parmaham/compare-hosts`.

### Changed

* The scripts that are the same for every database moved to `common/`; each
  database directory has its own `database-install.sh`, a plug-in
  (`lib/db.sh`, `lib/hdb-db.tcl`, `dashboard_collector.py`) and links to the
  common scripts, so `<db>/compute-capacity.sh` etc. work as before. A node
  runs one database (`PMH_DB`, set by `database-install.sh`).
* Dashboard: chart titles, series names and the database settings table come
  from the database's collector, which shows the closest equivalent metric
  under the database's own name where there is no exact one (README: "Database
  metrics per database").
* Dashboard: the chart code and styles moved to `static/chart.js` and
  `static/style.css`, shared with the compare page.
* Dashboard memory chart: VSZ that is only reserved address space (MariaDB)
  and RSS summed over many processes (PostgreSQL) are named but not plotted.
* Password masking in logs also covers PostgreSQL's `pg_superuserpass` and
  every password on a line.

### Fixed

* Process CPU charts had gaps when the dashboard sampler and
  `parmaham-procmem` drifted into step; the last rate is now repeated.
* Long legend entries and HammerDB report values no longer make the
  dashboard scroll sideways at phone width.

### Upgrading

Existing MySQL nodes keep working; re-run `mysql/install-workload.sh`,
`mysql/install-hammerdb-purge.sh` and `dashboard/install-dashboard.sh` to move
the services to the new paths (README: "Upgrading an existing installation").

### Tested

Ubuntu 24.04 on 2 vCPU / 4 GB Linode VMs with HammerDB 6.0: Oracle MySQL
26.7.0, Percona Server 9.7.2, MariaDB 13.0.2 and PostgreSQL 18.6, from install
through paced iterations (98.8% to 100.3% of target), purge and dashboard;
the compare page on a 1 GB VM. Not yet tested: MariaDB and PostgreSQL on
RHEL/Rocky, Debian 12, aarch64, multi-day runs.
