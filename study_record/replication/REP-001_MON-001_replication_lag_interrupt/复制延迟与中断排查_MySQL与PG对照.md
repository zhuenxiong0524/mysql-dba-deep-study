# 复制延迟与中断排查：MySQL 与 PostgreSQL 对照

> 环境：MySQL 8.4.10、PostgreSQL 18.4。实验均使用专用双实例，覆盖网络中断、接收/应用分离、MySQL 1062 数据冲突与修复。

## 问题边界与结论

“复制延迟”不是一个指标，而是一条管道中不同阶段的状态差：

```text
Source committed
  → sender 可提供
  → receiver 已接收
  → relay log 已落地
  → applier 已执行
  → 业务查询可见
```

本专题得到五个结论：

1. 必须分别诊断 transport lag 和 apply lag；`Seconds_Behind_Source` 不能告诉你哪一段坏了。
2. source 短时不可达属于 receiver 故障。receiver 进入 `CONNECTING`，applier 仍能消费已有 relay log，source 恢复后按 GTID 自动续接。
3. MySQL binlog 是逻辑 event，replica 本地数据分歧会令 applier 报 1062；此时 receiver 仍可能继续接收，Retrieved 与 Executed 分叉。
4. 修复 1062 必须先确认 source 的权威数据、消除 replica 分歧，再重启 applier；盲目跳过会把隐藏分歧固化。
5. PG physical standby 默认处于 recovery/read-only，无法用普通 DML制造同类行冲突，但 transport 与 replay 仍是两段独立进度。

## PG 基线与 MySQL 心智迁移

| 诊断层 | MySQL | PostgreSQL | 含义 |
|---|---|---|---|
| 发送端 | source binlog file/position、GTID | primary current/flush WAL LSN | 日志是否已产生/仍被保留 |
| 接收端 | receiver state、Retrieved GTID | walreceiver state、receive/flush LSN | 网络与落地进度 |
| 应用端 | applier/coordinator/worker、Executed GTID | startup replay LSN | 数据可见进度 |
| 错误面 | connection status 与 worker error | walreceiver/server log | 先确定故障属于哪段 |
| 本地分歧 | replica 可写时可能出现 | physical standby 普通表只读 | MySQL 应设置只读并控制高权限账号 |

PG 的 `sent_lsn/write_lsn/flush_lsn/replay_lsn` 是同一条物理 WAL 链上的不同水位。MySQL 的 source GTID、Retrieved GTID 与 Executed GTID表达事务身份集合；两者都不能只看一个“秒数”。

## MySQL 完整调用链

### Receiver 断连与重试

```text
handle_slave_io(rpl_replica.cc:5314)
  ├─ safe_connect
  ├─ request_dump(COM_BINLOG_DUMP_GTID)
  └─ read_event loop
      ├─ 正常 → queue_event → relay log / Retrieved_Gtid_Set
      └─ network error
          └─ try_to_reconnect(:5257)
              ├─ mi->report(connection error)
              ├─ slave_sleep(mi->connect_retry)
              ├─ safe_reconnect
              └─ request_dump(当前 received+executed GTID set)
```

source 停止后，本次 connection status 从 `ON/0` 变成 `CONNECTING/2003`，错误文本给出 attempt 3/10 和 1 秒间隔。applier status 仍为 ON，因为两条线程生命周期独立。source 重启后 receiver 清除连接错误并重新请求 GTID 流，replica 从 100 行续到 150 行。

### Applier 执行失败

```text
handle_slave_sql
  └─ coordinator 读取 relay log
      └─ worker 执行 source GTID transaction
          └─ exec_relay_log_event
              ├─ Write_rows_log_event::apply_event
              ├─ handler 写入 InnoDB
              └─ HA_ERR_FOUND_DUPP_KEY
                  ├─ worker.last_error = 1062/message/GTID
                  ├─ Relay_log_info::report
                  ├─ applier SERVICE_STATE=OFF
                  └─ Executed_Gtid_Set 不推进
```

本次在 replica 预先放入主键 1000，再让 source 用一个事务插入 1000、1001。worker 1 执行 source GTID `:7` 时在第一行报 1062，整个 source 事务未提交，因此 Executed 仍停在 `:6`；receiver 已把完整事务接收，Retrieved 到 `:7`。

消除本地冲突行后重新启动 SQL_THREAD，同一 GTID `:7` 被重新执行，1000 与 1001 两行一起出现，Executed 到 `:7`。这是“修复后重放”，不是跳过。

### 可观测投影

Performance Schema 并非另一套复制状态。`table_replication_connection_status::make_row()` 从 `Master_info` 的 running/reconnect/last_error 和 received set 构造 `ON/OFF/CONNECTING`；`table_replication_applier_status_by_worker::make_row()` 从 `Relay_log_info` 或 `Slave_worker` 投影 error、当前事务和时间戳。

