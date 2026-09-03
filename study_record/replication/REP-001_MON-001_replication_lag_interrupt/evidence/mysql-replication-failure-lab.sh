#!/usr/bin/env bash
set -euo pipefail

MYSQL_HOME=/usr/local/mysql/mysql-8.4.10
MYSQLD="$MYSQL_HOME/bin/mysqld"
MYSQL="$MYSQL_HOME/bin/mysql"
MYSQLADMIN="$MYSQL_HOME/bin/mysqladmin"
SOURCE_DIR=/data/myhome/mydata/mysql-rep14-source
REPLICA_DIR=/data/myhome/mydata/mysql-rep14-replica
SOURCE_CNF=/tmp/mysql-rep14-source.cnf
REPLICA_CNF=/tmp/mysql-rep14-replica.cnf
SOURCE_SOCKET=/tmp/mysql-rep14-source.sock
REPLICA_SOCKET=/tmp/mysql-rep14-replica.sock
SOURCE_PORT=33331
REPLICA_PORT=33332
OUTPUT=${1:-mysql-replication-failure-output.txt}

cleanup_processes() {
  "$MYSQLADMIN" --no-defaults -uroot -S "$REPLICA_SOCKET" shutdown >/dev/null 2>&1 || true
  "$MYSQLADMIN" --no-defaults -uroot -S "$SOURCE_SOCKET" shutdown >/dev/null 2>&1 || true
}
trap cleanup_processes EXIT

