# 隔离级别、Gap/Next-Key Lock、死锁与 SSI：从 PostgreSQL 迁移到 MySQL

> 实验版本：PostgreSQL 18.4 / MySQL 8.4.10 LTS
> 日期：2026-09-01
> 核心问题：同样叫 RR/Serializable，两边如何处理范围插入、死锁和写偏差？

## 1. 先记住结论

| 场景 | PostgreSQL 18.4 | MySQL 8.4.10 InnoDB |
|---|---|---|
| 默认隔离级别 | READ COMMITTED | REPEATABLE READ |
| RR 普通读 | 事务级快照 | 事务级 ReadView |
| RR 范围 FOR UPDATE | 锁已命中的 tuple，不锁不存在的键 | 对索引范围加 Next-Key Lock |
| 另一事务插入范围内新键 | 可立即提交；旧快照看不到 | 被 Gap/Next-Key Lock 阻塞 |
| RR 写偏差 | 允许 | 允许 |
| Serializable | SSI：SIREAD 检测 rw-conflict，通常不阻塞 | 普通 SELECT 在显式事务中变 S 锁，悲观阻塞 |
| 死锁 | 等待图成环，取消一个事务 | 等待图成环，取消一个事务 |
| 应用恢复 | 40P01/40001：重试整个事务 | 1213（SQLSTATE 40001）：重试整个事务 |

最重要的心智迁移是：

> “查询结果没有出现幻行”不等于“数据库锁住了范围”。PG RR 主要靠固定快照隐藏新行；
> InnoDB RR 的锁定读则能用 Next-Key Lock 阻止新行进入范围。

## 2. PG 基线：先拆开可见性、行锁和 SSI

### 2.1 RC 与 RR 的快照边界

PG RC 每条语句取得新快照；RR 在事务第一次需要快照时固定事务级快照。因此 T2 提交后：

- RC 的 T1 下一条普通 SELECT 可以看到新行；
- RR 的 T1 下一条普通 SELECT 仍按旧快照读，看不到新行；
- 这只是可见性规则，不能证明 T2 被锁住。

PG 的 `SELECT ... FOR UPDATE` 由 `nodeLockRows.c` 取得已扫描 tuple 的 TID，再调用
`table_tuple_lock()`。它能锁住 id=10、id=20，却没有一个“id=15 这条不存在记录”可锁。

### 2.2 PG RR 不是 Serializable

PG RR 基于 snapshot isolation，可以阻止脏读、不可重复读和结果层面的幻读，但仍允许写偏差：
两个事务都读到“两名医生值班”，随后各自关闭不同医生，两个 UPDATE 不冲突，最终无人值班。

因此“单行不会丢失更新”与“跨行业务不变量安全”是两回事。约束若不能由 UNIQUE/CHECK/FK
表达，RR 快照本身不保证它。

### 2.3 SSI 的 predicate lock 不是阻塞型范围锁

PG Serializable 使用 Serializable Snapshot Isolation。源码
`src/backend/storage/lmgr/predicate.c` 明确说明：

- SIREAD 覆盖实际读取的 tuple，也可提升为 page/relation 范围；
- 它用于记录 read-before-write 的 rw-conflict；
- 它与普通锁不同，写者不等待它，读者也不等待写者。

SSI 关注危险结构：

```text
Tin --rw--> Tpivot --rw--> Tout
```

当这类结构可能构成不可序列化环时，系统取消一个事务。本次 doctor 实验里，两边 SERIALIZABLE
事务的普通读均完成，两个 UPDATE 也先完成；T1 提交后，T2 在 COMMIT 阶段得到：

```text
could not serialize access due to read/write dependencies among transactions
Reason code: Canceled on identification as a pivot, during commit attempt.
The transaction might succeed if retried.
```

`pg_locks` 同时能看到两个会话的 relation 级 `SIReadLock`。最终只有一名医生下线，不变量保住。

## 3. InnoDB 的四种索引记录锁

InnoDB 锁不是抽象的“行锁”，而是落在索引记录及其间隙上。`lock0lock.h` 给出四个关键标志：

