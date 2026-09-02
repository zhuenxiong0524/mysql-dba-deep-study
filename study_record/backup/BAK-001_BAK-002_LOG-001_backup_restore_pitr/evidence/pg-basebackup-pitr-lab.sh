#!/usr/bin/env bash
set -euo pipefail

PG_BASE=/usr/local/pgsql/pgsql18.4
SOURCE_DATA=/data/pgdata/plan12/source
ARCHIVE_DIR=/data/pgdata/plan12/archive
BASE_BACKUP=/data/pgdata/plan12/base-backup
RESTORE_DATA=/data/pgdata/plan12/restore
SOURCE_PORT=54186
RESTORE_PORT=54187
EVIDENCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$EVIDENCE_DIR/pg-basebackup-pitr-output.txt"
BASEBACKUP_LOG="$EVIDENCE_DIR/pg-basebackup.log"
RESTORE_LOG="$EVIDENCE_DIR/pg-pitr-restore.log"
PSQL=("$PG_BASE/bin/psql" -X -v ON_ERROR_STOP=1 -U mysql -d postgres -h 127.0.0.1 -p "$SOURCE_PORT")

if [[ "$(id -un)" != "mysql" ]]; then
  echo 'STOP: run this dedicated lab as OS user mysql' >&2
  exit 2
fi

stop_source() {
  if [[ -f "$SOURCE_DATA/postmaster.pid" ]]; then
    "$PG_BASE/bin/pg_ctl" -D "$SOURCE_DATA" -m fast stop >/dev/null 2>&1 || true
  fi
}
stop_restore() {
  if [[ -f "$RESTORE_DATA/postmaster.pid" ]]; then
    "$PG_BASE/bin/pg_ctl" -D "$RESTORE_DATA" -m fast stop >/dev/null 2>&1 || true
  fi
}
trap 'stop_restore; stop_source' EXIT

for target in "$SOURCE_DATA" "$ARCHIVE_DIR" "$BASE_BACKUP" "$RESTORE_DATA"; do
  [[ ! -e "$target" ]] || { echo "STOP: dedicated target already exists: $target"; exit 3; }
done
mkdir -p "$SOURCE_DATA" "$ARCHIVE_DIR"
"$PG_BASE/bin/initdb" -D "$SOURCE_DATA" --no-locale --encoding=UTF8 >"$EVIDENCE_DIR/pg-initdb.log"
{
  printf '\nport = %s\n' "$SOURCE_PORT"
  printf 'listen_addresses = %s\n' "'127.0.0.1'"
  printf 'archive_mode = on\n'
  printf "archive_command = 'test ! -f %s/%%f && cp %%p %s/%%f'\n" "$ARCHIVE_DIR" "$ARCHIVE_DIR"
  printf 'wal_level = replica\n'
  printf 'max_wal_senders = 4\n'
  printf 'shared_buffers = 64MB\n'
} >>"$SOURCE_DATA/postgresql.conf"
"$PG_BASE/bin/pg_ctl" -D "$SOURCE_DATA" -l "$SOURCE_DATA/server.log" start >/dev/null

"${PSQL[@]}" <<'SQL'
CREATE TABLE public.t_pitr(
  id integer PRIMARY KEY,
  phase text NOT NULL,
  payload text NOT NULL
);
INSERT INTO public.t_pitr
SELECT g,'before-basebackup',repeat('b',2000)
FROM generate_series(1,5000) AS g;
CHECKPOINT;
SQL
{
  printf '%s\n' '[SOURCE BEFORE BASE BACKUP]'
  "${PSQL[@]}" -Atc "SELECT count(*),min(id),max(id),pg_current_wal_insert_lsn(),pg_current_wal_flush_lsn() FROM public.t_pitr;"
} >"$OUTPUT"

"$PG_BASE/bin/pg_basebackup" \
  -D "$BASE_BACKUP" -F plain -X stream -c fast -P \
  -U mysql -h 127.0.0.1 -p "$SOURCE_PORT" \
  >"$BASEBACKUP_LOG" 2>&1

"${PSQL[@]}" <<'SQL'
INSERT INTO public.t_pitr
SELECT g,'after-basebackup-good',repeat('g',2000)
FROM generate_series(10001,11000) AS g;
SELECT pg_create_restore_point('before_bad_delete');
DELETE FROM public.t_pitr;
SELECT pg_switch_wal();
SQL

for attempt in $(seq 1 120); do
  failed_count="$("${PSQL[@]}" -Atc 'SELECT failed_count FROM pg_stat_archiver')"
  [[ "$failed_count" == "0" ]] || { echo "STOP: archive failure count=$failed_count"; exit 4; }
  archived_count="$("${PSQL[@]}" -Atc 'SELECT archived_count FROM pg_stat_archiver')"
  (( archived_count >= 1 )) && break
  sleep 0.25
done
{
  printf '%s\n' '[SOURCE AFTER DISASTER]'
  "${PSQL[@]}" -Atc "SELECT count(*),pg_current_wal_insert_lsn(),pg_current_wal_flush_lsn() FROM public.t_pitr;"
  "${PSQL[@]}" -x -c 'SELECT archived_count,last_archived_wal,failed_count,last_failed_wal FROM pg_stat_archiver;'
  printf 'archive_files=%s\n' "$(find "$ARCHIVE_DIR" -maxdepth 1 -type f | wc -l)"
  printf '%s\n' '[BASE BACKUP MANIFEST]'
  "$PG_BASE/bin/pg_verifybackup" "$BASE_BACKUP"
} >>"$OUTPUT"

stop_source
cp -a "$BASE_BACKUP" "$RESTORE_DATA"
{
  printf "restore_command = 'cp %s/%%f %%p'\n" "$ARCHIVE_DIR"
  printf "recovery_target_name = 'before_bad_delete'\n"
  printf "recovery_target_action = 'promote'\n"
} >>"$RESTORE_DATA/postgresql.auto.conf"
touch "$RESTORE_DATA/recovery.signal"
"$PG_BASE/bin/pg_ctl" -D "$RESTORE_DATA" -l "$RESTORE_LOG" \
  -o "-p $RESTORE_PORT" start >/dev/null
for attempt in $(seq 1 120); do
  if "$PG_BASE/bin/psql" -X -U mysql -d postgres -h 127.0.0.1 -p "$RESTORE_PORT" -Atc 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
{
  printf '%s\n' '[RESTORED INSTANCE AT NAMED TARGET]'
  "$PG_BASE/bin/psql" -X -U mysql -d postgres -h 127.0.0.1 -p "$RESTORE_PORT" -Atc \
    "SELECT count(*),sum((phase='after-basebackup-good')::int),min(id),max(id),pg_is_in_recovery() FROM public.t_pitr;"
  grep -E 'starting point-in-time recovery|restored log file|recovery stopping at restore point|redo starts|redo done|selected new timeline|ready to accept' "$RESTORE_LOG" || true
} >>"$OUTPUT"

stop_restore
trap - EXIT
printf 'CLEAN SHUTDOWN COMPLETE; audit directories retained:\n%s\n%s\n%s\n%s\n' \
  "$SOURCE_DATA" "$ARCHIVE_DIR" "$BASE_BACKUP" "$RESTORE_DATA" >>"$OUTPUT"
