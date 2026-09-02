# MySQL 生产命令手册（按问题分类，不按命令分类）

> 持续扩展：每完成一个专题填充对应问题段。证据来自本机实测（study_record/env/ENV-00x/evidence）。
> 通用：`mysql -uroot -S /tmp/mysql.sock`（本机 root 仅 socket 空密码；生产必须用强口令账号 + login-path）

## 实例是否正常 / 实例在哪？

```bash
# 进程
ps -ef | grep mysqld | grep -v grep        # mysqld_safe → mysqld 两行
# 端口
ss -lntp | grep 3306
# socket
ss -lx | grep mysql
# 存活探针（等价 pg_isready）
mysqladmin -uroot -S /tmp/mysql.sock ping
# 状态计数（Uptime/Threads/Questions/Opens/Queries per second）
mysqladmin -uroot -S /tmp/mysql.sock status
```

```sql
SELECT @@hostname, @@port, @@socket, @@datadir, @@basedir, @@pid_file, @@log_error;
SELECT VERSION();
```

结果解释：
- `mysqld is alive` = 实例接受连接
- `ERROR 2002 ... Can't connect` = socket 不存在/实例未启动
- `ERROR 1045 (28000)` = 认证失败（Account 匹配/密码，见 ENV-004/007）
- 本机无 systemd 单元（`systemctl status mysqld` → Unit not found），由 mysqld_safe 托管

## 实例挂了，先看哪里？

```text
1. ps/pid 文件（/data/myhome/mydata/mysql/mysql.pid）→ mysqld 在不在
2. mysqladmin ping → 探活
3. error log 尾部（log_error 指向 /data/myhome/mydata/mysql/error.log）
4. mysqld_safe.log（托管进程日志）
5. 系统资源（df -h 磁盘满？free -m OOM？dmesg | tail）
```

```bash
tail -50 /data/myhome/mydata/mysql/error.log
grep -E "ready for connections|Shutdown complete|ERROR|FATAL" /data/myhome/mydata/mysql/error.log | tail
```

## 当前连接多少 / 谁在跑 SQL？

```sql
SHOW FULL PROCESSLIST;               -- 当前连接 + 正在执行的 SQL（P_S OFF 时兜底）
SHOW GLOBAL STATUS LIKE 'Threads%';  -- Threads_connected / Threads_running
SHOW VARIABLES LIKE 'max_connections';
```

线程数观察（ENG-001：mysqld 单进程多线程，进程恒 1 个）：

```bash
ps -ef | grep "[m]ysqld"                          # 进程恒 1 个（+守护 mysqld_safe），≠ 负载
ls /proc/$(cat /data/myhome/mydata/mysql/mysql.pid)/task | wc -l   # 全部线程数
ps -L -p $(cat /data/myhome/mydata/mysql/mysql.pid) -o tid,comm | head
```

```sql
SHOW ENGINE INNODB STATUS\G  -- BACKGROUND THREAD / FILE I/O 段：后台线程族（purge/page_cleaner/log_*/io_*）
-- P_S=OFF 时 performance_schema.threads 为空，用 processlist + SHOW ENGINE INNODB STATUS 兜底
```

## 当前用户是谁 / 有什么权限？

```sql
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
SHOW GRANTS;
SHOW GRANTS FOR CURRENT_USER;
```

## 登录与认证速查（ENV-007）

```bash
# 连接路线决定 host 匹配方向：socket→localhost；TCP→IP 字面量（skip-name-resolve=ON）
mysql -uroot -S /tmp/mysql.sock                 # socket
mysql -uuser -h127.0.0.1 -P3306 -p             # TCP 回环
mysql --login-path=demo                        # 加密凭据（mysql_config_editor set 生成）
```

```sql
-- USER()=客户端声称身份；CURRENT_USER()=实际命中的 Account（不一致=命中 % 通配账号）
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
-- 认证插件与账号 host
SELECT user, host, plugin FROM mysql.user WHERE user LIKE '目标%';
-- 连接是否 TLS（caching_sha2 免 RSA 的前提；Ssl_cipher 空=socket 或未走 TLS）
SHOW SESSION STATUS LIKE 'Ssl_cipher';
```

```text
ERROR 1045 (28000) ... using password: YES → 密码错/账号不存在/host 不匹配（见 CASE-001）
ERROR 2061 (HY000) Authentication requires secure connection
  → caching_sha2 非 TLS 需 RSA：加 --ssl-mode=REQUIRED 或 --get-server-public-key
```

