# MySQL DBA 第一年对照学习总任务（PG 18.4 → MySQL 8.4）

> 版本：v0.2（2026-08-26 修订：压缩 PG 深/MySQL 浅的拆篇，新增 MySQL 独有主题）
> 基线：PostgreSQL 18.4（已掌握） → MySQL 8.4.10 LTS（学习中）
> 任务 ID 前缀：ENV/ENG/MVCC/ISO/REDO/LOG/BUF/IDX/OPT/MON/REP/BAK/SQL/CHA
> 完成定义：专题目录含对照文章（PG 基线 + MySQL 源码定位 + 同实验 + 差异表 + Evidence）并经过理解验证

## 使用原则

- 每个专题先写 PG 侧机制与结论（基线），再定位 MySQL 源码对应机制，最后同一实验两边各跑一遍
- 关键结论必须源码确认（MySQL 源码在 /data/myhome/mydata/mysql-src/mysql-8.4.10）
- MySQL 缺失/不同实现（GIN/GiST、SSI、逻辑复制、流复制）标注为"心智地图差异点"，不单独成文
- 熟悉内容快速成文；核心机制深入源码 + 调用链

## 权重与优先级

- `S`：快速整理，1 分；`M`：标准研究，2 分；`L`：深度机制，3 分
- 优先级：P0 最先（当前执行）→ P1 核心 → P2 常规

## ENV 环境

### ENV-001 MySQL 8.4.10 源码编译安装（S，P0）
- 进行中：源码下载校验、cmake 配置、编译安装（见 docs/environment.md）
- 待完成：实例初始化、启动、验证 3306

### ENV-002 双引擎交叉访问与对照实验工具链（S，P0）
- PG 侧：mysql 用户 trust 免密；MySQL 侧：建 pg@localhost
- 建立标准对照实验脚本模板（同 SQL 两边跑）

### ENV-003 数据字典与元数据架构（S，P2，新增）
- PG：pg_catalog 系统目录 + 统计视图；MySQL：数据字典（mysql.ibd + DD API）
- 实验：information_schema 常用查询对照 pg_catalog
- 源码：sql/dd/；PG src/include/catalog/

### ENV-004 账号权限体系（S，P2，新增）
- PG：role/privilege/GRANT；MySQL：mysql.user + 账号权限 + 角色
- 实验：同权限矩阵两边执行；8.4 默认 caching_sha2_password（PG trust/scram 对照）

## ENG InnoDB 架构（MySQL 独有，无 PG 直接对应）

### ENG-001 InnoDB 架构与线程模型（L，P1，新增）
- PG 基线：进程模型（postmaster/backend，一连接一进程）
- MySQL：引擎插件化（handler 接口）+ 一连接一线程 + InnoDB 后台线程族（purge/page_cleaner/log_writer/log_flusher/log_checkpointer/io_read/io_write）
- 实验：连接数变化观察 PG 进程 vs MySQL 线程（performance_schema.threads / information_schema.processlist）；后台线程定位
- 源码：storage/innobase/srv/srv0start.cc、os0thread.cc、handler/ha_innodb.cc

### ENG-002 表空间与文件布局（M，P1，新增）
- PG：base/ 每个数据库目录 + pg_wal + 表文件（relfilenode）
- MySQL：系统表空间 ibdata1、独立表空间 *.ibd、undo 表空间、redo 目录 #innodb_redo、doublewrite 文件、change buffer
- 实验：建表/删表/ALTER 前后对比两边文件布局；doublewrite 与 change buffer 状态
- 源码：storage/innobase/fil/fil0fil.cc、fsp0fsp.cc、buf/buf0dblwr.cc、ibuf/ibuf0ibuf.cc

## MVCC

