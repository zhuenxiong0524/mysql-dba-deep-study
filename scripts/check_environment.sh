#!/usr/bin/env bash
# check_environment.sh — MySQL/PG 双引擎对照学习环境检查
# 用法: ./scripts/check_environment.sh
# 退出码: 0 = 无 FAIL; 1 = 存在 FAIL
set -uo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[OK]   $1"; PASS=$((PASS+1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "== 软件 =="
MYSQL_BIN=/usr/local/mysql/mysql-8.4.10/bin
[ -x "$MYSQL_BIN/mysql" ] && ok "mysql client: $MYSQL_BIN/mysql" || warn "mysql client missing at $MYSQL_BIN"
command -v psql >/dev/null 2>&1 && ok "psql: $(command -v psql)" || warn "psql not in PATH"

echo "== MySQL 8.4 =="
[ -x "$MYSQL_BIN/mysqld" ] && ok "mysqld: $MYSQL_BIN/mysqld" || fail "mysqld missing at $MYSQL_BIN"
[ -d /data/myhome/mydata/mysql ] && ok "datadir: /data/myhome/mydata/mysql" || fail "datadir missing"
[ -d /data/myhome/mydata/mysql-src/mysql-8.4.10 ] && ok "mysql source: /data/myhome/mydata/mysql-src/mysql-8.4.10" || fail "mysql source missing"
if [ -S /tmp/mysql.sock ]; then
  if "$MYSQL_BIN/mysql" -uroot -S /tmp/mysql.sock -e "SELECT VERSION();" >/dev/null 2>&1; then
    ok "MySQL reachable via socket ($("$MYSQL_BIN/mysql" -uroot -S /tmp/mysql.sock -Nse 'SELECT VERSION()' 2>/dev/null))"
  else
    warn "socket exists but connect failed"
  fi
else
  warn "MySQL not running (no /tmp/mysql.sock)"
fi

echo "== PostgreSQL 18.4 =="
if command -v psql >/dev/null 2>&1 && psql -U mysql -d mysql -h 127.0.0.1 -p 54184 -tAc "SELECT version();" >/dev/null 2>&1; then
  ok "PG 54184 reachable ($(psql -U mysql -d mysql -h 127.0.0.1 -p 54184 -tAc 'SHOW server_version' 2>/dev/null))"
else
  fail "PG 54184 not reachable as mysql user"
fi
[ -d /data/soft/postgres/postgresql-18.4 ] && ok "pg source: /data/soft/postgres/postgresql-18.4" || warn "pg source missing"

echo "== 机器资源 =="
MEM=$(free -m | awk '/^Mem:/{print $2}')
SWAP=$(free -m | awk '/^Swap:/{print $2}')
[ "$SWAP" -gt 0 ] && ok "swap: ${SWAP}MB" || warn "no swap"
[ "$MEM" -ge 1536 ] && ok "memory: ${MEM}MB" || warn "memory low: ${MEM}MB"
DISK=$(df -m /data | awk 'NR==2{print $4}')
[ "$DISK" -gt 10240 ] && ok "disk /data: ${DISK}MB free" || warn "disk low: ${DISK}MB"

echo "== 项目 =="
[ -d /data/myhome/myfuture/dba_one_year_mysql/study_record ] && ok "study_record exists" || fail "study_record missing"
git -C /data/myhome/myfuture/dba_one_year_mysql rev-parse --git-dir >/dev/null 2>&1 && ok "git repo initialized" || fail "not a git repo"

echo
echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
