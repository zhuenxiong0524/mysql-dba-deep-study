# Binlog 主从复制与 GTID：PG 物理流复制对照

> 实测版本：MySQL 8.4.10、PostgreSQL 18.4。本文沿用 MySQL 8.4 的 source/replica 术语；源码中的 `Master_info`、`start_slave_threads` 等历史命名按原名保留。

## 问题边界与结论矩阵

本专题回答“事务如何从一个实例异步到达另一个实例”，不展开计划 14 的延迟诊断、并行复制调优，也不把复制等同于自动故障切换。

| 结论 | MySQL 观察 | PG 对照 | 生产含义 |
|---|---|---|---|
| 发送、接收、应用分段 | receiver 已收 GTID `:6`，applier 仍停在 `:5` | receive LSN 领先 replay LSN 16MB | “已经收到”不等于“查询可见” |
| GTID auto-position 是集合协议 | replica 发送已执行/已接收集合，自动取得缺失 GTID | PG 用 timeline + LSN 起点 | 切源时不再手填 file/position，但仍需连续日志 |
| relay log 是接收与应用的缓冲 | SQL_THREAD 停止时 relay space 增长 | standby `pg_wal` 接收继续、startup replay 暂停 | 分别监控网络积压和应用积压 |
| GTID 不是事务副本 | 缺少 GTID `:7` 的 binlog 后报 1236 | 缺 WAL 段同样无法恢复 | 复制槽/保留策略必须覆盖最大中断窗口 |
| 复制身份不同 | 事务保留 source UUID:GNO | PG standby 重放物理 WAL LSN | GTID 处理拓扑与去重，LSN 表示物理日志位置 |

## PG 基线与 MySQL 心智迁移

PG 物理流复制链是：primary 的 WAL sender 从某个 timeline/LSN 读取 WAL 字节，standby 的 walreceiver 接收并写入 `pg_wal`，startup process 独立 replay。MySQL 链是：source binlog sender 读取逻辑 binlog event，replica receiver 写 relay log，applier 再执行 event。

```text
PostgreSQL
backend commit → WAL → walsender → walreceiver → standby pg_wal → startup replay
                  LSN       sent      receive/flush             replay

MySQL
session commit → binlog → Binlog_sender → receiver → relay log → applier
                 GTID         source      IO thread               SQL thread
```

相似点是接收与应用解耦；关键差异是复制内容：PG physical replication 是整个集群的物理 WAL 变化，DDL 也随 WAL replay；MySQL binlog replication 传输 event，可按库表过滤、支持多 channel，并能在兼容约束内跨版本。旧 PG 笔记中“物理复制不支持 DDL”的说法不准确，本专题不沿用。

## MySQL 完整调用链

### 1. `START REPLICA` 创建两条执行线

```text
SQLCOM_SLAVE_START
  └─ start_slave_cmd(rpl_replica.cc:733)
      └─ start_slave
          └─ start_slave_threads(:2061)
              ├─ REPLICA_IO  → start_slave_thread(handle_slave_io)
              └─ REPLICA_SQL → start_slave_thread(handle_slave_sql)
```

`START REPLICA IO_THREAD` 与 `START REPLICA SQL_THREAD` 正是这两个 mask 的外部控制面。两条线程各有 run lock、condition、running flag 和错误状态，所以能独立启停。本次实验只停 SQL_THREAD，receiver 仍为 `ON`。

### 2. GTID auto-position 请求

receiver 连接 source、验证版本/UUID、注册后进入 `request_dump()`：

```cpp
enum_server_command command =
    mi->is_auto_position() ? COM_BINLOG_DUMP_GTID : COM_BINLOG_DUMP;

if (command == COM_BINLOG_DUMP_GTID) {
  gtid_executed.add_gtid_set(mi->rli->get_gtid_set());
  gtid_executed.add_gtid_set(gtid_state->get_executed_gtids());
  rpl->flags |= MYSQL_RPL_GTID;
  rpl->fix_gtid_set = fix_gtid_set;
}
```

