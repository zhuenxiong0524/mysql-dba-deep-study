# MySQL 配置文件与参数体系：从 postgresql.conf 与 ALTER SYSTEM 迁移

> 版本：v1.0（2026-08-28，实机验证于 1C/2G 学习机；含一次受控重启验证）
> 基线：PostgreSQL 18.4（端口 54184）→ 目标：MySQL 8.4.10 LTS（端口 3306）
> 系列：PG DBA → MySQL 生产 DBA 迁移项目 · 第一阶段专题 2（ENV-006）
> 证据：`evidence/pg-config.txt`、`evidence/mysql-config.txt`

---

## 1. 为什么 PG DBA 要学这个

PG 改参数的心智是：`postgresql.conf` + `ALTER SYSTEM`（auto.conf）+ `pg_settings.context` 判断改法 + `reload/restart`。
这套心智直接套到 MySQL 会踩的坑：

- 你以为"改 /etc/my.cnf 就生效"——MySQL 的生效来源可能是启动参数、`mysqld-auto.cnf`（SET PERSIST），且配置文件有搜索路径。
- 你以为"SHOW VARIABLES 就是配置"——它显示的是**当前生效值**，不告诉你来源。
- 你以为"在线 SET GLOBAL 重启就丢"——`SET PERSIST` 会写盘，重启保留；`PERSIST_ONLY` 只写盘不生效。
- 你以为"重启一定需要"——本机实测 `server_id` 在 8.0+ 在线可改（5.7 时代是静态的），判断"能不能在线改"不能靠旧文档。

本文用实机命令建立：**参数从哪来 → 怎么读 → 怎么改（四态）→ 哪些要重启 → 怎么验证**。

---

## 2. PostgreSQL 已知模型（基线）

```text
postgresql.conf          主配置文件
ALTER SYSTEM SET ...     → 写入 postgresql.auto.conf（优先级高于 postgresql.conf）
pg_settings              当前生效值 + context（决定怎么改）
  context=postmaster      → 需重启（pending_restart=t）
  context=sighup          → pg_reload_conf() 即生效
  context=superuser/user  → 会话内 SET / 超管 SET
  context=backend         → 每个会话单独
SET work_mem = ...       会话级，仅本会话
SET LOCAL ...            仅当前事务
```

本机 PG 实测（`pg_settings` context）：

```text
max_connections            100   postmaster  ← 需重启
shared_buffers             16GB(128MB?)  postmaster
log_min_duration_statement -1     superuser  ← reload/超管可改
autovacuum                 on     sighup     ← reload 即生效
work_mem / temp_buffers    ...    user       ← 会话 SET
synchronous_commit         on     user
```

实测 ALTER SYSTEM + reload（superuser 参数无需重启）：

```text
ALTER SYSTEM SET log_min_duration_statement = '1000';
SELECT pg_reload_conf();            → t
pg_settings: setting=1000, source=configuration file, pending_restart=f   ← 已生效
```

实测 postmaster 参数（需重启）：

```text
ALTER SYSTEM SET max_connections = '250';  SELECT pg_reload_conf();
pg_settings: setting=100, pending_restart=t   ← 生效值没变，标记待重启
```

清理还原后 `postgresql.auto.conf` 为空——实验不残留。

> PG 18 细节：`log_min_duration_statement` 是 superuser context（不是 sighup），ALTER SYSTEM 不能写在事务块里（psql -c 多语句会失败）。

---

## 3. MySQL 模型

### 3.1 配置来源链与优先级

```text
优先级从高到低：
1. mysqld 命令行参数（--port=3306 ...）
2. mysqld-auto.cnf（SET PERSIST / SET PERSIST_ONLY 写入，8.0+）
3. 配置文件搜索路径（按顺序读取，后读覆盖先读）
   /etc/my.cnf → /etc/mysql/my.cnf → <basedir>/etc/my.cnf → ~/.my.cnf
4. 编译默认值
```

注意：**没有"改一个文件就统一生效"**；同一个参数可能同时存在于多个来源，最终值由优先级决定。

### 3.2 变量读取与修改方式

```text
读取:   SHOW [GLOBAL|SESSION] VARIABLES LIKE '...'；SELECT @@GLOBAL.x / @@SESSION.x / @@x
修改四态:
  SET SESSION x=...      本会话生效，不持久，不影响其他连接
  SET GLOBAL x=...       在线生效（通常影响新连接/全局），不持久，重启丢失
  SET PERSIST x=...      在线生效 + 写入 mysqld-auto.cnf，重启保留（8.0+）
  SET PERSIST_ONLY x=... 只写入 mysqld-auto.cnf，不改变当前运行值（用于需重启参数预配置）
静态参数（启动时定死）:  SET GLOBAL 报 ERROR 1238 read only variable → 需改配置文件/启动参数后重启
```

