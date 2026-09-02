# Crash Recovery：PostgreSQL WAL 与 InnoDB Redo/Undo 对照

> 专题：REDO-001；研究级别：S。实测 PostgreSQL 18.4、MySQL 8.4.10，日期
> 2026-09-02。本文讨论单机数据库进程崩溃恢复，不把 `kill -9` 冒充断电。

## 1. 先给结论：相同结果，不同收敛路径

| 待证明问题 | PostgreSQL 18.4 | MySQL 8.4.10 / InnoDB | 本次证据 |
|---|---|---|---|
| 恢复从哪里开始 | checkpoint 的 REDO pointer | latest valid checkpoint LSN | PG `0/177BA88`；MySQL `19361848` |
| checkpoint 后已提交数据 | WAL replay 后保留 | redo 后保留 | 两边恢复后均为 3001 行 |
| 崩溃时未提交数据 | tuple 可被 WAL 重放，但无已提交 xid 因而不可见 | 先 redo 数据页与 undo，再沿 undo 回滚 | 两边 1000 行均不可见；MySQL 日志明确 `1000 rows to undo` |
| 物理恢复粒度 | WAL record 分派给 rmgr | redo 按 space/page 聚合并结合 page LSN 应用 | 源码调用链 |
| 已 prepare 事务 | 由 PG 两阶段事务状态处理 | `TRX_STATE_PREPARED` 留给 Server/XA 协调 | 源码分支；本实验未构造 prepared 事务 |
| 何时算恢复完成 | redo 与收尾后 `ready` | redo、字典/锁、XA 协调并启动 rollback 后 `ready` | 两边启动日志 |

最容易迁移错的心智是：“未提交数据恢复后不见了，所以两个引擎都执行了 undo”。PG 的
可见性结论不等于 InnoDB 式物理反向修改。InnoDB 的本次日志则把顺序写得很清楚：扫描 redo，
完成 InnoDB 初始化，进行 XA crash recovery，取得恢复所需表锁，然后后台回滚 1000 行。

## 2. 问题模型：崩溃时磁盘上可能有什么

一次更新至少涉及三类事实：事务是否承诺成功、日志是否持久、数据页是否落盘。fuzzy checkpoint
不要求某一瞬间所有脏页都落盘，因此崩溃时可能出现：

```text
                 日志已持久              数据页可能仍旧
已提交事务     commit + page redo        需要前滚，必须保留
未提交事务     page redo + undo/WAL       先保证页可解释，再恢复事务语义
```

日志重放首先解决物理一致性，事务状态再解决逻辑可见性。二者不能互换：若 InnoDB 跳过 redo
直接读 undo，undo 页自己也可能尚未写回；若仅做 redo，则未提交事务的修改可能留在用户可见页上。

## 3. PostgreSQL 基线：WAL 前滚与 xid 可见性

PG 的 checkpoint record 保存 REDO pointer。启动进程读取 `ControlFileData`，由控制文件状态判断
上次是 clean shutdown、生产状态中断，还是 recovery 中断。`InitWalRecovery()` 解析 checkpoint，
`PerformWalRecovery()` 从 REDO pointer 读取 WAL record。

每条记录的 `xl_rmid` 选择资源管理器，再调用对应 `rm_redo`。heap、btree、xact 等资源管理器各自
理解自己的 WAL。xact commit/abort WAL 重建事务状态；没有有效 commit 的 xid 不会因为 heap tuple
被重放就变成可见。

因此 PG 的语义是：

```text
控制文件状态 → checkpoint/REDO pointer → 读 WAL record
             → rmgr redo → 恢复事务状态 → 一致点/恢复收尾 → ready
```

未提交 tuple 可能物理存在，之后由 VACUUM 清理。查询不到它证明的是 MVCC 可见性，不是逐行物理
undo；这是与 InnoDB 最重要的心智地图差异点。

## 4. MySQL / InnoDB 完整调用链

### 4.1 从存储引擎初始化到 redo 恢复

```text
innobase_init_files()                         ha_innodb.cc
└─ srv_start(create=false)                    srv0start.cc
   ├─ recv_recovery_from_checkpoint_start()   log0recv.cc
   │  ├─ recv_find_max_checkpoint()
   │  ├─ recv_recovery_begin(checkpoint_lsn)
   │  └─ 扫描 block → 解析 record → 按 space/page 放入 hash
   ├─ recv_apply_hashed_log_recs()
   │  └─ recv_recover_page_func()
   └─ recv_recovery_from_checkpoint_finish()

srv_dict_recover_on_restart()
├─ 恢复字典事务、动态元数据和锁
└─ trx_resurrect_locks(true)

srv_start_threads()
└─ 若 trx_sys_need_rollback
   └─ trx_recovery_rollback_thread()
      └─ trx_recovery_rollback()
         └─ trx_rollback_or_clean_recovered(true)

Server 层 XA crash recovery → ready for connections
```