```bash
# login-path 管理（~/.mylogin.cnf 加密；print 显示掩码）
mysql_config_editor set --login-path=demo --host=127.0.0.1 --user=u --password
mysql_config_editor print --all
mysql_config_editor remove --login-path=demo
```

## 参数从哪里来的？

```sql
SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size';  -- 当前生效值（GLOBAL 视角）
SHOW VARIABLES LIKE 'transaction_isolation';           -- SESSION 视角
```

```bash
my_print_defaults mysqld               # 配置链合成结果
cat /data/myhome/mydata/mysql/mysqld-auto.cnf   # SET PERSIST 残留（优先级高于 my.cnf）
ps -ef | grep mysqld                   # 启动命令行参数
```

## 改参数三态（本机实测，ENV-006）

| 分类 | 示例 | 改法 | 重启后 |
|---|---|---|---|
| 会话级 | transaction_isolation / sort_buffer_size | `SET SESSION x=...` | 丢失 |
| 全局动态 | max_connections / server_id(8.0+) | `SET GLOBAL x=...` 或 `SET PERSIST x=...` | GLOBAL 丢失 / PERSIST 保留 |
| 静态需重启 | port / performance_schema | 改 my.cnf 或 `SET PERSIST_ONLY` | 保留 |

```sql
SET SESSION sort_buffer_size=524288;          -- 仅本会话
SET GLOBAL max_connections=200;               -- 在线生效，不持久
SET PERSIST max_connections=105;              -- 在线生效 + 写 auto.cnf，重启保留
SET PERSIST_ONLY innodb_buffer_pool_size=...; -- 只写文件，下次重启生效
RESET PERSIST max_connections;                -- 从 auto.cnf 删除
-- 静态参数 SET GLOBAL → ERROR 1238 (HY000) read only variable → 需重启

-- 参数来源判定（P_S=OFF 也可查）：VARIABLE_SOURCE=COMPILED/GLOBAL/COMMAND_LINE/DYNAMIC/PERSISTED
SELECT VARIABLE_NAME, VARIABLE_SOURCE, VARIABLE_PATH, SET_TIME, SET_USER
  FROM performance_schema.variables_info WHERE VARIABLE_NAME='max_connections';
```

## 索引是否回表 / 是否覆盖？（IDX-001 实测）

```sql
SHOW INDEX FROM db_name.table_name;
EXPLAIN SELECT ...;          -- Extra=Using index：投影被覆盖
EXPLAIN ANALYZE SELECT ...;  -- TREE 中 Covering index lookup：覆盖
```

判断规则：

- `Index lookup ... using secondary_index` 且没有 `Using index`：二级索引命中后通常按主键回聚簇索引。
- `Using index` 是覆盖索引；`Using index condition` 是 ICP，二者不是一回事，ICP 仍可能回表。
- InnoDB 二级索引自动携带 PRIMARY KEY；不要为了“覆盖主键”重复把主键列写进索引。
- 主键会进入每个二级索引：优先短、稳定、尽量单调的键；宽/随机 UUID 会放大空间与随机写。
- 无显式主键会生成隐藏 `GEN_CLUST_INDEX`；生产表应显式设计可用主键。

PG 对照：`Index Scan` 按 TID 回 heap；`Index Only Scan` 还要看 `Heap Fetches`，不为 0 时仍访问 heap。

## 长事务是否拖住 Undo/Purge？（MVCC-001 实测）

```sql
SELECT trx_mysql_thread_id,trx_id,trx_state,trx_started,
       trx_isolation_level,trx_rows_modified,trx_query
FROM information_schema.innodb_trx ORDER BY trx_started;

SHOW ENGINE INNODB STATUS\G
-- TRANSACTIONS 段重点看：Purge done for... / History list length
SHOW FULL PROCESSLIST;  -- 按 trx_mysql_thread_id 找用户、来源和 SQL（P_S=OFF 兜底）
```

判断与处置：

- HLL 是实例级 undo log header 数，不是行版本数或字节数；看持续增长趋势。
- `trx_rows_modified=0` 的只读长事务也可能持有旧 ReadView，不能只筛写事务。
- 先确认业务影响，再结束/提交根因事务；随后持续观察 HLL，Purge 异步执行，不会保证瞬间归零。
- 不要手工删除 `undo_001/undo_002`，也不要把重启当作清理手段。