```cpp
if (mi->slave_running == MYSQL_SLAVE_RUN_CONNECT)
  service_state = ON;
else if (mi->slave_running == MYSQL_SLAVE_RUN_NOT_CONNECT)
  service_state = CONNECTING;
else
  service_state = OFF;
```

因此看到 `CONNECTING` 就应沿 receiver 连接链查，不应去处理 SQL worker；看到 worker 1062 则网络通道通常仍正常。

## 核心数据结构

```cpp
class Master_info : public Rpl_info {
  char host[];
  uint port;
  uint connect_retry;
  int retry_count;
  int slave_running;
  THD *info_thd;
  Relay_log_info *rli;
  // receiver connection error + received transaction boundary
};

class Relay_log_info : public Rpl_info {
  MYSQL_BIN_LOG relay_log;
  int slave_running;
  THD *info_thd;
  // coordinator/applier position, last_error, Executed progress
};

class Slave_worker : public Relay_log_info {
  // worker id, current group/GTID, last_error, retry state
};
```

关键所有权：一个 channel 的 `Master_info` 代表 receiver，指向 `Relay_log_info`；启用多线程 applier 时 coordinator 把事务分派给多个 `Slave_worker`。本机默认产生 4 个 worker 行，只有 worker 1 保存 1062，其他 worker error 为 0。

进度不变量：

```text
Executed_Gtid_Set ⊆ 已完整接收且可重放的事务集合
Retrieved_Gtid_Set 可以领先 Executed_Gtid_Set
Executed 只有事务成功提交或被明确标记执行后才推进
```

如果 receiver 仍接收而 applier 停止，relay log 占用持续增长；最终可能耗尽磁盘，所以“IO 线程正常”并不代表可以等待不处理。

## 状态变化与关键分支

### 故障分类状态机

```text
健康: connection=ON, applier=ON, Retrieved≈Executed

Source down:
  connection ON → CONNECTING(error 2003) → ON
  applier    ON → ON（可消费已有 relay）

Apply conflict:
  connection ON → ON，Retrieved继续推进
  applier    ON → OFF(error 1062)，Executed停止

修复分歧:
  删除/更正仅存在 replica 的冲突数据
  START REPLICA SQL_THREAD
  applier OFF → ON，失败 GTID重新执行并提交
```

### `Seconds_Behind_Source` 为什么不够

源码根据 applier 看到的 source event timestamp、当前时间和时钟差计算。线程未运行时可以为 NULL；没有新 event 或某些初始化状态可显示 0；多线程执行时更新时间还受提交队列影响。因此：

- 0 不证明 receiver 与 applier 都健康；
- NULL 不自动等于网络故障；
- 秒数不能说明 backlog 有多少事务/字节；
- 跨主机时钟偏差会污染解释。

生产判断至少组合线程状态、last error、Retrieved/Executed 集合差、relay log space、commit timestamp 和业务校验。

### 不应直接跳过 1062

1062 可能来自重复写、错误初始备份、replica 被本地写入、非确定性语句或拓扑回环。`sql_replica_skip_counter` / 注入空 GTID 只会改变执行记录，不会证明数据一致。只有确认该 source 事务的每一项效果已经等价存在时，才可能制定经审批的跳过方案；默认修复或重建。

## MySQL 行为实验：断连后自动续接

实验建立 100 行健康副本，然后正常关闭 source：

| 阶段 | connection | error | applier | replica 行数 |
|---|---|---:|---|---:|
| 健康 | ON | 0 | ON | 100 |
| source down | CONNECTING | 2003 | ON | 100 |
| source restart + 写 50 | ON | 0 | ON | 150 |

错误文本明确为连接 `127.0.0.1:33331` 被拒绝，按 `SOURCE_CONNECT_RETRY=1` 重试。重启后 error log 报 replication resumed，GTID auto-position 没有重复应用已有 100 行。

PG 对照：primary 停机后 `pg_stat_wal_receiver` 行数变为 0，standby 仍处于 recovery 且可读 150 行；primary 重启后 walreceiver 自动从 LSN `0/4000000` streaming，新增 50 行后 standby 达到 200。

## MySQL 路径实验：1062 时接收继续、应用停止

制造目标关系：

```text
Source GTID = Retrieved GTID = :1-7
Executed GTID = :1-6
connection=ON
applier=OFF, worker 1 error=1062
```

实测完全满足：source 有 152 行；replica 只有本地冲突行 1000，`COUNT(*) WHERE id=1000` 为 1 且 payload 为 `replica-local-divergence`；worker 错误指向 source GTID `:7`、`Write_rows`、表 `rep_lab.events`、主键 1000、binlog end position 2229。

