# Undo、ReadView、Purge：从 PostgreSQL MVCC 迁移到 InnoDB

> 版本：v1.0（2026-09-01）
> 环境：PostgreSQL 18.4 @54184；MySQL 8.4.10 @3306
> 实验：同一行、旧 RR 快照、另一会话 201 次独立提交、释放快照后清理
> Evidence：`evidence/` 中完整 SQL、会话输出、VACUUM/INNODB STATUS 与源码摘录

## 0. 一句话心智

- PG 把新旧 tuple 版本放在 heap 中，用 `xmin/xmax + Snapshot` 判断可见性，VACUUM 清理无快照需要的旧 tuple。
- InnoDB 把当前记录留在聚簇索引，用 `DB_ROLL_PTR` 串到 update undo 中的旧值，以 `ReadView` 判断可见性，Purge 清理最老 ReadView 不再需要的 undo/删除标记。
- 两者共同风险是长事务/长快照阻塞清理；但要看的对象不同：PG 看 `backend_xmin/n_dead_tup`，MySQL 看 `INNODB_TRX/History list length/undo`。

## 1. PostgreSQL 基线

### 1.1 tuple 版本与 Snapshot

PG heap tuple 头包含创建事务 `xmin` 和删除/更新事务 `xmax`。UPDATE 通常创建一个新 tuple，
旧版本写入 `xmax`；若索引列未变，可形成 HOT 链。实验初始版本为：

```text
xmin=1354 xmax=0 ctid=(0,1) version_no=0
```

T1 在 RR 中取得 `snapshot=1355:1355:`。另一会话完成 201 次独立提交后，新会话看到：

```text
xmin=1556 xmax=0 ctid=(1,17) version_no=201
```

但 T1 仍看到旧版本：

```text
xmin=1354 xmax=1356 ctid=(0,1) version_no=0
```

注意旧 tuple 原始头中的 xmax 已写入 1356，但它对 T1 Snapshot 来说是“快照之后发生的更新”，
所以旧 tuple 仍可见。

`procarray.c:2143-2153 GetSnapshotData()` 给出 PG 快照规则：

- xid `< xmin`：已结束；
- xid `>= xmax`：按仍在运行处理；
- `[xmin,xmax)`：查询运行 xid 列表 xip。

`heapam_visibility.c:960 HeapTupleSatisfiesMVCC()` 将 tuple 的 xmin/xmax 与快照比较，决定返回哪个 heap 版本。

### 1.2 VACUUM 为什么被旧快照挡住

T1 在 `pg_stat_activity` 中显示：

```text
state=idle in transaction, backend_xid=1355, backend_xmin=1355
```

此时执行 `VACUUM (VERBOSE, ANALYZE)`：

```text
tuples: 0 removed, 202 remain, 201 are dead but not yet removable
removable cutoff: 1355, which was 202 XIDs old
n_live_tup=1, n_dead_tup=201
```

`vacuum.c` 用 `GetOldestNonRemovableTransactionId()` 形成 `OldestXmin`；
`vacuumlazy.c:2335` 将 tuple 交给 `HeapTupleSatisfiesVacuum`，旧快照仍可能看到的版本成为
`HEAPTUPLE_RECENTLY_DEAD`，不能删。verbose 文案来自 `vacuumlazy.c:1024`。

T1 COMMIT 后再次 VACUUM，最终 `n_dead_tup=0`、两页设为 all-visible。第二次日志只显示
`16 removed`，不代表只清了 16 个历史版本；HOT/page pruning 与 VACUUM 统计口径会分摊清理数量，
最终无 dead tuple 才是状态结论。

## 2. InnoDB：当前行 + Undo 版本链

### 2.1 聚簇记录如何连接旧版本

InnoDB 聚簇记录包含两个核心隐藏字段：

- `DB_TRX_ID`：最后修改该记录的事务 ID；
- `DB_ROLL_PTR`：指向 update undo 记录。

UPDATE 保留当前聚簇记录，并把构造旧版本所需信息写到 update undo。沿 roll_ptr 可以逐级重建
`v201 → ... → v1 → v0`。这与 PG “多个完整 tuple 在 heap/HOT 链”达到同一 MVCC 目标，
物理实现完全不同。

读取调用链：

```text
row_search_mvcc
  → lock_clust_rec_cons_read_sees             判断当前聚簇记录
  → row_sel_build_prev_vers_for_mysql         row0sel.cc:5330
    → row_vers_build_for_consistent_read      row0vers.cc:1249
      → trx_undo_prev_version_build           trx0rec.cc:2447
```

`row0sel.cc:5319-5347` 明确：当前聚簇记录不被 ReadView 看见时，从 undo 构造 old version。

### 2.2 ReadView 边界如何判断

`trx0trx.cc:2315-2332 trx_assign_read_view()` 说明，同一事务内的 consistent reads 复用首次创建的 ReadView。
核心算法在 `read0types.h:163-182 changes_visible()`：

```text
trx_id < m_up_limit_id            → 可见
trx_id >= m_low_limit_id          → 不可见
两者之间                         → 若在 m_ids 活跃事务集合中则不可见，否则可见
creator trx_id                    → 自己的修改可见
```

