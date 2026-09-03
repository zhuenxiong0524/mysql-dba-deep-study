# MySQL DBA 第一年对照学习总任务（PG 18.4 → MySQL 8.4）

> 版本：v0.3（2026-08-26 修订：并入运维关键点 CONN/UPG/DR，CLONE 并入 BAK，容量管理并入 ENG/MVCC）
> 基线：PostgreSQL 18.4（已掌握） → MySQL 8.4.10 LTS（学习中）
> 任务 ID 前缀：ENV/ENG/MVCC/ISO/REDO/LOG/BUF/IDX/OPT/MON/CONN/REP/BAK/UPG/SQL/CHA/DR
> 完成定义：专题目录含深度对照文章（PG 基线 + MySQL 源码因果链 + 最小同构实验 + 差异表 + Evidence）
> 以及可直接执行、判断和清理的完整 MySQL 命令/SQL；
> 理解验证、独立 Runbook 与扩展实验按风险或用户要求添加

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
- ✅ 已完成（2026-08-26）：源码下载校验、cmake 配置、编译安装、初始化、启动验证 3306、双引擎互通
- 详见 `study_record/env/ENV-001_mysql84_source_build/`

### ENV-002 双引擎交叉访问与对照实验工具链（S，P0）
- PG 侧：mysql 用户 trust 免密；MySQL 侧：建 pg@localhost
- 建立标准对照实验脚本模板（同 SQL 两边跑）

### ENV-003 数据字典与元数据架构（S，P2）
- PG：pg_catalog 系统目录 + 统计视图；MySQL：数据字典（mysql.ibd + DD API）
- 实验：information_schema 常用查询对照 pg_catalog
- 源码：sql/dd/；PG src/include/catalog/

### ENV-004 账号权限体系（S，P2，已完成）
- **状态（2026-08-28）**：✅ 对照文章 + evidence 已产出并推送（`study_record/env/ENV-004_mysql_privilege_system/`，15+ 组实验；EXP16 空密码/TCP 实测）
- 实测要点：'user'@'host' 是独立 Account；MySQL 无显式 DENY（库级授权后表级 REVOKE 报 1147）；Role 默认不激活（CURRENT_ROLE()=NONE）；PG 18 中 pg_* 角色名保留

- PG：role/privilege/GRANT；MySQL：mysql.user + 账号权限 + 角色
- 实验：同权限矩阵两边执行；8.4 默认 caching_sha2_password（PG trust/scram 对照）

### ENV-005 实例架构与生命周期（S，P0，生产向，✅ 已完成 2026-09-01）
- PG 基线：postmaster/backend 进程模型、postgresql.conf、data dir、pg_ctl、error log
- MySQL：mysqld 单进程多线程（连接线程 + InnoDB 后台线程族）、Server Layer + Storage Engine、datadir 构成
- 实验：ps/ss/systemctl（本机无 systemd 单元）、@@datadir/@@basedir/@@pid_file/@@log_error、error log 启动日志、P_S=OFF 现状
- 交付：环境基线 + 实例生命周期文章 + "实例挂了先看哪" 路径

### ENV-006 配置文件与参数体系（M，P0，生产向，✅ 已完成 2026-09-01）
- PG：postgresql.conf / ALTER SYSTEM / pg_settings / reload vs restart
- MySQL：my.cnf 搜索路径、mysqld --verbose --help、GLOBAL/SESSION/PERSIST/PERSIST_ONLY、动态 vs 需重启参数
- 实验：改参数三张表（在线/仅新连接/需重启）+ SET PERSIST 重启验证

### ENV-007 登录与认证（M，P0，生产向，✅ 已完成 2026-09-01）
- PG：Role + pg_hba.conf + trust/md5/scram
- MySQL：socket/TCP/localhost/IP、user@host 匹配、authentication_policy、caching_sha2_password、.my.cnf/login-path
- 实验：三种连接路线身份验证（USER()/CURRENT_USER()/CURRENT_ROLE()）；登录失败 Runbook
- 产出：`study_record/env/ENV-007_authentication/`（对照文章 + 4 evidence；host 匹配/TLS-2061/login-path 实测）

