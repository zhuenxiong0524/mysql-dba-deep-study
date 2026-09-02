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
  state VARCHAR(40) NOT NULL,
  payload VARCHAR(4000) NOT NULL
) ENGINE=InnoDB;
DELIMITER //
CREATE PROCEDURE crash_lab.fill_rows(IN first_id INT, IN row_count INT, IN row_state VARCHAR(40))
BEGIN
  DECLARE n INT DEFAULT 0;
  WHILE n < row_count DO
    INSERT INTO crash_lab.t_recovery VALUES(first_id+n,row_state,REPEAT(row_state,100));
    SET n=n+1;
  END WHILE;
END//
DELIMITER ;
INSERT INTO crash_lab.t_recovery VALUES (1,'baseline-before-checkpoint','baseline');
SQL

"${MYSQL[@]}" -e 'SET GLOBAL innodb_max_dirty_pages_pct=0;'
for attempt in $(seq 1 80); do
  dirty_pages="$("${MYSQL[@]}" --skip-column-names -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_dirty'" | awk '{print $2}')"
  [[ "$dirty_pages" == "0" ]] && break
  sleep 0.25
done
printf '%s\n' 'BASELINE AFTER FORCED DIRTY-PAGE DRAIN:'
"${MYSQL[@]}" -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_redo_log_current_lsn','Innodb_redo_log_flushed_to_disk_lsn','Innodb_redo_log_checkpoint_lsn','Innodb_buffer_pool_pages_dirty');"
"${MYSQL[@]}" -e 'SET GLOBAL innodb_max_dirty_pages_pct=100; START TRANSACTION; CALL crash_lab.fill_rows(1000,3000,"committed-after-checkpoint"); COMMIT;'
printf '%s\n' 'COMMITTED PATH STATE BEFORE OPEN TRANSACTION:'
"${MYSQL[@]}" -e "SELECT COUNT(*) committed_rows FROM crash_lab.t_recovery; SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_redo_log_current_lsn','Innodb_redo_log_flushed_to_disk_lsn','Innodb_redo_log_checkpoint_lsn','Innodb_buffer_pool_pages_dirty');"

"${MYSQL[@]}" <<'SQL' >/tmp/mysql-crash-redo001-t1.out 2>&1 &
START TRANSACTION;
CALL crash_lab.fill_rows(10000,1000,'uncommitted-at-crash');
SELECT COUNT(*) rows_visible_inside_t1 FROM crash_lab.t_recovery;
SELECT GET_LOCK('redo001_t1_ready',0);
SELECT SLEEP(300);
SQL
t1_pid=$!
for attempt in $(seq 1 80); do
  lock_owner="$("${MYSQL[@]}" --skip-column-names -e "SELECT COALESCE(IS_USED_LOCK('redo001_t1_ready'),0)")"
  [[ "$lock_owner" != "0" ]] && break
  sleep 0.1
done
[[ "$lock_owner" != "0" ]] || { echo 'STOP: T1 did not reach synchronization point'; exit 3; }

printf '%s\n' 'OUTSIDE BEFORE CRASH:'
"${MYSQL[@]}" -e "SELECT COUNT(*) outside_rows, SUM(state='uncommitted-at-crash') outside_uncommitted FROM crash_lab.t_recovery; SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_redo_log_current_lsn','Innodb_redo_log_flushed_to_disk_lsn','Innodb_redo_log_checkpoint_lsn','Innodb_buffer_pool_pages_dirty');"
server_pid="$(<"$LAB_DATA/mysqld.pid")"
printf 'KILL -9 dedicated mysqld pid=%s datadir=%s\n' "$server_pid" "$LAB_DATA"
kill -9 "$server_pid"
wait "$t1_pid" 2>/dev/null || true
find "$LAB_DATA" -maxdepth 1 -type f -name 'mysqld.pid' -delete

"$MYSQL_BASE/bin/mysqld" --defaults-file="$LAB_CNF" --daemonize
for attempt in $(seq 1 60); do
  [[ -S "$LAB_SOCKET" ]] && "${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1 && break
  sleep 0.25
done

printf '%s\n' 'AFTER CRASH RECOVERY:'
"${MYSQL[@]}" -e "SELECT COUNT(*) recovered_rows, SUM(state='uncommitted-at-crash') recovered_uncommitted FROM crash_lab.t_recovery; SELECT MIN(id),MAX(id) FROM crash_lab.t_recovery; CHECK TABLE crash_lab.t_recovery; SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_redo_log_current_lsn','Innodb_redo_log_flushed_to_disk_lsn','Innodb_redo_log_checkpoint_lsn'); SHOW BINARY LOG STATUS;"
printf '%s\n' 'RECOVERY LOG EXCERPT:'
grep -Ei 'checkpoint|log sequence|crash recovery|recovery|rolling back|rollback|ready for connections' "$LAB_DATA/error.log" || true

"$MYSQL_BASE/bin/mysqladmin" -uroot -S "$LAB_SOCKET" shutdown
trap - EXIT
printf 'CLEAN SHUTDOWN COMPLETE; dedicated datadir retained for evidence cleanup: %s\n' "$LAB_DATA"