`srv_start()` 不是一个笼统的“初始化函数”。它把 checkpoint 选择、redo 扫描/应用和 recovery
finish 串起来；随后字典、锁和事务恢复必须在合适的依赖顺序完成。

### 4.2 checkpoint 选择与恢复判定

`recv_recovery_from_checkpoint_start()` 先寻找最新有效 checkpoint，再把 `checkpoint_lsn`、
`scanned_lsn`、`recovered_lsn` 建立在该边界上。关键关系是：

```text
checkpoint_lsn ≤ page 所需 redo 的 LSN ≤ scanned_lsn
```

本实验强制把脏页降到 0 后记录基线：

```text
checkpoint_lsn = 19361848
current_lsn    = 19362278
dirty_pages    = 0
```

随后提交 3000 行，checkpoint 仍为 `19361848`，current/flushed LSN 已到 `27758472`；再制造
1000 行未提交修改，崩溃前 current LSN 到 `29918077`。这排除了旧实验中“redo start/done
几乎相邻，可能没有真正页重放”的弱证据。

### 4.3 scan、parse、hash、apply 不是一件事

InnoDB 并非读取一条 redo 就机械写一次磁盘。扫描层检查日志块头与 checksum，解析层识别 mlog
记录，收集层以 tablespace/page 为键挂入恢复结构，应用层在页面进入 buffer pool 后比较 page LSN。

概念化后的关键代码是：

```cpp
struct recv_addr_t {
  recv_addr_state state;       // NOT_PROCESSED / BEING_READ / ...
  space_id_t space;
  page_no_t page_no;
  UT_LIST_BASE_NODE_T(recv_t, rec_list) rec_list;
};

void recv_recover_page_func(bool just_read_in, buf_block_t *block) {
  recv_addr_t *addr = recv_get_rec(block->page.id.space(),
                                   block->page.id.page_no());
  if (addr == nullptr || addr->state == RECV_BEING_PROCESSED ||
      addr->state == RECV_PROCESSED) return;
  addr->state = RECV_BEING_PROCESSED;
  // 比较页 LSN，按序应用该页所需 redo，完成后标记 PROCESSED
}
```

page LSN 是幂等边界：页已经包含某条 redo 的效果时，不应重复修改；落后的页才前滚。按页组织
还允许恢复与页面读取协作，而不是要求先把整个数据集装入内存。

### 4.4 为什么 redo 必须先于 undo

未提交事务同样生成数据页 redo，undo 页的写入也受 redo 保护。恢复首先把两者推进到日志描述的
可解释状态，才能可靠地重建事务和 undo 链。之后 `trx_rollback_or_clean_recovered()` 分类处理：

```cpp
switch (trx->state.load()) {
  case TRX_STATE_COMMITTED_IN_MEMORY:
    // 清理可能残留的 insert undo
    break;
  case TRX_STATE_PREPARED:
    // XA prepared：保留，交给 Server 协调
    break;
  default:
    // 普通未提交事务：沿 undo 回滚
    trx_rollback_active(trx);
}
```

这是语义化伪代码，准确源码位置记录在证据文件。本次错误日志直接验证普通未提交分支：事务
`1305` 有 `1000 rows to undo`，随后 `Rollback ... completed`。

## 5. 核心数据结构：恢复状态放在哪里

| 结构 | 关键字段/职责 | 为什么重要 |
|---|---|---|
| MySQL `log_t` | `last_checkpoint_lsn`、`recovered_lsn`、`m_scanned_lsn` | 区分 checkpoint、已扫描和已恢复边界 |
| MySQL `recv_sys_t` | parse buffer、`checkpoint_lsn`、`scanned_lsn`、`recovered_lsn`、页映射 | 承载一次 redo recovery 的全局状态 |
| MySQL `recv_addr_t` | `space`、`page_no`、state、redo record list | 把日志记录组织为页面恢复任务 |
| MySQL `trx_t` / undo ptr | 恢复事务状态、undo 链、prepare 状态 | 决定清理、回滚还是留给 XA |
| PG `ControlFileData` | 数据库状态、checkpoint 位置 | 决定启动是否进入 recovery |
| PG `XLogReaderState` | WAL 读取位置、decoded record、block refs | 维护跨页/段读取与解码状态 |
| PG `DecodedXLogRecord` | LSN、record header、main data、block refs | 向 rmgr 提供已解码记录 |
| PG `RmgrData` | `rm_redo` 等回调 | 用 rmid 分派具体资源的 redo |

