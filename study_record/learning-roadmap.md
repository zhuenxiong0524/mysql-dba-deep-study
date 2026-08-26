# MySQL DBA 第一年对照学习总任务（PG 18.4 → MySQL 8.4）

> 版本：v0.1
> 基线：PostgreSQL 18.4（已掌握） → MySQL 8.4.10 LTS（学习中）
> 任务 ID 前缀：ENV/MVCC/ISO/REDO/BUF/IDX/OPT/LCK/REP/BAK
> 完成定义：专题目录含对照文章（PG 基线 + MySQL 源码定位 + 同实验 + 差异表 + Evidence）并经过理解验证

## 使用原则

- 每个专题先写 PG 侧机制与结论（基线），再定位 MySQL 源码对应机制，最后同一实验两边各跑一遍
- 关键结论必须源码确认（MySQL 源码在 /data/myhome/mydata/mysql-src/mysql-8.4.10）
- MySQL 缺失/不同实现（GIN/GiST、SSI、逻辑复制、流复制）单独标注为"心智地图差异点"
- 熟悉内容快速成文；核心机制深入源码 + 调用链

## 权重

- `S`：快速整理，1 分
- `M`：标准研究，2 分
- `L`：深度机制，3 分

## ENV 环境

### ENV-001 MySQL 8.4.10 源码编译安装（S，P0）
- 已完成：源码下载校验、cmake 配置、编译安装（见 docs/environment.md）
- 待完成：实例初始化、启动、验证 3306

### ENV-002 双引擎交叉访问与对照实验工具链（S，P0）
- PG 侧：mysql 用户 trust 免密；MySQL 侧：建 pg@localhost
- 建立标准对照实验脚本模板（同 SQL 两边跑）

## MVCC

### MVCC-001 事务版本链：PG xmin/xmax vs MySQL undo log（L，P0，首专题）
- PG 基线：tuple 头 xmin/xmax、snapshot（MVCC 快照）、vacuum 清理
- MySQL：InnoDB undo log（insert/update undo）、roll_ptr 版本链、ReadView、purge 线程
- 实验：同表同隔离级别插入/更新/删除，观察 PG（t_infomask/快照）与 MySQL（information_schema/performance_schema、undo 状态）行为
- 源码：PG heapam.c / vacuumlazy.c；MySQL storage/innobase/trx/trx0rseg.c、trx0undo.c、read0read.c、purge0purge.c

### MVCC-002 快照与可见性判断（M）
- PG：SnapshotData 元组可见性规则；MySQL：ReadView（m_ids/m_low_limit_id/m_up_limit_id）
- 实验：同一并发读写场景，两边对比可见性结果与隔离级别差异

### MVCC-003 旧版本清理：vacuum vs purge（M）
- PG autovacuum/vacuum 与 MySQL purge 线程对比：触发条件、清理范围、undo 保留策略（history list）

## ISO 隔离级别与锁

### ISO-001 隔离级别语义对照（L）
- PG：Read Committed（每语句快照）/ Repeatable Read（每事务快照）/ Serializable(SSI)
- MySQL：Repeatable Read（默认，快照读 + next-key 锁）/ Read Committed
- 实验：幻读、不可重复读、写偏斜（SSI vs MySQL 串行化）——SSI 为心智地图差异点

### ISO-002 行锁与 gap/next-key 锁（L）
- PG：行锁（tuple lock）+ predicate lock；MySQL：record/gap/next-key/insert intention
- 实验：同场景锁等待与死锁检测（PG 死锁检测 vs InnoDB 死锁检测）对比

## REDO 日志与恢复

### REDO-001 redo log 结构与刷盘（L）
- PG：WAL（wal_level/LSN/checkpoint、full_page_writes）
- MySQL：InnoDB redo log（ib_logfile/innodb_redo、LSN、group commit、innodb_flush_log_at_trx_commit）
- 实验：崩溃恢复场景两边跑（kill -9 后启动观察恢复）

### REDO-002 checkpoint 机制（M）
- PG checkpoint 与 MySQL checkpoint（fuzzy checkpoint、adaptive flush）对比

## BUF Buffer Pool

### BUF-001 缓冲池与淘汰策略（L）
- PG：shared_buffers + clock sweep；MySQL：innodb_buffer_pool（LRU + 预读 + 自适应哈希）
- 实验：缓存命中率、冷数据扫描对缓存的影响（PG 与 MySQL 行为差异）

## IDX 索引

### IDX-001 B-tree 索引结构对照（M）
- PG btpage/bufpage vs InnoDB B+tree（page0/btree0）、聚簇索引差异（InnoDB 主键聚簇，PG 堆表 + 索引回表）

### IDX-002 覆盖索引与执行计划（M）
- PG INCLUDE 索引 vs MySQL 覆盖索引（二级索引含主键）；EXPLAIN 对照

### IDX-003 索引类型差异（S，差异点）
- GIN/GiST/BRIN/SP-GiST 为 PG 特有；MySQL 仅有 B-tree/Hash（内存表）/全文/空间索引——心智地图差异点

## OPT 优化器

### OPT-001 统计信息与 ANALYZE（M）
- PG：ANALYZE/统计信息/代价模型；MySQL：ANALYZE TABLE/统计信息（持久化表 mysql.innodb_table_stats）
- 实验：同表同数据量，pg_class.reltuples vs mysql.innodb_table_stats，EXPLAIN 计划差异

### OPT-002 EXPLAIN 输出对照（M）
- PG EXPLAIN (ANALYZE, BUFFERS) vs MySQL EXPLAIN ANALYZE；连接顺序、join 算法对照

## LCK 锁与并发

### LCK-001 表级锁与 DDL 锁（M）
- PG：AccessShare/AccessExclusive（DDL 阻塞）；MySQL：MDL（metadata lock）
- 实验：DDL 与 DML 并发时两边行为

## REP 复制

### REP-001 binlog 与主从复制（L）
- PG：streaming/logical replication；MySQL：binlog（statement/row/mixed）+ 主从
- 实验：搭建 3306→3307 主从，与 PG 流复制对照；逻辑复制为 PG 优势差异点

## BAK 备份恢复

### BAK-001 逻辑备份对照（M）
- pg_dump vs mysqldump（一致性快照、--single-transaction）

### BAK-002 物理备份对照（M）
- pg_basebackup vs xtrabackup（物理备份 + 增量）对比
