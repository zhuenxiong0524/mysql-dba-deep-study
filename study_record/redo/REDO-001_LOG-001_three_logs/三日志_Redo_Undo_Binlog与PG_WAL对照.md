# Undo、Redo、Binlog：从 PostgreSQL WAL 深入 MySQL 提交与持久性

> MySQL 8.4.10 / PostgreSQL 18.4，实测日期 2026-09-02。本文讨论的核心是：客户端收到
> COMMIT 成功时，数据已经到哪里？

## 1. 生产结论

| 问题 | PostgreSQL 18.4 | MySQL 8.4 | 迁移判断 |
|---|---|---|---|
| 崩溃恢复 | WAL | InnoDB redo | redo 最像 WAL 的恢复职责，但不是完整替代 |
| 旧版本/回滚 | heap tuple + 事务状态；WAL 保护变化 | undo record；redo 保护 undo 页 | undo 不是 WAL，也不是 binlog |
| 复制/PITR | 同一 WAL | binlog | MySQL 多出 redo/binlog 一致性边界 |
| 本地刷盘 | `synchronous_commit` 决定是否等 WAL flush | `innodb_flush_log_at_trx_commit` 控 redo，`sync_binlog` 控 binlog | MySQL 必须看两个轴 |
| 远端确认 | local/remote_write/on/remote_apply 是同一框架的等级 | 异步复制另加半同步插件及等待点 | 不能一对一翻译参数 |
| 副本不可用 | 配置同步候选但没有满足者时提交等待 | 半同步可 timeout 后关闭等待，退回异步 | 失败策略不同 |

最保守的单机组合是 `innodb_flush_log_at_trx_commit=1`、`sync_binlog=1`。它覆盖两套本地
日志的同步要求，但仍不表示远端副本已收到、落盘或回放。

## 2. 一次 MySQL 提交经过什么

### 2.1 三日志不是三份相同数据

一次 InnoDB UPDATE 可以同时产生：

1. **undo**：保存撤销信息与旧版本入口，支持 ROLLBACK 和一致性读；
2. **redo**：保护 InnoDB 持久页变化，包括数据、索引和 undo 页，供崩溃恢复；
3. **binlog**：Server 层已提交逻辑变更流，供复制和 PITR。

因此，回滚后 binlog 没有该事务，不表示它没有产生物理工作。实测回滚事务令 redo LSN 前进，
事务 binlog cache 被截断，binlog position 不前进。

PG 没有这套三分法：heap/index 的变化、COMMIT/ABORT、复制所需记录都进入 WAL；旧行版本主要
留在 heap，由 xmin/xmax 和事务状态解释。把 PG WAL 直接翻译为 binlog 会漏掉崩溃恢复；翻译为
redo 又会漏掉复制/PITR。

### 2.2 redo 与 binlog 为什么需要协调

MySQL 一个事务跨越 InnoDB 与 Server 两个日志域。正常提交进入
`MYSQL_BIN_LOG::ordered_commit()`：

```text
事务 binlog cache
  → FLUSH stage：组内事务写入 binlog file cache
  → SYNC stage：按 sync_binlog 决定是否同步 binlog
  → COMMIT stage：按顺序提交存储引擎事务
  → 返回客户端
```

InnoDB 以 prepare/commit 参与内部两阶段协调，避免两种裂缝：InnoDB 已提交但 binlog 永久缺失，
或 binlog 有完整事务但 InnoDB 最终回滚。前者会让副本/PITR 永远漏事务，后者会使源库与回放结果
不一致。这里不是应用显式操作两个资源的 XA；group commit 也不是省略持久性，而是让多个事务
共享 flush/fsync，同时维持 binlog 与引擎提交顺序。

### 2.3 成功、可见、持久、已复制是四件事

| 状态 | 含义 | 典型证据 |
|---|---|---|
| 已写入 | 字节进入进程/OS 文件缓存 | binlog position、redo written LSN |
| 本地持久 | 目标 LSN/文件完成要求的 flush | redo flushed LSN、两项刷盘参数 |
| 源端可见 | 引擎 commit 后其他会话能读到 | 新事务 SELECT |
| 远端确认 | 副本收到/写入/flush/apply 到指定位置 | ACK、GTID 和复制线程状态 |

