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
CREATE TABLE t_recovery(id int PRIMARY KEY, state text NOT NULL);
INSERT INTO t_recovery VALUES (1,'committed-before-crash');
CHECKPOINT;
SQL

"${PSQL[@]}" <<'SQL' >/tmp/pg-crash-redo001-t1.out 2>&1 &
BEGIN;
INSERT INTO t_recovery VALUES (2,'uncommitted-at-crash');
SELECT id,state FROM t_recovery ORDER BY id;
SELECT pg_sleep(300);
SQL
t1_pid=$!
sleep 1

printf '%s\n' 'OUTSIDE BEFORE CRASH:'
"${PSQL[@]}" -c 'SELECT id,state FROM t_recovery ORDER BY id;'
postmaster_pid="$(sudo head -1 "$LAB_DATA/postmaster.pid")"
printf 'KILL -9 dedicated postmaster pid=%s datadir=%s\n' "$postmaster_pid" "$LAB_DATA"
sudo kill -9 "$postmaster_pid"
wait "$t1_pid" 2>/dev/null || true
sleep 1
sudo pkill -u postgres -f "$LAB_DATA" 2>/dev/null || true
sudo rm -f "$LAB_DATA/postmaster.pid"

sudo -u postgres "$PG_BASE/bin/pg_ctl" -D "$LAB_DATA" -l "$LAB_DATA/server.log" \
  -o "-p $LAB_PORT -c listen_addresses=127.0.0.1 -c shared_buffers=32MB -c synchronous_commit=on" start >/dev/null
printf '%s\n' 'AFTER CRASH RECOVERY:'
"${PSQL[@]}" -c 'SELECT id,state FROM t_recovery ORDER BY id;'
"${PSQL[@]}" -c 'SELECT pg_relation_size('"'"'t_recovery'"'"') relation_bytes, pg_current_wal_insert_lsn(), pg_current_wal_flush_lsn();'
printf '%s\n' 'RECOVERY LOG EXCERPT:'
sudo grep -E 'database system was interrupted|redo starts at|redo done at|database system is ready to accept connections' "$LAB_DATA/server.log" || true

sudo -u postgres "$PG_BASE/bin/pg_ctl" -D "$LAB_DATA" stop -m fast >/dev/null
printf 'CLEAN SHUTDOWN COMPLETE; dedicated datadir retained for evidence cleanup: %s\n' "$LAB_DATA"