请求集合包含 relay log 中完整接收的 GTID 和本机全局 executed GTID。source 的 `com_binlog_dump_gtid()` 解码集合，`mysql_binlog_send()` 创建 `Binlog_sender`；sender 用 `find_first_log_not_in_gtid_set()` 找到第一个可能含缺失事务的 binlog，再逐 event 发送不在 replica 集合中的事务。

这不是“向 source 问当前 file/position 再保存”。file/position 仍存在于内部和监控输出，但 auto-position 的切入依据是集合差。

### 3. Source sender

```text
COM_BINLOG_DUMP_GTID
  └─ com_binlog_dump_gtid(rpl_source.cc)
      └─ mysql_binlog_send
          └─ Binlog_sender::run
              ├─ init / check_start_file
              ├─ find_first_log_not_in_gtid_set
              └─ send_binlog
                  └─ send_events → send_packet
```

sender 是 source 上服务该复制连接的 THD 上下文。它维护 replica 提交来的 GTID set、当前 binlog 文件/位置、上个 event 类型和网络 packet。活动日志读到末尾后会等待新 event，而不是退出；这对应 `SHOW REPLICA STATUS` 的 `Waiting for source to send event`。

### 4. Receiver 写 relay log

```text
handle_slave_io
  ├─ safe_connect
  ├─ get_master_version_and_clock / get_master_uuid
  ├─ register_slave_on_master
  ├─ request_dump
  └─ loop: read_event
      └─ queue_event
          ├─ 校验 event/checksum/事务边界
          ├─ 写入 Relay_log_info::relay_log
          ├─ 完整事务结束后推进 Retrieved_Gtid_Set
          └─ flush receiver metadata
```

`Retrieved_Gtid_Set` 只在完整事务接收完成后加入该 GTID，不能在刚看到 GTID event 时就推进，否则重连会误以为一个半截事务已经完整持有。本次暂停 applier 后，connection status 已显示 received `:1-6`，而全局 executed 仍是 `:1-5`。

### 5. Applier 执行 relay log

```text
handle_slave_sql
  └─ Applier_reader 读取 relay log event
      └─ exec_relay_log_event
          ├─ ev->shall_skip
          ├─ apply_event / update_pos
          ├─ commit source GTID transaction
          └─ 推进 Executed_Gtid_Set 与 applier metadata
```

单线程 applier 按事务顺序执行。本专题显式保持单线程，以便分离 receiver/applier 关系；多线程 coordinator/worker 是后续延迟专题。GTID event 的 `do_shall_skip()` 会检查 GTID 是否已经执行，避免 relay log 重读或重连导致同一事务重复应用。

## 核心数据结构

### `Master_info`：receiver/channel 连接状态

```cpp
class Master_info : public Rpl_info {
 public:
  char host[HOSTNAME_LENGTH + 1];
  Relay_log_info *rli;
  THD *info_thd;
  int slave_running;
 private:
  char user[USERNAME_LENGTH + 1];
  char password[MAX_PASSWORD_LENGTH + 1];
  Gtid_monitoring_info *gtid_monitoring_info;
  Transaction_boundary_parser transaction_parser;
};
```

它属于一个 replication channel，保存连接参数、receiver THD、运行/错误状态、source UUID 和已接收事务边界。类名仍叫 Master，但 SQL 与日志已经使用 source。

### `Relay_log_info`：relay log 与 applier 状态

```cpp
class Relay_log_info : public Rpl_info {
 public:
  Master_info *mi;
  MYSQL_BIN_LOG relay_log;
  THD *info_thd;
  int slave_running;
  bool is_relay_log_recovery;
  Rpl_filter *rpl_filter;
};
```

它拥有 relay log、applier 位置、过滤规则、执行错误和恢复状态。`Master_info::rli` 把 receiver 与同一 channel 的 applier 连接起来，但两者生命周期可独立控制。

