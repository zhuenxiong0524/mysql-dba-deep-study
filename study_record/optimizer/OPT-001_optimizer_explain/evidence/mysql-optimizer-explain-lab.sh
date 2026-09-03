#!/usr/bin/env bash
set -euo pipefail

MYSQL_HOME=/usr/local/mysql/mysql-8.4.10
MYSQLD="$MYSQL_HOME/bin/mysqld"
MYSQL="$MYSQL_HOME/bin/mysql"
MYSQLADMIN="$MYSQL_HOME/bin/mysqladmin"
DATA_DIR=/data/myhome/mydata/mysql-opt15
MYSQL_CNF=/tmp/mysql-opt15.cnf
MYSQL_SOCKET=/tmp/mysql-opt15.sock
MYSQL_PORT=33341
OUTPUT=${1:-mysql-optimizer-explain-output.txt}

cleanup_process() {
  "$MYSQLADMIN" --no-defaults -uroot -S "$MYSQL_SOCKET" shutdown >/dev/null 2>&1 || true
}
trap cleanup_process EXIT

cleanup_process
if [[ -e "$DATA_DIR" ]]; then
  echo "refusing to overwrite existing directory: $DATA_DIR" >&2
  exit 1
fi
install -d -o mysql -g mysql -m 0750 "$DATA_DIR"
printf '%s\n' \
  '[mysqld]' "basedir=$MYSQL_HOME" "datadir=$DATA_DIR" \
  "socket=$MYSQL_SOCKET" "port=$MYSQL_PORT" 'server_id=1501' \
  'innodb_buffer_pool_size=64M' 'performance_schema=ON' 'mysqlx=OFF' \
  "pid_file=$DATA_DIR/mysqld.pid" "log_error=$DATA_DIR/error.log" \
  > "$MYSQL_CNF"
sudo -u mysql "$MYSQLD" --defaults-file="$MYSQL_CNF" --initialize-insecure \
  > /tmp/mysql-opt15-init.log 2>&1
sudo -u mysql "$MYSQLD" --defaults-file="$MYSQL_CNF" --daemonize
for _ in $(seq 1 120); do
  "$MYSQLADMIN" --no-defaults -uroot -S "$MYSQL_SOCKET" ping >/dev/null 2>&1 && break
  sleep 0.25
done

{
  echo '[VERSION AND SETUP]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$MYSQL_SOCKET" -e \
    'SELECT @@version,@@port,@@optimizer_switch,@@explain_format;'
  "$MYSQL" --no-defaults -uroot -S "$MYSQL_SOCKET" <<'SQL'
CREATE DATABASE opt_lab;
USE opt_lab;
CREATE TABLE customers(
  id INT PRIMARY KEY,
  region VARCHAR(8) NOT NULL,
  KEY idx_region(region)
) ENGINE=InnoDB;
CREATE TABLE orders(
  id INT PRIMARY KEY,
  customer_id INT NOT NULL,
  status VARCHAR(12) NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  created_at DATETIME NOT NULL,
  KEY idx_customer(customer_id),
  KEY idx_status(status)
) ENGINE=InnoDB;
SET SESSION cte_max_recursion_depth=25000;
INSERT INTO customers
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i+1 FROM n WHERE i<1000)
SELECT i,CONCAT('r',MOD(i,10)) FROM n;
INSERT INTO orders
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i+1 FROM n WHERE i<20000)
SELECT i,MOD(i,1000)+1,
       IF(MOD(i,200)=0,'rare','common'),
       MOD(i*17,10000)/10,
       TIMESTAMP('2026-01-01') + INTERVAL MOD(i,365) DAY
FROM n;
ANALYZE TABLE customers,orders;
SQL
  echo '[TABLE COUNTS]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$MYSQL_SOCKET" opt_lab -e \
    "SELECT COUNT(*) FROM customers; SELECT COUNT(*),SUM(status='rare') FROM orders;"

  echo '[BEHAVIOR: SARGABLE PRIMARY KEY]'
  "$MYSQL" --no-defaults -uroot -S "$MYSQL_SOCKET" opt_lab -e \
    "EXPLAIN FORMAT=TREE SELECT * FROM orders WHERE id=19999; EXPLAIN ANALYZE SELECT * FROM orders WHERE id=19999;"
  echo '[BEHAVIOR: NON-SARGABLE EXPRESSION]'
  "$MYSQL" --no-defaults -uroot -S "$MYSQL_SOCKET" opt_lab -e \
    "EXPLAIN FORMAT=TREE SELECT * FROM orders WHERE id+0=19999; EXPLAIN ANALYZE SELECT * FROM orders WHERE id+0=19999;"

  echo '[JOIN ORDER AND ITERATORS]'
  "$MYSQL" --no-defaults -uroot -S "$MYSQL_SOCKET" opt_lab -e \
    "EXPLAIN FORMAT=JSON SELECT c.region,COUNT(*),SUM(o.amount) FROM customers c JOIN orders o ON o.customer_id=c.id WHERE c.id BETWEEN 10 AND 20 GROUP BY c.region; EXPLAIN ANALYZE SELECT c.region,COUNT(*),SUM(o.amount) FROM customers c JOIN orders o ON o.customer_id=c.id WHERE c.id BETWEEN 10 AND 20 GROUP BY c.region;"

  echo '[EXPLAIN DOES NOT RUN; ANALYZE RUNS SLEEP]'
  "$MYSQL" --no-defaults -uroot -S "$MYSQL_SOCKET" opt_lab -e \
    "EXPLAIN FORMAT=TREE SELECT id FROM orders WHERE id<=10 AND SLEEP(0.01)=0; EXPLAIN ANALYZE SELECT id FROM orders WHERE id<=10 AND SLEEP(0.01)=0;"

  echo '[PATH: OPTIMIZER TRACE SARGABLE]'
  "$MYSQL" --no-defaults -uroot -S "$MYSQL_SOCKET" opt_lab <<'SQL'
SET optimizer_trace='enabled=on',optimizer_trace_max_mem_size=1048576;
SELECT COUNT(*) FROM orders WHERE customer_id=42;
SELECT TRACE FROM information_schema.optimizer_trace\G
SET optimizer_trace='enabled=off';
SQL
  echo '[PATH: OPTIMIZER TRACE NON-SARGABLE]'
  "$MYSQL" --no-defaults -uroot -S "$MYSQL_SOCKET" opt_lab <<'SQL'
SET optimizer_trace='enabled=on',optimizer_trace_max_mem_size=1048576;
SELECT COUNT(*) FROM orders WHERE customer_id+0=42;
SELECT TRACE FROM information_schema.optimizer_trace\G
SET optimizer_trace='enabled=off';
SQL

  echo '[DML SAFETY: UPDATE SUPPORT MUST BE VERIFIED IN A ROLLBACK-SAFE TRANSACTION]'
  "$MYSQL" --no-defaults -N -B -uroot -S "$MYSQL_SOCKET" opt_lab <<'SQL'
SELECT amount FROM orders WHERE id=1;
START TRANSACTION;
EXPLAIN ANALYZE UPDATE orders SET amount=amount+100 WHERE id=1;
SELECT amount FROM orders WHERE id=1;
ROLLBACK;
SELECT amount FROM orders WHERE id=1;
SQL
} > "$OUTPUT" 2>&1

echo "completed: $OUTPUT"
