# ISO-001 双引擎并发实验复现手册

> 两个终端分别标为 T1/T2。每组实验前恢复对应表的初始数据。命令按标注顺序交错执行。
> MySQL 使用 `/tmp/mysql.sock`；PG 使用 54184 端口。

## 0. 准备

```bash
mysql -uroot -S /tmp/mysql.sock < evidence/mysql-setup.sql
createdb -p 54184 pg_iso001
psql -p 54184 -d pg_iso001 -f evidence/pg-setup.sql
```

连接：

```bash
mysql -uroot -S /tmp/mysql.sock mysql_iso001
psql -p 54184 -d pg_iso001
```

## 1. 范围锁：MySQL RR 阻塞，MySQL RC / PG RR 不阻塞

MySQL RR，T1：

```sql
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION;
SELECT * FROM range_lab WHERE id BETWEEN 10 AND 20 FOR UPDATE;
-- 等 T2 进入等待后：
SELECT trx_mysql_thread_id,trx_state,trx_query,trx_rows_locked
FROM information_schema.innodb_trx;
SHOW ENGINE INNODB STATUS\G
COMMIT;
```

MySQL RR，T2（在 T1 提交前执行）：

```sql
SET SESSION innodb_lock_wait_timeout=20;
INSERT INTO range_lab VALUES (15,'fifteen'); -- 等待；可能因观察时间超过 20s 而 1205
-- T1 释放后重试，应立即成功
INSERT INTO range_lab VALUES (15,'fifteen');
```

MySQL RC：重置表后，仅把 T1 隔离级别改为 `READ COMMITTED`，同样的 T2 插入会立即成功。

PG RR，T1：

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT * FROM range_lab WHERE id BETWEEN 10 AND 20 FOR UPDATE;
-- T2 提交后再次查，固定快照仍只有 10、20
SELECT * FROM range_lab WHERE id BETWEEN 10 AND 20 ORDER BY id;
COMMIT;
-- 新事务可见 10、15、20
SELECT * FROM range_lab WHERE id BETWEEN 10 AND 20 ORDER BY id;
```

PG RR，T2：

```sql
INSERT INTO range_lab VALUES (15,'fifteen'); -- 立即成功
```

观察 PG 锁：

```sql
SELECT pid,state,backend_xmin,wait_event_type,wait_event,query
FROM pg_stat_activity WHERE datname='pg_iso001';
SELECT pid,locktype,mode,granted,relation::regclass
FROM pg_locks WHERE pid IN (<T1-pid>,<T2-pid>) ORDER BY pid,locktype,mode;
```

## 2. 经典死锁：反序更新

两边执行形状相同。T1：

```sql
BEGIN;
UPDATE account_lab SET balance=balance-10 WHERE id=1;
-- T2 锁住 id=2 后：
UPDATE account_lab SET balance=balance-10 WHERE id=2; -- 等待
COMMIT;
```

T2：

```sql
BEGIN;
UPDATE account_lab SET balance=balance-20 WHERE id=2;
-- T1 已等待 id=2 后：
UPDATE account_lab SET balance=balance-20 WHERE id=1; -- 被选为 victim
ROLLBACK;
```

MySQL 查 `SHOW ENGINE INNODB STATUS\G` 的 `LATEST DETECTED DEADLOCK`；PG 错误详情直接给出
两个 transaction id 的等待环。PG victim 的事务会进入 aborted 状态，必须 `ROLLBACK`。

## 3. RR 写偏差

重置 `doctor_lab` 为两行 `on_call=1`。两边 T1/T2 均使用 RR：

```sql
-- T1
BEGIN ISOLATION LEVEL REPEATABLE READ; -- MySQL 写成 SET ...; START TRANSACTION WITH CONSISTENT SNAPSHOT
SELECT count(*) FROM doctor_lab WHERE on_call=1; -- 2
UPDATE doctor_lab SET on_call=0 WHERE id=1;
COMMIT;

-- T2 与 T1 同时读到 2
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM doctor_lab WHERE on_call=1; -- 2
UPDATE doctor_lab SET on_call=0 WHERE id=2;
COMMIT;
```

最终两行均为 0：两边 RR 都允许该写偏差。

## 4. PG SSI 与 MySQL SERIALIZABLE

PG 把上组实验改为 `BEGIN ISOLATION LEVEL SERIALIZABLE`。两边普通 SELECT 都不互相阻塞；
`pg_locks` 可见 `SIReadLock`。两个 UPDATE 可先执行，但一个 COMMIT 报 40001，最终至少一人值班。

MySQL 把隔离级别改为 `SERIALIZABLE` 并使用显式事务。普通 SELECT 被转成 S 锁；两边都读完后，
T1 更新自己的行会等待 T2 的 S 锁，T2 再更新自己的行形成死锁，一个事务报 1213。

## 5. 清理

```sql
-- MySQL
SET GLOBAL innodb_status_output_locks=OFF;
DROP DATABASE IF EXISTS mysql_iso001;
```

```bash
dropdb -p 54184 --if-exists pg_iso001
```