## ENG InnoDB 架构（MySQL 独有，无 PG 直接对应）

### ENG-001 InnoDB 架构与线程模型（L，P1）
- PG 基线：进程模型（postmaster/backend，一连接一进程）
- MySQL：引擎插件化（handler 接口）+ 一连接一线程 + InnoDB 后台线程族（purge/page_cleaner/log_writer/log_flusher/log_checkpointer/io_read/io_write）
- 实验：连接数变化观察 PG 进程 vs MySQL 线程（performance_schema.threads / information_schema.processlist）；后台线程定位
- 源码：storage/innobase/srv/srv0start.cc、os0thread.cc、handler/ha_innodb.cc

### ENG-002 表空间、文件布局与容量管理（M，P1）
- PG：base/ 每个数据库目录 + pg_wal + 表文件（relfilenode）
- MySQL：系统表空间 ibdata1、独立表空间 *.ibd、undo 表空间、redo 目录 #innodb_redo、doublewrite 文件、change buffer
- 容量管理：ibdata1 不回收、独立表空间碎片（OPTIMIZE TABLE）、undo 表空间膨胀、binlog/redo 磁盘上限
- 实验：建表/删表/ALTER 前后对比两边文件布局；制造碎片与膨胀观察两边回收手段
- 源码：storage/innobase/fil/fil0fil.cc、fsp0fsp.cc、buf/buf0dblwr.cc、ibuf/ibuf0ibuf.cc

## MVCC

### MVCC-001 事务版本链、可见性与清理（L，P0，✅ 已完成 2026-09-01）
- PG 基线：tuple xmin/xmax、snapshot、vacuum/autovacuum
- MySQL：undo log（insert/update undo）、roll_ptr 版本链、ReadView（m_ids/low_limit_id/up_limit_id）、purge 线程 + history list
- 运维视角：history list 长度过长（大事务/长查询拖住 purge）、undo 膨胀排查
- 实验：同表同隔离级别增删改，观察版本链、可见性、history list 长度变化；innodb_trx 对照 pg_stat_activity
- 源码：PG heapam.c/vacuumlazy.c；MySQL storage/innobase/trx/trx0rseg.c、trx0undo.c、read/read0read.c、purge/purge0purge.c

## ISO 隔离级别与锁

### ISO-001 隔离级别与锁（L，P1，✅ 已完成 2026-09-01）
- PG：RC（每语句快照）/RR（每事务快照）/Serializable(SSI)；行锁 + predicate lock；SSI 为差异点
- MySQL：RR（默认，快照读 + next-key）/RC；record/gap/next-key/insert intention；死锁检测
- 实验：RR 范围插入、RC 对照、反序更新死锁、RR 写偏差、PG SSI/MySQL SERIALIZABLE 两边均已跑通
- 源码：PG nodeLockRows.c/predicate.c/deadlock.c；MySQL lock0lock.h/trx0trx.h/row0sel.cc/ha_innodb.cc/lock0wait.cc
- 产出：`study_record/iso/ISO-001_locks_deadlock_ssi/`（文章、双会话复现手册、原始输出、源码证据、验证题）

### ISO-002 在线 DDL 与 MDL（M，P1，含原 LCK-001）
- PG：ALTER TABLE AccessExclusive 锁 + 重写；MySQL：MDL（metadata lock）+ ALGORITHM=INSTANT/INPLACE/COPY
- 大表 DDL 工具：gh-ost / pt-osc（MySQL 生态独有）
- 实验：大表 ADD COLUMN 两边并发 DML 对比（阻塞 vs 在线）；8.0 INSTANT 列操作
- 源码：storage/innobase/ddl/、sql/mdl.cc；PG src/backend/commands/tablecmds.c

## REDO 日志与恢复

