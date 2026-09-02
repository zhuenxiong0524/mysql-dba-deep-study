# Backup / Restore / PITR：PG WAL 与 XtraBackup + Binlog 对照

> 环境：MySQL 8.4.10、Percona XtraBackup 8.4.0-6、PostgreSQL 18.4。本文结论来自本机双引擎实验，不把“备份命令成功”当成“能够恢复”。

## 先给结论

1. XtraBackup 的在线物理备份不是某一瞬间的数据目录副本。数据页在不同时间复制，后台同时追赶 redo；`--prepare` 再用这段 redo 完成崩溃恢复，才形成可启动的一致副本。
2. MySQL 的恢复链分工明确：XtraBackup + redo 恢复到备份一致点，binlog 再把状态推进到目标事务之前。redo 不能替代 binlog 做业务 PITR。
3. PG 的 base backup 与 PITR 都由 WAL 串起来；MySQL 则是 redo 与 binlog 两段式交接。迁移心智时最容易错在这里。
4. 增量链不是“目录按日期排好即可”。上一层 `to_lsn` 必须等于下一层 `from_lsn`；还原后应核对行数、校验值、GTID 和被排除的破坏事务。
5. `LOCK INSTANCE FOR BACKUP` 保护备份期间不发生危险的元数据、文件和日志清理变化，不是为了停止普通 DML。本次 full backup 持锁 9.019 秒，写入仍持续，备份中包含 825 条并发提交。

## PG 基线与 MySQL 心智迁移

| 问题 | PostgreSQL 18.4 | MySQL 8.4 + XtraBackup |
|---|---|---|
| 在线物理副本的一致性 | backup 起止信息 + WAL | 数据文件副本 + XtraBackup 捕获的 InnoDB redo |
| 物理副本之后继续推进 | 继续回放 WAL | 回放 binlog，redo 不承担业务 PITR |
| PITR 停止条件 | time、XID、LSN、named restore point | mysqlbinlog 的 position/time 或人工筛选事务边界 |
| 日志归档责任 | `archive_command` 连续归档 WAL | 必须另行保留全量 binlog；备份内的位置文件只是交接点 |
| 新恢复分支 | promotion 后创建新 timeline | 恢复实例应使用新 server identity，并规划 GTID/binlog 分支 |
| 增量物理备份 | PG 17+ 原生增量 base backup | XtraBackup delta/page tracking 或 page LSN full scan |

关键差异不是命令名字，而是日志职责。PG DBA 习惯说“base backup + WAL”；到了 MySQL 必须拆成：

```text
数据页复制 ── XtraBackup redo ── prepare 后的一致备份点
                                      │
                                      └── xtrabackup_binlog_info
                                                  │
                                                  ▼
                                      binlog 事务回放 ── 目标点
```

`xtrabackup_binlog_info` 是两段恢复的桥，不是 binlog 归档本身。只有位置而没有对应日志文件，仍然无法 PITR。

## MySQL 完整调用链

### 在线 full backup

```text
main(xtrabackup.cc:7948)
  └─ xtrabackup_backup_func(:4238)
      ├─ Redo_Log_Data_Manager::init
      │   ├─ 找最大 checkpoint
      │   └─ 初始化 redo reader/parser/writer
      ├─ Redo_Log_Data_Manager::start
      │   ├─ find_start_checkpoint_lsn
      │   ├─ 创建 xtrabackup_logfile
      │   └─ 后台 copy_func 持续复制/解析 redo
      ├─ 复制 InnoDB tablespace
      ├─ backup_start(backup_copy.cc:1410)
      │   ├─ LOCK INSTANCE FOR BACKUP
      │   ├─ 复制非 InnoDB/元数据文件
      │   ├─ flush binary logs
      │   └─ 获取 log_status：LSN、binlog file/position、GTID
      ├─ redo_mgr.stop_at(log_status.lsn, checkpoint_lsn)
      ├─ 写 xtrabackup_checkpoints / xtrabackup_binlog_info
      └─ UNLOCK INSTANCE
```

