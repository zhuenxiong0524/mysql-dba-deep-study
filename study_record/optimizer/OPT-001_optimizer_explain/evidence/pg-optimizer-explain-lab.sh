#!/usr/bin/env bash
set -euo pipefail

PG_HOME=/usr/local/pgsql/pgsql18.4
INITDB="$PG_HOME/bin/initdb"
PG_CTL="$PG_HOME/bin/pg_ctl"
CREATEDB="$PG_HOME/bin/createdb"
PSQL="$PG_HOME/bin/psql"
DATA_DIR=/data/pgdata/opt15
PG_PORT=54351
OUTPUT=${1:-pg-optimizer-explain-output.txt}

cleanup_process() {
  sudo -u mysql "$PG_CTL" -D "$DATA_DIR" -m fast stop >/dev/null 2>&1 || true
}
trap cleanup_process EXIT

if [[ -f "$DATA_DIR/postmaster.pid" ]]; then
  echo "refusing to touch a running cluster: $DATA_DIR" >&2
  exit 1
fi
if [[ -e "$DATA_DIR" ]]; then
  echo "refusing to overwrite existing directory: $DATA_DIR" >&2
  exit 1
fi

sudo install -d -o mysql -g mysql -m 0700 "$DATA_DIR"
sudo -u mysql "$INITDB" -D "$DATA_DIR" --auth-local=trust --auth-host=trust \
  > /tmp/pg-opt15-init.log 2>&1
{
  echo "port = $PG_PORT"
  echo "unix_socket_directories = '/tmp'"
  echo "listen_addresses = '127.0.0.1'"
  echo "shared_buffers = '32MB'"
  echo "max_connections = 20"
} | sudo -u mysql tee -a "$DATA_DIR/postgresql.conf" >/dev/null
sudo -u mysql "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/server.log" start >/dev/null
for _ in $(seq 1 120); do
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d postgres -Atqc 'SELECT 1' \
    >/dev/null 2>&1 && break
  sleep 0.25
done

"$CREATEDB" -h /tmp -p "$PG_PORT" -U mysql opt_lab
"$PSQL" -X -v ON_ERROR_STOP=1 -h /tmp -p "$PG_PORT" -U mysql -d opt_lab <<'SQL' >/dev/null
CREATE TABLE customers(
  id integer PRIMARY KEY,
  region varchar(8) NOT NULL
);
CREATE INDEX idx_region ON customers(region);
CREATE TABLE orders(
  id integer PRIMARY KEY,
  customer_id integer NOT NULL,
  status varchar(12) NOT NULL,
  amount numeric(10,2) NOT NULL,
  created_at timestamp NOT NULL
);
CREATE INDEX idx_customer ON orders(customer_id);
CREATE INDEX idx_status ON orders(status);
INSERT INTO customers
SELECT i, 'r' || i % 10 FROM generate_series(1,1000) AS g(i);
INSERT INTO orders
SELECT i, i % 1000 + 1,
       CASE WHEN i % 200 = 0 THEN 'rare' ELSE 'common' END,
       (i * 17 % 10000) / 10.0,
       timestamp '2026-01-01' + (i % 365) * interval '1 day'
FROM generate_series(1,20000) AS g(i);
ANALYZE customers;
ANALYZE orders;
SQL

{
  echo '[VERSION AND SETUP]'
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d opt_lab -Atqc \
    "SELECT version(); SELECT current_setting('port'),current_setting('shared_buffers');"
  echo '[TABLE COUNTS]'
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d opt_lab -Atqc \
    "SELECT count(*) FROM customers; SELECT count(*),count(*) FILTER (WHERE status='rare') FROM orders;"

  echo '[BEHAVIOR: SARGABLE PRIMARY KEY]'
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d opt_lab -c \
    "EXPLAIN (ANALYZE,BUFFERS,VERBOSE,SETTINGS) SELECT * FROM orders WHERE id=19999;"
  echo '[BEHAVIOR: NON-SARGABLE EXPRESSION]'
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d opt_lab -c \
    "EXPLAIN (ANALYZE,BUFFERS,VERBOSE,SETTINGS) SELECT * FROM orders WHERE id+0=19999;"

  echo '[JOIN ORDER AND PLAN NODES]'
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d opt_lab -c \
    "EXPLAIN (ANALYZE,BUFFERS,VERBOSE,SETTINGS) SELECT c.region,count(*),sum(o.amount) FROM customers c JOIN orders o ON o.customer_id=c.id WHERE c.id BETWEEN 10 AND 20 GROUP BY c.region;"

  echo '[EXPLAIN DOES NOT RUN; ANALYZE RUNS SLEEP]'
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d opt_lab -c \
    "EXPLAIN (VERBOSE) SELECT id FROM orders WHERE id<=10 AND pg_sleep(id*0+0.01) IS NULL;"
  "$PSQL" -X -h /tmp -p "$PG_PORT" -U mysql -d opt_lab -c \
    "EXPLAIN (ANALYZE,VERBOSE) SELECT id FROM orders WHERE id<=10 AND pg_sleep(id*0+0.01) IS NULL;"

  echo '[DML SAFETY: POSTGRESQL EXPLAIN ANALYZE EXECUTES; ROLLBACK RESTORES]'
  "$PSQL" -X -v ON_ERROR_STOP=1 -h /tmp -p "$PG_PORT" -U mysql -d opt_lab <<'SQL'
SELECT amount AS before_amount FROM orders WHERE id=1;
BEGIN;
EXPLAIN (ANALYZE,BUFFERS,WAL,VERBOSE) UPDATE orders SET amount=amount+100 WHERE id=1;
SELECT amount AS inside_transaction FROM orders WHERE id=1;
ROLLBACK;
SELECT amount AS after_rollback FROM orders WHERE id=1;
SQL
} > "$OUTPUT" 2>&1

echo "completed: $OUTPUT"