### 3.3 本机配置链实测

```text
mysqld --verbose --help 的 "Default options"：
  /etc/my.cnf /etc/mysql/my.cnf /data/myhome/mydata/mysql-8.4.10/etc/my.cnf ~/.my.cnf
  组: mysql_cluster mysqld server mysqld-8.4

my_print_defaults mysqld（配置链合成后的有效参数）：
  --datadir=/data/myhome/mydata/mysql --port=3306 --socket=/tmp/mysql.sock
  --pid-file=... --log_error=... --innodb_buffer_pool_size=64M
  --innodb_redo_log_capacity=96M --performance_schema=OFF
  --skip-name-resolve --max_connections=100 --character_set_server=utf8mb4

实际存在的文件: /etc/my.cnf（root 所有）；/etc/mysql/、~/.my.cnf 不存在
```

---

## 4. 关键差异（先给结论）

| 维度 | PostgreSQL 18.4 | MySQL 8.4.10 |
|---|---|---|
| 主配置 | postgresql.conf（单文件，data dir 内） | my.cnf 搜索路径（本机 /etc/my.cnf） |
| 运行时持久化 | ALTER SYSTEM → postgresql.auto.conf | SET PERSIST → mysqld-auto.cnf（datadir 内） |
| 生效值视图 | pg_settings（含 source/pending_restart） | SHOW VARIABLES / @@（无来源列；P_S 的 variables_info 本机不可用） |
| 改法判断 | context（postmaster/sighup/superuser/user） | 直接试：静态报 ERROR 1238；动态可 SET GLOBAL |
| reload | pg_reload_conf()（sighup 生效） | 无全局 reload；SET GLOBAL/PERSIST 即时生效 |
| 重启标志 | pg_settings.pending_restart=t | 无等价物；用 SET PERSIST_ONLY 预写"待重启"参数 |
| 会话级 | SET / SET LOCAL | SET SESSION（无 SET LOCAL） |
| 来源优先级 | auto.conf > postgresql.conf | 命令行 > auto.cnf > my.cnf 链 |

---

## 5. 本地实验环境

同 ENV-005 基线（`study_record/environment-baseline.md`）：MySQL 8.4.10 @3306 socket /tmp/mysql.sock；PG 18.4 @54184。

---

## 6. 实验步骤与实际输出

### 实验 A：读参数三式

```sql
SELECT @@GLOBAL.max_connections, @@SESSION.transaction_isolation, @@max_connections;
SHOW GLOBAL VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE 'transaction_isolation';
```

实际输出：

```text
g_max=100  s_tx_iso=REPEATABLE-READ  cur_max=100  bp_mb=64  log_bin=1
max_connections  100
transaction_isolation  REPEATABLE-READ
```

解释：`@@x` 默认取 SESSION 值；`SHOW VARIABLES` 也是 SESSION 视角。查全局必须 `GLOBAL` 或 `@@GLOBAL.`。

### 实验 B：SESSION 级修改（只影响本会话）

```sql
SET SESSION transaction_isolation='READ-COMMITTED';
SELECT @@SESSION.transaction_isolation, @@GLOBAL.transaction_isolation;
-- READ-COMMITTED | REPEATABLE-READ
-- 新会话：REPEATABLE-READ（不变）

SET SESSION sort_buffer_size=524288;      -- 默认 262144
SELECT @@GLOBAL.sort_buffer_size, @@SESSION.sort_buffer_size;  -- 262144 | 524288
-- 新会话：262144
```

解释：SESSION 修改是本连接级、立即失效于断开、不写盘；PG 对应 `SET work_mem`。

### 实验 C：动态 GLOBAL（在线生效）

```sql
SET GLOBAL max_connections=200;
SELECT @@GLOBAL.max_connections;            -- 200（本会话也能读到）
-- 新连接：200（已生效）
SET GLOBAL max_connections=100;             -- 还原
```

实测附加发现：**`server_id` 在 8.0+ 是动态参数**（`SET GLOBAL server_id=2` 成功，无报错）——5.7 时代它是静态的，旧文档不可照抄。

### 实验 D：静态参数（必须重启）