Position 增长不证明 `sync_binlog=0` 时已经稳定落盘；源库可见也不证明副本已收到。

## 3. PostgreSQL synchronous_commit 五档语义

| 值 | 本地 WAL | 同步备库确认点 | COMMIT 返回时可断言 |
|---|---|---|---|
| `off` | 不等本次 flush | 不等 | COMMIT record 已生成；崩溃可丢近期已确认事务，但不破坏数据库一致性 |
| `local` | 等本地 flush | 不等 | 主库本地持久 |
| `remote_write` | 等本地 flush | 等备库写入 OS | 到达备库 OS，未保证备库稳定介质 |
| `on` | 等本地 flush | 等备库 flush | 本地和选定同步备库持久；源码中等于 remote flush |
| `remote_apply` | 等本地/远端 flush | 再等 replay | 返回时同步备库查询可看到该事务 |

PG 提交源码在同步路径执行 `XLogFlush(XactLastRecEnd)`，随后 `SyncRepWaitForLSN()` 按
WRITE/FLUSH/APPLY 等待远端确认。

### 3.1 无同步备库时为什么几个模式看起来一样

本机 `synchronous_standby_names=''`。每档执行 100 次独立提交：

```text
on           insert_lsn=0/2A1AD598 flush_lsn=0/2A1AD598
local        insert_lsn=0/2A1B3C18 flush_lsn=0/2A1B3C18
remote_write insert_lsn=0/2A1B8578 flush_lsn=0/2A1B8578
remote_apply insert_lsn=0/2A1BCEC0 flush_lsn=0/2A1BCEC0
off          insert_lsn=0/2A1C1818 flush_lsn=0/2A1BCEC0 gap=18776 bytes
```

前三个远端档位与 `local` 都只证明本地 flush；没有同步备库，就没有远端等待。这也是一个实用
陷阱：会话显示 remote_apply 不代表系统真的获得远端 apply 保障。

`off` 在提交返回后直接观察到 18,776 字节 insert/flush gap。WAL writer 会稍后补刷；风险窗口
受 `wal_writer_delay=200ms` 等因素影响，但不能承诺严格等于 200ms。

两个常见误读：`off` 不会关闭 WAL，它只取消当前事务等待；`remote_apply` 不是“最终会回放”，
而是把当前 COMMIT 返回点推迟到同步备库已 replay。

## 4. MySQL 两轴持久性

### 4.1 innodb_flush_log_at_trx_commit 控制 redo

源码 `trx_flush_log_if_needed_low()` 的分支为：

| 值 | COMMIT 路径 | mysqld 崩溃 | OS/主机掉电 |
|---:|---|---|---|
| 1 | write redo 并要求 flush | 已确认事务应可恢复 | 依赖 OS/存储兑现 flush |
| 2 | write redo，不要求每次 flush | OS cache 通常仍在 | 近期事务可能丢失 |
| 0 | 本次提交不主动 write/flush，后台处理 | 近期事务可能丢失 | 近期事务可能丢失 |

“每秒刷一次”只是后台目标节奏，不是严格的一秒损失上限。调度、负载、存储和异常类型都会改变
窗口；DDL 强制路径也可能绕过普通事务分支执行 flush。

### 4.2 sync_binlog 控制 binlog

| 值 | 含义 | 风险 |
|---:|---|---|
| 1 | 每个 binlog group 同步一次 | 最强本地 binlog 持久性；组内事务共享 sync |
| N>1 | 每 N 个 group 同步 | 中间 groups 可能只在 OS cache |
| 0 | MySQL 不按 group 主动同步，交给 OS | 主机故障可能丢尾部 binlog |

单位是 **group**，不是事务。并发越高，一个 group 可能包含越多事务。

### 4.3 组合才是实际承诺

| redo | binlog | 本地承诺 | 主要风险 |
|---:|---:|---|---|
| 1 | 1 | 两日志都按提交组要求持久 | 最保守；仍需验证存储 flush 语义 |
| 1 | 0/N | InnoDB 恢复面强，binlog 尾部弱 | 源库有事务，复制/PITR 流可能缺尾部 |
| 2/0 | 1 | binlog 强，redo 弱 | 恢复结果与逻辑日志形成棘手边界 |
| 2/0 | 0/N | 两边都放宽 | 丢失窗口最大、最难推理 |