### REDO-001 redo log 与崩溃恢复（L，P1）
- ✅ 完成（2026-09-02）：正常提交链及专用双引擎 kill -9 crash recovery 已完成；明确进程崩溃与断电边界
- PG：WAL（LSN/checkpoint/full_page_writes/pg_waldump）
- MySQL：InnoDB redo（LSN、group commit、innodb_flush_log_at_trx_commit、#innodb_redo、fuzzy checkpoint/adaptive flush）
- 实验：kill -9 崩溃恢复两边跑，对比 WAL 与 redo 日志内容、恢复日志输出
- 源码：PG src/backend/access/transam/xlog.c；MySQL storage/innobase/log/log0log.cc、log0chkp.cc

### LOG-001 binlog 与 PITR（L，P2）
- ✅ 阶段 1（2026-09-02）：ROW binlog 提交/回滚与 redo 协调已完成；PITR 待计划 12
- PG：WAL 归档 + restore_command 做时间点恢复；MySQL：binlog（statement/row/mixed）+ GTID + mysqlbinlog PITR
- 关键差异：MySQL 双日志体系（redo 本地崩溃恢复 / binlog 逻辑恢复+复制），PG 单 WAL
- 运维点：binlog 磁盘管理（binlog_expire_logs_seconds）
- 实验：建库→写入→drop→mysqlbinlog 恢复；对比 pg_waldump 时间点恢复
- 源码：sql/binlog.cc、sql/log_event.cc、sql/rpl_gtid.cc

## BUF Buffer Pool

### BUF-001 缓冲池与淘汰策略（L，P1）
- PG：shared_buffers + clock sweep；MySQL：innodb_buffer_pool（LRU + 预读 + 自适应哈希）
- 实验：缓存命中率（pg_buffercache vs information_schema.INNODB_BUFFER_PAGE_LRU）、冷数据扫描污染对照
- 源码：PG src/backend/storage/buffer/bufmgr.c；MySQL storage/innobase/buf/buf0lru.cc、buf0rea.cc

## IDX 索引

### IDX-001 B+tree、聚簇与覆盖索引（M，P1，✅ 已完成 2026-09-01）
- PG：堆表 + B-tree 索引 + 回表；INCLUDE 索引；MySQL：InnoDB 聚簇索引（主键即数据）+ 二级索引回主键 + 覆盖索引
- 实验：同表同查询 EXPLAIN 对照（回表 vs 覆盖）；页结构对比（PG bufpage vs InnoDB page 头）
- 源码：PG src/backend/access/nbtree/；MySQL storage/innobase/btr/btr0cur.cc、page/page0cur.cc

### IDX-002 索引类型差异与全文/空间索引（S，P2，差异点）
- PG 独有：GIN/GiST/BRIN/SP-GiST（差异点清单）；MySQL：B-tree/Hash(内存表)/FULLTEXT/空间 R-tree
- 实验：全文检索两边跑（GIN vs InnoDB FULLTEXT）作为差异演示

## OPT 优化器

### OPT-001 统计信息与执行计划对照（M，P1）
- PG：ANALYZE + 代价模型 + EXPLAIN (ANALYZE, BUFFERS)；MySQL：ANALYZE TABLE + 持久化统计（mysql.innodb_table_stats）+ EXPLAIN ANALYZE/TREE
- 实验：同表同数据量同 SQL 两边计划对照（join 顺序、索引选择）；统计信息刷新机制
- 源码：PG src/backend/commands/analyze.c；MySQL sql/opt_explain.cc、storage/innobase/dict/dict0stats.cc

## MON 监控与排障

### MON-001 慢查询日志、performance_schema 与排障流程（M，P2）
- PG 对照：log_min_duration_statement + pg_stat_activity/pg_stat_statements
- MySQL：slow_query_log（mysqldumpslow/pt-query-digest）、performance_schema（events_statements_summary、等待事件、metadata_locks、data_lock_waits）、sys schema、error log/general log 定位
- 实验：制造慢 SQL、MDL 阻塞、死锁，两边捕获对照
- 源码：sql/slow_log.cc、storage/perfschema/

