#!/usr/bin/env bash
set -euo pipefail

MYSQL_BASE=/usr/local/mysql/mysql-8.4.10
TOPIC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE_DIR="$TOPIC_DIR/evidence"
SOURCE_CNF="$EVIDENCE_DIR/mysql-xtrabackup-source.cnf"
RESTORE_CNF="$EVIDENCE_DIR/mysql-xtrabackup-restore.cnf"
SOURCE_DATA=/data/myhome/mydata/mysql-bak-plan12-source
RESTORE_DATA=/data/myhome/mydata/mysql-bak-plan12-restore
BACKUP_ROOT=/data/myhome/mybackup/mysql-bak-plan12
FULL_BACKUP="$BACKUP_ROOT/full"
SOURCE_SOCKET=/tmp/mysql-bak-plan12-source.sock
RESTORE_SOCKET=/tmp/mysql-bak-plan12-restore.sock
SOURCE_OUT="$EVIDENCE_DIR/mysql-xtrabackup-full-output.txt"
BACKUP_LOG="$EVIDENCE_DIR/mysql-xtrabackup-backup.log"
PREPARE_LOG="$EVIDENCE_DIR/mysql-xtrabackup-prepare.log"
COPYBACK_LOG="$EVIDENCE_DIR/mysql-xtrabackup-copyback.log"
MYSQL=("$MYSQL_BASE/bin/mysql" -uroot --batch --socket="$SOURCE_SOCKET")

if [[ "$(id -un)" != "mysql" ]]; then
  echo 'STOP: run this dedicated lab as OS user mysql' >&2
  exit 2
fi

stop_source() {
  if [[ -S "$SOURCE_SOCKET" ]]; then
    "$MYSQL_BASE/bin/mysqladmin" -uroot --socket="$SOURCE_SOCKET" shutdown >/dev/null 2>&1 || true
  fi
}

stop_restore() {
  if [[ -S "$RESTORE_SOCKET" ]]; then
    "$MYSQL_BASE/bin/mysqladmin" -uroot --socket="$RESTORE_SOCKET" shutdown >/dev/null 2>&1 || true
  fi
}