```sql
SET GLOBAL port=3307;
-- ERROR 1238 (HY000): Variable 'port' is a read only variable
SET GLOBAL performance_schema=ON;
-- ERROR 1238 (HY000): Variable 'performance_schema' is a read only variable
```

解释：`ERROR 1238` = 该参数只能在配置/启动时设置，运行时改不了；要改就改配置文件/启动参数 + 重启。
这等价于 PG 的 context=postmaster（但 PG 至少有 pending_restart 提示，MySQL 只能靠报错或查文档）。

### 实验 E：SET PERSIST（写盘 + 立即生效 + 重启保留）

```sql
SET PERSIST max_connections=105;
SELECT @@GLOBAL.max_connections;   -- 105（立即生效）
```

mysqld-auto.cnf 内容（8.0+ 是 JSON）：

```json
{"Version": 2, "mysql_dynamic_parse_early_variables": {
  "max_connections": {"Value": "105", "Metadata": {"Host": "localhost", "User": "root", "Timestamp": ...}}}}
```

**受控重启验证**（mysqladmin shutdown → mysqld_safe 拉起）：

```text
重启后: SELECT @@GLOBAL.max_connections → 105   ← my.cnf 里是 100，PERSIST 覆盖生效
重启后: innodb_buffer_pool_size=64M、port=3306  ← 未受影响
```

结论：`mysqld-auto.cnf` 优先级高于 `my.cnf`，PERSIST 参数重启保留。

### 实验 F：SET PERSIST_ONLY（只写文件，不生效）

```sql
SET PERSIST_ONLY innodb_buffer_pool_size=134217728;   -- 128M
SELECT @@GLOBAL.innodb_buffer_pool_size/1024/1024;    -- 64（运行值未变）
RESET PERSIST IF EXISTS innodb_buffer_pool_size;      -- 从 auto.cnf 删除
```

解释：PERSIST_ONLY 是给"需重启参数"做预配置用的（写盘等下次重启生效），等价于 PG 的 ALTER SYSTEM 改 postmaster 参数但还没重启。

### 实验 G：PG 对照实验（同思路）

```text
PG: ALTER SYSTEM SET log_min_duration_statement='1000' + pg_reload_conf()
    → setting=1000，pending_restart=f（superuser 参数，无需重启）
PG: ALTER SYSTEM SET max_connections='250' + pg_reload_conf()
    → setting=100，pending_restart=t（postmaster 参数，待重启）
PG: SET work_mem='16MB' → 本会话 16MB，新会话 4MB（对应 MySQL SET SESSION）
```

---

## 7. 故障实验与故障排查

### 7.1 "改了参数没生效" 排查路径

```text
1. 确认读的是不是全局：SHOW GLOBAL VARIABLES LIKE 'x' / @@GLOBAL.x（SESSION 视角会骗人）
2. 确认来源优先级：命令行 > mysqld-auto.cnf > my.cnf 链
   - cat <datadir>/mysqld-auto.cnf       有没有 PERSIST 残留覆盖
   - my_print_defaults mysqld            配置链合成结果
   - ps -ef | grep mysqld                启动命令行带了什么 --xx
3. 确认是不是静态参数：SET GLOBAL 报 1238 → 只能改配置+重启
4. 确认是不是 PERSIST_ONLY：值没变但文件有 → 等重启生效（设计如此）
5. 确认改完是否验证过新连接：SESSION 级修改不传染其他连接
```

### 7.2 "MySQL 挂了/起不来，参数背锅" 排查

```text
tail -50 <log_error>       启动失败第一现场（如 unknown variable、Invalid value）
my_print_defaults mysqld   看配置链有没有非法值
SET PERSIST 残留           重启前先看 mysqld-auto.cnf（曾有人 PERSIST 了错误值导致起不来）
```

本机安全约束：无 kill 实验（学习主实例）；重启使用 `mysqladmin shutdown` + `mysqld_safe` 受控执行并验证恢复。

---

## 8. 生产环境意义

1. **"参数从哪来"是改参数的第一问题**：先 `SHOW GLOBAL VARIABLES` 看现值，再 `my_print_defaults` + `mysqld-auto.cnf` + ps 命令行定位来源，最后决定改哪里。
2. **在线改 vs 重启改的三态表**（见第 13 节）直接决定变更窗口：能 SET GLOBAL/PERSIST 的不需要停机。
3. **PERSIST 是把双刃剑**：方便持久化，但残留值会在下次重启时覆盖 my.cnf——变更后要 `RESET PERSIST` 或确认 auto.cnf 内容。
4. **P_S=OFF 影响"参数来源"查询**：`performance_schema.variables_info` 不可用，运维脚本要兼容。
5. **旧文档毒药**：server_id 在 8.0+ 已是动态参数；判断"能否在线改"以当前版本实测为准。

