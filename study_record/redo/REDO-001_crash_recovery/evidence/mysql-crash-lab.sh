#!/usr/bin/env bash
set -euo pipefail

MYSQL_BASE=/usr/local/mysql/mysql-8.4.10
LAB_DATA=/data/myhome/mydata/mysql-crash-redo001
LAB_CNF="$(cd "$(dirname "$0")" && pwd)/mysql-crash.cnf"
LAB_SOCKET=/tmp/mysql-crash-redo001.sock
MYSQL=("$MYSQL_BASE/bin/mysql" -uroot -S "$LAB_SOCKET" --batch)

stop_if_running() {
  if [[ -S "$LAB_SOCKET" ]]; then
    "$MYSQL_BASE/bin/mysqladmin" -uroot -S "$LAB_SOCKET" shutdown >/dev/null 2>&1 || true
  fi
}
trap stop_if_running EXIT

if [[ -e "$LAB_DATA" ]]; then
  printf 'STOP: dedicated target already exists: %s\n' "$LAB_DATA" >&2
  exit 2
fi

mkdir -p "$LAB_DATA"
"$MYSQL_BASE/bin/mysqld" --defaults-file="$LAB_CNF" --initialize-insecure
"$MYSQL_BASE/bin/mysqld" --defaults-file="$LAB_CNF" --daemonize
for attempt in $(seq 1 60); do
  [[ -S "$LAB_SOCKET" ]] && "${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1 && break
  sleep 0.25
done

"${MYSQL[@]}" <<'SQL'
SELECT VERSION(), @@port, @@innodb_flush_log_at_trx_commit, @@sync_binlog;
CREATE DATABASE crash_lab;
CREATE TABLE crash_lab.t_recovery(
  id INT PRIMARY KEY,
  state VARCHAR(40) NOT NULL
) ENGINE=InnoDB;
INSERT INTO crash_lab.t_recovery VALUES (1,'committed-before-crash');
SQL

"${MYSQL[@]}" <<'SQL' >/tmp/mysql-crash-redo001-t1.out 2>&1 &
START TRANSACTION;
INSERT INTO crash_lab.t_recovery VALUES (2,'uncommitted-at-crash');
SELECT id,state FROM crash_lab.t_recovery ORDER BY id;
SELECT SLEEP(300);
SQL
t1_pid=$!
sleep 1

printf '%s\n' 'OUTSIDE BEFORE CRASH:'
"${MYSQL[@]}" -e 'SELECT id,state FROM crash_lab.t_recovery ORDER BY id;'
server_pid="$(<"$LAB_DATA/mysqld.pid")"
printf 'KILL -9 dedicated mysqld pid=%s datadir=%s\n' "$server_pid" "$LAB_DATA"
kill -9 "$server_pid"
wait "$t1_pid" 2>/dev/null || true
for attempt in $(seq 1 40); do [[ ! -e "$LAB_DATA/mysqld.pid" ]] && break; sleep 0.25; done

"$MYSQL_BASE/bin/mysqld" --defaults-file="$LAB_CNF" --daemonize
for attempt in $(seq 1 60); do
  [[ -S "$LAB_SOCKET" ]] && "${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1 && break
  sleep 0.25
done

printf '%s\n' 'AFTER CRASH RECOVERY:'
"${MYSQL[@]}" -e 'SELECT id,state FROM crash_lab.t_recovery ORDER BY id; CHECK TABLE crash_lab.t_recovery; SHOW BINARY LOG STATUS;'
printf '%s\n' 'RECOVERY LOG EXCERPT:'
grep -E 'Database was not shutdown normally|Starting crash recovery|crash recovery|Rolling back|ready for connections' "$LAB_DATA/error.log" || true

"$MYSQL_BASE/bin/mysqladmin" -uroot -S "$LAB_SOCKET" shutdown
trap - EXIT
printf 'CLEAN SHUTDOWN COMPLETE; dedicated datadir retained for evidence cleanup: %s\n' "$LAB_DATA"
