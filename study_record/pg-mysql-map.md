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
| Heap table | Clustered Index（主键即数据） | ❌ | 二级索引携带主键回表，PG 索引存 TID 回堆 | IDX-001 |
| WAL | InnoDB Redo + Binlog | ❌ | 双日志体系：redo 崩溃恢复 / binlog 复制+PITR | REDO-001/LOG-001 |
| VACUUM / autovacuum | Purge 线程 + history list | ❌ | PG 原地清理旧版本；InnoDB undo 链 + 后台 purge | MVCC-001 |
| Tuple 版本链（xmin/xmax） | undo log + roll_ptr 版本链 | 🔶 | 机制类似（多版本），实现和清理完全不同 | MVCC-001 |
| pg_locks | performance_schema.data_locks（或 innodb_status） | 🔶 | PG 系统表实时；MySQL P_S 表（本机 OFF，需另开） | ISO-001 |
| pg_stat_activity | SHOW PROCESSLIST / P_S.threads | 🔶 | 本机 P_S=OFF，用 PROCESSLIST + status 计数兜底 | MON-001 |
| pg_stat_statements | P_S.events_statements_summary / slow log | 🔶 | 本机 P_S=OFF，用 slow log + performance_schema 需启用 | MON-001 |
| pg_basebackup | xtrabackup（未装）/ CLONE | 🔶 | 本环境物理备份工具缺失，备份走 mysqldump+binlog | BAK-001/002 |
| WAL PITR（restore_command） | binlog + mysqlbinlog PITR | 🔶 | 逻辑回放，需 binlog 在库（log_bin=ON 已确认） | LOG-001 |
| Streaming Replication | Binlog Replication（source→replica） | ❌ | 异步/半同步 + GTID，relay log 中转 | REP-001 |
| EXPLAIN ANALYZE | EXPLAIN ANALYZE / EXPLAIN TREE | ✅ | 概念类似，格式与字段不同 | OPT-001 |
| 日志：postgresql.log | error.log + slow_query_log + general_log | 🔶 | error log 最核心；slow log 默认关 | MON-001 |
| 参数持久化 ALTER SYSTEM | SET PERSIST / SET PERSIST_ONLY | 🔶 | 均写盘（auto.conf vs mysqld-auto.cnf）；PG reload/pending_restart，MySQL 静态参数报 1238 | ENV-006 |
| 连接池 pgbouncer | thread_cache_size / 连接池 | 🔶 | PG 环境已有 pgbouncer；MySQL 学习实例单实例 | CONN-001 |