### MVCC-001 事务版本链、可见性与清理（L，P0，首专题）
> 原 MVCC-001/002/003 合并：PG Snapshot 深度在 PG 项目已学，MySQL 侧 ReadView/purge 相对简单，一篇覆盖
- PG 基线：tuple xmin/xmax、snapshot、vacuum/autovacuum
- MySQL：undo log（insert/update undo）、roll_ptr 版本链、ReadView（m_ids/low_limit_id/up_limit_id）、purge 线程 + history list
- 实验：同表同隔离级别增删改，观察版本链、可见性、history list 长度变化；innodb_row_versions/innodb_trx 对照 pg_stat_activity + 快照
- 源码：PG heapam.c/vacuumlazy.c；MySQL storage/innobase/trx/trx0rseg.c、trx0undo.c、read/read0read.c、purge/purge0purge.c

## ISO 隔离级别与锁

### ISO-001 隔离级别与锁（L，P1）
> 原 ISO-001/002 合并：MySQL gap/next-key 锁与隔离级别是同一机制
- PG：RC（每语句快照）/RR（每事务快照）/Serializable(SSI)；行锁 + predicate lock；SSI 为差异点
- MySQL：RR（默认，快照读 + next-key）/RC；record/gap/next-key/insert intention；死锁检测
- 实验：幻读、不可重复读、写偏斜两边对照；锁等待与死锁检测日志对比（innodb_status_output_locks vs pg_locks）
- 源码：PG heapam.c/lock.c；MySQL storage/innobase/lock/lock0lock.c、lock0prdt.cc

### ISO-002 在线 DDL 与 MDL（M，P1，新增，含原 LCK-001）
- PG：ALTER TABLE AccessExclusive 锁 + 重写；MySQL：MDL（metadata lock）+ ALGORITHM=INSTANT/INPLACE/COPY
- 实验：大表 ADD COLUMN 两边并发 DML 对比（阻塞 vs 在线）；8.0 INSTANT 列操作
- 源码：storage/innobase/ddl/、sql/mdl.cc；PG src/backend/commands/tablecmds.c

## REDO 日志与恢复

### REDO-001 redo log 与崩溃恢复（L，P1）
> 原 REDO-001/002 合并：MySQL 8.0.30+ checkpoint 由 #innodb_redo 管理，单独成文单薄
- PG：WAL（LSN/checkpoint/full_page_writes/pg_waldump）
- MySQL：InnoDB redo（LSN、group commit、innodb_flush_log_at_trx_commit、#innodb_redo、fuzzy checkpoint/adaptive flush）
- 实验：kill -9 崩溃恢复两边跑，对比 WAL 与 redo 日志内容、恢复日志输出
- 源码：PG src/backend/access/transam/xlog.c；MySQL storage/innobase/log/log0log.cc、log0chkp.cc

### LOG-001 binlog 与 PITR（L，P2，新增）
- PG：WAL 归档 + restore_command 做时间点恢复；MySQL：binlog（statement/row/mixed）+ GTID + mysqlbinlog PITR
- 关键差异：MySQL 双日志体系（redo 本地崩溃恢复 / binlog 逻辑恢复+复制），PG 单 WAL
- 实验：建库→写入→drop→mysqlbinlog 恢复；对比 pg_waldump 时间点恢复
- 源码：sql/binlog.cc、sql/log_event.cc、sql/rpl_gtid.cc

## BUF Buffer Pool

### BUF-001 缓冲池与淘汰策略（L，P1）
- PG：shared_buffers + clock sweep；MySQL：innodb_buffer_pool（LRU + 预读 + 自适应哈希）
- 实验：缓存命中率（pg_buffercache vs information_schema.INNODB_BUFFER_PAGE_LRU）、冷数据扫描污染对照
- 源码：PG src/backend/storage/buffer/bufmgr.c；MySQL storage/innobase/buf/buf0lru.cc、buf0rea.cc

## IDX 索引

### IDX-001 B+tree、聚簇与覆盖索引（M，P1）
> 原 IDX-001/002 合并
- PG：堆表 + B-tree 索引 + 回表；INCLUDE 索引；MySQL：InnoDB 聚簇索引（主键即数据）+ 二级索引回主键 + 覆盖索引
- 实验：同表同查询 EXPLAIN 对照（回表 vs 覆盖）；页结构对比（PG bufpage vs InnoDB page 头）
- 源码：PG src/backend/access/nbtree/；MySQL storage/innobase/btr/btr0cur.cc、page/page0cur.cc