### CONN-001 连接管理与连接池（S，P1，新增）
- PG 基线：进程模型连接开销、max_connections 内存估算
- MySQL：thread cache（threads_connected/thread_cache_size）、Too many connections 处理、连接泄漏排查、ProxySQL 连接池
- 实验：连接数压测对照（PG 进程数 vs MySQL 线程数、内存占用）
- 源码：sql/conn_handler/connection_handler_manager.cc、mysys/thr_mutex.cc

## REP 复制

### REP-001 binlog 主从复制与 GTID（L，P2）
- PG：streaming/logical replication；MySQL：binlog 主从（异步/半同步）+ GTID；MGR（组复制）为 MySQL 独有
- 运维点：Seconds_Behind_Master 延迟排查、relay log 管理、主从切换
- 实验：3306→3307 主从搭建，故障切换对照 PG 流复制；逻辑复制为 PG 优势差异点
- 源码：sql/rpl_replica.cc、sql/rpl_gtid.cc、storage/innobase/arch/

## BAK 备份恢复

### BAK-001 逻辑备份对照（M，P2）
- pg_dump vs mysqldump：一致性快照（--single-transaction vs REPEATABLE READ + FTWRL）

### BAK-002 物理备份对照（M，P2）
- pg_basebackup vs xtrabackup（物理备份 + 增量 + 恢复演练）
- MySQL 8.4 原生 CLONE 插件（8.0.17+）：搭建从库/备份，与 xtrabackup 场景对比

## UPG 变更与升级

### UPG-001 版本升级与参数持久化（M，P2，新增）
- PG：pg_upgrade、ALTER SYSTEM、postgresql.conf 管理
- MySQL：8.0→8.4 升级路径、启动时自动升级数据字典（8.4 无需手动 mysql_upgrade）、SET PERSIST / SET PERSIST_ONLY（8.0+，重启保留，细粒度优于 ALTER SYSTEM）
- 实验：参数修改后重启两边验证持久化行为
- 源码：sql/sys_vars.cc、sql/persisted_variable.cc

## SQL 方言与心智迁移

### SQL-001 SQL 方言对照（M，P1）
- 高频差异：LIMIT vs FETCH FIRST；ON DUPLICATE KEY UPDATE vs ON CONFLICT；REPLACE INTO；INSERT IGNORE；UPDATE ... JOIN vs UPDATE FROM；GROUP BY 宽松（MySQL 功能依赖）；FOR UPDATE SKIP LOCKED 差异
- 实验：同一"业务脚本"两边改写对照；数据类型差异（JSON/ENUM vs json/jsonb、AUTO_INCREMENT vs SERIAL）
- 源码：sql/sql_yacc.yy、sql/sql_lex.cc

### CHA-001 字符集与排序规则（S，P2）
- PG：encoding + collation；MySQL：character_set_server/utf8mb4/collation 三层
- 实验：乱码与排序行为两边对照
- 源码：strings/、sql/charset.cc

## DR 故障演练

### DR-001 故障演练对照（S，P2，新增）
- 同故障两边演练对照：OOM（PG 进程隔离 vs MySQL 线程全挂风险）、磁盘满、连接打满、主从切换、崩溃恢复
- 交付：故障演练清单 + 处置 SOP 对照表（MySQL 侧为主体）

## MYSQL-BASIC 基础命令对照（新增系列，v0.4 2026-08-27）

### MYSQL-BASIC-001 基础命令与核心概念对照（M，P0，✅ 已完成 2026-09-01）
- PG 基线：psql 元命令、pg_stat_activity、pg_settings、role、事务/DDL 语义
- MySQL：mysql 客户端、SHOW 系列、PROCESSLIST、SHOW VARIABLES、user@host、autocommit/DDL 隐式提交
- 实验：26 类"同命令两边跑"，输出见 study_record/mysql/MYSQL-BASIC-001_pg_vs_mysql_basic/evidence/
- 交付：对照文章（16 条易踩坑 + 30+ 概念映射表）+ 22 道验证题（含答案）；2026-09-01 环境清理完毕


---

## MySQL 生产 DBA 快速迁移执行计划（v0.5，2026-08-28 追加）

