# PostgreSQL → MySQL 总映射表（持续扩展）

> 说明：本表是"心智迁移索引"，不是等价声明。每完成一个专题就扩展。
> "是否等价"列：✅ 可直接类比 / 🔶 部分等价（必须讲清差异）/ ❌ 不等价（禁止简单替换名字）。
> 依据：实机验证 + 各专题文章（链接指向 study_record/ 对应任务）。

| PostgreSQL | MySQL | 是否等价 | 一句话差异 | 出处 |
|---|---|---|---|---|
| postgres（postmaster+backend 进程） | mysqld（单进程多线程） | 🔶 | PG 一连接一进程；MySQL 一连接一线程 + InnoDB 后台线程族 | ENV-005/ENG-001 |
| postmaster 辅助进程（checkpointer/bgwriter/walwriter/autovacuum launcher） | InnoDB 后台线程族（purge/page_cleaner/log_writer/log_flusher/log_checkpointer/io_read/io_write） | 🔶 | 职责一一对应（purge≈vacuum、page_cleaner≈bgwriter、log_*≈walwriter），但形态是进程 vs 线程；MySQL 无进程隔离 | ENG-001 |
| postgresql.conf | my.cnf + 启动参数 | 🔶 | PG 单文件集中；MySQL 有配置搜索路径 + SET PERSIST(mysqld-auto.cnf) | ENV-006 |
| pg_settings（SHOW） | SHOW [GLOBAL\|SESSION] VARIABLES / @@var + performance_schema.variables_info | 🔶 | PG 有 context+source+pending_restart；MySQL 无来源列但 variables_info（P_S=OFF 也可查）给 VARIABLE_SOURCE/PATH/SET_USER，无全局 reload | ENV-006 |
| pg_ctl start/stop/reload | mysqld_safe / mysqladmin shutdown / systemd | 🔶 | 本环境无 systemd 单元，mysqld_safe 托管 | ENV-005 |
| Role | Account = 'user'@'host' | ❌ | host 是身份一部分，同名不同 host 是不同账号 | ENV-004 |
| pg_hba.conf | mysql.user host 匹配 + authentication_policy | ❌ | PG 来源由 hba 行决定（trust/md5/scram）；MySQL host 焊死在账号里，无匹配 Account 即 1045 | ENV-004/007 |
| password_encryption / SCRAM | 认证插件（默认 caching_sha2_password） | 🔶 | PG 密码存 SCRAM-SHA-256；MySQL 账号带 plugin 列；caching_sha2 需 TLS 或 RSA（--ssl-mode=DISABLED 报 2061） | ENV-007 |
| ~/.pgpass | login-path / .my.cnf [client] | 🔶 | login-path 加密（~/.mylogin.cnf）优于明文 .my.cnf | ENV-007 |
| CREATE ROLE ... LOGIN | CREATE USER / CREATE ROLE | 🔶 | MySQL 的 role 默认不可登录且需激活 | ENV-004 |
| GRANT/REVOKE + ACL | GRANT/REVOKE + mysql 权限表 | 🔶 | MySQL 集中权限表、无显式 DENY（库级伞下 REVOKE 报 1147） | ENV-004 |
| WITH GRANT OPTION | WITH GRANT OPTION | ✅ | 均只能转授持有且不超 scope 的权限 | ENV-004 |
| Role Membership INHERIT | GRANT role TO user + 激活 | ❌ | PG 默认继承生效；MySQL 默认不激活（CURRENT_ROLE()=NONE） | ENV-004 |
| shared_buffers | innodb_buffer_pool_size | 🔶 | 均缓存数据页；MySQL 还有 log buffer/双写/自适应哈希 | BUF-001 |
| Heap table + 独立 B-tree（主键也存 TID） | Clustered Index（PRIMARY 叶子即整行） | ❌ | PG Index Scan 按 TID 回 heap；InnoDB 二级索引自动携带聚簇键，缺列时回 PRIMARY | IDX-001 |
| Index Only Scan + INCLUDE + visibility map | Covering index (`Using index`) | 🔶 | PG 即使 Index Only 也可能 Heap Fetch；InnoDB 投影覆盖通常免常规回表，但 MVCC 可见性不足时仍可能访问聚簇记录 | IDX-001 |
| 无 PRIMARY KEY 的 heap 表 | 隐藏 `GEN_CLUST_INDEX` + `DB_ROW_ID` | ❌ | PG 仍是普通 heap；InnoDB 永远需要聚簇索引，隐藏键不可供业务稳定引用 | IDX-001 |
| WAL | InnoDB Redo + Binlog | ❌ | 双日志体系：redo 崩溃恢复 / binlog 复制+PITR | REDO-001/LOG-001 |
| WAL 中同时含数据变更与 COMMIT/ABORT | InnoDB redo/undo + 仅提交事务进入 binlog | ❌ | 可回滚事务会推进 redo LSN，但事务 binlog cache 被截断，position 不前进 | REDO-001/LOG-001 |
| synchronous_commit | innodb_flush_log_at_trx_commit + sync_binlog | ❌ | PG 一个 WAL 刷盘维度；MySQL 必须同时评估 redo 与 binlog 两侧故障窗口 | REDO-001/LOG-001 |
| 表文件（base/<oid>/<relfilenode>） | 库名/表.ibd（file-per-table） | 🔶 | PG 文件是裸数字 relfilenode；MySQL 文件名一眼可读；8.4 字典在 mysql.ibd、ibdata1 不再膨胀 | ENG-002 |
| VACUUM (FULL) / TRUNCATE | OPTIMIZE TABLE / TRUNCATE TABLE | 🔶 | 都重写/换文件；PG VACUUM FULL=CLUSTER 变体，MySQL OPTIMIZE=ALTER 重建；TRUNCATE 都回到初始文件 | ENG-002 |
| VACUUM / autovacuum + OldestXmin | Purge 线程 + oldest ReadView + History List Length | ❌ | 长快照都拖住清理；PG 留 dead heap tuples，InnoDB 留 update undo/history | MVCC-001 |
| Heap tuple 版本链（xmin/xmax/ctid） | 聚簇记录 DB_TRX_ID/DB_ROLL_PTR + update undo 链 | 🔶 | PG 新旧完整 tuple 在 heap；InnoDB 当前记录在 PRIMARY、旧值由 undo 重建 | MVCC-001 |
| Snapshot xmin/xmax/xip | ReadView up/low limit + m_ids | 🔶 | 都按事务 ID 边界与活跃集合判可见；PG 默认 RC 每语句快照，MySQL 默认 RR 复用 ReadView | MVCC-001 |
| RR 范围 FOR UPDATE 锁已命中 tuple | RR 范围锁定读的 Next-Key Lock | ❌ | PG 不锁不存在的键，插入可提交、旧快照看不到；InnoDB 锁索引记录及前方 gap，阻塞范围插入 | ISO-001 |
| 无 Gap/Next-Key Lock | Record/Gap/Next-Key/Insert Intention Lock | ❌ | PG 行锁基于已找到 tuple；InnoDB 锁落在索引记录/间隙，范围取决于索引与扫描路径 | ISO-001 |
| Serializable SSI + 非阻塞 SIReadLock | SERIALIZABLE 普通读转 S 锁（显式事务） | ❌ | PG 乐观跟踪 rw-conflict 并在危险结构时取消；MySQL 悲观阻塞，可能形成死锁 | ISO-001 |
| RR snapshot isolation 写偏差 | RR consistent read 写偏差 | 🔶 | 同一 doctor 实验两边均允许不相交写集提交，跨行不变量被破坏 | ISO-001 |
| deadlock detected（40P01） | ERROR 1213（SQLSTATE 40001） | 🔶 | 均检测等待环并取消 victim；PG 事务进入 aborted，应用都应重试整个事务 | ISO-001 |
| pg_locks / pg_blocking_pids() | performance_schema.data_locks/data_lock_waits 或 INNODB_TRX + InnoDB status | 🔶 | PG 系统视图直接查；本机 MySQL P_S=OFF，以 INNODB_TRX/PROCESSLIST/status 兜底 | ISO-001 |
| pg_stat_activity | SHOW PROCESSLIST / P_S.threads | 🔶 | 本机 P_S=OFF，用 PROCESSLIST + status 计数兜底 | MON-001 |
| pg_stat_statements | P_S.events_statements_summary / slow log | 🔶 | 本机 P_S=OFF，用 slow log + performance_schema 需启用 | MON-001 |
| pg_basebackup | xtrabackup（未装）/ CLONE | 🔶 | 本环境物理备份工具缺失，备份走 mysqldump+binlog | BAK-001/002 |
| WAL PITR（restore_command） | binlog + mysqlbinlog PITR | 🔶 | 逻辑回放，需 binlog 在库（log_bin=ON 已确认） | LOG-001 |
| Streaming Replication | Binlog Replication（source→replica） | ❌ | 异步/半同步 + GTID，relay log 中转 | REP-001 |
| EXPLAIN ANALYZE | EXPLAIN ANALYZE / EXPLAIN TREE | ✅ | 概念类似，格式与字段不同 | OPT-001 |
| 日志：postgresql.log | error.log + slow_query_log + general_log | 🔶 | error log 最核心；slow log 默认关 | MON-001 |
| 参数持久化 ALTER SYSTEM | SET PERSIST / SET PERSIST_ONLY | 🔶 | 均写盘（auto.conf vs mysqld-auto.cnf）；PG reload/pending_restart，MySQL 静态参数报 1238 | ENV-006 |
| 连接池 pgbouncer | thread_cache_size / 连接池 | 🔶 | PG 环境已有 pgbouncer；MySQL 学习实例单实例 | CONN-001 |