PG 对照：查 `pg_stat_activity.xact_start/backend_xmin` 与 `pg_stat_user_tables.n_dead_tup`；
旧 backend_xmin 会令 VACUUM 报 `dead but not yet removable`。

## 锁等待 / 死锁（ISO-001 实测）

```sql
-- 1. 先看正在执行/等待什么；Id 可与 trx_mysql_thread_id 对上
SHOW FULL PROCESSLIST;

-- 2. P_S=OFF 也可用：长事务、LOCK WAIT、持锁行数、当前 SQL
SELECT trx_mysql_thread_id,trx_id,trx_state,trx_started,trx_wait_started,
       trx_isolation_level,trx_rows_locked,trx_rows_modified,trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started;

-- 3. 锁记录与最近一次死锁；重点看 HOLDS / WAITING、index、gap/rec、victim
SHOW ENGINE INNODB STATUS\G
```

若生产开启 Performance Schema：

```sql
SELECT * FROM performance_schema.data_lock_waits\G
SELECT * FROM performance_schema.data_locks\G
```

处置顺序：

1. `1205 Lock wait timeout`：找等待最久会话和 blocker，确认业务后让根因事务 COMMIT/ROLLBACK；
   不要只调大 `innodb_lock_wait_timeout`。
2. `1213 Deadlock found`：InnoDB 已回滚 victim；保存 `LATEST DETECTED DEADLOCK`，应用重试整个事务。
3. 统一对象/主键访问顺序，缩短事务，避免事务中等待用户或远程调用。
4. RR 范围 DML/`FOR UPDATE` 检查实际索引；Next-Key Lock 可能阻塞看似无关的 gap 插入。
5. 从 PG SSI 迁移时不要直接把 MySQL 提到 SERIALIZABLE：显式事务的普通 SELECT 会变 S 锁，
   先压测等待与死锁，并确保 1213/40001 的事务级重试。

PG 对照：`pg_stat_activity + pg_blocking_pids(pid) + pg_locks`；40P01 是死锁，40001 是 SSI
序列化失败，均回滚并重试整个事务。PG RR `FOR UPDATE` 不提供 InnoDB 式 gap 锁。

## 待填充（随专题扩展）

- Buffer Pool/Redo 状态 → BUF-001/REDO-001
- Binlog/复制状态 → LOG-001/REP-001
- 慢 SQL → MON-001
- CPU/IO/磁盘 → MON-001/DR-001
- 备份恢复 → BAK-001/002

## 磁盘空间 / 表大小（ENG-002 实测）

```sql
-- 所有 InnoDB 表空间文件（P_S=OFF 也可用）：General=mysql.ibd / Single=*.ibd / Undo=undo_* / System=ibtmp1
SELECT SPACE, NAME, SPACE_TYPE, FILE_SIZE, ALLOCATED_SIZE
  FROM information_schema.INNODB_TABLESPACES ORDER BY FILE_SIZE DESC;
-- 按库/表看逻辑大小（data_length+index_length ≈ 表数据+索引）
SELECT table_schema, table_name, engine, ROUND((data_length+index_length)/1024/1024,2) AS mb
  FROM information_schema.tables ORDER BY mb DESC;
```

```bash
du -sh /data/myhome/mydata/mysql/*/*.ibd | sort -h | tail     # 物理大户（.ibd 一眼可读）
ls -lh /data/myhome/mydata/mysql/#innodb_redo/               # redo 目录（容量=innodb_redo_log_capacity）
du -sh /data/myhome/mydata/mysql/undo_00*                    # undo 膨胀（长事务撑大，等 purge）
ls -lh /data/myhome/mydata/mysql/binlog.* | tail             # binlog 保留
```

空间回收行为（实测结论）：
- DELETE 只标记删除，`.ibd` 不缩小 → 回收用 `OPTIMIZE TABLE 库.表;`（= ALTER 重建，会锁表，低峰做）
- 清空表用 `TRUNCATE TABLE 库.表;`（重建 `.ibd` 回初始 7 页 ≈ 114688 bytes，非 0）
- 8.4 的 `ibdata1` 不再装数据字典（字典在 `mysql.ibd`），一般不会无限膨胀
