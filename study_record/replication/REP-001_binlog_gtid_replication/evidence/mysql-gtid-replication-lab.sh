#!/usr/bin/env bash
set -euo pipefail

MYSQL_HOME=/usr/local/mysql/mysql-8.4.10
MYSQLD="$MYSQL_HOME/bin/mysqld"
MYSQL="$MYSQL_HOME/bin/mysql"
MYSQLADMIN="$MYSQL_HOME/bin/mysqladmin"
SOURCE_DIR=/data/myhome/mydata/mysql-rep13-source
REPLICA_DIR=/data/myhome/mydata/mysql-rep13-replica
SOURCE_CNF=/tmp/mysql-rep13-source.cnf
REPLICA_CNF=/tmp/mysql-rep13-replica.cnf
SOURCE_SOCKET=/tmp/mysql-rep13-source.sock
REPLICA_SOCKET=/tmp/mysql-rep13-replica.sock
SOURCE_PORT=33321
REPLICA_PORT=33322
OUTPUT=${1:-mysql-gtid-replication-output.txt}

cleanup_processes() {
  "$MYSQLADMIN" --no-defaults -uroot -S "$REPLICA_SOCKET" shutdown >/dev/null 2>&1 || true
  "$MYSQLADMIN" --no-defaults -uroot -S "$SOURCE_SOCKET" shutdown >/dev/null 2>&1 || true
}
trap cleanup_processes EXIT

