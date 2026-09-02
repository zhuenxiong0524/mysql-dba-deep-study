# Crash Recovery：PostgreSQL WAL 与 InnoDB Redo/Undo 对照

> 实测版本：PostgreSQL 18.4、MySQL 8.4.10；日期：2026-09-02。故障注入只针对全新初始化的
> 专用数据目录，不触碰日常学习实例。

## 1. 结论速览

| 待证明结论 | PostgreSQL | MySQL/InnoDB | 迁移含义 |
|---|---|---|---|
| 强持久提交能否保留 | `synchronous_commit=on` 的行保留 | redo=1、sync_binlog=1 的行保留 | 进程崩溃后两边都兑现本地提交 |
| 未提交行如何处理 | WAL 前滚后，缺少 COMMIT 的 xid 不可见 | redo 先恢复页，再用 undo 回滚未提交事务 | 最终结果相同，恢复路径不同 |
| 从哪里开始恢复 | checkpoint redo pointer | latest valid checkpoint LSN | 都不是从日志历史开头重放 |
| 何时开放连接 | startup process 完成 redo 与收尾后 | InnoDB redo/字典恢复、事务/XA 协调后 | `ready` 日志之前不能把实例当恢复完成 |
| kill -9 证明什么 | 进程级非正常退出 | 进程级非正常退出 | 不等于 OS 掉电、存储丢写或日志损坏 |

本次同构实验中，T1 在未提交事务内部都能看到 id=2，外部会话都只看到已提交 id=1。强制终止
数据库进程并重启后，两边都只剩 id=1。

## 2. 崩溃恢复真正解决的两个问题

数据库恢复不是简单地“把日志再执行一遍”，而要同时解决：

1. **物理一致性**：内存中的脏页可能部分或完全没写入数据文件，日志必须把页推进到一致状态；
2. **事务一致性**：崩溃点存在未提交、已提交或已 prepare 的事务，恢复后不能暴露错误状态。

PG 和 InnoDB 在第一点相似，第二点差异很大：

```text
PostgreSQL
checkpoint → WAL redo → 恢复事务提交状态 → 未提交 xid 的 tuple 不可见

InnoDB
checkpoint → redo 扫描/页重放 → 恢复事务与锁 → undo 回滚未提交事务 → XA 协调
```

因此，InnoDB 的“redo + undo”不能压缩成 PG 的一句“WAL replay”。

## 3. PostgreSQL 基线

### 3.1 checkpoint 是起点，不是恢复终点

PG checkpoint 把一个可恢复起点记录到控制文件/WAL。崩溃后 `StartupXLOG()` 检查控制文件状态；
若上次状态是 `DB_IN_PRODUCTION`，日志报告 database system was interrupted，然后读取 checkpoint
记录及 redo pointer。

恢复循环从 checkpoint 指向的记录开始调用各资源管理器的 redo 函数。日志中：

```text
redo starts at 0/177B600
redo done at 0/177B658
database system is ready to accept connections
```

checkpoint 之前已经保证可恢复的数据不需要从头重放；checkpoint 之后的 WAL 负责补齐数据页状态。

### 3.2 为什么 PG 不需要逐行 undo

崩溃前未提交事务可能已经把 heap tuple 写进数据页，WAL 也可能被重放。但 tuple 上的 xmin 指向
一个没有 COMMIT 状态的事务，正常快照不会把它视为可见。后续 VACUUM 可以清理死 tuple。

这与 InnoDB 的关键差异是：PG 主要通过 tuple 头和事务提交状态判定可见性，而不是启动时沿每条
记录的 undo 链把数据页恢复成“从未写过”。所以“恢复后查不到 id=2”不代表其物理 tuple/WAL
从未存在。

## 4. InnoDB 恢复链

### 4.1 redo 从 latest valid checkpoint LSN 前滚

`recv_recovery_from_checkpoint_start()`：

1. `recv_find_max_checkpoint()` 找最新有效 checkpoint；
2. 将 checkpoint/scanned/recovered LSN 初始化为 checkpoint LSN；
3. 从该位置向后扫描 redo；
4. 将 redo 记录按页组织，再由 `recv_apply_hashed_log_recs()` 应用到对应文件页；
5. 完成字典动态元数据等恢复收尾。

源码注释明确说明 MySQL 8 可以从落在 redo record 中间的 checkpoint LSN 开始，扫描时寻找下一组
完整记录边界。这正是“fuzzy checkpoint 可恢复”的实现基础：checkpoint 不要求瞬间把所有脏页
刷净，而是保证恢复所需 redo 仍在日志窗口中。

### 4.2 redo 为什么会重放未提交事务的页修改

redo 回答的是“如何把页恢复到崩溃前日志描述的物理状态”，不是“业务事务最终应不应该存在”。
未提交 INSERT 产生的页修改及其 undo 页修改也可能需要 redo，否则页本身可能不一致，undo 链也
无法可靠重建。