这不是简单的“丢几秒数据”，还会影响副本重建、PITR 截止点和故障后哪个日志可作为事实来源。

### 4.4 六组合实测

每组执行 100 次独立 autocommit INSERT：

| redo | sync_binlog | InnoDB redo fsync 增量 | binlog 增长 |
|---:|---:|---:|---:|
| 1 | 1 | 207 | 32,292 bytes |
| 1 | 0 | 205 | 32,292 bytes |
| 2 | 1 | 2 | 32,292 bytes |
| 2 | 0 | 3 | 32,292 bytes |
| 0 | 1 | 1 | 32,292 bytes |
| 0 | 0 | 0 | 32,292 bytes |

redo=1 约 2 次/事务来自当前日志/提交协调活动；这里只用来证明它与 0/2 的路径差异。
`Innodb_os_log_fsyncs` 不统计 binlog fsync，不能用该列比较 sync_binlog。六组 position 都增长
再次证明写入不等于同步落盘。耗时 666–853ms 受单 CPU、重复连接和后台任务影响，不是性能基准。

## 5. PG 模式如何映射到 MySQL

没有精确的一对一映射，只能按确认点迁移：

| PG 目标 | MySQL 需要什么 | 不等价点 |
|---|---|---|
| `off` | redo=0/2 可放宽 redo；binlog 另行决定 | PG 是一条 WAL，MySQL 有两个日志轴 |
| `local` | redo=1 + sync_binlog=1 才覆盖两日志 | binlog 按 group sync，内部有两阶段协调 |
| `remote_write` | 半同步 ACK，且需核实副本 ACK 位置 | 不是 PG WAL receiver 的同一状态机 |
| `on` | 不能仅凭“半同步已开启”推断远端 flush | 必须核实 ACK 与副本存储语义 |
| `remote_apply` | 额外等待副本 applier 执行目标 GTID | 传统半同步 ACK 不代表已 apply/可见 |

### 5.1 AFTER_SYNC 与 AFTER_COMMIT

MySQL 半同步 source 插件有两个源端等待位置：

- `AFTER_SYNC`：binlog sync 阶段后、源端引擎 commit 前等待 ACK；其他源端会话不会先看到事务；
- `AFTER_COMMIT`：源端引擎已 commit、给当前客户端回包前等待；其他会话可能已经看到事务。

它们描述的是**源端等待钩子**，不是副本 apply 等级，都不能直接翻译为 PG remote_apply。

### 5.2 超时降级才是关键失败语义

源码中 ACK 使用 timed wait；超时后增加计数并 `switch_off()` 半同步等待，即为避免副本故障无限
阻塞业务而退回异步。DBA 不能只看配置为 ON，还要看运行状态和超时：

```sql
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_status';
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_wait_timeouts';
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients';
```

本机没有安装半同步插件，因此远端等待由 MySQL 8.4.10 本地源码确认，没有伪造双节点实测。

## 6. 实际故障如何判断

### 客户端 COMMIT 超时

不能直接认定失败。网络可能断在服务端完成提交之后；先按业务唯一键/幂等键查源库，再核对
binlog/GTID。无条件重试可能制造重复操作。

### 主机异常后源库有数据、复制端没有

核对故障前两项刷盘参数、半同步实际状态、超时计数和源/副本 GTID。redo=1 只能解释 InnoDB
恢复，不能证明 binlog 尾部或远端接收状态。

### 为性能把 redo 改成 2

先回答容忍 mysqld 崩溃还是整机掉电、binlog/PITR 是否仍需强持久、存储是否兑现 flush、RPO
如何演练。没有答案就只是把故障窗口藏起来。

### 半同步开启但副本查询仍旧

半同步主要约束 ACK 位置，不等于 SQL/applier 已执行。需要 read-after-write 时，应等待目标 GTID
在副本执行完成，或将读取留在源端，而不是把半同步当成 remote_apply。

## MySQL 实操：命令与 SQL

前置条件：MySQL 8.4 已启动，root 可通过本机 socket 登录。参数矩阵会临时改变所有新事务的
持久性，需要 `SYSTEM_VARIABLES_ADMIN`，只能在实验实例运行；不能可靠保存原值时立即停止。

### 7.1 连接、准备与提交/回滚

