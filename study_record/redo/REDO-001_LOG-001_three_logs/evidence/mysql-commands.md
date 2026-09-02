# MySQL 三日志实验完整命令

连接：

```bash
mysql -uroot -S /tmp/mysql.sock
```

准备与配置检查：

```sql
SELECT VERSION(),@@log_bin,@@binlog_format,@@gtid_mode,@@sync_binlog,
       @@innodb_flush_log_at_trx_commit,@@innodb_redo_log_capacity,
       @@binlog_expire_logs_seconds;
DROP DATABASE IF EXISTS mysql_lab_redo_log;
CREATE DATABASE mysql_lab_redo_log;
USE mysql_lab_redo_log;
CREATE TABLE t_log_lab(id INT PRIMARY KEY,note VARCHAR(80) NOT NULL,amount INT NOT NULL) ENGINE=InnoDB;
SHOW BINARY LOG STATUS;
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log%lsn';
```

提交与回滚：

```sql
START TRANSACTION;
INSERT INTO t_log_lab VALUES(101,'commit-redo-binlog-marker',100);
UPDATE t_log_lab SET amount=amount+1 WHERE id=101;
COMMIT;
SHOW BINARY LOG STATUS;

START TRANSACTION;
INSERT INTO t_log_lab VALUES(202,'rollback-undo-marker',200);
UPDATE t_log_lab SET amount=amount+2 WHERE id=202;
ROLLBACK;
SELECT * FROM t_log_lab ORDER BY id;
SHOW BINARY LOG STATUS;
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log%lsn';
```

判断：最终只有 id=101；COMMIT 后 binlog position 前进，ROLLBACK 后不再前进；redo current LSN 可继续前进。

解码（把位置替换为自己两次 `SHOW BINARY LOG STATUS` 的值）：

```bash
mysqlbinlog --base64-output=DECODE-ROWS -vv \
  --start-position=926 --stop-position=1460 \
  /data/myhome/mydata/mysql/binlog.000017
```

预期看到 id=101 的 `Write_rows`、`Update_rows`、`Xid`/`COMMIT`，看不到 rollback marker。

清理：

```sql
DROP DATABASE IF EXISTS mysql_lab_redo_log;
```

## 持久性参数矩阵（需要 SYSTEM_VARIABLES_ADMIN）

下面的脚本按 `(innodb_flush_log_at_trx_commit, sync_binlog)` 六种组合各执行 100 次独立提交，
记录耗时、InnoDB redo fsync 增量和 binlog 字节增量，并通过 `trap` 恢复原参数、删除实验库：

```bash
chmod +x evidence/mysql-durability-matrix.sh
evidence/mysql-durability-matrix.sh
```

执行前也可手工记录原值；若脚本被 `kill -9`，用记录值恢复：

```sql
SELECT @@GLOBAL.innodb_flush_log_at_trx_commit, @@GLOBAL.sync_binlog;
SET GLOBAL innodb_flush_log_at_trx_commit = 1;
SET GLOBAL sync_binlog = 1;
DROP DATABASE IF EXISTS mysql_lab_redo_log;
```

判断标准：`redo=1` 的 `Innodb_os_log_fsyncs` 增量应显著高于 0/2；所有组合的 binlog
position 都会增长。后者只证明写入 binlog 文件，不能证明 `sync_binlog=0` 已经 fsync。