wait_mysql() {
  local socket=$1
  for _ in $(seq 1 120); do
    if "$MYSQLADMIN" --no-defaults -uroot -S "$socket" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_value() {
  local socket=$1 sql=$2 expected=$3
  for _ in $(seq 1 120); do
    value=$("$MYSQL" --no-defaults -N -B -uroot -S "$socket" -e "$sql" 2>/dev/null || true)
    if [[ "$value" == "$expected" ]]; then
      return 0
    fi
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
  '[mysqld]' \
  "basedir=$MYSQL_HOME" \
  "datadir=$SOURCE_DIR" \
  "socket=$SOURCE_SOCKET" \
  "port=$SOURCE_PORT" \
  'server_id=1301' \
  "log_bin=$SOURCE_DIR/binlog" \
  'binlog_format=ROW' \
  'gtid_mode=ON' \
  'enforce_gtid_consistency=ON' \
  'log_replica_updates=ON' \
  'innodb_buffer_pool_size=64M' \
  'performance_schema=ON' \
  'mysqlx=OFF' \
  "pid_file=$SOURCE_DIR/mysqld.pid" \
  "log_error=$SOURCE_DIR/error.log" > "$SOURCE_CNF"

printf '%s\n' \
  '[mysqld]' \
  "basedir=$MYSQL_HOME" \
  "datadir=$REPLICA_DIR" \
  "socket=$REPLICA_SOCKET" \
  "port=$REPLICA_PORT" \
  'server_id=1302' \
  "log_bin=$REPLICA_DIR/binlog" \
  "relay_log=$REPLICA_DIR/relay-bin" \
  'binlog_format=ROW' \
  'gtid_mode=ON' \
  'enforce_gtid_consistency=ON' \
  'log_replica_updates=ON' \
  'relay_log_recovery=ON' \
  'skip_replica_start=ON' \
  'innodb_buffer_pool_size=64M' \
  'performance_schema=ON' \
  'mysqlx=OFF' \
  "pid_file=$REPLICA_DIR/mysqld.pid" \
  "log_error=$REPLICA_DIR/error.log" > "$REPLICA_CNF"

sudo -u mysql "$MYSQLD" --defaults-file="$SOURCE_CNF" --initialize-insecure \
  > /tmp/mysql-rep13-source-initialize.log 2>&1
sudo -u mysql "$MYSQLD" --defaults-file="$REPLICA_CNF" --initialize-insecure \
  > /tmp/mysql-rep13-replica-initialize.log 2>&1
sudo -u mysql "$MYSQLD" --defaults-file="$SOURCE_CNF" --daemonize
sudo -u mysql "$MYSQLD" --defaults-file="$REPLICA_CNF" --daemonize
wait_mysql "$SOURCE_SOCKET"
wait_mysql "$REPLICA_SOCKET"

{
  echo '[VERSIONS AND IDENTITIES]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    "SELECT @@version,@@port,@@server_id,@@server_uuid,@@gtid_mode,@@binlog_format;"
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT @@version,@@port,@@server_id,@@server_uuid,@@gtid_mode,@@binlog_format;"

  "$MYSQL" --no-defaults -uroot -S "$SOURCE_SOCKET" <<'SQL'
CREATE USER 'repl'@'127.0.0.1' IDENTIFIED BY 'rep13-local-only';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'127.0.0.1';
CREATE DATABASE rep_lab;
CREATE TABLE rep_lab.events (
  id BIGINT PRIMARY KEY,
  payload VARCHAR(64) NOT NULL,
  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB;
INSERT INTO rep_lab.events(id,payload)
SELECT n, CONCAT('seed-',n)
FROM JSON_TABLE(
  CONCAT('[', REPEAT('0,', 99), '0]'), '$[*]'
  COLUMNS(n FOR ORDINALITY)
) AS j;
SQL

  echo '[SOURCE BEFORE REPLICATION]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SHOW BINARY LOG STATUS;"

  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='127.0.0.1',
  SOURCE_PORT=$SOURCE_PORT,
  SOURCE_USER='repl',
  SOURCE_PASSWORD='rep13-local-only',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
  wait_value "$REPLICA_SOCKET" 'SELECT COUNT(*) FROM rep_lab.events' '100'

  echo '[AUTO-POSITION CAUGHT UP]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events;"
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT CHANNEL_NAME,SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status; SELECT CHANNEL_NAME,SERVICE_STATE FROM performance_schema.replication_applier_status;"

  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e 'STOP REPLICA SQL_THREAD;'
  "$MYSQL" --no-defaults -uroot -S "$SOURCE_SOCKET" <<'SQL'
INSERT INTO rep_lab.events(id,payload)
SELECT 100+n, CONCAT('queued-',n)
FROM JSON_TABLE(
  CONCAT('[', REPEAT('0,', 199), '0]'), '$[*]'
  COLUMNS(n FOR ORDINALITY)
) AS j;
SQL
  source_gtid=$("$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e 'SELECT @@GLOBAL.gtid_executed')
  for _ in $(seq 1 120); do
    retrieved=$("$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e "SELECT RECEIVED_TRANSACTION_SET FROM performance_schema.replication_connection_status")
    [[ "$retrieved" == "$source_gtid" ]] && break
    sleep 0.25
  done

  echo '[RECEIVER RUNNING, APPLIER STOPPED]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SELECT CHANNEL_NAME,SERVICE_STATE,RECEIVED_TRANSACTION_SET,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status; SELECT CHANNEL_NAME,SERVICE_STATE FROM performance_schema.replication_applier_status; SHOW REPLICA STATUS\G"

  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e 'START REPLICA SQL_THREAD;'
  wait_value "$REPLICA_SOCKET" 'SELECT COUNT(*) FROM rep_lab.events' '300'
  echo '[APPLIER RESTARTED AND CAUGHT UP]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SELECT WAIT_FOR_EXECUTED_GTID_SET('$source_gtid',5);"

  "$MYSQLADMIN" --no-defaults -uroot -S "$REPLICA_SOCKET" shutdown
  sudo -u mysql "$MYSQLD" --defaults-file="$REPLICA_CNF" --daemonize
  wait_mysql "$REPLICA_SOCKET"
  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e 'START REPLICA;'
  wait_value "$REPLICA_SOCKET" 'SELECT COUNT(*) FROM rep_lab.events' '300'
  echo '[REPLICA RESTART PERSISTENCE]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SELECT CHANNEL_NAME,SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status;"

  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e 'STOP REPLICA;'
  "$MYSQL" --no-defaults -uroot -S "$SOURCE_SOCKET" -e \
    "INSERT INTO rep_lab.events(id,payload) VALUES(301,'purged-before-fetch'); FLUSH BINARY LOGS;"
  current_binlog=$("$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    'SHOW BINARY LOG STATUS' | awk '{print $1}')
  "$MYSQL" --no-defaults -uroot -S "$SOURCE_SOCKET" -e \
    "PURGE BINARY LOGS TO '$current_binlog';"
  "$MYSQL" --no-defaults -uroot -S "$REPLICA_SOCKET" -e 'START REPLICA;'
  for _ in $(seq 1 120); do
    io_error=$("$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
      'SELECT LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status')
    [[ "$io_error" != '0' ]] && break
    sleep 0.25
  done
  echo '[AUTO-POSITION REQUIRED GTID WAS PURGED]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$SOURCE_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SHOW BINARY LOGS;"
  "$MYSQL" --no-defaults -N -B -uroot -S "$REPLICA_SOCKET" -e \
    "SELECT COUNT(*),@@GLOBAL.gtid_executed FROM rep_lab.events; SELECT CHANNEL_NAME,SERVICE_STATE,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE FROM performance_schema.replication_connection_status;"
} > "$OUTPUT" 2>&1

echo "completed: $OUTPUT"