数据页复制期间 redo 线程必须跑在覆盖风险之前。`stop_at()` 不是随便停止：它等待扫描和解析推进到服务器报告的停止 LSN，同时保留最后 checkpoint，最终形成 `to_lsn` 与 `last_lsn`。

### prepare、增量合并与 copy-back

```text
main
  ├─ --prepare → xtrabackup_prepare_func(xtrabackup.cc:6804)
  │   ├─ 读 xtrabackup_checkpoints
  │   ├─ 校验 backup_type
  │   ├─ 增量时校验 base.to_lsn == incremental.from_lsn
  │   ├─ 把 *.delta 合并到基础 tablespace
  │   ├─ InnoDB recovery 应用 xtrabackup_logfile
  │   └─ 写回 log-applied 或 full-prepared
  └─ --copy-back
      ├─ 拒绝非 full-prepared 备份
      └─ 复制文件到空 datadir；属主仍需显式修复
```

增量恢复的顺序是“准备基础备份以接收增量 → 逐层合并 → 最后一层完成 prepare”。本次只跑了一层增量，但源码校验适用于多层链；多层时每一层都必须连续。

### Binlog PITR

```text
xtrabackup_binlog_info 的 file/position
  └─ mysqlbinlog --start-position
      ├─ 解码 Format_description / GTID / row events
      ├─ 只输出到 --stop-position 之前的完整事件
      └─ mysql 客户端执行输出 SQL → 恢复实例
```

`--start-position` 只作用于输入列表的第一个日志，`--stop-position` 只作用于最后一个日志。多文件回放必须按 index 顺序把全部文件传给一次命令，或逐个明确边界。position 是 binlog 字节边界，不是业务时间；停在事务中间会产生不完整事务警告或错误，因此应先用 `mysqlbinlog --base64-output=DECODE-ROWS -vv` 找到破坏事务前一个完整事务的结束位置。

## 核心数据结构

XtraBackup 的核心不是一个复制循环，而是协调 reader、parser、writer 与停止条件的 `class Redo_Log_Data_Manager`：

```cpp
class Redo_Log_Data_Manager {
 public:
  bool init();
  bool start();
  bool stop_at(lsn_t lsn, lsn_t checkpoint_lsn);
  lsn_t get_start_checkpoint_lsn() const;
  lsn_t get_last_checkpoint_lsn() const;
  lsn_t get_stop_lsn() const;
 private:
  os_thread_t thread;
  std::atomic_bool aborted;
  std::atomic<lsn_t> stop_lsn;
  lsn_t start_checkpoint_lsn;
  lsn_t last_checkpoint_lsn;
  Log_file_reader reader;
  Log_file_writer writer;
  Log_parser parser;
  Redo_Log_Consumer redo_log_consumer;
};
```

几个 LSN 不能混读：

| 字段 | 含义 | 恢复用途 |
|---|---|---|
| `from_lsn` | 增量开始边界；full 为 0 | 必须匹配上一层 `to_lsn` |
| `to_lsn` | 最后 checkpoint LSN | 增量链的下一层起点 |
| `last_lsn` | 备份停止时捕获到的 redo 末端 | 覆盖数据文件复制期间产生的变化 |
| `flushed_lsn` | 服务器报告的 flushed redo | 审计捕获边界，不等同于增量链连接键 |

本次增量实际采用 page LSN full scan，而不是 page tracking：日志明确记录 `using the full scan for incremental backup`。因此“增量文件更小”不等于“扫描开销也按变化量缩小”。

PG 对应的停止判断由 WAL record 驱动：

```c
static bool
recoveryStopsAfter(XLogReaderState *record)
{
    if (recoveryTarget == RECOVERY_TARGET_NAME &&
        rmid == RM_XLOG_ID && info == XLOG_RESTORE_POINT)
    {
        if (strcmp(recordRestorePointData->rp_name,
                   recoveryTargetName) == 0)
        {
            recoveryStopAfter = true;
            return true;
        }
    }
    return false;
}
```

named restore point 是“应用该 restore-point WAL record 后停止”。本次误删发生在它之后，所以恢复保留了 1000 条好数据、排除了 DELETE。