| 类型 | 保护对象 | 典型表示 |
|---|---|---|
| Record Lock | 某条索引记录，不含前方 gap | `LOCK_REC_NOT_GAP` |
| Gap Lock | 某记录前的空隙，不含记录本身 | `LOCK_GAP` |
| Next-Key Lock | 索引记录 + 其前方 gap | `LOCK_ORDINARY` |
| Insert Intention | 插入者在 gap 内具体位置的申请/等待标志 | `LOCK_INSERT_INTENTION` |

假设索引键为 10、20、30，记录 20 上的 Next-Key Lock 可理解为 `(10,20]`。边界还会涉及
infimum/supremum 伪记录。它不是“按 SQL 文本锁数字区间”，而是按实际选择的索引、扫描路径和
索引顺序锁记录/间隙；没有合适索引时，锁范围可能远大于直觉。

唯一索引等值命中通常可退化为 Record Lock，因为搜索已精确定位，不需要保护前方 gap。
范围条件、非唯一等值和未命中搜索则更容易涉及 gap/next-key。

Insert Intention 并不让一个 gap 内所有插入彼此互斥。不同位置的插入意向通常兼容；它的关键作用是：
当已有冲突 gap/next-key 锁时，插入者以明确的等待请求进入队列。

## 4. MySQL RR：普通读与锁定读必须分开

### 4.1 普通 SELECT 是快照读

RR 下普通 SELECT 通过 ReadView 做 consistent read，通常不加 record/gap 锁。它的“重复读”
来自 MVCC-001 已验证的 undo 版本重建。

### 4.2 FOR UPDATE 是当前读

`SELECT ... FOR UPDATE`、UPDATE、DELETE 要查看并锁住当前版本。对范围扫描，RR 的
`skip_gap_locks()` 返回 false，`row0sel.cc` 会在 ordinary/record-only/gap 之间选锁模式。

本实验：

```sql
-- T1, MySQL RR
START TRANSACTION;
SELECT * FROM range_lab WHERE id BETWEEN 10 AND 20 FOR UPDATE;

-- T2
INSERT INTO range_lab VALUES (15,'fifteen');
```

T2 阻塞。`INNODB_TRX` 显示 T2 为 `LOCK WAIT`；InnoDB status 给出：

- T1 对 id=10 是 record-only，对右端 id=20 是 next-key X；
- T2 在 id=20 前 gap 上以 `X locks gap before rec insert intention waiting` 等待。

观察过程超过设置的 20 秒后 T2 得到 1205；T1 释放后重试同一 INSERT 立即成功。这既验证阻塞，
也保留了超时边界的真实结果。

### 4.3 RC 为什么不阻塞同一插入

`trx0trx.h::skip_gap_locks()` 对 READ UNCOMMITTED/READ COMMITTED 返回 true，对
REPEATABLE READ/SERIALIZABLE 返回 false。把 T1 改成 RC 后，同一范围 `FOR UPDATE`
不再用普通 Next-Key 保护 id=15 所在 gap，T2 插入立即成功。

这不是“RC 永不使用 gap lock”。唯一性检查、外键约束等一致性检查仍可能使用 gap 相关锁。

## 5. 同一实验在 PG RR 上的结果

PG T1 执行相同范围锁定读：

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT * FROM range_lab WHERE id BETWEEN 10 AND 20 FOR UPDATE;
```

T2 插入 id=15 立即提交。`pg_locks` 只显示 T1 的 relation/transaction 等常规锁，没有可类比
InnoDB gap 的阻塞锁。T1 在同一事务普通重读仍只看到 10、20；COMMIT 后新事务看到 10、15、20。

由此必须把两个问题分开：

1. T1 自己会不会看到幻行？PG RR 不会，MySQL RR consistent read 也不会。
2. T2 能不能把新行插进谓词范围？PG RR 可以；MySQL RR 范围锁定读通常不可以。

## 6. 死锁：两边机制相似，但现场形态有差异

实验用两个账户：

```text
T1: UPDATE id=1 → 等待 UPDATE id=2
T2: UPDATE id=2 → 等待 UPDATE id=1
```

等待图为：

```text
T1 --waits-for--> T2
 ^                 |
 |                 v
 +----waits-for----+