### 三组不能混为一谈的位置

| 状态 | 含义 | 本次暂停时 |
|---|---|---|
| source `gtid_executed` | source 已提交的 GTID | `:1-6` |
| `RECEIVED_TRANSACTION_SET` / Retrieved | relay log 已完整接收 | `:1-6` |
| replica `gtid_executed` / Executed | applier 已提交、本机已执行 | `:1-5` |

receiver lag 看 source 与 received 的差；apply lag 看 received 与 executed 的差。`Seconds_Behind_Source` 只是时间估算，线程停止时可能为 NULL，也不能替代集合差和线程错误。

PG 的 `WalSnd` 保存 sent/write/flush/apply LSN，`WalRcvData` 保存 receiver 状态、receive start、written/flushed/latest WAL end。它同样明确分开接收进度与 replay 进度。

## 状态变化与关键分支

### 正常状态机

```text
未配置
  └─ CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1
      └─ configured / stopped
          └─ START REPLICA
              ├─ receiver: CONNECTING → ON → waiting/receiving
              └─ applier:  ON → reading/applying/waiting

STOP REPLICA SQL_THREAD
  receiver=ON, applier=OFF, Retrieved 可推进, Executed 停止

START REPLICA SQL_THREAD
  applier=ON, relay backlog 被应用, Executed 追上 Retrieved
```

本次重启前配置了 `skip_replica_start=ON`，所以 mysqld 重启不会自动拉起 channel；手工 `START REPLICA` 后，连接参数与位置从 `mysql.slave_master_info` / `mysql.slave_relay_log_info` 恢复，300 行保持一致。这也验证 MySQL 8.4 的仓库已经是表式持久化。

### GTID auto-position 的关键分支

- `gtid_mode` 必须为 ON；匿名事务不能满足纯 GTID 定位。
- auto-position 与显式 `SOURCE_LOG_FILE/SOURCE_LOG_POS` 互斥。
- replica 集合覆盖某 GTID时，source sender跳过它；relay log已有重复时，applier仍有GTID去重保护。
- source 的 `gtid_executed` 知道缺口但对应 binlog 已 purge 时，无法生成事务内容，receiver 停止。

本次真实失败为：source 已到 `:1-7`，replica 仅 `:1-6`，source 只剩新空日志。connection status：

```text
SERVICE_STATE=OFF
LAST_ERROR_NUMBER=13114
Got fatal error 1236 from source ... source purged required binary logs ...
missing transactions are 'source_uuid:7'
```

处理不是跳过 GTID。正确选择是从其他仍保留该事务的节点补齐，或重新从一致备份 provision replica；随后扩大 binlog 保留窗口并监控最落后副本。

### MySQL 8.4 配置迁移分支

实验第一次把旧配置 `source_info_repository=TABLE` 放入 8.4.10，初始化直接报 `MY-000067 unknown variable`。MySQL 8.4 已使用表式仓库，不再接受这个旧变量。升级配置必须用目标版本启动验证，不能原样搬运旧模板。

## MySQL 行为实验：GTID 自动追平与重启续接

两个全新实例使用不同 `server_id` 和 `server_uuid`，source 先创建库表并写 100 行，replica 没有做初始快照，因为 source 从第一条业务 binlog 开始仍保留全部历史。配置 auto-position 后结果：

| 阶段 | source | replica | 结论 |
|---|---:|---:|---|
| 建链前 | 100 | 无业务表 | source binlog 含 GTID `:1-5` |
| auto-position 追平 | 100 | 100 | DDL 与 DML 都由 binlog 补齐 |
| 再写 200、恢复应用 | 300 | 300 | `WAIT_FOR_EXECUTED_GTID_SET(...)=0` |
| replica 重启 | 300 | 300 | channel 元数据持久化可续接 |

生产库通常已经 purge 早期 binlog，不能照搬“空 replica 直接追全部历史”。标准过程是：在 source/备份节点取得一致物理备份，记录其中 `gtid_executed`，restore 到 replica，再用 auto-position 获取备份点之后的缺失事务。