## 状态变化与关键分支

### XtraBackup 状态机

```text
full-backuped ── --prepare --apply-log-only ──> log-applied
      │                                         │
      └──────────── --prepare ──────────────────┴─> full-prepared

incremental(from=A,to=B)
      └─ 仅当 base.to_lsn=A 才能合并；合并后 base.to_lsn=B
```

- `full-backuped`：文件复制完成但仍可能包含未提交事务和跨时刻数据页，不能直接当恢复成功。
- `log-applied`：redo 已应用但保留为可继续接增量的中间态。
- `full-prepared`：完成回滚/恢复，可供 copy-back。
- 增量错链：源码直接比较 `metadata_to_lsn != incremental_lsn` 并报错，不会猜测正确顺序。
- redo 不足：prepare 后实际日志 LSN 未达到目标 `metadata_to_lsn`，报告 transaction log corrupted。
- copy-back：目标目录必须为空，且备份必须完成 prepare。

### Backup lock 分支

MySQL 语法入口 `Sql_cmd_lock_instance::execute()` 先检查 `BACKUP_ADMIN`，再申请 backup MDL。源码中的锁模式关系是：备份持有 `MDL_SHARED`，会破坏备份一致性的普通操作申请 `MDL_INTENTION_EXCLUSIVE`，两者冲突；常规行 DML 不因此全部冻结。

```cpp
bool Sql_cmd_lock_instance::execute(THD *thd) {
  if (check_global_access(thd, BACKUP_ADMIN_ACL) ||
      acquire_exclusive_backup_lock(
          thd, thd->variables.lock_wait_timeout, false))
    return true;
  return false;
}
```

binlog purge/reset 路径也获取 `Shared_backup_lock_guard`，所以备份锁能避免 XtraBackup 正在记录交接点时所需 binlog 被并发清除。它不替代备份窗口内的 DDL 变更管控。

### PG 恢复分支

`PerformWalRecovery()` 每读一条 WAL 都先调用 `recoveryStopsBefore()`，重放后再调用 `recoveryStopsAfter()`。时间/XID/LSN 的 inclusive 语义决定在事务结束记录前还是后停；named restore point 在 after 分支匹配。达到目标并 promote 后创建新 timeline，本次由 timeline 1 切到 2。

## MySQL 行为实验：在线备份期间 DML 是否继续

实验先写 2000 行，再启动慢速并发写入 3000 行，同时执行 full backup。

| 观察点 | 实测值 |
|---|---:|
| 备份前源库 | 2000 行 |
| 备份结束后源库 | 5000 行 |
| 备份一致点恢复 | 2825 行 |
| 其中备份期间提交 | 825 行 |
| backup lock 时长 | 9.019 秒 |
| 备份 binlog GTID | `:1-2830` |

结论：恢复结果既不是开始时的 2000，也不是命令返回后的 5000，而是 XtraBackup 建立的一致点 2825。并发 DML 没被 backup lock 全面阻塞；redo 使跨时刻复制的数据页能够在 prepare 时收敛。

证据同时暴露了权限陷阱：第一次账号缺少 Performance Schema `SELECT`，XtraBackup 返回 `1142/42000`。只背一份旧版最小权限清单并不可靠；应以当前 PXB 版本的权限检查输出为准。本实验为隔离实例补了全局 `SELECT` 后跑通，生产应进一步收窄并审计。

## MySQL 路径实验：增量恢复后回放到误删前

路径完全跑通：

```text
5000 行
  └─ full base (to_lsn=28264821)
      └─ 再写 1000 → incremental
          from_lsn=28264821, to_lsn=28324292
          binlog=binlog.000006:198, GTID=:1-6005
          └─ 再写 1000 → 记录 stop-position=1645198
              └─ DELETE 7000 行，GTID=:7006

restore base+incremental = 6000 行
replay [198,1645198) = 7000 行，GTID=:1-7005
DELETE(:7006) 未进入恢复实例
```