三个 LSN 容易混淆：checkpoint LSN 是起点保护边界，scanned LSN 表示日志已验证到哪里，
recovered LSN 表示逻辑恢复进度。日志能扫描到某处不等于所有相关页已成功应用。

PG 的分派核心同样很直接：

```c
static void
ApplyWalRecord(XLogReaderState *xlogreader, XLogRecord *record,
               TimeLineID *replayTLI)
{
    if (record->xl_rmid == RM_XLOG_ID)
        xlogrecovery_redo(xlogreader, *replayTLI);
    GetRmgr(record->xl_rmid).rm_redo(xlogreader);
}
```

相似处是两边都由日志携带足够的物理变化信息并调用类型专属 redo；差异是 InnoDB 随后显式恢复
事务/undo，而 PG 把事务提交状态也作为 WAL replay 的一部分，最终用 MVCC 判断 tuple 可见性。

## 6. 状态变化、关键分支与失败语义

### 6.1 正常崩溃恢复状态机

```text
START
  ├─ clean shutdown ───────────────→ 无需 crash redo / 常规启动
  └─ crash detected
       ├─ checkpoint 无效 ─────────→ 启动失败或进入受限抢救路径
       └─ checkpoint 有效
            ├─ scan checksum/格式错 → corruption 分支，停止正常恢复
            └─ scan 到有效末端
                 → page redo apply
                 → 字典/锁/事务重建
                 ├─ COMMITTED → 清理 insert undo
                 ├─ PREPARED  → XA/Server 决策
                 └─ ACTIVE    → undo rollback
                 → ready
```

“日志尾部不完整”和“中间 checksum 损坏”不能一概称为可忽略。崩溃可能打断最后一个日志块，扫描
器有相应的 abrupt-end 判断；已持久有效区间内部的损坏则可能触发 corruption/fatal 分支。

### 6.2 `ready` 与后台回滚

本次 MySQL 日志中先启动后台 rollback，随后出现 ready；1000 行 rollback 的完成日志也出现在恢复
序列中。生产判断不能只看端口打开：还应同时看 error log、未完成事务回滚、业务查询延迟以及
`SHOW ENGINE INNODB STATUS`。大事务崩溃回滚可能使实例可连接但负载尚未恢复正常。

### 6.3 XA PREPARED 不能当普通未提交事务

普通 active 事务可以安全 undo；prepared 事务已跨过引擎 prepare 边界，最终提交决定可能存在于
binlog/事务协调器。InnoDB 源码明确跳过普通回滚，交给 Server 层 XA crash recovery。本文实验
未构造 XA prepared，所以只把源码分支列为已定位，不能把普通事务结果外推成 XA 实测结论。

## 7. 行为实验：同一事务在崩溃后的可见性

两边采用同一逻辑工作负载：checkpoint 后提交 3000 行；T1 再插入 1000 行但不提交；T2 验证
只能见 3001 行；对专用主进程发 SIGKILL；重启原数据目录并复查。

| 观察点 | PostgreSQL | MySQL |
|---|---:|---:|
| checkpoint 后已提交行数 | 3001 | 3001 |
| T1 内部崩溃前行数 | 4001 | 4001 |
| T2 外部崩溃前行数 | 3001 | 3001 |
| 恢复后行数 | 3001 | 3001 |
| 恢复后未提交标记行 | 0 | 0 |

行为相同只说明事务原子性和已持久提交结果相同；不能据此声称恢复算法相同。

## 8. 路径实验：强制制造非空恢复区间

### 8.1 MySQL 路径证据

| 时点 | checkpoint LSN | current/flushed LSN | dirty pages |
|---|---:|---:|---:|
| 基线刷净后 | 19361848 | 19362278 | 0 |
| 3000 行提交后 | 19361848 | 27758472 | 46 |
| 另有 1000 行未提交、崩溃前 | 19361848 | 29918077 | 191 |
| 恢复后 | 27820925 | 29994855 | — |

启动日志从 checkpoint 附近开始 parse，依次报告扫描到 `24604672`、`29847552`、`29918077`；
随后回滚事务 1305 的 1000 行。LSN 区间证明发生了真实扫描，rollback 行数证明进入了 undo 路径。

