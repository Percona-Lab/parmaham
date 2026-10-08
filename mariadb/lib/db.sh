# shellcheck shell=bash
# Database plug-in for MariaDB, built on the MySQL one (mysql/lib/db.sh
# describes the interface). Sourced by common/lib.sh load_db.

DB_LABEL=MariaDB
MYSQL_CLIENT=mariadb
# shellcheck disable=SC1091
source "$PMH_SRC/mysql/lib/db.sh"

db_service() { echo mariadb; }

mysql_conf_dir() {
    case $(os_family) in
        debian) echo /etc/mysql/mariadb.conf.d ;;
        rhel)   echo /etc/my.cnf.d ;;
    esac
}

db_procmem_spec() { echo mariadbd; }

# HammerDB's MariaDB interface (mariatcl) loads the system's libmariadb.so.3,
# installed with the MariaDB client
unset -f db_hammerdb_libs