变量命名容易误读：这里 `m_low_limit_id` 实际是高端边界（创建视图时的 next trx id），
`m_up_limit_id` 是低端边界（最小活跃 trx id）。应以源码判断式记忆，不按英文名字猜。

### 2.3 RR 实验结果

T1 执行：

```sql
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT ...;  -- v0
```

T2 完成 201 次独立提交后，新会话看到 v201，而 T1 再读仍是 v0。`INNODB_TRX` 定位到：

```text
trx_mysql_thread_id=155
trx_state=RUNNING
trx_isolation_level=REPEATABLE READ
trx_rows_modified=0
```

只读长事务也可能没有普通递增 trx_id，实验中显示一个很大的内部只读事务标识；排查不能只筛
`trx_rows_modified>0`，必须看开始时间、thread id 和隔离级别。

## 3. Purge 与 History List Length

### 3.1 HLL 是什么，不是什么

提交 update undo 时，`trx0purge.cc:364-373` 把 undo log header 加入 rollback segment history list，
并增加 `rseg_history_len`；移除 header 时 `:403-408` 才减一。

因此 History List Length：

- 是实例级“尚在 history list 中的 undo log 数”，不是某张表的行版本数；
- 不是字节数，也不等于 undo 文件大小；
- 与提交事务数更接近，不等于一笔事务内 UPDATE 的行数；
- 应看趋势和持续时间，不应照搬一个固定报警阈值。

本实验旧 ReadView 存在时：

```text
Purge done for trx's n:o < 7980
History list length 203
```

201 个实验提交之外还有实例原有 history，因此是 203 而不是精确 201。T1 COMMIT 后，Purge
异步推进；HLL 没有立刻下降，后续活动与后台批次运行后实测 `203 → 0`。这证明两点：

1. 旧 ReadView 确实限制了 purge horizon；
2. 释放长事务只是允许清理，不代表同步清完，监控要给后台线程时间并持续观察。

`srv0srv.cc:2940-2950` 每批读取 HLL 并调用 `trx_purge()`；Purge 还包含处理记录与截断 history
header 的阶段，所以 monitor 中 purge iterator 前进与 HLL 下降不一定在同一瞬间出现。

### 3.2 与 PG VACUUM 的边界

| 维度 | PostgreSQL | InnoDB |
|---|---|---|
| 当前/旧版本位置 | heap 中多个 tuple/HOT 链 | 当前聚簇记录 + update undo 链 |
| 行版本标识 | xmin/xmax | DB_TRX_ID/DB_ROLL_PTR |
| 快照 | xmin/xmax/xip | up/low limit + m_ids |
| 清理者 | VACUUM/autovacuum | Purge 后台线程 |
| 长快照影响 | OldestXmin 不前进，dead tuple 不能移除 | oldest ReadView 不前进，undo/history 不能清理 |
| 主要指标 | backend_xmin、n_dead_tup、age(xmin) | INNODB_TRX、HLL、undo 文件/表空间 |
| 手工清理 | VACUUM | 通常不手工 purge；结束根因事务后等待后台清理 |

## 4. RC 与默认隔离级别：最容易迁移错的地方

两边显式设为 READ COMMITTED 后，同一事务的第一次 SELECT 看到 v201，另一会话提交 v202，
第二次 SELECT 都看到 v202。因此两边 RC 都是“每条语句新快照”。

但默认值不同：

| 引擎 | 本机默认 | 同事务普通 SELECT 快照 |
|---|---|---|
| PostgreSQL 18.4 | READ COMMITTED | 每条语句更新 |
| MySQL 8.4.10 | REPEATABLE READ | 首次 consistent read 后复用 |

把 PG 应用原样迁到 MySQL 而不显式设置隔离级别，事务内第二次读取的语义可能改变。

## 5. 生产排查路径

### PostgreSQL

```sql
SELECT pid, usename, state, xact_start, backend_xid, backend_xmin,
       now()-xact_start AS xact_age, query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL ORDER BY xact_start;

SELECT relname,n_live_tup,n_dead_tup,last_autovacuum
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;
```

### MySQL

```sql
SELECT trx_mysql_thread_id,trx_id,trx_state,trx_started,
       trx_isolation_level,trx_rows_modified,trx_query
FROM information_schema.innodb_trx ORDER BY trx_started;

SHOW ENGINE INNODB STATUS\G  -- TRANSACTIONS: Purge done / History list length
SHOW FULL PROCESSLIST;        -- 用 thread id 回到用户/SQL；本机 P_S=OFF 的兜底
```

处置顺序：确认长事务与业务影响 → 联系/终止根因会话 → 观察 HLL 或 dead tuples 是否回落 →
再评估 undo/表空间是否需要后续维护。不要看到 HLL 大就先重启或删 undo 文件。

## 6. Evidence 与清理

- `mysql-setup.sql`、`mysql-churn.sql`、`mysql-mvcc-output.txt`
- `pg-setup.sql`、`pg-churn.sql`、`pg-mvcc-output.txt`
- `source-locations.txt`

实验结束删除 `mysql_mvcc001` 与 `pg_mvcc001`，不影响学习主实例其他对象。