这证明三件事：增量 LSN 连续；物理恢复只到 6000 行备份点；binlog 从备份交接点推进 1000 条且精确排除了误删事务。只检查服务能启动不足以证明 PITR 正确。

## PostgreSQL 同构实验

PG 侧使用相同业务故事：base backup 时 5000 行，之后写 1000 行，建立 `before_bad_delete` restore point，再 DELETE 6000 行。`pg_verifybackup` 成功，archive failed_count 为 0。恢复配置指定 named target 并 promote，结果为 6000 行，其中 1000 行来自 base backup 之后；日志显示：

```text
redo starts at 0/2000028
recovery stopping at restore point "before_bad_delete"
redo done at 0/3032908
selected new timeline ID: 2
```

对照结论：PG 的同一条 WAL 链既弥合 base backup 的物理复制窗口，又把实例推进到业务目标；MySQL 的物理一致性由 redo 完成，目标点推进由 binlog 完成。能力相似，故障排查入口不同。

## MySQL 实操：命令与 SQL

以下是可独立执行的最小 runbook。路径要替换为本机实际值；生产环境密码使用 `mysql_config_editor`、受控配置文件或密钥系统，不要把密码留在 shell history。

### 1. 连接、前置检查与备份账号

```sql
-- 管理连接：mysql -uroot -S /tmp/mysql.sock
SELECT VERSION();
SHOW VARIABLES WHERE Variable_name IN
  ('datadir','log_bin','gtid_mode','server_uuid','innodb_redo_log_capacity');
SHOW BINARY LOG STATUS;

CREATE USER 'xtrabackup'@'localhost' IDENTIFIED BY 'replace-me';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES,
      REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
-- PXB 8.4 本次还查询了 Performance Schema；实验用下列授权跑通。
GRANT SELECT ON performance_schema.* TO 'xtrabackup'@'localhost';
GRANT SELECT ON mysql.component TO 'xtrabackup'@'localhost';
SHOW GRANTS FOR 'xtrabackup'@'localhost';
```

判断：`log_bin=ON` 才能执行后续 PITR；备份用户必须通过当前版本 XtraBackup 启动时的权限检查。若出现 `ERROR 1142 (42000)`，按报错对象补最小权限，不要改用 root 掩盖问题。

### 2. full backup、prepare、copy-back

```bash
MYSQL_CNF=/etc/my.cnf
BACKUP_ROOT=/data/backup/mysql
FULL_DIR="$BACKUP_ROOT/full-$(date +%F-%H%M%S)"
RESTORE_DIR=/data/mysql-restore

install -d -m 0750 "$FULL_DIR"
xtrabackup --backup \
  --defaults-file="$MYSQL_CNF" \
  --user=xtrabackup --password='replace-me' \
  --socket=/tmp/mysql.sock \
  --target-dir="$FULL_DIR" \
  2>&1 | tee "$FULL_DIR/backup.log"

grep -E 'backup_type|from_lsn|to_lsn|last_lsn|flushed_lsn' \
  "$FULL_DIR/xtrabackup_checkpoints"
cat "$FULL_DIR/xtrabackup_binlog_info"
grep 'completed OK' "$FULL_DIR/backup.log"

xtrabackup --prepare --target-dir="$FULL_DIR" \
  2>&1 | tee "$FULL_DIR/prepare.log"
grep 'backup_type = full-prepared' "$FULL_DIR/xtrabackup_checkpoints"
grep 'completed OK' "$FULL_DIR/prepare.log"

# 停止目标 mysqld，并确认 RESTORE_DIR 是专用空目录。
install -d -o mysql -g mysql -m 0750 "$RESTORE_DIR"
xtrabackup --copy-back \
  --target-dir="$FULL_DIR" --datadir="$RESTORE_DIR" \
  2>&1 | tee "$FULL_DIR/copy-back.log"
chown -R mysql:mysql "$RESTORE_DIR"
```

判断：backup、prepare、copy-back 三段日志都必须出现 `completed OK`；prepare 后必须是 `full-prepared`。不要把“已有文件的生产 datadir”直接作为 copy-back 目标，也不要在原实例仍运行时覆盖文件。

