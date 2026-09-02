#!/usr/bin/env bash
set -euo pipefail

MYSQL_BASE=/usr/local/mysql/mysql-8.4.10
EVIDENCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_CNF="$EVIDENCE_DIR/mysql-xtrabackup-source.cnf"
RESTORE_CNF="$EVIDENCE_DIR/mysql-xtrabackup-incremental-restore.cnf"
SOURCE_DATA=/data/myhome/mydata/mysql-bak-plan12-source
RESTORE_DATA=/data/myhome/mydata/mysql-bak-plan12-inc-restore
BACKUP_ROOT=/data/myhome/mybackup/mysql-bak-plan12
BASE_BACKUP="$BACKUP_ROOT/incremental-base"
INC1_BACKUP="$BACKUP_ROOT/incremental-1"
SOURCE_SOCKET=/tmp/mysql-bak-plan12-source.sock
RESTORE_SOCKET=/tmp/mysql-bak-plan12-inc-restore.sock
OUTPUT="$EVIDENCE_DIR/mysql-xtrabackup-incremental-pitr-output.txt"
BASE_LOG="$EVIDENCE_DIR/mysql-xtrabackup-incremental-base.log"
INC1_LOG="$EVIDENCE_DIR/mysql-xtrabackup-incremental-1.log"
PREPARE_LOG="$EVIDENCE_DIR/mysql-xtrabackup-incremental-prepare.log"
COPYBACK_LOG="$EVIDENCE_DIR/mysql-xtrabackup-incremental-copyback.log"
REPLAY_SQL="$BACKUP_ROOT/pitr-replay.sql"
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

[[ -d "$SOURCE_DATA/mysql" ]] || { echo "STOP: full-lab source datadir is missing: $SOURCE_DATA"; exit 3; }
[[ ! -S "$SOURCE_SOCKET" ]] || { echo "STOP: source instance is already running: $SOURCE_SOCKET"; exit 3; }
for target in "$RESTORE_DATA" "$BASE_BACKUP" "$INC1_BACKUP"; do
  [[ ! -e "$target" ]] || { echo "STOP: dedicated target already exists: $target"; exit 3; }
done
mkdir -p "$RESTORE_DATA"

"$MYSQL_BASE/bin/mysqld" --defaults-file="$SOURCE_CNF" --daemonize
wait_ready "$SOURCE_SOCKET"
{
  printf '%s\n' '[SOURCE AT INCREMENTAL BASE START]'
  "${MYSQL[@]}" -e "SELECT COUNT(*) source_rows,MIN(id),MAX(id) FROM backup_lab.t_pitr; SHOW BINARY LOG STATUS; SHOW GLOBAL STATUS LIKE 'Innodb_redo_log_current_lsn';"
} >"$OUTPUT"

xtrabackup --defaults-file="$SOURCE_CNF" --backup \
  --target-dir="$BASE_BACKUP" \
  --user=backup_operator --password=plan12-local-only \
  --socket="$SOURCE_SOCKET" --no-server-version-check --parallel=1 \
  >"$BASE_LOG" 2>&1

"${MYSQL[@]}" -e "CALL backup_lab.fill_rows(20001,1000,'in-incremental-1',0);"
xtrabackup --defaults-file="$SOURCE_CNF" --backup \
  --target-dir="$INC1_BACKUP" \
  --incremental-basedir="$BASE_BACKUP" \
  --user=backup_operator --password=plan12-local-only \
  --socket="$SOURCE_SOCKET" --no-server-version-check --parallel=1 \
  >"$INC1_LOG" 2>&1

inc_binlog_file="$(awk 'NR==1 {print $1}' "$INC1_BACKUP/xtrabackup_binlog_info")"
inc_binlog_pos="$(awk 'NR==1 {print $2}' "$INC1_BACKUP/xtrabackup_binlog_info")"
inc_gtid_set="$(awk 'NR==1 {print $3}' "$INC1_BACKUP/xtrabackup_binlog_info")"