## MySQL 路径实验：receiver 与 applier 分离

制造关系：

```text
source_executed = received = :1-6
replica_executed = :1-5
receiver=ON, applier=OFF
```

操作顺序为 `STOP REPLICA SQL_THREAD`，source 单事务写入 200 行，等待 `RECEIVED_TRANSACTION_SET` 等于 source set。观察到：

- replica 查询仍为 100 行；
- receiver `ON`，applier `OFF`；
- relay log space 从此前位置增长到 10205 bytes；
- received 到 `:1-6`，executed 仍为 `:1-5`；
- 恢复 SQL_THREAD 后变为 300 行，executed 到 `:1-6`。

所以 300 行不是“碰巧最终一致”：内部证据证明事务先进入 relay log，再由另一执行线上提交。

## PostgreSQL 同构实验

PG 同样先写 100 行并用 `pg_basebackup -R -X stream` 建 standby。正常时 `sent/write/flush/replay` 都为 `0/3000000`。随后执行 `pg_wal_replay_pause()`、primary 写 200 行并 switch WAL：

```text
standby rows=100
walreceiver status=streaming
receive_lsn=0/4000000
replay_lsn=0/3000000
receive - replay = 16777216 bytes
```

resume 后 standby 为 300 行，receive/replay 都到 `0/4000000`；重启后仍处于 recovery 且 300 行一致。

与 MySQL 对照：PG pause 的是 startup replay，walreceiver 仍写 `pg_wal`；MySQL 停的是 SQL_THREAD，receiver 仍写 relay log。PG 使用物理 LSN 连续性，MySQL 使用 GTID 身份加 binlog event 内容。两者都必须分别观察 receive 与 apply。

## MySQL 实操：命令与 SQL

下面是一份从初始化到验证的单机实验 Runbook。生产部署需使用不同主机、TLS、密钥管理和一致备份，不要使用示例密码或 `--initialize-insecure`。

### 1. 前置配置

source 配置：

```ini
[mysqld]
basedir=/usr/local/mysql/mysql-8.4.10
datadir=/data/mysql-source
socket=/tmp/mysql-source.sock
port=33061
server_id=1301
log_bin=/data/mysql-source/binlog
gtid_mode=ON
enforce_gtid_consistency=ON
log_replica_updates=ON
binlog_format=ROW
innodb_buffer_pool_size=64M
mysqlx=OFF
pid_file=/data/mysql-source/mysqld.pid
log_error=/data/mysql-source/error.log
```

replica 配置：

```ini
[mysqld]
basedir=/usr/local/mysql/mysql-8.4.10
datadir=/data/mysql-replica
socket=/tmp/mysql-replica.sock
port=33062
server_id=1302
log_bin=/data/mysql-replica/binlog
relay_log=/data/mysql-replica/relay-bin
gtid_mode=ON
enforce_gtid_consistency=ON
log_replica_updates=ON
relay_log_recovery=ON
skip_replica_start=ON
innodb_buffer_pool_size=64M
mysqlx=OFF
pid_file=/data/mysql-replica/mysqld.pid
log_error=/data/mysql-replica/error.log
```

`server_id`、`server_uuid` 必须唯一。复制循环中的每个可提升节点应启用 `log_replica_updates`。MySQL 8.4 不要再配置 `source_info_repository` 或 `relay_log_info_repository`。

首次初始化并启动的完整命令：

```bash
MYSQL_HOME=/usr/local/mysql/mysql-8.4.10
sudo install -d -o mysql -g mysql -m 0750 /data/mysql-source /data/mysql-replica
sudo -u mysql "$MYSQL_HOME/bin/mysqld" \
  --defaults-file=/etc/mysql-source.cnf --initialize-insecure
sudo -u mysql "$MYSQL_HOME/bin/mysqld" \
  --defaults-file=/etc/mysql-replica.cnf --initialize-insecure
sudo -u mysql "$MYSQL_HOME/bin/mysqld" \
  --defaults-file=/etc/mysql-source.cnf --daemonize
sudo -u mysql "$MYSQL_HOME/bin/mysqld" \
  --defaults-file=/etc/mysql-replica.cnf --daemonize
```