### 8.2 PostgreSQL 路径证据

`pg_controldata` 给出 checkpoint `0/177BAE0`、REDO `0/177BA88`。提交工作后 flush LSN 为
`0/180C550`；崩溃前 insert LSN 为 `0/183BB68`。重启日志显示：

```text
redo starts at 0/177BA88
redo done at 0/1839F50
database system is ready to accept connections
```

redo 起点与控制文件 REDO pointer 完全相同，终点跨过 checkpoint 后提交负载。PG 没有输出
“1000 rows to undo”，这与其 xid 可见性模型吻合。

## MySQL 实操：命令与 SQL

### 完整流程与判断标准

以下脚本已实跑。它只操作端口 33311、socket `/tmp/mysql-crash-redo001.sock` 和专用目录
`/data/myhome/mydata/mysql-crash-redo001`。不要替换成日常 3306 数据目录。

前置准备：确认以 `mysql` 用户执行、MySQL 8.4.10 二进制存在，且上述专用端口、socket 和目录
没有被其他实例占用。连接统一使用专用 socket，不依赖默认客户端配置。

### 9.1 一键复现实验

```bash
cd /data/myhome/myfuture/dba_one_year_mysql/
sudo -u mysql bash \
  study_record/redo/REDO-001_crash_recovery/evidence/mysql-crash-lab.sh
```

脚本包含以下停止条件：目标目录已存在则拒绝初始化；故障前从专用 pid-file 取 PID；核对专用
socket/端口；只对匹配进程发送 SIGKILL。实验结束后优雅停库，但保留目录供审计。

### 9.2 手工观察 checkpoint、redo 与脏页

```bash
MYSQL=/usr/local/mysql/mysql-8.4.10/bin/mysql
SOCKET=/tmp/mysql-crash-redo001.sock
$MYSQL -uroot -S "$SOCKET"
```

```sql
SHOW GLOBAL STATUS WHERE Variable_name IN
 ('Innodb_buffer_pool_pages_dirty',
  'Innodb_redo_log_current_lsn',
  'Innodb_redo_log_flushed_to_disk_lsn',
  'Innodb_redo_log_checkpoint_lsn');

SELECT COUNT(*) AS rows_after_checkpoint
FROM crash_lab.t_recovery;
```

判断标准：崩溃前 `Innodb_redo_log_current_lsn > Innodb_redo_log_checkpoint_lsn`，且 dirty pages
大于 0；否则
这次实验没有制造出足够明确的 redo 区间，应增加负载后重跑。

### 9.3 手工制造未提交事务

会话 T1：

```sql
START TRANSACTION;
CALL crash_lab.fill_rows(10000,1000,'uncommitted-at-crash');
SELECT COUNT(*), SUM(state='uncommitted-at-crash')
FROM crash_lab.t_recovery;
-- 保持事务打开，不执行 COMMIT/ROLLBACK
```

会话 T2：

```sql
SELECT COUNT(*) AS outside_rows,
       SUM(state='uncommitted-at-crash') AS outside_uncommitted
FROM crash_lab.t_recovery;
```

T1 应为 4001/1000，T2 应为 3001/0。若 T2 看见未提交行，立即停止，不注入故障。

### 9.4 恢复后必须检查什么

```sql
SELECT COUNT(*) AS recovered_rows,
       SUM(state='uncommitted-at-crash') AS recovered_uncommitted,
       MIN(id),MAX(id)
FROM crash_lab.t_recovery;
CHECK TABLE crash_lab.t_recovery;
SHOW ENGINE INNODB STATUS\G
```

预期 `3001 / 0 / 1 / 3999` 且 `CHECK TABLE` 为 OK。再检查日志：

```bash
grep -E 'checkpoint|Doing recovery|crash recovery|rows to undo|Rollback|ready for connections' \
  /data/myhome/mydata/mysql-crash-redo001/error.log
```

### 9.5 清理

先确认专用实例已停：

```bash
test ! -S /tmp/mysql-crash-redo001.sock
test ! -e /data/myhome/mydata/mysql-crash-redo001/mysqld.pid
```

数据目录是实验审计证据，本文生成后暂不删除。需要删除时必须再次确认绝对路径只指向
`mysql-crash-redo001`；绝不能对 `/data/myhome/mydata/mysql` 或其上级目录做递归删除。

## 10. PostgreSQL 对照复现（精简）

PG 侧完整步骤已封装并实跑：

```bash
sudo -u mysql bash \
  study_record/redo/REDO-001_crash_recovery/evidence/pg-crash-lab.sh
```