```

### 6.1 MySQL

InnoDB `lock0wait.cc` 扫描 wait-for graph，发现 cycle 后选择 victim、标记并取消等待。本次 T2 得到
`ERROR 1213 (40001)`，T1 继续执行并提交。`SHOW ENGINE INNODB STATUS\G` 的
`LATEST DETECTED DEADLOCK` 完整列出双方持有与等待的 index record，并说明回滚 transaction 2。

### 6.2 PostgreSQL

PG `deadlock.c::DeadLockCheck()` 检查等待图。本次 T2 得到 `deadlock detected`，DETAIL 直接说明
两个 transaction id 各自在等待对方的 ShareLock。被取消语句后事务进入 aborted 状态，执行任何
后续语句都会被拒绝，直到 ROLLBACK。

### 6.3 生产处理

- 应用对 1213、PG 40P01，以及可安全重试的 PG/MySQL SQLSTATE 40001，回滚并重试整个事务；
- 重试应有限次、带抖动退避，且写操作必须幂等；
- 所有代码路径按相同顺序访问对象，是最有效的结构性预防；
- 减少事务内交互/外部调用，缩短持锁时间；
- 不要把增大 lock wait timeout 当成死锁修复，死锁是环，等待更久不会自行解除；
- MySQL 1205 是等待超时，不等同于已检测到死锁，要先找 blocker。

## 7. RR 写偏差：两边都复现

初始 `doctor_lab` 两行均为 `on_call=1`。T1/T2 都在 RR 快照中读到 count=2，然后分别更新
id=1 和 id=2。因为写集不重叠，两边均允许两个事务提交，最终 count=0。

| 引擎/级别 | T1 读 | T2 读 | 两边提交 | 最终 |
|---|---:|---:|---|---:|
| PG RR | 2 | 2 | 是 | 0 |
| MySQL RR | 2 | 2 | 是 | 0 |

Next-Key Lock 没有自动救场，因为实验用的是普通快照读；即使把某个 SQL 改为锁定读，也必须
确认谓词、索引和锁范围真正覆盖业务不变量。数据库设计优先使用声明式约束；无法表达时再选择
显式锁、聚合锁行或 SERIALIZABLE + 重试。

## 8. PG SSI 与 MySQL SERIALIZABLE：结果相似，路径相反

### 8.1 PG：乐观检测

普通读不因 SIREAD 阻塞写者；系统记录 rw-dependency，危险结构出现后取消一个事务。本实验
失败发生在第二个 COMMIT，错误建议重试。

### 8.2 MySQL：悲观加锁

`ha_innodb.cc` 的一致性读/锁模式表显示：隔离级别低于 SERIALIZABLE 时普通 SELECT 使用
`LOCK_NONE`；SERIALIZABLE 的显式事务把它转换为 `LOCK_S`（autocommit 只读语句是例外）。

本次两个会话先执行：

```sql
SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;
START TRANSACTION;
SELECT count(*) FROM doctor_lab WHERE on_call=1;
```

`INNODB_TRX` 显示双方各有 2 个 lock structures、3 rows locked。然后：

- T1 UPDATE id=1，需要把目标行升为 X，但 T2 持有 S，开始等待；
- T2 UPDATE id=2，同样需要越过 T1 的 S；
- 等待图成环，T2 得到 1213；T1 继续提交；
- 最终 id=1 为 0、id=2 为 1，不变量保住。

| 比较项 | PG Serializable SSI | MySQL SERIALIZABLE |
|---|---|---|
| 读标记 | SIReadLock/predicate lock | S record/next-key lock |
| 是否阻塞写 | 通常不阻塞 | 阻塞 |
| 冲突处理 | 检测危险 rw 结构，serialization failure | 锁等待/死锁检测 |
| 本实验失败点 | COMMIT | 第二个 UPDATE |
| 运维体验 | 低等待但可能提交失败 | 等待更明显，死锁可能增多 |

二者都要求事务级重试，但不能据此认为机制等价。

## 9. 源码调用链

### 9.1 MySQL 8.4.10

```text
SQL locking read / DML
  → ha_innodb.cc：按隔离级别决定 LOCK_NONE / LOCK_S
  → row0sel.cc：按搜索关系与 skip_gap_locks() 选择
       LOCK_ORDINARY / LOCK_REC_NOT_GAP / LOCK_GAP
  → lock0lock.h：lock mode bit 定义
  → lock0wait.cc：构建/扫描等待图，发现 cycle，选择 victim