连接方式示例：source `mysql -uroot -S /tmp/mysql-source.sock`，replica `mysql -uroot -S /tmp/mysql-replica.sock`。先执行：

```sql
SELECT @@version,@@server_id,@@server_uuid,@@gtid_mode,
       @@enforce_gtid_consistency,@@log_bin,@@log_replica_updates;
```

预期：两端 UUID/server_id 不同，其余开关符合配置。

### 2. Source 准备复制账号与测试对象

```sql
CREATE USER 'repl'@'10.%' IDENTIFIED BY 'replace-me';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'10.%';

CREATE DATABASE rep_lab;
CREATE TABLE rep_lab.events (
  id BIGINT PRIMARY KEY,
  payload VARCHAR(64) NOT NULL,
  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB;
INSERT INTO rep_lab.events VALUES (1,'seed',CURRENT_TIMESTAMP(6));
SHOW BINARY LOG STATUS;
SELECT @@GLOBAL.gtid_executed;
```

生产应限制来源网段、启用 TLS，并优先在 `START REPLICA USER/PASSWORD` 或受控凭据机制中提供密码，避免长期明文保存在 connection metadata。

### 3. Provision replica

实验 source 全新且所有 binlog 尚在，可以让空 replica 从头获取。生产必须先按计划 12 用 XtraBackup 建立一致副本：

```text
source/backup node: xtrabackup --backup → 保存 xtrabackup_binlog_info
restore host:        xtrabackup --prepare → --copy-back → chown
replica:             启动隔离实例，核对备份内 gtid_executed
```

确认 replica 数据状态与备份 GTID 对应后再建链，不能把一个任意时刻的数据目录与 auto-position 拼接。

### 4. 配置并启动 GTID 复制

在 replica 执行：

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='10.0.0.10',
  SOURCE_PORT=3306,
  SOURCE_USER='repl',
  SOURCE_PASSWORD='replace-me',
  SOURCE_AUTO_POSITION=1,
  SOURCE_SSL=1,
  GET_SOURCE_PUBLIC_KEY=1;

START REPLICA;
SHOW WARNINGS;
SHOW REPLICA STATUS\G
```

若已经启用验证正确的 TLS，通常不依赖 RSA public-key 获取；示例同时列出该选项是为了标明 `caching_sha2_password` 非 TLS实验连接的要求，生产按认证设计取舍。

正确判断不能只看一个 `Yes`：

```sql
SELECT CHANNEL_NAME,SERVICE_STATE,LAST_ERROR_NUMBER,LAST_ERROR_MESSAGE,
       RECEIVED_TRANSACTION_SET
FROM performance_schema.replication_connection_status;

SELECT CHANNEL_NAME,SERVICE_STATE
FROM performance_schema.replication_applier_status;

SELECT @@GLOBAL.gtid_executed;
SELECT COUNT(*) FROM rep_lab.events;
```

预期：connection/applier 都是 `ON`，错误号 0，业务行数一致。取得 source GTID 后可在 replica 设有界等待：

```sql
SELECT WAIT_FOR_EXECUTED_GTID_SET('source_uuid:1-100',10);
-- 0=已追到；1=超时；NULL=错误。不要无限等待。
```

### 5. 分线程暂停与恢复

```sql
-- Replica：仅停应用，receiver 继续接收
STOP REPLICA SQL_THREAD;

SELECT SERVICE_STATE,RECEIVED_TRANSACTION_SET
FROM performance_schema.replication_connection_status;
SELECT SERVICE_STATE
FROM performance_schema.replication_applier_status;
SELECT @@GLOBAL.gtid_executed;