# These are the transactions we want to retain with PITR.
"${MYSQL[@]}" -e "CALL backup_lab.fill_rows(30001,1000,'after-incremental-good',0);"
read -r stop_file stop_pos < <("${MYSQL[@]}" --skip-column-names -e "SHOW BINARY LOG STATUS" | awk 'NR==1 {print $1,$2}')
[[ "$stop_file" == "$inc_binlog_file" ]] || {
  printf 'STOP: lab expected one binlog file, start=%s stop=%s\n' "$inc_binlog_file" "$stop_file" >&2
  exit 4
}

# Disaster transaction: the desired PITR target is the position immediately before it.
"${MYSQL[@]}" -e "DELETE FROM backup_lab.t_pitr; SELECT ROW_COUNT() deleted_rows;"
{
  printf '%s\n' '[BACKUP CHAIN METADATA]'
  printf 'base checkpoints:\n'; sed -n '1,20p' "$BASE_BACKUP/xtrabackup_checkpoints"
  printf 'incremental checkpoints:\n'; sed -n '1,20p' "$INC1_BACKUP/xtrabackup_checkpoints"
  printf 'incremental binlog boundary: file=%s position=%s gtid=%s\n' "$inc_binlog_file" "$inc_binlog_pos" "$inc_gtid_set"
  printf 'PITR stop before DELETE: file=%s position=%s\n' "$stop_file" "$stop_pos"
  printf '%s\n' '[SOURCE AFTER DISASTER]'
  "${MYSQL[@]}" -e "SELECT COUNT(*) source_rows_after_delete FROM backup_lab.t_pitr; SHOW BINARY LOG STATUS;"
} >>"$OUTPUT"

# Incremental merge order: base apply-log-only, then final increment without it.
xtrabackup --prepare --apply-log-only --target-dir="$BASE_BACKUP" --parallel=1 \
  >"$PREPARE_LOG" 2>&1
xtrabackup --prepare --target-dir="$BASE_BACKUP" --incremental-dir="$INC1_BACKUP" --parallel=1 \
  >>"$PREPARE_LOG" 2>&1

xtrabackup --copy-back --datadir="$RESTORE_DATA" --target-dir="$BASE_BACKUP" \
  >"$COPYBACK_LOG" 2>&1
"$MYSQL_BASE/bin/mysqld" --defaults-file="$RESTORE_CNF" --daemonize
wait_ready "$RESTORE_SOCKET"
{
  printf '%s\n' '[RESTORED INCREMENTAL CHAIN BEFORE BINLOG]'
  "$MYSQL_BASE/bin/mysql" -uroot --batch --socket="$RESTORE_SOCKET" -e \
    "SELECT COUNT(*) restored_rows,SUM(phase='in-incremental-1') incremental_rows,SUM(phase='after-incremental-good') post_backup_rows FROM backup_lab.t_pitr; SELECT @@GLOBAL.gtid_executed;"
} >>"$OUTPUT"

"$MYSQL_BASE/bin/mysqlbinlog" \
  --start-position="$inc_binlog_pos" \
  --stop-position="$stop_pos" \
  "$SOURCE_DATA/$inc_binlog_file" >"$REPLAY_SQL"
"$MYSQL_BASE/bin/mysql" -uroot --socket="$RESTORE_SOCKET" <"$REPLAY_SQL"
{
  printf '%s\n' '[RESTORED INSTANCE AFTER BINLOG PITR]'
  "$MYSQL_BASE/bin/mysql" -uroot --batch --socket="$RESTORE_SOCKET" -e \
    "SELECT COUNT(*) recovered_rows,SUM(phase='in-incremental-1') incremental_rows,SUM(phase='after-incremental-good') recovered_post_backup_rows FROM backup_lab.t_pitr; SELECT @@GLOBAL.gtid_executed; CHECKSUM TABLE backup_lab.t_pitr;"
  grep -E 'completed OK|Shutdown completed' "$PREPARE_LOG" || true
  grep -E 'completed OK' "$COPYBACK_LOG" || true
} >>"$OUTPUT"

stop_restore
stop_source
trap - EXIT
printf 'CLEAN SHUTDOWN COMPLETE; audit directories retained:\n%s\n%s\n%s\n' \
  "$BASE_BACKUP" "$INC1_BACKUP" "$RESTORE_DATA" >>"$OUTPUT"
