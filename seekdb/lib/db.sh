# shellcheck shell=bash
# Database plug-in for seekdb (OceanBase's MySQL-compatible database), built
# on the MySQL plug-in (mysql/lib/db.sh describes the interface). seekdb has
# no Unix socket: clients connect over TCP to 127.0.0.1 and SEEKDB_PORT.

DB_LABEL=seekdb
MYSQL_CLIENT=mysql
# shellcheck disable=SC1091
source "$PMH_SRC/mysql/lib/db.sh"

db_service()      { echo seekdb; }
db_procmem_spec() { echo seekdb; }

# credential files: TCP host and port instead of a socket
write_client_cnf() {
    {
        echo "[client]"
        echo "user=$2"
        echo "password=$3"
        echo "host=127.0.0.1"
        echo "port=${SEEKDB_PORT:-2881}"
    } | write_cnf "$1" "$4" "$5"
}

hdb_env() {
    [[ -r $MYSQL_BENCH_CNF ]] || die "$MYSQL_BENCH_CNF not found - run database-install.sh first"
    export PMH_DB_HOST=127.0.0.1
    export PMH_DB_PORT=${SEEKDB_PORT:-2881}
    PMH_DB_USER=$(cnf_value "$MYSQL_BENCH_CNF" user)
    PMH_DB_PASS=$(cnf_value "$MYSQL_BENCH_CNF" password)
    export PMH_DB_USER PMH_DB_PASS
    export PMH_DB_NAME=$MYSQL_BENCH_DB
}

# seekdb's information_schema has no reliable table sizes: report the data
# disk in use instead
db_schema_size_mb() {
    db_admin "SELECT ROUND(DATA_DISK_IN_USE / 1048576) FROM oceanbase.V\$OB_SERVER_STAT"
}

# HammerDB creates the database as latin1, which seekdb does not support, but
# uses an existing empty database: create it as utf8mb4 first
db_before_build() {
    db_admin "CREATE DATABASE IF NOT EXISTS \`$MYSQL_BENCH_DB\` DEFAULT CHARACTER SET utf8mb4"
}

# HammerDB adds history's invisible key only for MySQL 8.0.30 and later
# (seekdb reports 5.7.25), and seekdb cannot add a primary key column to an
# existing table. Copy history into a table that has the key, 10 warehouses
# per transaction, and swap it in (HammerDB's inserts name their columns).
db_after_build() {
    if [[ -n $(db_bench "SELECT 1 FROM information_schema.columns WHERE table_schema = '$MYSQL_BENCH_DB' AND table_name = 'history' AND column_name = 'id'") ]]; then
        return 0
    fi
    local cols="h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data" max w
    max=$(db_bench "SELECT MAX(w_id) FROM warehouse")
    log "adding a BIGINT invisible primary key to history (copying it, 10 warehouses per transaction)"
    db_bench "DROP TABLE IF EXISTS history_new"
    db_bench "CREATE TABLE history_new (
        h_c_id INT NULL, h_c_d_id INT NULL, h_c_w_id INT NULL, h_d_id INT NULL, h_w_id INT NULL,
        h_date DATETIME NULL, h_amount DECIMAL(6, 2) NULL, h_data VARCHAR(24) BINARY NULL,
        id BIGINT NOT NULL AUTO_INCREMENT INVISIBLE, PRIMARY KEY (id))"
    for ((w = 1; w <= max; w += 10)); do
        db_bench "INSERT INTO history_new ($cols) SELECT $cols FROM history WHERE h_w_id BETWEEN $w AND $((w + 9))"
    done
    db_bench "RENAME TABLE history TO history_old, history_new TO history"
    db_bench "DROP TABLE history_old"
}

# Benchmark and monitoring accounts. OceanBase matches client hosts for TCP
# connections, so the accounts are for '%' (the server listens on 127.0.0.1
# only, see database-install.sh).
seekdb_create_accounts() {
    local bench_pass mon_pass
    if [[ -r $MYSQL_BENCH_CNF ]]; then bench_pass=$(cnf_value "$MYSQL_BENCH_CNF" password); else bench_pass=$(random_password); fi
    if [[ -r $MYSQL_MONITOR_CNF ]]; then mon_pass=$(cnf_value "$MYSQL_MONITOR_CNF" password); else mon_pass=$(random_password); fi
    db_admin <<EOF
CREATE USER IF NOT EXISTS '$MYSQL_BENCH_USER'@'%' IDENTIFIED BY '$bench_pass';
ALTER USER '$MYSQL_BENCH_USER'@'%' IDENTIFIED BY '$bench_pass';
GRANT ALL ON \`$MYSQL_BENCH_DB\`.* TO '$MYSQL_BENCH_USER'@'%';
GRANT SELECT ON oceanbase.* TO '$MYSQL_BENCH_USER'@'%';
CREATE USER IF NOT EXISTS '$MYSQL_MONITOR_USER'@'%' IDENTIFIED BY '$mon_pass';
ALTER USER '$MYSQL_MONITOR_USER'@'%' IDENTIFIED BY '$mon_pass';
GRANT SELECT ON oceanbase.* TO '$MYSQL_MONITOR_USER'@'%';
GRANT SELECT ON \`$MYSQL_BENCH_DB\`.* TO '$MYSQL_MONITOR_USER'@'%';
EOF
    write_client_cnf "$MYSQL_BENCH_CNF" "$MYSQL_BENCH_USER" "$bench_pass" "$PMH_USER" 0640
    write_client_cnf "$MYSQL_MONITOR_CNF" "$MYSQL_MONITOR_USER" "$mon_pass" root 0600
}