删除这条经确认只属于 replica 的冲突行后，启动 SQL_THREAD：replica 变为 152 行，1000/1001 两行均来自 source，Executed 到 `:7`，`WAIT_FOR_EXECUTED_GTID_SET(...)=0`。

这条路径同时证明错误归属、事务原子回滚和可恢复性；只看最终 152 行无法证明这些机制。

## PostgreSQL 路径实验：transport 与 replay 分离

PG standby 执行本地 INSERT 直接返回：

```text
ERROR 25006: cannot execute INSERT in a read-only transaction
LOCATION: PreventCommandIfReadOnly, utility.c:407
```

所以 physical standby 的普通表不能像可写 MySQL replica 那样制造本地行分歧。随后暂停 WAL replay，primary 写 50 行并 switch WAL：walreceiver 仍为 streaming、written/flush/latest end 都到 `0/4000000`，但 replay 留在 `0/3000000`，查询仍为 100 行，差值恰为 16MB。resume 后才变成 150 行。

PG 源码中 walreceiver 独立写/flush WAL；`PerformWalRecovery` 所在 startup process 检查 pause state 并等待。与 MySQL receiver/applier 分段相同，但物理只读约束减少了一类人为数据漂移。

## MySQL 实操：命令与 SQL

以下命令用于已配置 GTID replication 的生产诊断。全部先读状态，不要一上来执行 RESET、skip 或改数据。

### 1. 连接与前置确认

```bash
# Replica；生产使用 login-path 或受控凭据
mysql --login-path=replica_admin -h replica.example -P 3306
```

```sql
SELECT @@hostname,@@port,@@server_uuid,@@server_id,
       @@gtid_mode,@@read_only,@@super_read_only;
```

预期：确认自己连接的是 replica，GTID 为 ON；生产副本通常应 `read_only=ON, super_read_only=ON`。身份未确认前禁止修复数据。

### 2. 一次采集三段状态

```sql
SELECT NOW(6) AS sampled_at,
       CHANNEL_NAME,SERVICE_STATE,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE,
       LAST_HEARTBEAT_TIMESTAMP,RECEIVED_TRANSACTION_SET
FROM performance_schema.replication_connection_status\G

SELECT CHANNEL_NAME,SERVICE_STATE,REMAINING_DELAY
FROM performance_schema.replication_applier_status\G

SELECT CHANNEL_NAME,WORKER_ID,SERVICE_STATE,
       LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE,
       LAST_APPLIED_TRANSACTION,
       LAST_APPLIED_TRANSACTION_ORIGINAL_COMMIT_TIMESTAMP,
       LAST_APPLIED_TRANSACTION_END_APPLY_TIMESTAMP,
       APPLYING_TRANSACTION,
       APPLYING_TRANSACTION_START_APPLY_TIMESTAMP
FROM performance_schema.replication_applier_status_by_worker
ORDER BY CHANNEL_NAME,WORKER_ID\G

SELECT @@GLOBAL.gtid_executed;
SHOW REPLICA STATUS\G
```

判断顺序：

1. connection 为 OFF/CONNECTING：先处理 transport；读 connection last error。
2. connection ON、applier OFF：处理 apply error；读 worker/coordinator last error。
3. 两者 ON 但 Retrieved 领先 Executed：应用能力不足、锁等待或延迟配置。
4. 两集合接近但业务读旧：确认读到正确实例、事务快照和应用侧路由。

### 3. Source 不可达处置

```sql
-- Replica，只读诊断
SELECT SERVICE_STATE,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE
FROM performance_schema.replication_connection_status;
SHOW REPLICA STATUS\G
```

```bash
# 从 replica 主机验证网络；设置短超时
timeout 3 bash -c '</dev/tcp/source.example/3306'
```

检查 source mysqld、监听、DNS/路由、防火墙、账号/TLS、source UUID 和 binlog 保留。短时故障由 receiver 自动重试；若错误为 1236/purged required binary logs，停止等待，按计划 13 从其他节点补日志或重建副本。

恢复后用 GTID 有界验证：

```sql
SELECT WAIT_FOR_EXECUTED_GTID_SET('source_uuid:1-12345',30);
-- 0=已追平；1=30 秒超时；NULL=参数/状态错误
```

### 4. 1062 应用冲突调查与修复

先停止条件：仅当 applier 已因该错误停止，且 receiver/relay 磁盘仍安全时调查。不要先跳事务。