启动隔离恢复实例后验证：

```sql
SELECT @@port, @@server_uuid, @@global.gtid_executed;
SELECT COUNT(*), MIN(id), MAX(id) FROM backup_lab.t_pitr;
CHECKSUM TABLE backup_lab.t_pitr;
SHOW BINARY LOG STATUS;
```

### 3. 建立并恢复增量链

```bash
BASE_DIR="$BACKUP_ROOT/base"
INC1_DIR="$BACKUP_ROOT/inc-001"

xtrabackup --backup --defaults-file="$MYSQL_CNF" \
  --user=xtrabackup --password='replace-me' --socket=/tmp/mysql.sock \
  --target-dir="$BASE_DIR"

xtrabackup --backup --defaults-file="$MYSQL_CNF" \
  --user=xtrabackup --password='replace-me' --socket=/tmp/mysql.sock \
  --target-dir="$INC1_DIR" --incremental-basedir="$BASE_DIR"

awk '/^(backup_type|from_lsn|to_lsn|last_lsn)/' \
  "$BASE_DIR/xtrabackup_checkpoints" \
  "$INC1_DIR/xtrabackup_checkpoints"

# 中间态，允许继续接增量。
xtrabackup --prepare --apply-log-only --target-dir="$BASE_DIR"
# 合并 inc-001；有更多增量时逐层重复并保持顺序。
xtrabackup --prepare --apply-log-only --target-dir="$BASE_DIR" \
  --incremental-dir="$INC1_DIR"
# 最终 prepare，转为 full-prepared。
xtrabackup --prepare --target-dir="$BASE_DIR"
grep 'backup_type = full-prepared' "$BASE_DIR/xtrabackup_checkpoints"
```

判断：必须先人工核对 `BASE_DIR.to_lsn == INC1_DIR.from_lsn`；不相等即错链，停止恢复，不要复制 delta 文件强行拼接。

### 4. 确认事务边界并执行 binlog PITR

先从已合并备份取得起点：

```bash
cat "$BASE_DIR/xtrabackup_binlog_info"
# 示例输出：binlog.000006  198  uuid:1-6005

mysqlbinlog --base64-output=DECODE-ROWS -vv \
  /safe/binlog-archive/binlog.000006 | less
```

在误操作前一个完整事务的 `COMMIT`/`Xid` 后确定停止 position。先生成、审阅，再执行：

```bash
START_POS=198
STOP_POS=1645198
BINLOG=/safe/binlog-archive/binlog.000006
PITR_SQL=/data/backup/mysql/pitr-reviewed.sql

mysqlbinlog --start-position="$START_POS" --stop-position="$STOP_POS" \
  --disable-log-bin "$BINLOG" > "$PITR_SQL"

rg -n 'DELETE|DROP|TRUNCATE' "$PITR_SQL"
mysql -uroot -S /tmp/mysql-restore.sock < "$PITR_SQL"
```

`--disable-log-bin` 适合隔离恢复验证，避免回放再次写入恢复实例 binlog；若恢复实例要作为新生产分支或复制源，是否保留回放 binlog 必须按拓扑设计决定。多个 binlog 文件必须连续提供，并只对首尾文件设置边界。

回放后的结果判断：

```sql
SELECT COUNT(*) AS recovered_rows,
       SUM(id BETWEEN 10001 AND 11000) AS post_backup_rows
FROM backup_lab.t_pitr;
SELECT @@GLOBAL.gtid_executed;
CHECKSUM TABLE backup_lab.t_pitr;
```

本次预期与实测都是 7000 行、post_backup_rows=1000、GTID 到 `:7005`，而误删为 `:7006`。如果只对到行数但 GTID、关键业务聚合或校验值异常，仍判恢复失败。

### 5. 清理与回滚

```sql
-- 仅在确认不再需要备份账号时执行
DROP USER IF EXISTS 'xtrabackup'@'localhost';
```

先停止隔离恢复实例，再删除明确的临时 datadir 和过期备份；生产备份只能按保留策略及“至少一次恢复演练已通过”后淘汰。不要使用未展开变量或宽泛通配符清理。原生产实例在演练过程中无需回滚，因为恢复始终在隔离目录、独立 socket/port 进行。