```bash
mysql -uroot -S /tmp/mysql.sock
```

```sql
SELECT VERSION(), @@log_bin, @@binlog_format, @@gtid_mode,
       @@sync_binlog, @@innodb_flush_log_at_trx_commit,
       @@innodb_redo_log_capacity, @@binlog_expire_logs_seconds;

DROP DATABASE IF EXISTS mysql_lab_redo_log;
CREATE DATABASE mysql_lab_redo_log;
USE mysql_lab_redo_log;
CREATE TABLE t_log_lab(
  id INT PRIMARY KEY,
  note VARCHAR(80) NOT NULL,
  amount INT NOT NULL
) ENGINE=InnoDB;

SHOW BINARY LOG STATUS;
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log%lsn';

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

正确结果：最终只有 `id=101, amount=101`；提交后 Position 前进，回滚后不再前进；redo LSN
仍可能因回滚和后台活动继续前进。

用刚记录的实际文件和位置解码，以下数字只是本次样例：

```bash
mysqlbinlog --base64-output=DECODE-ROWS -vv \
  --start-position=926 --stop-position=1460 \
  /data/myhome/mydata/mysql/binlog.000017
```

应看到 id=101 的 `Write_rows`、`Update_rows`、`Xid/COMMIT`，看不到 rollback marker。

### 7.2 完整持久性矩阵

退出 mysql CLI，在专题目录执行：

```bash
chmod +x evidence/mysql-durability-matrix.sh
evidence/mysql-durability-matrix.sh
```

脚本顺序：读取原值 → 建表 → 六组各提交 100 次 → 输出指标 → trap 恢复参数并删库。成功时有
六行各 100 commits，redo=1 的 fsync 增量显著高于 0/2。结束后验证：

```bash
mysql -uroot -S /tmp/mysql.sock -e "
SELECT @@GLOBAL.innodb_flush_log_at_trx_commit, @@GLOBAL.sync_binlog;
SHOW DATABASES LIKE 'mysql_lab_redo_log';"
```

本机应恢复为 `1,1` 且实验库不存在。若脚本被强制终止，手工恢复：

```sql
SET GLOBAL innodb_flush_log_at_trx_commit = 1;
SET GLOBAL sync_binlog = 1;
DROP DATABASE IF EXISTS mysql_lab_redo_log;
```

不要在生产执行 `SET PERSIST` 做本实验；本文不执行 binlog purge、kill -9 或存储断电。

### 7.3 日常检查与半同步判定

```sql
SELECT @@GLOBAL.innodb_flush_log_at_trx_commit AS redo_policy,
       @@GLOBAL.sync_binlog AS binlog_policy,
       @@GLOBAL.log_bin AS binlog_enabled,
       @@GLOBAL.binlog_format AS binlog_format;
SHOW GLOBAL STATUS LIKE 'Innodb_redo_log%lsn';
SHOW BINARY LOG STATUS;
SHOW PLUGINS;
SHOW GLOBAL VARIABLES LIKE 'rpl_semi_sync_source%';
SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source%';
```

后两组为空表示半同步插件未安装，不能宣称获得远端 ACK。本节只读，无需清理。

## 8. 源码与 Evidence

- PG 本地同步/异步：`src/backend/access/transam/xact.c:1473-1531`
- PG 五档枚举：`src/include/access/xact.h:68-80`
- PG WRITE/FLUSH/APPLY：`src/backend/replication/syncrep.c:1123-1140`
- MySQL redo 0/1/2：`storage/innobase/trx/trx0trx.cc:1756-1802`
- binlog 组提交：`sql/binlog.cc:8915-9088`
- 半同步等待点：`plugin/semisync/semisync_source_plugin.cc:66-117,300-325`
- 超时降级：`plugin/semisync/semisync_source.cc:770-807`
- 双引擎结果：`evidence/durability-matrix-output.txt`
- 可复现脚本：`evidence/mysql-durability-matrix.sh`、`pg-commit-modes.sql`
- 原提交/回滚实验：`evidence/mysql-output.txt`、`pg-output.txt`

边界：本机没有同步 PG standby、MySQL replica 或半同步插件，远端 ACK/apply 只做源码锚定，留给
复制专题做双节点故障实验；本文没有断电/kill -9，不把参数语义冒充真实掉电恢复结果。