START REPLICA SQL_THREAD;
SHOW REPLICA STATUS\G
```

判断：暂停时 connection 为 ON、applier 为 OFF，received 可领先 executed；恢复后两集合追平。排障时可以分别启停，但生产暂停前要确认 relay log 空间和 binlog 保留窗口。

### 6. 常见错误与停止条件

- `LAST_ERROR_NUMBER=13114` 且消息含 source error 1236/purged required binary logs：立即停止反复重试，寻找含缺失 GTID 的节点或重建 replica。
- receiver OFF：先读 `replication_connection_status` 的错误，检查网络、认证、TLS、source UUID 与日志保留。
- applier OFF：读 coordinator/worker 错误，不要直接设置 `sql_replica_skip_counter`；GTID 事务需要查清数据分歧原因。
- source 与 replica 出现相同 `server_uuid`：停止建链，删除的是克隆副本的 `auto.cnf` 并在确认实例身份后重启生成新 UUID，不能碰 source。

### 7. 清理与回滚

在 replica：

```sql
STOP REPLICA;
RESET REPLICA ALL;
```

`RESET REPLICA ALL` 会删除连接参数和 relay log，执行前必须确认该 channel 不再需要且凭据/拓扑已有记录。在 source：

```sql
DROP USER IF EXISTS 'repl'@'10.%';
DROP DATABASE IF EXISTS rep_lab;
```

最后分别正常停止两个实验实例，再删除明确的实验 datadir。生产 replica 的数据目录不能作为“清理”对象。

## 源码—实验—生产映射

| 源码状态变化 | 实验证据 | 生产观察/动作 |
|---|---|---|
| `start_slave_threads` 分别启动 IO/SQL | receiver ON、applier OFF 可并存 | 分别查 connection/applier status |
| `request_dump` 编码 received+executed set | 无 file/pos 配置仍追到 100 行 | 切源用 GTID 集合，但先正确 provision |
| sender 查第一个未覆盖 binlog | source 全历史存在时空副本可补齐 | 保留期覆盖副本离线窗口 |
| `queue_event` 在事务边界推进 Retrieved | received `:6`、executed `:5` | received 不能当查询可见进度 |
| applier 提交后推进 Executed | resume 后 300 行、GTID `:6` | 用有界 GTID wait 验证读一致性 |
| source 找不到缺失 GTID 内容 | 13114/1236，明确缺 `:7` | 补日志或重建，不能凭集合恢复 |
| PG walreceiver 与 replay 分离 | receive-replay=16MB、行数仍 100 | 同样拆分传输 lag 与 replay lag |

## 验证边界与未实测范围

- 已实测：MySQL 8.4.10 单 channel、ROW、GTID auto-position、receiver/applier 独立启停、重启续接、purged-required-GTID 错误；PG 18.4 basebackup、physical slot、异步 streaming、pause/resume replay、重启续接。
- 未实测：MySQL 多线程 applier、半同步复制、多 source channel、复制过滤、TLS 证书部署、跨版本复制、网络断连重试、failover；PG synchronous replication、级联复制和 promotion。这些属于计划 14 或 HA 专题。
- 单机回环网络不能代表生产延迟与吞吐；本实验只证明状态关系和路径，不给性能结论。
- MySQL source 故障时，异步复制已提交但未接收的事务可能丢失；本专题没有宣称零 RPO。

## Evidence

- `evidence/mysql-gtid-replication-lab.sh`：MySQL 可复现实验与自动清理。
- `evidence/mysql-gtid-replication-output.txt`：GTID、线程状态、relay 位置、重启和 1236 失败。
- `evidence/mysql84-removed-repository-option-failure.txt`：8.4 拒绝旧 repository 变量。
- `evidence/pg-physical-replication-lab.sh`：PG 同构实验。
- `evidence/pg-physical-replication-output.txt`：receive/replay LSN 路径结果。
- `evidence/source-locations.txt`：MySQL/PG 18.4 源码入口与旧文章边界。
