#!/usr/bin/env bash
set -euo pipefail

MYSQL=(mysql -uroot -S /tmp/mysql.sock --batch --skip-column-names)
original_redo="$(${MYSQL[@]} -e "SELECT @@GLOBAL.innodb_flush_log_at_trx_commit")"
original_binlog="$(${MYSQL[@]} -e "SELECT @@GLOBAL.sync_binlog")"

restore() {
  "${MYSQL[@]}" -e "SET GLOBAL innodb_flush_log_at_trx_commit=${original_redo}; SET GLOBAL sync_binlog=${original_binlog}; DROP DATABASE IF EXISTS mysql_lab_redo_log;"
}
trap restore EXIT

"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS mysql_lab_redo_log; CREATE DATABASE mysql_lab_redo_log; CREATE TABLE mysql_lab_redo_log.t_commit(id BIGINT PRIMARY KEY AUTO_INCREMENT, payload VARCHAR(100) NOT NULL) ENGINE=InnoDB;"

printf 'version=%s original_redo=%s original_sync_binlog=%s\n' \
  "$("${MYSQL[@]}" -e 'SELECT VERSION()')" "$original_redo" "$original_binlog"

for pair in '1 1' '1 0' '2 1' '2 0' '0 1' '0 0'; do
  read -r redo binlog <<<"$pair"
  "${MYSQL[@]}" -e "SET GLOBAL innodb_flush_log_at_trx_commit=${redo}; SET GLOBAL sync_binlog=${binlog};"
  before_fsync="$(${MYSQL[@]} -e "SHOW GLOBAL STATUS LIKE 'Innodb_os_log_fsyncs'" | awk '{print $2}')"
  before_pos="$(${MYSQL[@]} -e 'SHOW BINARY LOG STATUS' | awk '{print $2}')"
  start_ns="$(date +%s%N)"
  for n in $(seq 1 100); do
    "${MYSQL[@]}" -e "INSERT INTO mysql_lab_redo_log.t_commit(payload) VALUES('redo=${redo},binlog=${binlog},n=${n}')"
  done
  end_ns="$(date +%s%N)"
  after_fsync="$(${MYSQL[@]} -e "SHOW GLOBAL STATUS LIKE 'Innodb_os_log_fsyncs'" | awk '{print $2}')"
  after_pos="$(${MYSQL[@]} -e 'SHOW BINARY LOG STATUS' | awk '{print $2}')"
  elapsed_ms="$(( (end_ns - start_ns) / 1000000 ))"
  printf 'redo=%s sync_binlog=%s commits=100 elapsed_ms=%s innodb_log_fsync_delta=%s binlog_bytes_delta=%s rows=%s\n' \
    "$redo" "$binlog" "$elapsed_ms" "$((after_fsync-before_fsync))" "$((after_pos-before_pos))" \
    "$("${MYSQL[@]}" -e 'SELECT COUNT(*) FROM mysql_lab_redo_log.t_commit')"
done

printf 'before_restore redo=%s sync_binlog=%s\n' \
  "$("${MYSQL[@]}" -e 'SELECT @@GLOBAL.innodb_flush_log_at_trx_commit')" \
  "$("${MYSQL[@]}" -e 'SELECT @@GLOBAL.sync_binlog')"