### IDX-002 索引类型差异与全文/空间索引（S，P2，差异点）
- PG 独有：GIN/GiST/BRIN/SP-GiST（差异点清单）；MySQL：B-tree/Hash(内存表)/FULLTEXT/空间 R-tree
- 实验：全文检索两边跑（GIN vs InnoDB FULLTEXT）作为差异演示

## OPT 优化器

### OPT-001 统计信息与执行计划对照（M，P1）
> 原 OPT-001/002 合并
- PG：ANALYZE + 代价模型 + EXPLAIN (ANALYZE, BUFFERS)；MySQL：ANALYZE TABLE + 持久化统计（mysql.innodb_table_stats）+ EXPLAIN ANALYZE/TREE
- 实验：同表同数据量同 SQL 两边计划对照（join 顺序、索引选择）；统计信息刷新机制
- 源码：PG src/backend/commands/analyze.c；MySQL sql/opt_explain.cc、storage/innobase/dict/dict0stats.cc

## MON 监控与排障（MySQL 重点）

### MON-001 慢查询日志与 performance_schema（M，P2，新增）
- PG 对照：log_min_duration_statement + pg_stat_activity/pg_stat_statements
- MySQL：slow_query_log（mysqldumpslow/pt-query-digest）、performance_schema（events_statements_summary、等待事件）、sys schema
- 实验：制造慢 SQL，两边捕获对照；PFS 线程/等待事件 vs PG 等待事件视图
- 源码：sql/slow_log.cc、storage/perfschema/

## REP 复制

### REP-001 binlog 主从复制与 GTID（L，P2）
- PG：streaming/logical replication；MySQL：binlog 主从（异步/半同步）+ GTID；MGR（组复制）为 MySQL 独有
- 实验：3306→3307 主从搭建，故障切换对照 PG 流复制；逻辑复制为 PG 优势差异点
- 源码：sql/rpl_replica.cc、sql/rpl_gtid.cc、storage/innobase/arch/（clone 插件）

## BAK 备份恢复

### BAK-001 逻辑备份对照（M，P2）
- pg_dump vs mysqldump：一致性快照（--single-transaction vs REPEATABLE READ + FTWRL）

### BAK-002 物理备份对照（M，P2）
- pg_basebackup vs xtrabackup（物理备份 + 增量 + 恢复演练）

## SQL 方言与心智迁移

### SQL-001 SQL 方言对照（M，P1，新增）
- 高频差异：LIMIT vs FETCH FIRST；ON DUPLICATE KEY UPDATE vs ON CONFLICT；REPLACE INTO；INSERT IGNORE；UPDATE ... JOIN vs UPDATE FROM；GROUP BY 宽松（MySQL 功能依赖）；FOR UPDATE SKIP LOCKED 差异
- 实验：同一"业务脚本"两边改写对照；数据类型差异（JSON/ENUM vs json/jsonb、AUTO_INCREMENT vs SERIAL）
- 源码：sql/sql_yacc.yy、sql/sql_lex.cc

### CHA-001 字符集与排序规则（S，P2，新增）
- PG：encoding + collation；MySQL：character_set_server/utf8mb4/collation 三层
- 实验：乱码与排序行为两边对照
- 源码：strings/、sql/charset.cc

## 心智地图差异点清单（不单独成文）

- PG 独有：GIN/GiST/BRIN/SP-GiST 索引、SSI、逻辑复制、WAL 归档单一日志体系、进程模型、vacuum 深度机制
- MySQL 独有：存储引擎插件化、doublewrite/change buffer、binlog 双日志体系、gap/next-key 锁、INSTANT DDL、slow query log/PFS、MGR、utf8mb4、AUTO_INCREMENT
- 历史差异：MySQL 查询缓存（8.0 已移除）