所以恢复顺序必须是：先 redo，使数据页和 undo 信息达到可解释状态；再由事务恢复逻辑决定哪些
事务需要回滚。

### 4.3 undo 才处理未提交事务

`trx_rollback_or_clean_recovered()` 的注释直接区分：

- 已提交事务：清理可能残留的 insert undo；
- 未提交事务：使用 undo 回滚；
- XA PREPARED：不擅自当普通未提交事务回滚，交给 MySQL Server 层协调。

本实验的 id=2 是普通未提交事务，重启后消失；error log 同时出现 `Starting XA crash recovery` 和
`XA crash recovery finished`，最后才出现 `ready for connections`。

### 4.4 redo 恢复与 binlog/XA 恢复不是一回事

InnoDB redo 先保证引擎物理一致；Server 随后需要根据 binlog 和 prepare 状态解决跨日志提交结果。
这延续了 REDO-001/LOG-001 第一阶段的结论：MySQL 有 redo 与 binlog 两个事实域，正常提交靠内部
两阶段协议协调，崩溃启动时也要恢复这段协议状态。

## 5. 同构故障实验

### 5.1 实验时序

两边都使用以下顺序：

```text
初始化专用实例
→ 创建同结构表
→ 提交 id=1
→ T1 BEGIN，插入 id=2，不提交并保持连接
→ 外部会话确认只能看到 id=1
→ kill -9 专用数据库主进程
→ 原 T1 收到连接中断
→ 启动同一专用数据目录
→ 查询结果、检查恢复日志
→ 优雅停库
```

### 5.2 结果

| 观察点 | PostgreSQL | MySQL |
|---|---|---|
| T1 内部 | id=1、id=2 | id=1、id=2 |
| 外部会话崩溃前 | 仅 id=1 | 仅 id=1 |
| T1 故障错误 | server closed connection unexpectedly | ERROR 2013 Lost connection |
| 重启后 | 仅 id=1 | 仅 id=1；CHECK TABLE OK |
| 恢复证据 | interrupted → redo starts/done → ready | InnoDB init → XA crash recovery → ready |

结果证明事务原子性和本地提交持久性，但没有证明两个引擎内部算法相同。

## 6. 实验边界：不要把 kill -9 叫作断电

`kill -9` 只终止数据库进程。OS page cache、磁盘控制器和文件系统仍正常，因此：

- 可以验证未正常 shutdown 时的启动恢复路径；
- 可以验证已持久提交与未提交事务的逻辑结果；
- 不能验证 OS 掉电时 cache 中数据是否丢失；
- 不能验证 torn write、磁盘丢写、redo/WAL 文件损坏；
- 不能外推 redo=0/2、sync_binlog=0 或 PG synchronous_commit=off 的掉电 RPO。

真正的掉电测试需要虚拟机/块设备故障注入，并校验存储 flush/barrier 语义，不能在学习主实例上做。

## MySQL 实操：命令与 SQL

### 前置条件和停止条件

- 使用专用端口 `33311`、socket `/tmp/mysql-crash-redo001.sock`；
- 专用目录固定为 `/data/myhome/mydata/mysql-crash-redo001`；
- 日常 `/data/myhome/mydata/mysql` 必须处于范围之外；
- 若专用目录已存在、3306 日常实例被命令命中、或无法读到专用 pid-file，立即停止；
- 需要对专用 mysqld 执行 `kill -9`，仅限本实验目录。

### 7.1 初始化与启动

配置文件内容：

```ini
[mysqld]
datadir=/data/myhome/mydata/mysql-crash-redo001
port=33311
socket=/tmp/mysql-crash-redo001.sock
pid-file=/data/myhome/mydata/mysql-crash-redo001/mysqld.pid
log-error=/data/myhome/mydata/mysql-crash-redo001/error.log
innodb-buffer-pool-size=32M
innodb-redo-log-capacity=32M
performance-schema=OFF
max-connections=20
log-bin=/data/myhome/mydata/mysql-crash-redo001/binlog
binlog-format=ROW
innodb-flush-log-at-trx-commit=1
sync-binlog=1
```

```bash
MYSQL_BASE=/usr/local/mysql/mysql-8.4.10
LAB_DATA=/data/myhome/mydata/mysql-crash-redo001
LAB_CNF=$PWD/evidence/mysql-crash.cnf

test ! -e "$LAB_DATA" || { echo "STOP: dedicated target exists"; exit 2; }
mkdir -p "$LAB_DATA"
"$MYSQL_BASE/bin/mysqld" --defaults-file="$LAB_CNF" --initialize-insecure
"$MYSQL_BASE/bin/mysqld" --defaults-file="$LAB_CNF" --daemonize
mysql -uroot -S /tmp/mysql-crash-redo001.sock -e \
  "SELECT VERSION(),@@port,@@innodb_flush_log_at_trx_commit,@@sync_binlog;"
```

