#!/usr/bin/env bash
set -euo pipefail

PG_BASE=/usr/local/pgsql/pgsql18.4
LAB_DATA=/data/pgdata/pg-crash-redo001
LAB_PORT=54185

if sudo test -e "$LAB_DATA"; then
  printf 'STOP: dedicated target already exists: %s\n' "$LAB_DATA" >&2
  exit 2
fi

sudo -u postgres "$PG_BASE/bin/initdb" -D "$LAB_DATA" --no-locale --encoding=UTF8 --auth-local=trust --auth-host=trust >/dev/null
sudo -u postgres "$PG_BASE/bin/pg_ctl" -D "$LAB_DATA" -l "$LAB_DATA/server.log" \
  -o "-p $LAB_PORT -c listen_addresses=127.0.0.1 -c shared_buffers=32MB -c synchronous_commit=on" start >/dev/null
PSQL=("$PG_BASE/bin/psql" -X -U postgres -d postgres -h 127.0.0.1 -p "$LAB_PORT" --set ON_ERROR_STOP=1)

"${PSQL[@]}" <<'SQL'
SELECT version(), current_setting('port'), current_setting('synchronous_commit');
CREATE TABLE t_recovery(id int PRIMARY KEY, state text NOT NULL, payload text NOT NULL);
INSERT INTO t_recovery VALUES (1,'baseline-before-checkpoint','baseline');
CHECKPOINT;
SQL

printf '%s\n' 'BASELINE CHECKPOINT:'
sudo -u postgres "$PG_BASE/bin/pg_controldata" "$LAB_DATA" | grep -E 'Latest checkpoint location|Latest checkpoint.s REDO location|Database cluster state'
"${PSQL[@]}" -c "INSERT INTO t_recovery SELECT g,'committed-after-checkpoint',repeat('C',2600) FROM generate_series(1000,3999) g;"
printf '%s\n' 'COMMITTED PATH STATE BEFORE OPEN TRANSACTION:'
"${PSQL[@]}" -c "SELECT count(*) committed_rows, pg_current_wal_insert_lsn() insert_lsn, pg_current_wal_flush_lsn() flush_lsn FROM t_recovery;"

"${PSQL[@]}" <<'SQL' >/tmp/pg-crash-redo001-t1.out 2>&1 &
BEGIN;
INSERT INTO t_recovery SELECT g,'uncommitted-at-crash',repeat('U',2600) FROM generate_series(10000,10999) g;
SELECT count(*) rows_visible_inside_t1 FROM t_recovery;
SELECT pg_advisory_lock(11001);
SELECT pg_sleep(300);
SQL
t1_pid=$!
for attempt in $(seq 1 80); do
  lock_ready="$("${PSQL[@]}" -Atc "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=11001 AND granted")"
  [[ "$lock_ready" == "1" ]] && break
  sleep 0.1
done
[[ "$lock_ready" == "1" ]] || { echo 'STOP: T1 did not reach synchronization point'; exit 3; }

printf '%s\n' 'OUTSIDE BEFORE CRASH:'
"${PSQL[@]}" -c "SELECT count(*) outside_rows, count(*) FILTER (WHERE state='uncommitted-at-crash') outside_uncommitted, pg_current_wal_insert_lsn() insert_lsn, pg_current_wal_flush_lsn() flush_lsn FROM t_recovery;"
postmaster_pid="$(sudo head -1 "$LAB_DATA/postmaster.pid")"
printf 'KILL -9 dedicated postmaster pid=%s datadir=%s\n' "$postmaster_pid" "$LAB_DATA"
sudo kill -9 "$postmaster_pid"
wait "$t1_pid" 2>/dev/null || true
sleep 1
sudo pkill -u postgres -f "$LAB_DATA" 2>/dev/null || true
sudo find "$LAB_DATA" -maxdepth 1 -type f -name 'postmaster.pid' -delete

sudo -u postgres "$PG_BASE/bin/pg_ctl" -D "$LAB_DATA" -l "$LAB_DATA/server.log" \
  -o "-p $LAB_PORT -c listen_addresses=127.0.0.1 -c shared_buffers=32MB -c synchronous_commit=on" start >/dev/null
printf '%s\n' 'AFTER CRASH RECOVERY:'
"${PSQL[@]}" -c "SELECT count(*) recovered_rows, count(*) FILTER (WHERE state='uncommitted-at-crash') recovered_uncommitted, min(id),max(id) FROM t_recovery;"
"${PSQL[@]}" -c 'SELECT pg_relation_size('"'"'t_recovery'"'"') relation_bytes, pg_current_wal_insert_lsn(), pg_current_wal_flush_lsn();'
printf '%s\n' 'RECOVERY LOG EXCERPT:'
sudo grep -E 'database system was interrupted|redo starts at|redo done at|database system is ready to accept connections' "$LAB_DATA/server.log" || true

sudo -u postgres "$PG_BASE/bin/pg_ctl" -D "$LAB_DATA" stop -m fast >/dev/null
printf 'CLEAN SHUTDOWN COMPLETE; dedicated datadir retained for evidence cleanup: %s\n' "$LAB_DATA"