---

## 9. 常见误区（PG DBA 视角）

- ❌ "改 /etc/my.cnf 就生效" → 生效来源可能是命令行/auto.cnf；改文件还要重启（除非参数支持在线）。
- ❌ "SHOW VARIABLES 是配置" → 是生效值，不是来源；`@@x` 默认 SESSION 视角。
- ❌ "SET GLOBAL 重启就丢，所以要用 ALTER SYSTEM" → MySQL 有 SET PERSIST（写盘）；ALTER SYSTEM 的对应物不是 SET GLOBAL。
- ❌ "需要重启的参数只能靠猜" → 实测：静态参数 SET GLOBAL 报 1238；PERSIST_ONLY 可预写。
- ❌ "pg_reload_conf() 有对应物" → MySQL 没有全局 reload；在线参数改完立即生效，静态参数必须重启。
- ❌ "server_id 是静态的" → 8.0+ 已动态（本机实测 SET GLOBAL server_id 成功）。

---

## 10. DBA Checklist（参数变更前）

```text
[ ] SHOW GLOBAL VARIABLES LIKE '目标参数'       记录当前生效值
[ ] my_print_defaults mysqld                   看配置链现有设置
[ ] cat <datadir>/mysqld-auto.cnf              看 PERSIST 残留
[ ] ps -ef | grep mysqld                       看启动命令行参数
[ ] 确认参数类型：SESSION/GLOBAL/静态（试 SET GLOBAL 看是否 1238）
[ ] 选择变更方式：SET SESSION / SET GLOBAL / SET PERSIST / PERSIST_ONLY / 改 my.cnf
[ ] 需要重启 → 评估窗口 + 准备回滚（改回配置或 RESET PERSIST）
[ ] 变更后：新连接验证 + SHOW GLOBAL VARIABLES 确认 + auto.cnf 复查
[ ] 变更前拍现场（error log 尾部、PROCESSLIST），变更后可回滚
```

---

## 11. PG → MySQL 心智模型更新

```text
PG:  postgresql.conf + auto.conf(ALTER SYSTEM)
     pg_settings.context → 怎么改（postmaster=重启 / sighup=reload / user=SET）
     pg_reload_conf() / pending_restart

MySQL: my.cnf 链 + mysqld-auto.cnf(SET PERSIST) + 命令行
     SET SESSION（本会话）/ SET GLOBAL（在线）/ SET PERSIST（在线+写盘）/ PERSIST_ONLY（只写盘）
     静态参数 SET GLOBAL → ERROR 1238（= 必须重启）
     "reload" 概念不存在；在线参数即时生效
```

一句话：**PG 用 context 告诉你"怎么改"，MySQL 用报错和写盘行为告诉你"怎么改"；生产变更前先回答'参数从哪来、改完哪一层生效、重启丢不丢'。**

---

## 12. 参数可改性三态表（本机实测）

| 分类 | MySQL 示例（实测） | 修改方式 | 生效范围 | 重启后 |
|---|---|---|---|---|
| 会话级 | transaction_isolation / sort_buffer_size | SET SESSION | 本连接 | 丢失（回默认） |
| 全局动态 | max_connections / server_id(8.0+) | SET GLOBAL / SET PERSIST | 全局，新连接生效 | SET GLOBAL 丢失；SET PERSIST 保留 |
| 静态（需重启） | port / performance_schema / datadir / socket | 改 my.cnf / 启动参数 / PERSIST_ONLY | 启动时生效 | 保留（来自配置） |

PG 对照：user/superuser ≈ SET SESSION/全局动态；sighup ≈ 在线动态；postmaster ≈ 静态需重启（pending_restart=t 等价物是 MySQL 的 ERROR 1238 + PERSIST_ONLY 预写）。

---

## 13. Evidence 索引

| 文件 | 内容 |
|---|---|
| evidence/pg-config.txt | PG：context 分层、ALTER SYSTEM+reload、pending_restart=t、session SET、auto.conf 清理 |
| evidence/mysql-config.txt | MySQL：搜索路径、my_print_defaults、三式读取、SESSION/GLOBAL/PERSIST/PERSIST_ONLY、1238、重启验证、还原 |

相关资产：`study_record/environment-baseline.md`、`study_record/pg-mysql-map.md`、`study_record/runbook/mysql-dba-cheatsheet.md`