PG 读者通常已熟悉 `initdb/pg_ctl/psql`，所以正文不逐条展开；对照判断必须保留：checkpoint REDO
小于崩溃前 WAL LSN，恢复日志的 redo start 与 REDO pointer 对齐，恢复后只见 3001 行。

## 11. 源码、实验、生产症状映射

| 源码阶段 | 实验证据 | 生产可见症状 | 排障含义 |
|---|---|---|---|
| 找 checkpoint | MySQL 19361848；PG 0/177BA88 | 日志出现 redo start/checkpoint | 起点异常先查控制文件/redo header |
| scan/parse WAL/redo | MySQL 多次 `scanned up to` | 启动耗时、I/O 上升 | redo 区间长或存储吞吐低 |
| page/rmgr apply | 恢复后 committed 行完整 | buffer pool/读写 I/O | 页落后越多，应用工作越大 |
| 事务/锁重建 | MySQL acquired lock | 启动阶段 MDL/字典等待 | 不应只盯 redo scan |
| undo rollback | `1000 rows to undo` | ready 前后持续回滚、负载高 | 大事务会延长业务恢复 |
| XA recovery | XA start/finish | prepared 事务、binlog 协调日志 | 不要手工把 prepared 当 active 清掉 |
| 完成 | 两边 ready | 端口可用 | ready 是必要信号，业务健康仍需验证 |

恢复时间不能只由 redo 字节数估算。页是否已落盘、随机 I/O、buffer pool 大小、待回滚事务量、
字典对象与锁恢复都会参与。生产容量测试至少分别记录 redo 扫描区间、dirty pages、undo 行数和
从进程启动到 ready 的时间。

## 12. 验证边界与未验证项

本次已验证：专用数据库进程非正常退出；强持久配置下 checkpoint 后已提交事务保留；普通未提交
事务在恢复后不可见；MySQL 确实执行 redo scan 和 1000 行 undo rollback；PG 确实从 checkpoint
REDO pointer 前滚。

本次未实测：

- OS/虚拟机掉电、磁盘缓存丢失、flush/barrier 失效；
- torn page、redo/WAL 中段 checksum 损坏、磁盘丢写；
- `innodb_force_recovery` 各级别的数据抢救与只读导出；
- XA PREPARED、PG prepared transaction 的故障矩阵；
- `innodb_flush_log_at_trx_commit=0/2`、`sync_binlog=0`、PG
  `synchronous_commit=off` 的掉电 RPO；
- redo 容量、并行恢复和不同脏页比例的恢复时长曲线。

所以结论只能覆盖数据库进程崩溃。要研究真实断电，需在可抛弃虚拟机或块设备故障注入环境中
同时观测操作系统、文件系统和存储持久化语义。

## 13. DBA 心智迁移表

| PostgreSQL 心智 | MySQL / InnoDB 对应项 | 不可直接类比之处 |
|---|---|---|
| checkpoint REDO pointer | latest checkpoint LSN | 字段与 checkpoint 格式不同 |
| WAL reader + rmgr redo | redo scan/parse + page hash/apply | InnoDB 更显式地按 page 组织恢复 |
| commit/abort WAL + clog/事务状态 | trx 状态 + undo | PG 不做 InnoDB 式逐行启动 undo |
| tuple xmin/xmax 可见性 | read view + 版本链 | “查询不可见”背后的物理状态不同 |
| prepared transaction | XA PREPARED + binlog/Server 协调 | MySQL 有引擎与 Server 两个事实域 |
| startup process ready | mysqld/InnoDB ready | MySQL 还需关注后台 rollback |

最终可压缩为一句话：PG 是“WAL 前滚后用事务状态解释 tuple”，InnoDB 是“redo 先把页和 undo
恢复到可解释状态，再用 undo/XA 把事务收敛”。两者都从 checkpoint 缩短恢复区间，但 checkpoint
不是“所有数据页已经同步落盘”的同义词。

## 14. 证据索引

- MySQL 可复现脚本：`evidence/mysql-crash-lab.sh`
- MySQL 专用配置：`evidence/mysql-crash.cnf`
- PostgreSQL 对照脚本：`evidence/pg-crash-lab.sh`
- MySQL 实测摘录：`evidence/mysql-output.txt`
- PostgreSQL 实测摘录：`evidence/pg-output.txt`
- 双引擎源码位置：`evidence/source-locations.txt`

源码行号以 MySQL 8.4.10 与 PostgreSQL 18.4 为准；升级小版本后应按函数名重新定位，不应把行号
当稳定 API。
