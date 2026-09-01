# CASE-002 权限拒绝：ERROR 1044 / 1142 / 1143 / 1147

> 状态：✅ 已完成（2026-09-01 实跑）
> 关联：ENV-004（权限层级/GRANT-REVOKE）/ ISO-002（MDL 场景另见 CASE-014）
> 证据：`study_record/troubleshooting/evidence/case002-access-denied-mysql.txt`、`case001-002-pg-comparison.txt`
> 环境：MySQL 8.4.10 @3306；PG 18.4 @54184（对照）

## 现象

- 能登录（认证过了），但执行 SQL 被拒：`SELECT`/`INSERT`/`CREATE DATABASE`/`REVOKE` 等
- 错误码分层：**1044（库）/ 1142（表）/ 1143（列）**，外加 1147（REVOKE 未授权）
- 关键：MySQL 权限检查**逐层下探**（全局 → 库 → 表 → 列），错误码本身指示你卡在哪一层

## 告警/错误（本机实跑）

```text
# 无任何授权时 SELECT 表 → 先报 1044（库级），不是 1142
ERROR 1044 (42000): Access denied for user 'lab_case002'@'localhost' to database 'mysql_lab_case'

# 有库级权限（INSERT on db.*）、无表级 SELECT → 1142
ERROR 1142 (42000) at line 1: SELECT command denied to user 'lab_case1142'@'localhost' for table 't_emp'

# 仅授 name 列，SELECT * → 1143，并指出第一个无权列
ERROR 1143 (42000) at line 1: SELECT command denied to user 'lab_case003'@'localhost' for column 'id' in table 't_emp'

# 无建库权限
ERROR 1044 (42000) at line 1: Access denied for user 'lab_case002'@'localhost' to database 'hack_db'

# REVOKE 一个不存在的授权
ERROR 1147 (42000) at line 1: There is no such grant defined for user 'lab_case002' on host 'localhost' on table 't_emp'
```

## 第一步检查：SHOW GRANTS（先看"有什么"）

```sql
SHOW GRANTS FOR 'user'@'host';
-- 或看当前用户
SHOW GRANTS FOR CURRENT_USER;
```

本机实测：

```text
lab_case002（无授权）: GRANT USAGE ON *.* TO ...            ← 只有占位符
lab_case003（列授权）: GRANT USAGE ON *.* + GRANT SELECT (`name`) ON `mysql_lab_case`.`t_emp`
lab_case1142（库授权）: GRANT USAGE ON *.* + GRANT INSERT ON `mysql_lab_case`.*
```

附注（实测发现）：`GRANT USAGE ON db.*` 会被 MySQL 规范化成全局 `GRANT USAGE ON *.*`——USAGE 是"无权限"占位符，只在 `*.*` 存在，不能用来表示"库级有权限"。

## 第二步检查：按错误码定位层级

```sql
-- 账号与 host
SELECT user, host FROM mysql.user WHERE user LIKE '目标%';
-- 库级授权
SELECT * FROM mysql.db WHERE User='目标';
-- 表级 / 列级授权
SELECT * FROM mysql.tables_priv WHERE User='目标';
SELECT * FROM mysql.columns_priv WHERE User='目标';
```

本机实测（lab_case002 无授权、lab_case003 仅列授权，root 执行）：

```text
-- mysql.user：账号与认证插件
user	host	plugin
lab_case002	localhost	caching_sha2_password
lab_case003	localhost	caching_sha2_password

-- mysql.db（库级授权）：空 = 两个账号都没有库级授权
-- mysql.tables_priv（表级授权）：lab_case003 在 t_emp 有记录（Table_priv 空 = 仅列授权）
Host	Db	User	Table_name	Table_priv
localhost	mysql_lab_case	lab_case003	t_emp

-- mysql.columns_priv（列级授权）：name 列 Select
Host	Db	User	Table_name	Column_name	Column_priv
localhost	mysql_lab_case	lab_case003	t_emp	name	Select
```

判断：错误码 1143 → 查 `mysql.columns_priv` 找缺的列；1142 → 查 `mysql.tables_priv`；1044 → 查 `mysql.db`。空结果 = 该层没授权，就是根因。

## 根因

1. 1044：对目标库无任何权限（连接库、建库、库内操作都会触发）
2. 1142：**有库级权限但目标表无该操作权限**（如只有 `INSERT on db.*`，`SELECT` 被表级拒）
3. 1143：表级有权限但**具体列无权限**（`SELECT *` 会因第一个无权列失败）
4. 1147：`REVOKE` 时该授权从未存在（MySQL 不幂等）
5. 常见隐藏根因：`SELECT *` 陷阱——列级授权下 `SELECT *` 不等于"只读可见列"

## 处理

```sql
-- 1044 → 补库级权限
GRANT SELECT ON db.* TO 'u'@'h';
-- 1142 → 补表级权限
GRANT SELECT ON db.t_emp TO 'u'@'h';
-- 1143 → 补列级权限（或避免 SELECT *）
GRANT SELECT (name) ON db.t_emp TO 'u'@'h';
-- 1147 → 先 SHOW GRANTS 确认授权存在，再 REVOKE（MySQL 不幂等）
SHOW GRANTS FOR 'u'@'h';
REVOKE SELECT ON db.t_emp FROM 'u'@'h';
```

## 验证恢复（本机实测）

```sql
-- GRANT SELECT 后重试成功
SELECT * FROM t_emp;
-- id  name  salary
-- 1   Alice 20000.00
-- 2   Bob   18000.00
```

## PG 对照（同实验两边跑）

| 场景 | PostgreSQL 18.4 | MySQL 8.4 |
|---|---|---|
| 无表权限 | `ERROR: permission denied for table t_emp` | `ERROR 1142 ... for table 't_emp'` |
| 列权限（仅授 name） | `SELECT *` / `SELECT id` 均报 `permission denied for table t_emp`（PG 18.4 实测**不提示列名**） | `ERROR 1143 ... for column 'id' in table 't_emp'`（报第一个无权列） |
| 列权限排查 | `information_schema.column_privileges` | `mysql.columns_priv` |
| 无建库权限 | `ERROR: permission denied to create database` | `ERROR 1044 ... to database 'hack_db'` |
| REVOKE 不存在的授权 | 幂等成功（`REVOKE`） | `ERROR 1147 There is no such grant defined` |
| 无库权限 | PG 默认 `PUBLIC` 对库有 CONNECT，能连库再被表拒 | 1044 直接在库层拦截 |

## 生产经验

1. 错误码顺序 = 排查路径：1044 → 库；1142 → 表；1143 → 列；从外层往里查
2. `SELECT *` 在列级授权下是坑：应用要按最小列集查询，或授全列
3. MySQL 的 REVOKE 不幂等，变更脚本要先 `SHOW GRANTS` 确认；PG 的 REVOKE 幂等（脚本可重复执行）——两边运维脚本写法不同
4. 排查工具优先级：`SHOW GRANTS FOR 'u'@'h'` 最快；`mysql.user/db/tables_priv/columns_priv` 看存储细节
5. "能登录但没权限"（认证过了、授权缺）与"登录失败"（1045）是两条不同排查路径，先分清
