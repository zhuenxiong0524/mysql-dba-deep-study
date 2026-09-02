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