## 失败模式与生产判断

| 失败模式 | 表象 | 根因/处理 |
|---|---|---|
| 备份账号权限不全 | 1142/42000 | 按 PXB 实际查询对象补最小权限 |
| redo 被覆盖或不连续 | backup/prepare 中止 | 提高 redo 容量、降低备份时长，监控捕获线程；不能忽略错误 |
| 增量 LSN 不连续 | prepare 拒绝 | 找正确上一层或重新做 base |
| 只保留位置未归档 binlog | 无法推进到目标 | 独立连续归档并校验 binlog |
| stop-position 在事务中间 | 不完整事务警告/失败 | 用 verbose 解码确认完整事务边界 |
| 备份能启动但数据错 | 表面“恢复成功” | 核对行数、业务聚合、checksum、GTID、破坏事务缺席 |
| PG WAL archive 有缺口 | recovery 找不到下一段 | 同时监控 archived_count 和 failed_count，恢复演练验证连续性 |

RPO 由“最后一个可用且已验证的 binlog/WAL”决定，不由最近一次 full backup 的时间单独决定。RTO 则至少包括取回备份、prepare/增量合并、copy-back、日志回放、业务校验和流量切换。

## 源码—实验—生产映射

| 源码机制 | 实验证据 | 生产动作 |
|---|---|---|
| `Redo_Log_Data_Manager` 持续捕获并 `stop_at` | 恢复点含 825 条备份期间提交 | 监控 redo 捕获速度与备份耗时 |
| checkpoint 元数据状态机 | `full-backuped → full-prepared` | 每阶段检查状态与 `completed OK` |
| `base.to_lsn == inc.from_lsn` | `28264821 == 28264821` | 生成并校验备份链清单 |
| `LOCK INSTANCE FOR BACKUP` 与危险操作互斥 | 持锁 9.019 秒但 DML 继续 | 控制 DDL/purge，观察锁等待 |
| `xtrabackup_binlog_info` 写交接点 | `binlog.000006:198`, GTID `:6005` | 备份位置与 binlog 归档一并保管 |
| mysqlbinlog 首尾 position 过滤 | 回放到 1645198 得 7000 行，排除 `:7006` | 先解码审阅，再在隔离实例回放 |
| PG `recoveryStopsAfter` 匹配 restore point | 6000 行、timeline 2 | promotion 后按新时间线管理 WAL |

## 验证边界

- 已实测：单机 MySQL 8.4.10、PXB 8.4.0-6；full、单层 incremental、prepare、copy-back、单文件 binlog position PITR；并发 DML；PG 18.4 basebackup + WAL archive + named restore point。
- 未实测：多层增量、压缩/加密/xbstream/xbcloud、远端对象存储、超大库并发、复制集恢复、MySQL page tracking、多文件跨日志 PITR、时间边界 PITR、部分表恢复。
- 本次使用 `--no-server-version-check` 的实验脚本，仅因 PXB 通用版本检查把 8.4.0 与本机 8.4.10 判为不一致，且已核实同属 8.4 系列；生产不能把该参数当成跨大版本兼容保证。
- 源码证据基于 PXB tag `percona-xtrabackup-8.4.0-6`（commit `ec789837e7abf35fc5f1f54ae885f870d37883c5`）、MySQL 8.4.10 与 PG 18.4。后续升级必须重新核对调用链和权限。

## 可审计证据

- `evidence/mysql-xtrabackup-full-output.txt`：并发 full backup、元数据与恢复结果。
- `evidence/mysql-xtrabackup-incremental-pitr-output.txt`：LSN 链、GTID、停止 position 与 PITR 结果。
- `evidence/mysql-xtrabackup-permission-failure.txt`：1142/42000 权限失败。
- `evidence/pg-basebackup-pitr-output.txt`：PG 校验、WAL 恢复点与 timeline 结果。
- `evidence/source-locations.txt`：三套源码的版本与精确入口。