wait_mysql() {
  local socket=$1
  for _ in $(seq 1 120); do
    "$MYSQLADMIN" --no-defaults -uroot -S "$socket" ping >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

wait_value() {
  local socket=$1 sql=$2 expected=$3
  for _ in $(seq 1 120); do
    value=$("$MYSQL" --no-defaults -N -B -uroot -S "$socket" -e "$sql" 2>/dev/null || true)
    [[ "$value" == "$expected" ]] && return 0
    sleep 0.25
  done
  echo "timeout: expected $expected, got ${value:-<empty>}" >&2
  return 1
}

cleanup_processes
for dir in "$SOURCE_DIR" "$REPLICA_DIR"; do
  if [[ -e "$dir" ]]; then
    echo "refusing to overwrite existing directory: $dir" >&2
    exit 1
  fi
  install -d -o mysql -g mysql -m 0750 "$dir"
done

printf '%s\n' \
  '[mysqld]' "basedir=$MYSQL_HOME" "datadir=$SOURCE_DIR" \
  "socket=$SOURCE_SOCKET" "port=$SOURCE_PORT" 'server_id=1401' \
  "log_bin=$SOURCE_DIR/binlog" 'binlog_format=ROW' 'gtid_mode=ON' \
  'enforce_gtid_consistency=ON' 'log_replica_updates=ON' \
  'innodb_buffer_pool_size=64M' 'performance_schema=ON' 'mysqlx=OFF' \
  "pid_file=$SOURCE_DIR/mysqld.pid" "log_error=$SOURCE_DIR/error.log" \
  > "$SOURCE_CNF"

printf '%s\n' \
  '[mysqld]' "basedir=$MYSQL_HOME" "datadir=$REPLICA_DIR" \
  "socket=$REPLICA_SOCKET" "port=$REPLICA_PORT" 'server_id=1402' \
  "log_bin=$REPLICA_DIR/binlog" "relay_log=$REPLICA_DIR/relay-bin" \
  'binlog_format=ROW' 'gtid_mode=ON' 'enforce_gtid_consistency=ON' \
  'log_replica_updates=ON' 'relay_log_recovery=ON' 'skip_replica_start=ON' \
  'innodb_buffer_pool_size=64M' 'performance_schema=ON' 'mysqlx=OFF' \
  "pid_file=$REPLICA_DIR/mysqld.pid" "log_error=$REPLICA_DIR/error.log" \
  > "$REPLICA_CNF"

sudo -u mysql "$MYSQLD" --defaults-file="$SOURCE_CNF" --initialize-insecure \
  > /tmp/mysql-rep14-source-init.log 2>&1
sudo -u mysql "$MYSQLD" --defaults-file="$REPLICA_CNF" --initialize-insecure \
  > /tmp/mysql-rep14-replica-init.log 2>&1
sudo -u mysql "$MYSQLD" --defaults-file="$SOURCE_CNF" --daemonize
sudo -u mysql "$MYSQLD" --defaults-file="$REPLICA_CNF" --daemonize
wait_mysql "$SOURCE_SOCKET"
wait_mysql "$REPLICA_SOCKET"

{
  echo '[SETUP]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    'SELECT @@version,@@port,@@server_id,@@server_uuid,@@gtid_mode;'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    'SELECT @@version,@@port,@@server_id,@@server_uuid,@@gtid_mode;'
  "$MYSQL" --no-defaults -uroot -S "$SOURCE_SOCKET" <<'SQL'
CREATE USER 'repl'@'127.0.0.1' IDENTIFIED BY 'rep14-local-only';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'127.0.0.1';
CREATE DATABASE rep_lab;
CREATE TABLE rep_lab.events(id BIGINT PRIMARY KEY,payload VARCHAR(64) NOT NULL) ENGINE=InnoDB;
INSERT INTO rep_lab.events
SELECT n,CONCAT('seed-',n)
FROM JSON_TABLE(CONCAT('[',REPEAT('0,',99),'0]'),'$[*]' COLUMNS(n FOR ORDINALITY)) AS j;
SQL
  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" <<SQL
CHANGE REPLICATION SOURCE TO
 SOURCE_HOST='127.0.0.1',SOURCE_PORT=$SOURCE_PORT,
 SOURCE_USER='repl',SOURCE_PASSWORD='rep14-local-only',
 SOURCE_AUTO_POSITION=1,SOURCE_CONNECT_RETRY=1,GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
  wait_value "$REPLICA_SOCKET" 'SELECT COUNT(*) FROM rep_lab.events' '100'
  echo '[HEALTHY BASELINE]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    'SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events;'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SELECT SERVICE_STATE,LAST_ERROR_NUMBER,RECEIVED_TRANSACTION_SET FROM performance_schema.replication_connection_status; SELECT SERVICE_STATE FROM performance_schema.replication_applier_status;"

  "$MYSQLADMIN" --no-defaults -uroot -S "$SOURCE_SOCKET" shutdown
  for _ in $(seq 1 80); do
    conn_error=$("$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
      'SELECT LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status')
    [[ "$conn_error" != '0' ]] && break
    sleep 0.25
  done
  echo '[SOURCE DOWN: RECEIVER RETRYING, APPLIER AVAILABLE]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*) FROM rep_lab.events; SELECT SERVICE_STATE,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE FROM performance_schema.replication_connection_status; SELECT SERVICE_STATE FROM performance_schema.replication_applier_status;"

  sudo -u mysql "$MYSQLD" --defaults-file="$SOURCE_CNF" --daemonize
  wait_mysql "$SOURCE_SOCKET"
  "$MYSQL" --no-defaults -uroot -S "$SOURCE_SOCKET" -e \
    "INSERT INTO rep_lab.events(id,payload) SELECT 100+n,CONCAT('after-reconnect-',n) FROM JSON_TABLE(CONCAT('[',REPEAT('0,',49),'0]'),'\$[*]' COLUMNS(n FOR ORDINALITY)) AS j;"
  wait_value "$REPLICA_SOCKET" 'SELECT COUNT(*) FROM rep_lab.events' '150'
  echo '[SOURCE RESTARTED: GTID AUTO-RESUME]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SELECT SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status;"

  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e 'STOP REPLICA SQL_THREAD;'
  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e \
    "SET SESSION sql_log_bin=0; INSERT INTO rep_lab.events VALUES(1000,'replica-local-divergence');"
  "$MYSQL" --no-defaults -uroot -S "$SOURCE_SOCKET" -e \
    "INSERT INTO rep_lab.events VALUES(1000,'source-authoritative'),(1001,'source-after-conflict');"
  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e 'START REPLICA SQL_THREAD;'
  for _ in $(seq 1 120); do
    sql_error=$("$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
      'SELECT LAST_ERROR_NUMBER FROM performance_schema.replication_applier_status_by_worker LIMIT 1')
    [[ "$sql_error" == '1062' ]] && break
    sleep 0.25
  done
  source_gtid=$("$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    'SELECT @@GLOBAL.gtid_executed')
  for _ in $(seq 1 120); do
    received=$("$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
      'SELECT RECEIVED_TRANSACTION_SET FROM performance_schema.replication_connection_status')
    [[ "$received" == "$source_gtid" ]] && break
    sleep 0.25
  done
  echo '[APPLIER 1062: RECEIVER CONTINUES]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    'SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events;'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),payload,@@GLOBAL.gtid_executed FROM rep_lab.events WHERE id=1000; SELECT SERVICE_STATE,LAST_ERROR_NUMBER,RECEIVED_TRANSACTION_SET FROM performance_schema.replication_connection_status; SELECT SERVICE_STATE FROM performance_schema.replication_applier_status; SELECT WORKER_ID,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE,APPLYING_TRANSACTION FROM performance_schema.replication_applier_status_by_worker;"

  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e \
    "SET SESSION sql_log_bin=0; DELETE FROM rep_lab.events WHERE id=1000 AND payload='replica-local-divergence'; START REPLICA SQL_THREAD;"
  wait_value "$REPLICA_SOCKET" 'SELECT COUNT(*) FROM rep_lab.events' '152'
  echo '[DIVERGENCE REPAIRED: APPLIER CAUGHT UP]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),SUM(id IN (1000,1001)),@@GLOBAL.gtid_executed FROM rep_lab.events; SELECT SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status; SELECT SERVICE_STATE FROM performance_schema.replication_applier_status; SELECT WAIT_FOR_EXECUTED_GTID_SET('$source_gtid',5);"
} > "$OUTPUT" 2>&1

echo "completed: $OUTPUT"