```

关键锚点：

- `storage/innobase/include/lock0lock.h:964-983`
- `storage/innobase/include/trx0trx.h:1113-1131`
- `storage/innobase/row/row0sel.cc:5215-5230`
- `storage/innobase/handler/ha_innodb.cc:18999-19052`
- `storage/innobase/lock/lock0wait.cc:692-702,1265-1305`

### 9.2 PostgreSQL 18.4

```text
SELECT FOR UPDATE
  → nodeLockRows.c
  → table_tuple_lock()：锁扫描得到的 tuple

SERIALIZABLE read/write
  → predicate.c：SIREAD + rw-conflict
  → FlagRWConflict()：检查 dangerous structure
  → PreCommit_CheckForSerializationFailure()：提交前取消 doomed transaction

regular lock wait
  → deadlock.c::DeadLockCheck()
  → DeadLockReport()
```

关键锚点：

- `src/backend/executor/nodeLockRows.c:165-229`
- `src/backend/storage/lmgr/predicate.c:8-48,4500-4735`
- `src/backend/storage/lmgr/deadlock.c:205-245,1133-1138`

完整带行号摘录见 `evidence/source-locations.txt`。

## 10. DBA 排障路径

### 10.1 MySQL（本机 performance_schema=OFF）

```sql
SHOW FULL PROCESSLIST;

SELECT trx_mysql_thread_id,trx_id,trx_state,trx_started,
       trx_wait_started,trx_isolation_level,trx_rows_locked,trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started;

SHOW ENGINE INNODB STATUS\G
```

若生产启用了 P_S，优先补充 `performance_schema.data_locks` 与 `data_lock_waits`，可精确拼等待边。

### 10.2 PostgreSQL

```sql
SELECT pid,usename,state,xact_start,wait_event_type,wait_event,
       pg_blocking_pids(pid) AS blockers,query
FROM pg_stat_activity
WHERE datname=current_database();

SELECT pid,locktype,mode,granted,relation::regclass,page,tuple
FROM pg_locks
ORDER BY pid,granted,locktype;
```

PG deadlock error detail 往往已经给出等待环；SSI 则重点识别 SQLSTATE 40001，并确认应用具备事务重试。

## 11. 迁移检查清单

- 隔离级别必须在连接池/事务入口显式设置，不能依赖两边不同的默认值；
- 区分普通快照读与锁定当前读，不用“RR 会防幻读”替代具体分析；
- 检查范围 DML/locking read 是否命中合适索引，避免意外扩大 next-key 锁范围；
- 统一批量更新和业务对象的加锁顺序；
- 对 1213、40P01、40001 设计整个事务重试；1205 先排阻塞链；
- 从 PG SSI 迁到 MySQL SERIALIZABLE，要评估额外读锁、等待和死锁，而不只是功能结果；
- 从 MySQL RR 锁定范围迁到 PG RR，若业务依赖“阻止范围插入”，需要显式重构并发控制；
- 监控长事务、锁等待时间、死锁频率、回滚/重试率，而不是只看慢 SQL。

## 12. 实验结论

1. MySQL RR 范围锁定读通过 Next-Key Lock 阻塞区间插入；RC 同实验不阻塞。
2. PG RR 范围 `FOR UPDATE` 不阻塞新键，事务内看不到新键是快照效果。
3. 两边都能检测经典行锁死锁并取消 victim，应用必须重试整个事务。
4. 两边 RR 均允许跨行写偏差。
5. PG SSI 以非阻塞 SIREAD/rw-conflict 在提交期取消危险事务。
6. MySQL SERIALIZABLE 以普通 SELECT 的 S 锁制造阻塞/死锁来序列化本实验。
7. 同名隔离级别只能当需求标签，不能当实现等价关系。

原始证据、完整命令和可复现步骤均在本专题 `evidence/` 目录。