正确结果必须是 MySQL 8.4.10、端口 33311、两个刷盘参数均为 1。

### 7.2 准备已提交行

```bash
mysql -uroot -S /tmp/mysql-crash-redo001.sock
```

```sql
CREATE DATABASE crash_lab;
CREATE TABLE crash_lab.t_recovery(
  id INT PRIMARY KEY,
  state VARCHAR(40) NOT NULL
) ENGINE=InnoDB;
INSERT INTO crash_lab.t_recovery VALUES (1,'committed-before-crash');
SELECT * FROM crash_lab.t_recovery;
```

必须看到 id=1。退出该客户端。

### 7.3 T1 创建未提交事务

T1：

```bash
mysql -uroot -S /tmp/mysql-crash-redo001.sock
```

```sql
START TRANSACTION;
INSERT INTO crash_lab.t_recovery VALUES (2,'uncommitted-at-crash');
SELECT id,state FROM crash_lab.t_recovery ORDER BY id;
SELECT SLEEP(300);
```

T1 必须看到 id=1、id=2，并停在 SLEEP。不要 COMMIT。

T2：

```bash
mysql -uroot -S /tmp/mysql-crash-redo001.sock -e \
  "SELECT id,state FROM crash_lab.t_recovery ORDER BY id;"
```

T2 必须只看到 id=1；否则停止，不执行故障注入。

### 7.4 只终止专用 mysqld

```bash
LAB_DATA=/data/myhome/mydata/mysql-crash-redo001
server_pid=$(<"$LAB_DATA/mysqld.pid")
ps -p "$server_pid" -o pid,args=
```

输出参数必须包含专用 datadir/配置和端口 33311。确认后：

```bash
kill -9 "$server_pid"
```

T1 预期返回 `ERROR 2013 (HY000): Lost connection to MySQL server`。

### 7.5 重启、判断与优雅关闭

```bash
MYSQL_BASE=/usr/local/mysql/mysql-8.4.10
LAB_CNF=$PWD/evidence/mysql-crash.cnf
"$MYSQL_BASE/bin/mysqld" --defaults-file="$LAB_CNF" --daemonize

mysql -uroot -S /tmp/mysql-crash-redo001.sock -e \
  "SELECT id,state FROM crash_lab.t_recovery ORDER BY id;
   CHECK TABLE crash_lab.t_recovery;
   SHOW BINARY LOG STATUS;"

grep -E 'crash recovery|ready for connections|InnoDB initialization' \
  /data/myhome/mydata/mysql-crash-redo001/error.log

mysqladmin -uroot -S /tmp/mysql-crash-redo001.sock shutdown
```

正确结果：仅 id=1；`CHECK TABLE` 为 OK；日志先完成 InnoDB/XA recovery，之后才 ready。

完整自动化命令等价于：

```bash
chmod +x evidence/mysql-crash-lab.sh
evidence/mysql-crash-lab.sh
```

### 7.6 清理

确认专用实例已停止、路径完全匹配后删除专用目录：

```bash
test ! -S /tmp/mysql-crash-redo001.sock
test "/data/myhome/mydata/mysql-crash-redo001" = "/data/myhome/mydata/mysql-crash-redo001"
sudo rm -rf -- /data/myhome/mydata/mysql-crash-redo001
rm -f /tmp/mysql-crash-redo001-t1.out
```

不要删除 `/data/myhome/mydata/mysql`，不要把清理路径改成变量通配符。

## 8. 生产恢复判断

1. 先区分 clean shutdown、mysqld crash、OS reboot、存储故障，故障模型不同；
2. 启动慢时先看 error log 的 checkpoint/redo、rollback、XA 阶段，不要连续重启；
3. 未提交大事务的 undo rollback 可能延续较久，redo 完成不等于所有业务清理都结束；
4. 发现 redo/checkpoint 损坏时先保护数据目录副本；`innodb_force_recovery` 是抢救读取工具，不是修复；
5. binlog 是否完整要结合 `sync_binlog` 与 XA recovery 判断，不能由 `CHECK TABLE OK` 推出；
6. 恢复完成后校验关键表、业务幂等键、binlog/GTID 和副本状态，而不只看进程存活。

## 9. Evidence

- `evidence/mysql-output.txt`：MySQL 事务可见性、ERROR 2013、恢复结果与日志
- `evidence/pg-output.txt`：PG 同构实验与 redo LSN
- `evidence/source-locations.txt`：两引擎 checkpoint、redo、undo/事务状态源码链
- `evidence/mysql-crash-lab.sh`、`mysql-crash.cnf`：MySQL 完整自动化实验
- `evidence/pg-crash-lab.sh`：PG 实测脚本

未决项：物理断电/损坏恢复、`innodb_force_recovery` 分级抢救和 redo 容量对恢复时长的影响应独立
成灾备实验，不在本轮对学习主机做破坏性扩展。