wait_ready() {
  local socket=$1
  for attempt in $(seq 1 120); do
    if [[ -S "$socket" ]] && "$MYSQL_BASE/bin/mysql" -uroot --socket="$socket" -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

trap 'stop_restore; stop_source' EXIT

# Safety stop: never overwrite or merge with an existing lab/backup directory.
for target in "$SOURCE_DATA" "$RESTORE_DATA" "$BACKUP_ROOT"; do
  if [[ -e "$target" ]]; then
    printf 'STOP: dedicated target already exists: %s\n' "$target" >&2
    exit 2
  fi
done

mkdir -p "$SOURCE_DATA" "$RESTORE_DATA" "$BACKUP_ROOT"
"$MYSQL_BASE/bin/mysqld" --defaults-file="$SOURCE_CNF" --initialize-insecure
"$MYSQL_BASE/bin/mysqld" --defaults-file="$SOURCE_CNF" --daemonize
wait_ready "$SOURCE_SOCKET"

"${MYSQL[@]}" <<'SQL'
SELECT VERSION() version,@@port port,@@log_bin log_bin,@@gtid_mode gtid_mode;
CREATE DATABASE backup_lab;
CREATE TABLE backup_lab.t_pitr(
  id INT PRIMARY KEY,
  phase VARCHAR(32) NOT NULL,
  payload VARCHAR(2000) NOT NULL
) ENGINE=InnoDB;
DELIMITER //
CREATE PROCEDURE backup_lab.fill_rows(
  IN first_id INT, IN row_count INT, IN row_phase VARCHAR(32), IN delay_seconds DECIMAL(6,4)
)
BEGIN
  DECLARE n INT DEFAULT 0;
  WHILE n < row_count DO
    INSERT INTO backup_lab.t_pitr VALUES(first_id+n,row_phase,REPEAT(row_phase,60));
    IF delay_seconds > 0 THEN
      DO SLEEP(delay_seconds);
    END IF;
    SET n=n+1;
  END WHILE;
END//
DELIMITER ;
CALL backup_lab.fill_rows(1,2000,'before-full-backup',0);
CREATE USER 'backup_operator'@'localhost' IDENTIFIED BY 'plan12-local-only';
GRANT SELECT, BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT
  ON *.* TO 'backup_operator'@'localhost';
SQL

{
  printf '%s\n' '[SOURCE BEFORE ONLINE BACKUP]'
  "${MYSQL[@]}" -e "SELECT COUNT(*) rows_before,MIN(id),MAX(id) FROM backup_lab.t_pitr; SHOW BINARY LOG STATUS; SHOW GLOBAL STATUS LIKE 'Innodb_redo_log_current_lsn';"
} >"$SOURCE_OUT"

# T1 continues committing rows while xtrabackup copies physical files.
"${MYSQL[@]}" -e "CALL backup_lab.fill_rows(10001,3000,'during-full-backup',0.002);" \
  >"$EVIDENCE_DIR/mysql-xtrabackup-writer.txt" 2>&1 &
writer_pid=$!
for attempt in $(seq 1 100); do
  during_count="$("${MYSQL[@]}" --skip-column-names -e "SELECT COUNT(*) FROM backup_lab.t_pitr WHERE phase='during-full-backup'")"
  (( during_count >= 25 )) && break
  sleep 0.05
done
printf 'writer_rows_when_backup_started=%s\n' "$during_count" >>"$SOURCE_OUT"

# PXB 8.4.0-6 supports the 8.4 series. Its numeric base version is lower than
# upstream 8.4.10, so the generic "source newer than tool" guard must be disabled.
xtrabackup --defaults-file="$SOURCE_CNF" \
  --backup \
  --target-dir="$FULL_BACKUP" \
  --user=backup_operator \
  --password=plan12-local-only \
  --socket="$SOURCE_SOCKET" \
  --no-server-version-check \
  --parallel=1 >"$BACKUP_LOG" 2>&1

wait "$writer_pid"
{
  printf '%s\n' '[SOURCE AFTER BACKUP AND WRITER COMPLETION]'
  "${MYSQL[@]}" -e "SELECT COUNT(*) source_rows,SUM(phase='during-full-backup') concurrent_rows FROM backup_lab.t_pitr; SHOW BINARY LOG STATUS; SHOW GLOBAL STATUS LIKE 'Innodb_redo_log_current_lsn';"
  printf '%s\n' '[BACKUP METADATA BEFORE PREPARE]'
  sed -n '1,80p' "$FULL_BACKUP/xtrabackup_checkpoints"
  sed -n '1,80p' "$FULL_BACKUP/xtrabackup_binlog_info"
  grep -E 'log scanned up to|Transaction log of lsn|completed OK' "$BACKUP_LOG" || true
} >>"$SOURCE_OUT"

xtrabackup --prepare --target-dir="$FULL_BACKUP" --parallel=1 \
  >"$PREPARE_LOG" 2>&1
{
  printf '%s\n' '[BACKUP METADATA AFTER PREPARE]'
  sed -n '1,80p' "$FULL_BACKUP/xtrabackup_checkpoints"
  grep -E 'Starting shutdown|Shutdown completed|completed OK' "$PREPARE_LOG" || true
} >>"$SOURCE_OUT"

# Restore target is an explicit empty dedicated directory. Never omit --datadir.
xtrabackup --copy-back \
  --datadir="$RESTORE_DATA" \
  --target-dir="$FULL_BACKUP" \
  >"$COPYBACK_LOG" 2>&1

"$MYSQL_BASE/bin/mysqld" --defaults-file="$RESTORE_CNF" --daemonize
wait_ready "$RESTORE_SOCKET"
{
  printf '%s\n' '[RESTORED INSTANCE]'
  "$MYSQL_BASE/bin/mysql" -uroot --batch --socket="$RESTORE_SOCKET" -e \
    "SELECT @@port restored_port,COUNT(*) restored_rows,SUM(phase='during-full-backup') restored_concurrent_rows,MIN(id),MAX(id) FROM backup_lab.t_pitr; CHECKSUM TABLE backup_lab.t_pitr; SHOW BINARY LOG STATUS;"
  grep -E 'completed OK' "$COPYBACK_LOG" || true
} >>"$SOURCE_OUT"

stop_restore
stop_source
trap - EXIT
printf 'CLEAN SHUTDOWN COMPLETE; audit directories retained:\n%s\n%s\n%s\n' \
  "$SOURCE_DATA" "$RESTORE_DATA" "$FULL_BACKUP" >>"$SOURCE_OUT"
