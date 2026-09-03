#!/usr/bin/env bash
set -euo pipefail

PGHOME=/usr/local/pgsql/pgsql18.4
INITDB="$PGHOME/bin/initdb"
PG_CTL="$PGHOME/bin/pg_ctl"
PSQL="$PGHOME/bin/psql"
PG_BASEBACKUP="$PGHOME/bin/pg_basebackup"
PRIMARY_DIR=/data/pgdata/rep14-primary
STANDBY_DIR=/data/pgdata/rep14-standby
PRIMARY_PORT=54341
STANDBY_PORT=54342
OUTPUT=${1:-pg-replication-failure-output.txt}

cleanup_processes() {
  "$PG_CTL" -D "$STANDBY_DIR" -m fast stop >/dev/null 2>&1 || true
  "$PG_CTL" -D "$PRIMARY_DIR" -m fast stop >/dev/null 2>&1 || true
}
trap cleanup_processes EXIT

wait_psql() {
  local port=$1
  for _ in $(seq 1 120); do
    "$PSQL" -X -qAt -h /tmp -p "$port" -U mysql -d postgres \
      -c 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

wait_value() {
  local port=$1 db=$2 sql=$3 expected=$4
  for _ in $(seq 1 120); do
    value=$("$PSQL" -X -qAt -h /tmp -p "$port" -U mysql -d "$db" \
      -c "$sql" 2>/dev/null || true)
    [[ "$value" == "$expected" ]] && return 0
    sleep 0.25
  done
  echo "timeout: expected $expected, got ${value:-<empty>}" >&2
  return 1
}

cleanup_processes
for dir in "$PRIMARY_DIR" "$STANDBY_DIR"; do
  if [[ -e "$dir" ]]; then
    echo "refusing to overwrite existing directory: $dir" >&2
    exit 1
  fi
done
sudo install -d -o mysql -g mysql -m 0700 "$PRIMARY_DIR" "$STANDBY_DIR"

"$INITDB" -D "$PRIMARY_DIR" -U mysql --auth-local=trust --auth-host=scram-sha-256 \
  > /tmp/pg-rep14-primary-init.log 2>&1
printf '%s\n' \
  "port=$PRIMARY_PORT" "listen_addresses='127.0.0.1'" \
  "unix_socket_directories='/tmp'" 'wal_level=replica' 'max_wal_senders=5' \
  'max_replication_slots=5' 'hot_standby=on' 'shared_buffers=32MB' \
  >> "$PRIMARY_DIR/postgresql.conf"
printf '%s\n' \
  'host replication repl 127.0.0.1/32 scram-sha-256' \
  >> "$PRIMARY_DIR/pg_hba.conf"
"$PG_CTL" -D "$PRIMARY_DIR" -l "$PRIMARY_DIR/server.log" start >/dev/null
wait_psql "$PRIMARY_PORT"

{
  echo '[SETUP]'
  "$PSQL" -X -v ON_ERROR_STOP=1 -h /tmp -p "$PRIMARY_PORT" -U mysql -d postgres <<'SQL'
CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD 'rep14-local-only';
CREATE DATABASE rep_lab;
SQL
  "$PSQL" -X -v ON_ERROR_STOP=1 -h /tmp -p "$PRIMARY_PORT" -U mysql -d rep_lab <<'SQL'
CREATE TABLE events(id bigint PRIMARY KEY,payload text NOT NULL);
INSERT INTO events SELECT n,'seed-'||n FROM generate_series(1,100) AS n;
SQL
  PGPASSWORD=rep14-local-only "$PG_BASEBACKUP" \
    -h 127.0.0.1 -p "$PRIMARY_PORT" -U repl -D "$STANDBY_DIR" \
    -R -X stream -C -S rep14_slot --checkpoint=fast
  printf '%s\n' "port=$STANDBY_PORT" "unix_socket_directories='/tmp'" \
    'hot_standby=on' 'shared_buffers=32MB' >> "$STANDBY_DIR/postgresql.auto.conf"
  "$PG_CTL" -D "$STANDBY_DIR" -l "$STANDBY_DIR/server.log" start >/dev/null
  wait_psql "$STANDBY_PORT"
  wait_value "$STANDBY_PORT" rep_lab 'SELECT count(*) FROM events' '100'
  echo '[HEALTHY BASELINE]'
  "$PSQL" -X -qAt -h /tmp -p "$PRIMARY_PORT" -U mysql -d postgres \
    -c 'SELECT application_name,state,sync_state,sent_lsn,write_lsn,flush_lsn,replay_lsn FROM pg_stat_replication;'
  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d rep_lab \
    -c 'SELECT count(*),pg_is_in_recovery(),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn() FROM events;'

  echo '[STANDBY LOCAL DIVERGENCE ATTEMPT]'
  set +e
  "$PSQL" -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
    -h /tmp -p "$STANDBY_PORT" -U mysql -d rep_lab \
    -c "INSERT INTO events VALUES(1000,'standby-local-divergence');"
  readonly_rc=$?
  set -e
  echo "standby_write_exit_code=$readonly_rc"

  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d postgres \
    -c 'SELECT pg_wal_replay_pause();'
  "$PSQL" -X -v ON_ERROR_STOP=1 -h /tmp -p "$PRIMARY_PORT" -U mysql -d rep_lab \
    -c "INSERT INTO events SELECT n,'lag-'||n FROM generate_series(101,150) AS n;"
  "$PSQL" -X -qAt -h /tmp -p "$PRIMARY_PORT" -U mysql -d postgres \
    -c 'SELECT pg_switch_wal();' >/dev/null
  wait_value "$STANDBY_PORT" postgres \
    "SELECT (pg_wal_lsn_diff(pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn())>0)::int" '1'
  echo '[TRANSPORT HEALTHY, REPLAY LAGGING]'
  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d rep_lab \
    -c 'SELECT count(*),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn(),pg_wal_lsn_diff(pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn()) FROM events;'
  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d postgres \
    -c 'SELECT status,written_lsn,flushed_lsn,latest_end_lsn FROM pg_stat_wal_receiver; SELECT pg_wal_replay_resume();'
  wait_value "$STANDBY_PORT" rep_lab 'SELECT count(*) FROM events' '150'
  echo '[REPLAY CAUGHT UP]'
  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d rep_lab \
    -c 'SELECT count(*),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn() FROM events;'

  "$PG_CTL" -D "$PRIMARY_DIR" -m fast stop >/dev/null
  wait_value "$STANDBY_PORT" postgres \
    'SELECT count(*) FROM pg_stat_wal_receiver' '0'
  echo '[PRIMARY DOWN: WALRECEIVER EXITED, STANDBY READABLE]'
  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d rep_lab \
    -c 'SELECT count(*),pg_is_in_recovery(),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn() FROM events;'
  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d postgres \
    -c 'SELECT count(*) FROM pg_stat_wal_receiver;'

  "$PG_CTL" -D "$PRIMARY_DIR" -l "$PRIMARY_DIR/server.log" start >/dev/null
  wait_psql "$PRIMARY_PORT"
  "$PSQL" -X -v ON_ERROR_STOP=1 -h /tmp -p "$PRIMARY_PORT" -U mysql -d rep_lab \
    -c "INSERT INTO events SELECT n,'after-reconnect-'||n FROM generate_series(151,200) AS n;"
  wait_value "$STANDBY_PORT" rep_lab 'SELECT count(*) FROM events' '200'
  echo '[PRIMARY RESTARTED: STREAMING RESUMED]'
  "$PSQL" -X -qAt -h /tmp -p "$PRIMARY_PORT" -U mysql -d postgres \
    -c 'SELECT application_name,state,sent_lsn,write_lsn,flush_lsn,replay_lsn FROM pg_stat_replication;'
  "$PSQL" -X -qAt -h /tmp -p "$STANDBY_PORT" -U mysql -d rep_lab \
    -c 'SELECT count(*),pg_is_in_recovery(),pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn() FROM events;'
} > "$OUTPUT" 2>&1

echo "completed: $OUTPUT"