```sql
SELECT WORKER_ID,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE,
       APPLYING_TRANSACTION
FROM performance_schema.replication_applier_status_by_worker
WHERE LAST_ERROR_NUMBER <> 0\G

SELECT @@GLOBAL.gtid_executed;
SELECT * FROM rep_lab.events WHERE id=1000;
```

在 source 单独查询同一主键和失败 GTID 对应 binlog event：

```bash
mysqlbinlog --base64-output=DECODE-ROWS -vv \
  --start-position=2000 --stop-position=2300 /archive/binlog.000003
```

只有确认 replica 的冲突行是错误本地数据、source 行是权威值后，才在变更单和备份保护下执行：

```sql
-- Replica T1：确认 SQL_THREAD 已停止
STOP REPLICA SQL_THREAD;

-- 避免修复动作进入 replica 自己的 binlog并污染下游；先评估拓扑
SET SESSION sql_log_bin=0;
DELETE FROM rep_lab.events
WHERE id=1000 AND payload='replica-local-divergence';
SELECT ROW_COUNT();  -- 必须为预期的 1，否则 ROLLBACK/停止

START REPLICA SQL_THREAD;
```

```sql
-- Replica T2：验证，不要只看线程 ON
SELECT SERVICE_STATE FROM performance_schema.replication_applier_status;
SELECT * FROM rep_lab.events WHERE id IN (1000,1001) ORDER BY id;
SELECT @@GLOBAL.gtid_executed;
SELECT WAIT_FOR_EXECUTED_GTID_SET('source_uuid:7',30);
```

若冲突范围不清、source/replica 都有业务写入、校验差异广泛或修复 SQL 不能唯一命中，停止在线修补，重新 provision replica。

### 5. 延迟量化

```sql
SHOW REPLICA STATUS\G
-- Relay_Log_Space：接收缓存规模
-- Seconds_Behind_Source：辅助趋势，不作为唯一告警

SELECT GTID_SUBTRACT(
  (SELECT RECEIVED_TRANSACTION_SET
   FROM performance_schema.replication_connection_status
   WHERE CHANNEL_NAME=''),
  @@GLOBAL.gtid_executed) AS received_not_executed;
```

GTID set 能告诉你缺哪些事务身份，不能直接给出字节/TPS成本；结合 relay log space、worker commit timestamps、磁盘 IO、锁等待和 source TPS 解释。

### 6. 清理与回滚

诊断查询无需清理。实验环境完成后：

```sql
STOP REPLICA;
RESET REPLICA ALL; -- 破坏性：仅确认废弃该 channel 后执行
```

生产修复发生错误时，不要用反向 DML盲目“回滚修复”；停止 SQL_THREAD、保留 relay/binlog 和证据，依据备份或重新 provision 回到已验证的一致状态。

## 源码—实验—生产映射

| 源码状态 | 实验证据 | 生产动作 |
|---|---|---|
| `try_to_reconnect` 按 connect_retry 等待 | CONNECTING/2003，1秒重试 | 查 receiver 错误和网络，不动 applier 数据 |
| receiver/applier 独立 running state | source down 时 applier仍 ON | 分段告警，不合并成一个 replication up |
| queue_event 推进 Retrieved | 1062 时 Retrieved 到 `:7` | 评估 relay 磁盘与接收积压 |
| worker 保存 apply error/GTID | worker 1 报 1062 与主键1000 | 锁定失败事务和权威数据 |
| 失败事务不推进 Executed | Executed停 `:6` | 修复后重放，不伪造执行记录 |
| PG executor只读检查 | SQLSTATE 25006 | physical standby默认防本地漂移 |
| PG receive/replay分离 | LSN差16MB、查询仍100行 | 分开监控 transport/replay lag |

## 验证边界

- 已实测：MySQL GTID receiver 断连/重连、connection 2003、MTS worker 1062、Retrieved/Executed 分叉、定点删除冲突后重放追平；PG physical streaming 断连恢复、replay pause、standby只读错误25006。
- 未实测：网络丢包/高延迟、磁盘写满、relay log损坏、锁等待导致的自然延迟、超大事务、MTS依赖调度、复制过滤、半同步超时、自动 failover。
- 本次单机回环实验不提供延迟阈值或吞吐结论；生产阈值必须根据RPO、磁盘余量和追赶速率制定。
- 删除冲突行是本实验已知真值下的修复演示，不是通用1062处方。无法证明权威数据时应重建。

## Evidence

- `evidence/mysql-replication-failure-lab.sh` 与 output：2003重连、1062、GTID分叉和修复。
- `evidence/pg-replication-failure-lab.sh` 与 output：25006、LSN分叉和断连续接。
- `evidence/source-locations.txt`：MySQL/PG源码入口、状态与错误投影。
- `evidence/server-log-excerpts.txt`：关键服务端日志摘要。