> 目标：以 PG 18.4 为参照系，按 6 阶段快速获得 MySQL 生产接管能力（P0=能运维生产 > P1=能深入分析 >>> P2=专家级）。
> 与上面专题体系的关系：本计划是"执行顺序与优先级视图"，专题定义以本文件上方案列为准。
> 每个专题默认深度快跑：待证明结论 → PG 基线 → MySQL 核心源码链 → 最小同构实验 → MySQL 完整实操
> → 收敛 evidence/文章
> → 仅按需更新 map/runbook/verification → 汇报（不自动 commit）；高风险或证据不足部分才升级深度模式。

### 第一阶段：敢登录、敢看、不会误操作（P0）
| 顺序 | 专题 | 任务 ID | 状态 |
|---|---|---|---|
| 1 | 实例架构与生命周期 | ENV-005 | ✅ 已完成 2026-09-01 |
| 2 | 配置文件与参数体系 | ENV-006 | ✅ 已完成 2026-09-01 |
| 3 | 登录与认证 | ENV-007 | ✅ 已完成 2026-09-01 |
| 4 | 账号与权限体系 | ENV-004 | ✅ 已完成 |

### 第二阶段：能理解 MySQL 正在发生什么（P0）
| 顺序 | 专题 | 任务 ID | 状态 |
|---|---|---|---|
| 5 | InnoDB 架构 | ENG-001 | ✅ 已完成 2026-09-01 |
| 6 | 表空间/文件/容量 | ENG-002 | ✅ 已完成 2026-09-01 |
| 7 | Clustered Index 与回表 | IDX-001 | ✅ 已完成 2026-09-01 |
| 8 | 事务/MVCC/Undo | MVCC-001 | ✅ 已完成 2026-09-01 |
| 9 | 锁/Gap/Next-Key/死锁 | ISO-001 | ✅ 已完成 2026-09-01 |

### 第三阶段：数据出问题能恢复（P0）
| 顺序 | 专题 | 任务 ID | 状态 |
|---|---|---|---|
| 10 | Redo/Undo/Binlog 三日志 | REDO-001 + LOG-001 | ✅ 阶段 1 完成 2026-09-02 |
| 11 | Crash Recovery（专用实验实例） | REDO-001 | ✅ 2026-09-02 |
| 12 | Backup/Restore/PITR | BAK-001/002 + LOG-001 | ✅ S 级完成（双引擎实验、源码链、MySQL Runbook） |

### 第四阶段：能接主从生产（P0）
| 顺序 | 专题 | 任务 ID | 状态 |
|---|---|---|---|
| 13 | Binlog 主从复制 + GTID | REP-001 | ✅ S 级完成 2026-09-03 |
| 14 | 复制延迟/中断排查 | REP-001 + MON-001 | 未开始 |

### 第五阶段：能处理性能故障（P0/P1）
| 顺序 | 专题 | 任务 ID | 状态 |
|---|---|---|---|
| 15 | Optimizer/EXPLAIN | OPT-001 | 未开始 |
| 16 | 组合索引与统计信息 | OPT-001 + IDX-001 | 未开始 |
| 17 | Performance Schema / 慢 SQL | MON-001（注意：本机 P_S=OFF） | 未开始 |
| 18 | 连接数/长事务/CPU/IO/磁盘 | CONN-001 + MON-001 + DR-001 | 未开始 |

### 第六阶段：完整生产运维（P0/P1）
| 顺序 | 专题 | 任务 ID | 状态 |
|---|---|---|---|
| 19 | Online DDL 与 MDL | ISO-002 | 未开始 |
| 20 | HA/Failover | DR-001 + REP-001 | 未开始 |

### 横切资产（随专题持续扩展）
- study_record/pg-mysql-map.md：PG→MySQL 总映射表
- study_record/environment-baseline.md：环境基线
- study_record/safety.md：实验安全规范
- study_record/runbook/mysql-dba-cheatsheet.md：生产命令手册（按问题分类）
- study_record/troubleshooting/：故障案例库（CASE-001 Login Failed ... CASE-018 Buffer Pool Pressure）
