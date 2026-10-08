# Changelog

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
