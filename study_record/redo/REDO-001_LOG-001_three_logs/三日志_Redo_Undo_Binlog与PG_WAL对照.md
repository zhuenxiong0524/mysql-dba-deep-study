# Undo、Redo、Binlog：从 PostgreSQL WAL 理解 MySQL 三日志

> MySQL 8.4.10 / PostgreSQL 18.4，实测日期 2026-09-02。

## 1. 结论速览

| 问题 | PostgreSQL | MySQL | 迁移含义 |
|---|---|---|---|
| 旧版本/回滚 | heap 旧 tuple + WAL/事务状态 | undo record | undo 不是崩溃持久化日志的替代品 |
| 崩溃恢复 | WAL | InnoDB redo | 二者都是物理恢复主线 |
| 复制/PITR | 同一 WAL | binlog | MySQL 有 redo+binlog 双日志边界 |
| 回滚事务 | WAL 有数据变更和 ABORT | redo/undo 有活动，事务 binlog cache 丢弃 | binlog 不是所有物理变化的审计流 |
| 提交持久性 | `synchronous_commit` | `innodb_flush_log_at_trx_commit` + `sync_binlog` | MySQL 必须同时评估两套刷盘策略 |

## 2. PG 基线

PG 修改 heap/index 时写 WAL；COMMIT 写事务记录，默认 `synchronous_commit=on` 时
`XLogFlush(XactLastRecEnd)`。回滚事务产生的 heap/index WAL 仍存在，并有 ABORT 记录，因为 WAL
描述物理变化与恢复需要，不等同于“只记录最终业务结果”。

实测 LSN 从 `0/2A177F60` 经提交到 `0/2A1780E0`，回滚后继续到 `0/2A1781E8`；
`pg_waldump` 显示 xid 1582 COMMIT、xid 1583 ABORT。

## 3. MySQL 三日志职责

### Undo

`trx_undo_report_row_operation()` 为聚簇记录 insert/update/delete-mark 写 undo，源码明确用于
transaction rollback 和 consistent read。它提供“怎么撤销/怎么重建旧版本”，不是 binlog。

### InnoDB redo

数据页、索引页及 undo 页等持久结构的变化由 redo 保护。提交得到 commit LSN 后，
`trx_flush_log_if_needed_low()` 按 `innodb_flush_log_at_trx_commit` 决定：

- 1：write 并 flush；
- 2：write，不要求每次 flush；
- 0：提交路径不做 write/flush，后台周期处理。

本机为 1；当前、flushed-to-disk LSN 最终一致。Checkpoint LSN 落后表示仍有恢复需要覆盖的脏页范围。

### Binlog

ROW binlog 是 Server 层逻辑变更流，用于复制/PITR。事务事件先进入 binlog cache；正常可回滚
事务 ROLLBACK 时，`MYSQL_BIN_LOG::rollback()` 调用引擎回滚并 truncate transaction cache。
COMMIT 则走 prepare 与 `ordered_commit()`：

1. FLUSH stage：事务 cache 写入 binlog file cache；
2. SYNC stage：按 `sync_binlog` 同步文件；
3. COMMIT stage：调用存储引擎 commit，并保持提交顺序。

这就是 MySQL 比 PG 多出的协调面：InnoDB redo 与 Server binlog 必须形成一致提交结果。

## 4. 最小对照实验结果

MySQL setup 后基线 binlog position=926。id=101 的 INSERT+UPDATE 提交后 position=1460，
`mysqlbinlog -vv` 解码出 `Write_rows`、`Update_rows`、`Xid=32` 和 `COMMIT`。

id=202 在事务内可见为 amount=202；ROLLBACK 后该行消失，binlog position 仍为 1460，
但 redo current LSN 从 713716367 前进到 713719275，稍后 flush 到 713721162。

因此：

- undo 负责把逻辑状态撤回；
- redo 仍需记录执行与撤销涉及的持久页变化；
- 可安全回滚的事务不会成为已提交 binlog 事务。

PG 同构实验也只留下 id=101，但 WAL 同时保留提交与回滚事务的物理记录。这是“PG 单 WAL”
迁移到“MySQL redo+binlog”最关键的心智差异。

## MySQL 实操：命令与 SQL

前置条件：MySQL 8.4 已启动，使用 root socket 连接；实验只创建 `mysql_lab_redo_log`。

```bash
mysql -uroot -S /tmp/mysql.sock
```

先检查参数并准备对象：

```sql
SELECT VERSION(),@@log_bin,@@binlog_format,@@gtid_mode,@@sync_binlog,
       @@innodb_flush_log_at_trx_commit,@@innodb_redo_log_capacity,
       @@binlog_expire_logs_seconds;
DROP DATABASE IF EXISTS mysql_lab_redo_log;
CREATE DATABASE mysql_lab_redo_log;
USE mysql_lab_redo_log;
CREATE TABLE t_log_lab(
  id INT PRIMARY KEY,note VARCHAR(80) NOT NULL,amount INT NOT NULL
) ENGINE=InnoDB;
SHOW BINARY LOG STATUS;
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log%lsn';
```

预期 `log_bin=1`、`binlog_format=ROW`。记录当前 File/Position，然后执行：

```sql
START TRANSACTION;
INSERT INTO t_log_lab VALUES(101,'commit-redo-binlog-marker',100);
UPDATE t_log_lab SET amount=amount+1 WHERE id=101;
COMMIT;
SHOW BINARY LOG STATUS;

START TRANSACTION;
INSERT INTO t_log_lab VALUES(202,'rollback-undo-marker',200);
UPDATE t_log_lab SET amount=amount+2 WHERE id=202;
SELECT * FROM t_log_lab WHERE id=202;
ROLLBACK;

SELECT * FROM t_log_lab ORDER BY id;
SHOW BINARY LOG STATUS;
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log%lsn';
```

结果判断：最终只有 id=101、amount=101；提交后 Position 前进，回滚后 Position 不再前进。

使用自己记录的文件和位置解码：

```bash
mysqlbinlog --base64-output=DECODE-ROWS -vv \
  --start-position=926 --stop-position=1460 \
  /data/myhome/mydata/mysql/binlog.000017
```

预期看到 id=101 与 COMMIT，看不到 `rollback-undo-marker`。位置必须用本机实测值，不能照抄。

清理：

```sql
DROP DATABASE IF EXISTS mysql_lab_redo_log;
```

本阶段不修改持久化参数、不删除 binlog、不停止实例、不做 kill -9。

## 6. 生产判断

- `innodb_flush_log_at_trx_commit=1` 只保证 redo 侧；`sync_binlog=1` 才覆盖 binlog 每组同步。
- binlog position 没变化不能证明事务没做过物理工作；要结合 redo LSN、事务和错误日志。
- binlog 用于逻辑回放，不要用它解释页恢复、未提交事务撤销或 buffer pool 脏页。
- 调低任一刷盘参数都改变故障窗口；不能只类比 PG `synchronous_commit` 一个开关。
- crash recovery 和 PITR 是下一阶段，必须使用专用实例/恢复目录。

## 7. Evidence

- `evidence/mysql-output.txt`：配置、提交/回滚、LSN/position
- `evidence/pg-output.txt`：PG LSN 与 WAL COMMIT/ABORT
- `evidence/source-locations.txt`：MySQL/PG 源码锚点
- `evidence/mysql-commands.md`：完整复现命令
