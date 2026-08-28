# MySQL 权限体系实战：从 PostgreSQL DBA 视角理解 Account、GRANT、Role 与权限检查

> 版本：v1.0（2026-08-28，实机验证于 1C/2G 学习机）
> 基线：PostgreSQL 18.4（端口 54184）→ 目标：MySQL 8.4.10 LTS（端口 3306）
> 方法：同一实验两边实机执行，输出存档 `evidence/`，文章只保留关键片段
> 读者：已熟悉 PostgreSQL Role / ACL / GRANT 的 DBA

---

## 1. 实验环境

### 1.1 环境探测（实际输出）

```text
MySQL version:      mysql  Ver 8.4.10 for Linux on x86_64 (Source distribution)
PostgreSQL version: psql (PostgreSQL) 18.4
OS:                 Debian GNU/Linux 11 (bullseye)，Linux node01 5.10.0-38-amd64，1C/2G
MySQL port:         3306（另 33060 X Protocol），socket /tmp/mysql.sock，数据 /data/myhome/mydata/mysql
PostgreSQL port:    54184，数据 /data/pgdata/pgdata18.4
MySQL 认证:         账号均为 caching_sha2_password；root@localhost 空密码（socket 免密）
PG 认证 (pg_hba):   local / 127.0.0.1 / ::1 = trust；192.168.101.0/24 = md5
```

### 1.2 当前登录身份（探测记录）

MySQL（root）：
```sql
SELECT USER(), CURRENT_USER();
-- USER()=root@localhost   CURRENT_USER()=root@localhost
```

PG（mysql 用户）：
```sql
SELECT current_user, session_user;
-- current_user=mysql   session_user=mysql
```

> 提前给结论（实验 14 展开）：MySQL 的 `USER()` 是"客户端声称的账户 + 实际来源"，`CURRENT_USER()` 是"服务端实际匹配到的 mysql.user 行"；PG 的 `current_user`/`session_user` 在没有 `SET ROLE` 时相同。

### 1.3 测试对象（两边同构）

```text
mysql_priv_lab.employees (id/name/department/salary)  +  departments (id/name)
pg_priv_lab.employees 同构
种子数据：Alice(1)/Bob(2)/Carol(3)；实验 4 追加 Dave(4)
测试账号：lab_* / global_* / table_* / column_* / mix_* / grant_* / role_* / routine_* / trouble*
PG 角色：lab_reader / lab_role_user / lab_priv_noh / lab_user_noh / lab_user_noh2
```

---

## 2. 先理解 MySQL Account（实验 1）

**实验目的**：验证 `'user'@'host'` 是否是两个独立账号；与 PG 全局 Role 对照。

**执行 SQL**：
```sql
CREATE USER 'lab_user'@'localhost' IDENTIFIED BY 'LabPass_123!';
SELECT user, host, plugin FROM mysql.user WHERE user='lab_user';
CREATE USER 'lab_user'@'%' IDENTIFIED BY 'LabPass_456!';
SELECT user, host, plugin FROM mysql.user WHERE user='lab_user';
```

**实际输出**：
```text
（创建 @localhost 后）
user      host       plugin
lab_user  localhost  caching_sha2_password

（再创建 @% 后）
user      host       plugin
lab_user  %          caching_sha2_password
lab_user  localhost  caching_sha2_password
```

**独立性验证**：
```sql
DROP USER 'lab_user'@'%';
SELECT user,host FROM mysql.user WHERE user='lab_user';   -- 只剩 localhost 行
CREATE USER 'lab_user'@'%' IDENTIFIED BY 'LabPass_456!';  -- 再建回来（实验 15 用）
```

**现象与原因**：
- MySQL 的身份是 `(username, host)` 二元组，host 不是装饰，是身份的一部分：两个 Account 各自有独立密码、独立权限、独立锁定状态。
- `SHOW GRANTS FOR` 两个 Account 输出互相独立。

**PostgreSQL 对比**：PG 的 Role 是**全局的**——一个角色名就是身份，连接来源与认证方式完全由 `pg_hba.conf` 决定（本机 trust / 网段 md5），不需要为"localhost 来的"和"网段来的"各建一个角色。MySQL 把"来源"做进了账号本身，pg_hba 的职责被拆成：账号 host 匹配 + 认证插件。

**DBA 意义**：排查权限不能只看用户名：
```text
'application'@'localhost'   （socket 本机连接）
'application'@'10.%'        （内网网段）
'application'@'%'           （兜底）
```
是三个 Account。"同一用户名本机能查、远程却 Access denied"完全可能是正常匹配结果（实验 15 实测）。

---

## 3. CREATE USER 后到底拥有什么权限（实验 2）

**实验目的**：新建用户能登录，但能不能碰业务数据？

**执行**：
```sql
SHOW GRANTS FOR 'lab_user'@'localhost';
```
**实际输出**：
```text
Grants for lab_user@localhost
GRANT USAGE ON *.* TO `lab_user`@`localhost`
```

以 lab_user 登录（socket）：
```sql
SELECT USER(), CURRENT_USER();      -- lab_user@localhost | lab_user@localhost
SELECT * FROM mysql_priv_lab.employees;
```
**实际输出**：
```text
ERROR 1142 (42000): SELECT command denied to user 'lab_user'@'localhost' for table 'employees'
```
且 `SHOW DATABASES` 只列出 `information_schema` / `performance_schema`——业务库对用户不可见。

**现象与原因**：
- `USAGE` 的真实意义：该 Account **存在、可以连接认证，但没有任何业务权限**。它是对"零权限"的占位表示，不是一个可选权限。
- 认证（Authentication）成功 ≠ 授权（Authorization）成功。错误 1142 发生在 Authorization 层。

**PostgreSQL 对比**：PG 新建角色默认同样"能连（取决于 hba）但什么也访问不了"。共同点：创建账号 ≠ 获得数据访问权。差异在模型：PG 用对象 ACL（默认只授给属主），MySQL 用集中权限表（一行 USAGE 占位）。

**DBA 意义**："用户能登录但 SELECT 报 Access denied"不是故障，是默认状态——只有 GRANT 之后才有权限。

---

## 4. MySQL 权限层级

### 4.1 权限级别总表（含存储位置）

| 权限级别 | MySQL 写法 | 示例 | 存储位置 |
|---|---|---|---|
| Global | `*.*` | `GRANT SELECT ON *.*` | `mysql.user` |
| Database | `db.*` | `GRANT SELECT ON mysql_priv_lab.*` | `mysql.db` |
| Table | `db.table` | `GRANT SELECT ON mysql_priv_lab.employees` | `mysql.tables_priv` |
| Column | `db.table(col,...)` | `GRANT SELECT (id,name) ON ...` | `mysql.columns_priv` |
| Routine | `PROCEDURE/FUNCTION db.name` | `GRANT EXECUTE ON PROCEDURE db.p` | `mysql.procs_priv` |

角色关系存 `mysql.role_edges` / `mysql.default_roles`；动态管理权限（如 `BACKUP_ADMIN`、`SYSTEM_USER`）存 `mysql.global_grants`。

### 4.2 各级别作用范围（本实验实测）

- Global：作用于所有库所有对象。实验 6：`CREATE TEMPORARY TABLES ON *.*` 在任意库生效，且使 `SHOW DATABASES` 列出全部库。
- Database：作用于该库所有表。实验 3：`GRANT SELECT ON mysql_priv_lab.*` 后 employees 可查。
- Table：只作用于指定表。实验 7：employees 可查、departments 报 1142。
- Column：只作用于指定列。实验 8：salary 报 1143。
- Routine：只作用于指定存储过程。实验：`CALL count_emps()` 成功、SELECT 表仍 1142。

---

## 5. GRANT 实验（实验 3 / 4）

### 实验：数据库级 SELECT

**目的**：验证权限按操作类型独立控制、多次 GRANT 累加。

**执行 SQL**：
```sql
GRANT SELECT ON mysql_priv_lab.* TO 'lab_user'@'localhost';
SHOW GRANTS FOR 'lab_user'@'localhost';
```
**输出**：
```text
GRANT USAGE ON *.* TO `lab_user`@`localhost`
GRANT SELECT ON `mysql_priv_lab`.* TO `lab_user`@`localhost`
```

重新登录测试：
```sql
SELECT * FROM mysql_priv_lab.employees;
-- 成功，3 行（Alice/Bob/Carol）
INSERT INTO mysql_priv_lab.employees VALUES (4,'Dave','TEST',15000);
-- ERROR 1142 (42000): INSERT command denied to user 'lab_user'@'localhost' for table 'employees'
```

**现象**：SELECT 可以、INSERT 不可以 → 权限按操作类型分别授权。

### 实验：增加 INSERT

**执行 SQL**：
```sql
GRANT INSERT ON mysql_priv_lab.* TO 'lab_user'@'localhost';
SHOW GRANTS FOR 'lab_user'@'localhost';
```
**输出**：
```text
GRANT SELECT, INSERT ON `mysql_priv_lab`.* TO `lab_user`@`localhost`
```
INSERT 成功（Dave 入库，COUNT=4）。

**现象与原因**：SHOW GRANTS 合并展示 `SELECT, INSERT` → **多次 GRANT 累加**，同一层级权限位在同一行合并（`mysql.db` 里是 `enum('N','Y')` 列）。

**PostgreSQL 对比**：PG 多次 GRANT SELECT/INSERT 到同一对象同样累加进同一 ACL 项（实测 `lab_reader=r/postgres`）；语义一致，但 PG 的 ACL 是对象上的 aclitem 数组，MySQL 是权限表里的位/集合列。

**DBA 意义**：权限是"累积生效"，不是"最后一次覆盖"。

---

## 6. REVOKE 实验（实验 5）

**目的**：REVOKE 是否精确只撤销对应权限。

**执行 SQL**：
```sql
REVOKE INSERT ON mysql_priv_lab.* FROM 'lab_user'@'localhost';
SHOW GRANTS FOR 'lab_user'@'localhost';
```
**输出**：
```text
GRANT SELECT ON `mysql_priv_lab`.* TO `lab_user`@`localhost`   -- 回到只有 SELECT
```

测试：
```sql
INSERT INTO mysql_priv_lab.employees VALUES (5,'Eve','TEST',10000);
-- ERROR 1142 (42000): INSERT command denied ...
SELECT COUNT(*) FROM mysql_priv_lab.employees;   -- 4，SELECT 不受影响
```

**结论**：`REVOKE INSERT` 只撤销 INSERT 位，SELECT 保留。REVOKE 是"删权限位/删授权行"，不是加一个拒绝标记。

**PostgreSQL 对比**：PG `REVOKE INSERT ON TABLE ...` 同样只移除该权限；但 PG 没有 MySQL 的"数据库级覆盖整库"结构（见实验 9），表级 REVOKE 立即生效、无更高级别兜底（第 13 节实测）。

**DBA 意义**：撤销是精确的、定向的；误以为"撤销某一项会影响其他项"是常见的误解。

---

## 7. 多级权限叠加规则（实验 6 / 7 / 8 / 9）

### 7.1 全局 + 数据库级叠加（实验 6）

选择 `CREATE TEMPORARY TABLES ON *.*`：只影响临时表、会话级、不可见业务数据、低风险，又能直观体现"全局生效"。

**执行 SQL**：
```sql
CREATE USER 'global_user'@'localhost' IDENTIFIED BY 'Global_123!';
GRANT CREATE TEMPORARY TABLES ON *.* TO 'global_user'@'localhost';
GRANT SELECT ON mysql_priv_lab.* TO 'global_user'@'localhost';
SHOW GRANTS FOR 'global_user'@'localhost';
```
**输出**：
```text
GRANT CREATE TEMPORARY TABLES ON *.* TO `global_user`@`localhost`
GRANT SELECT ON `mysql_priv_lab`.* TO `global_user`@`localhost`
```

登录验证：
```sql
USE mysql_priv_lab;
CREATE TEMPORARY TABLE tmp1 (x INT); INSERT INTO tmp1 VALUES (1); SELECT * FROM tmp1;  -- 成功
SELECT COUNT(*) AS emp_cnt FROM employees;   -- 4（数据库级 SELECT 生效）
SHOW DATABASES;
```
**输出**（节选）：`cmp / db_compare / db_compare2 / demo_schema / information_schema / mysql / mysql_priv_lab / performance_schema / sys`

**现象与分析**：全局权限 `*.*` 让所有库在 `SHOW DATABASES` 可见——`SHOW DATABASES` 列表 ≠ "我都有权限"，只要存在任意全局权限就全列出。`*.*` 表示"所有库所有对象"；Global 与 Database 级权限叠加生效（判断时各层级取并集，授权语义是累加）。

### 7.2 表级（实验 7）

**执行 SQL**：
```sql
CREATE USER 'table_user'@'localhost' IDENTIFIED BY 'Table_123!';
GRANT SELECT ON mysql_priv_lab.employees TO 'table_user'@'localhost';
```
测试：
```sql
SELECT COUNT(*) FROM mysql_priv_lab.employees;   -- 4，成功
SELECT * FROM mysql_priv_lab.departments;
-- ERROR 1142 (42000): SELECT command denied to user 'table_user'@'localhost' for table 'departments'
```
**结论**：表级权限只影响指定表。

### 7.3 列级（实验 8）

**执行 SQL**：
```sql
CREATE USER 'column_user'@'localhost' IDENTIFIED BY 'Column_123!';
GRANT SELECT (id, name, department) ON mysql_priv_lab.employees TO 'column_user'@'localhost';
SHOW GRANTS FOR 'column_user'@'localhost';
```
**输出**：
```text
GRANT SELECT (`department`, `id`, `name`) ON `mysql_priv_lab`.`employees` TO `column_user`@`localhost`
```

测试：
```sql
SELECT id, name, department FROM mysql_priv_lab.employees;  -- 成功
SELECT salary FROM mysql_priv_lab.employees;
-- ERROR 1143 (42000): SELECT command denied to user 'column_user'@'localhost' for column 'salary' in table 'employees'
SELECT * FROM mysql_priv_lab.employees;
-- ERROR 1142 (42000): SELECT command denied to user 'column_user'@'localhost' for table 'employees'
```

**现象与原因**：
- 列级授权后，`SELECT *` 因包含未授权列 salary 而整体失败。
- 注意两个错误码不同：缺列报 **1143**，`SELECT *` 因"表未整体授权"报 **1142**。
- `SHOW GRANTS` 里列按字母序展示（`department,id,name`），是存储层排序，不是授权顺序。

**PostgreSQL 对比**：PG 支持列级权限（`GRANT SELECT (col) ON TABLE ...`），`SELECT *` 同样会因未授权列失败。差异在存储：PG 记录在 `pg_attribute.attacl`，MySQL 在 `mysql.columns_priv`。

### 7.4 能不能"数据库级允许 + 表级拒绝"？（实验 9，重点）

**目的**：MySQL 权限模型是否存在显式 DENY？能否用库级授权 + 表级 REVOKE 实现 deny？

**执行 SQL**：
```sql
CREATE USER 'mix_user'@'localhost' IDENTIFIED BY 'Mix_123!';
GRANT SELECT ON mysql_priv_lab.* TO 'mix_user'@'localhost';
REVOKE SELECT ON mysql_priv_lab.employees FROM 'mix_user'@'localhost';
```
**实际输出**：
```text
ERROR 1147 (42000): There is no such grant defined for user 'mix_user' on host 'localhost' on table 'employees'
```
再试从未授权过的表（departments）同样 **ERROR 1147**。而 mix_user 的 `SELECT employees` / `SELECT departments` **依然成功**。

**结论（实测）**：
1. 数据库级授权不会在 `tables_priv` 生成表级行 → 低层级 REVOKE 找不到可删的行，报 1147。
2. MySQL **不存在显式 DENY**；权限模型是"只增不减（REVOKE 只删已存在的授权行）"。
3. 无法用"库级允许 + 表级撤销"实现 deny——这是从带 DENY 模型的数据库迁移来的 DBA 最容易踩的坑。

**PostgreSQL 对比**：PG 同样没有显式 DENY（REVOKE 只是从 ACL 删除授权）。但两者模型不同：PG 表权限是对象级 ACL，**数据库级 CONNECT 不等于表级 SELECT**，所以不存在"库级权限覆盖表级 REVOKE"的问题；PG 撤销表级 SELECT 立即生效（第 13.4 节实测）。MySQL 的 db 级授权是一把"整库伞"，伞下 REVOKE 不了。

**DBA 意义**：要"部分表可读、个别表不可读"，MySQL 只能：只做表级授权（不给 db 级）、用视图隔离、或单独拆库。不能靠"先给整库再撤个别表"。

---

## 8. WITH GRANT OPTION（实验 10）

**目的**：带 GRANT OPTION 的用户能授什么权？风险在哪？

**执行 SQL**：
```sql
CREATE USER 'grant_admin'@'localhost' IDENTIFIED BY 'Grant_123!';
CREATE USER 'grant_target'@'localhost' IDENTIFIED BY 'Target_123!';
GRANT SELECT ON mysql_priv_lab.* TO 'grant_admin'@'localhost' WITH GRANT OPTION;
```

以 grant_admin 登录：
```sql
GRANT SELECT ON mysql_priv_lab.employees TO 'grant_target'@'localhost';   -- 成功
GRANT INSERT ON mysql_priv_lab.employees TO 'grant_target'@'localhost';
-- ERROR 1142 (42000): INSERT command denied to user 'grant_admin'@'localhost' for table 'employees'
GRANT SELECT ON *.* TO 'grant_target'@'localhost';
-- ERROR 1045 (28000): Access denied for user 'grant_admin'@'localhost' (using password: YES)
```
grant_target 最终 `SHOW GRANTS`：
```text
GRANT USAGE ON *.* ...
GRANT SELECT ON `mysql_priv_lab`.`employees` TO `grant_target`@`localhost`
```
且 grant_target 能查到 employees（cnt=4）。

**现象与原因**：
- `WITH GRANT OPTION` ≠ "可以授权任意权限"。只能授：**自己持有 且 授权范围不比自己更大** 的权限。
- INSERT 报 1142：grant_admin 自己没持有 INSERT。
- 全局 `*.*` 报 1045：持有 scope 是库级，不能授更宽的全局级。
- 风险：授权会**级联扩散**——若被授方也带 GRANT OPTION 可继续转授；且 GRANT OPTION 是对整个权限组生效，无法只让部分权限可转授。最小权限原则下默认不加 GRANT OPTION。

**PostgreSQL 对比**：PG `GRANT ... WITH GRANT OPTION` + `REVOKE GRANT OPTION FOR ...` 语义一致；PG 还能 `GRANT role TO user WITH ADMIN OPTION`。差异：PG 授权信息存在对象 ACL（aclitem 记录 grantor），MySQL 在权限表的 `Grantor` 字段（实测 `tables_priv.Grantor = grant_admin@localhost`）。

---

## 9. MySQL Role（实验 11）

**目的**：Role 授予后默认生效吗？

**执行 SQL**：
```sql
CREATE ROLE 'role_reader';
GRANT SELECT ON mysql_priv_lab.* TO 'role_reader';
CREATE USER 'role_user'@'localhost' IDENTIFIED BY 'Role_123!';
GRANT 'role_reader' TO 'role_user'@'localhost';
SHOW GRANTS FOR 'role_user'@'localhost';
```
**输出**：
```text
GRANT USAGE ON *.* TO `role_user`@`localhost`
GRANT `role_reader`@`%` TO `role_user`@`localhost`
```

role_user 登录直接测试：
```sql
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
-- role_user@localhost | role_user@localhost | NONE
SELECT * FROM mysql_priv_lab.employees;
-- ERROR 1142 (42000): SELECT command denied to user 'role_user'@'localhost' for table 'employees'
```

`SET ROLE` 后：
```sql
SET ROLE 'role_reader';
SELECT CURRENT_ROLE();   -- `role_reader`@`%`
SELECT * FROM mysql_priv_lab.employees;   -- 成功 4 行
```

**现象与原因**：
- MySQL Role（8.0+）是"带锁的账号"：`mysql.user` 里有行（实测 `role_reader@%`，`account_locked=Y`）。
- **Role 被授予 ≠ Role 被激活**。默认会话 `CURRENT_ROLE()=NONE`，role 的权限不生效（除非 `activate_all_roles_on_login=ON` 或设了 `DEFAULT ROLE`）。
- 这与 PG 默认 INHERIT（成员自动继承权限）正好相反——是 PG DBA 学 MySQL 最大的认知翻转点。

---

## 10. SET ROLE 与 DEFAULT ROLE（实验 12）

**执行 SQL**：
```sql
SET DEFAULT ROLE 'role_reader' TO 'role_user'@'localhost';
-- mysql.default_roles 出现一行：USER=role_user, HOST=localhost, DEFAULT_ROLE_USER=role_reader, DEFAULT_ROLE_HOST=%
```
重新登录 role_user：
```sql
SELECT CURRENT_ROLE();   -- `role_reader`@`%`（自动激活）
SELECT * FROM mysql_priv_lab.employees;   -- 成功
SET ROLE NONE;
SELECT CURRENT_ROLE();   -- NONE
SELECT * FROM mysql_priv_lab.employees;
-- ERROR 1142 (42000): SELECT command denied ...
```

**结论**：
- "授予"是关系（role_edges），"激活"是会话状态（当前生效的 role 集合），两个概念。
- `SET DEFAULT ROLE`：登录后自动激活指定 role；`SET ROLE`：当前会话临时切换；`SET ROLE NONE`：全部停用。
- 运维意义：只 GRANT role 不激活 = "给了等于没给"；批量用户可 `activate_all_roles_on_login=ON` 全局开启。

**PostgreSQL 对比**（详见第 13 节实测）：
- PG 默认 INHERIT：成员角色的权限自动可用（lab_role_user 直接 SELECT 成功），无需激活。
- PG 的"激活"语义是 `SET ROLE`（切换当前身份），配合 NOINHERIT 成员角色（lab_user_noh2 必须先 SET ROLE 才能访问）。
- 实测发现：**NOINHERIT 要加在成员角色上**（`CREATE ROLE x LOGIN NOINHERIT`），加在"被授予的角色"上不生效——第一轮实验加反了，SELECT 依然成功，这就是实测的价值。
- 对照：PG 默认继承 ≈ MySQL 需要显式激活（DEFAULT ROLE / SET ROLE / activate_all_roles_on_login）；PG NOINHERIT + SET ROLE ≈ MySQL 默认行为（授予但不激活）。

---

## 11. MySQL 权限存储结构（实验 13）

### 11.1 权限相关表（`SHOW TABLES FROM mysql` 过滤）

```text
user / db / tables_priv / columns_priv / procs_priv /
role_edges / default_roles / global_grants / func / proxies_priv
```

### 11.2 各表作用与关键字段（实测 DESC）

**mysql.user —— 账号 + 全局权限**
- 身份列：`Host` / `User`；认证列：`plugin` / `authentication_string`；状态列：`account_locked` / `password_expired` / `password_lifetime`
- 每个静态全局权限一列：`Select_priv` / `Insert_priv` / `Update_priv` / ... / `Super_priv`（`enum('N','Y')`）
- 8.0+ 额外：`Create_role_priv` / `Drop_role_priv` / `User_attributes`(json)
- 实测 role 也是这里的行：`role_reader | % | caching_sha2_password | account_locked=Y | password_expired=Y`

**mysql.db —— 数据库级**
- `Host` / `Db` / `User` + 每权限一列 `enum('N','Y')`（Select/Insert/Update/Delete/Create/Drop/Grant/.../Trigger）
- 实测 `mysql_priv_lab` 有 5 行：role_reader / grant_admin / global_user / lab_user / mix_user，`Select_priv=Y`，`Insert_priv` 全部 N（lab_user 的 INSERT 已被 REVOKE）

**mysql.tables_priv —— 表级**
- `Host` / `Db` / `User` / `Table_name` / `Grantor` / `Timestamp` / `Table_priv`(set) / `Column_priv`(set)
- 表级权限用 set 列（不是每权限一列）；`Grantor` 记录谁授的（实测 grant_target 行 `Grantor=grant_admin@localhost`）
- 实测 3 行：table_user / column_user / grant_target（都是 employees）

**mysql.columns_priv —— 列级**
- `Host` / `Db` / `User` / `Table_name` / `Column_name` / `Column_priv` set('Select','Insert','Update','References')
- 实测 column_user 三行：id / name / department

**mysql.procs_priv —— 存储过程/函数**
- `Host` / `Db` / `User` / `Routine_name` / `Proc_priv` / `Grantor`
- 实测：routine_user / count_emps / Execute / Grantor=root@localhost

**mysql.role_edges / default_roles —— 角色关系**
- role_edges：`FROM_USER/FROM_HOST/TO_USER/TO_HOST/WITH_ADMIN_OPTION`（实测 role_reader → role_user）
- default_roles：`USER/HOST/DEFAULT_ROLE_USER/DEFAULT_ROLE_HOST`（实测 role_user → role_reader）

**mysql.global_grants —— 动态管理权限（8.0+）**
- `USER/HOST/PRIV/WITH_GRANT_OPTION`；实测有 `mysql.infoschema` 的 `AUDIT_ABORT_EXEMPT / FIREWALL_EXEMPT / SYSTEM_USER` 等

### 11.3 与 PG Catalog 对比

PG 没有这套集中权限表：
- 权限 = 对象上内嵌的 ACL：`pg_class.relacl`、`pg_namespace.nspacl`、`pg_database.datacl`、`pg_attribute.attacl`（aclitem 数组）。
- 角色关系 = `pg_auth_members`；角色属性 = `pg_authid`（**仅超管可读**，实测普通用户 `SELECT * FROM pg_authid` 报 `permission denied for table pg_authid`，普通用户看 `pg_roles` 视图）。

| 维度 | PostgreSQL | MySQL |
|---|---|---|
| 权限存储 | 分布式 ACL 内嵌在目录对象里 | 集中式权限表（mysql.user/db/tables_priv/...） |
| 查询方式 | 扫多个对象的 ACL / information_schema | `SHOW GRANTS` / 查 mysql.* 表 |
| 生命周期 | 删对象即删 ACL | 对象删了权限行可能残留 |
| 角色关系 | pg_auth_members | role_edges / default_roles |

---

## 12. USER()、CURRENT_USER() 与 CURRENT_ROLE()（实验 14 / 15）

**目的**：同一用户名从不同来源连接，为什么权限可能不同？

**前置设置**：
```text
'lab_user'@'localhost'：有 mysql_priv_lab 的 SELECT，密码 LabPass_123!
'lab_user'@'%'        ：无任何业务权限，密码 LabPass_456!
```

socket 登录（匹配 @localhost）：
```sql
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
-- lab_user@localhost | lab_user@localhost | NONE
SELECT COUNT(*) FROM mysql_priv_lab.employees;   -- 4，成功
```

TCP 127.0.0.1 登录（匹配 @%）：
```sql
mysql -ulab_user -p'LabPass_456!' -h 127.0.0.1 --protocol=TCP
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
-- lab_user@127.0.0.1 | lab_user@% | NONE
SELECT COUNT(*) FROM mysql_priv_lab.employees;
-- ERROR 1142 (42000): SELECT command denied to user 'lab_user'@'127.0.0.1' for table 'employees'
```

密码验证也按匹配到的 Account 生效：
```bash
mysql -ulab_user -p'LabPass_123!' -h 127.0.0.1 --protocol=TCP
# ERROR 1045 (28000): Access denied for user 'lab_user'@'127.0.0.1' (using password: YES)
```
（@localhost 的密码在 TCP 连接上不适用，因为匹配到的是 @% 账号，用的是 @% 的密码。）

**结论**：
- `USER()`：客户端声明的用户名 + 实际连接来源（socket → localhost；TCP → IP）。
- `CURRENT_USER()`：服务端按 host 匹配规则选中的 `mysql.user` 行 → **权限判断的真实身份**。
- `CURRENT_ROLE()`：当前会话激活的 role（NONE = 未激活任何 role）。
- 三者可以完全不同 → "明明授权了为什么没权限"的第一排查项就是看 `CURRENT_USER()` 是不是你以为的那个账号。

**PostgreSQL 对比**：PG 没有 host 维度的身份分裂——`session_user` 固定为连接角色，`current_user` 随 `SET ROLE` 变化；来源只影响认证方式（hba），不影响角色身份。

---

## 13. PostgreSQL Role 模型对照（PG 侧实验）

### 13.1 建角色与授权

```sql
CREATE ROLE lab_reader;
GRANT CONNECT ON DATABASE pg_priv_lab TO lab_reader;
GRANT USAGE ON SCHEMA public TO lab_reader;
GRANT SELECT ON TABLE employees TO lab_reader;
CREATE ROLE lab_role_user LOGIN PASSWORD 'Role_123!';
GRANT lab_reader TO lab_role_user;
```
> 实测坑：PG 18 中 `CREATE ROLE pg_reader` 报 `ERROR: role name "pg_reader" is reserved`（`pg_` 前缀保留，系统角色 16 个：pg_monitor/pg_read_all_data/pg_database_owner...），实验改用 `lab_` 前缀。

### 13.2 默认 INHERIT（成员自动继承）

以 lab_role_user 登录：
```sql
SELECT current_user, session_user;   -- lab_role_user | lab_role_user
SELECT * FROM employees;             -- 直接成功（无需任何激活）
SET ROLE lab_reader;
SELECT current_user;                 -- lab_reader
SELECT * FROM employees;             -- 成功
```

### 13.3 NOINHERIT（对应 MySQL 角色激活）

```sql
CREATE ROLE lab_priv_noh NOINHERIT;
GRANT SELECT ON TABLE employees TO lab_priv_noh;
CREATE ROLE lab_user_noh2 LOGIN NOINHERIT PASSWORD 'Noh_456!';
GRANT lab_priv_noh TO lab_user_noh2;
```
- 不 SET ROLE：`ERROR: permission denied for table employees`
- `SET ROLE lab_priv_noh` 后：成功
- **关键实测**：NOINHERIT 必须写在**成员角色**（lab_user_noh2）上；写在被授予角色（lab_priv_noh）上不生效（第一轮验证：SELECT 依然成功）。

### 13.4 REVOKE 无"上级覆盖"

```sql
REVOKE SELECT ON TABLE employees FROM lab_reader;
-- information_schema.role_table_grants 中 lab_reader 行消失
-- lab_role_user 立即 SELECT 失败（ERROR: permission denied for table employees）
GRANT SELECT ON TABLE employees TO lab_reader;   -- 恢复
```
PG 没有 MySQL 的"db 级授权盖住表"结构：撤销即生效、没有兜底层。

### 13.5 Catalog 查询

```sql
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolinherit
FROM pg_roles WHERE rolname LIKE 'lab_%';
-- lab_reader    | f | f | f | t
-- lab_role_user | t | f | f | t

SELECT grantee, privilege_type, is_grantable
FROM information_schema.role_table_grants WHERE table_name='employees';
-- lab_priv_noh | SELECT | NO
-- lab_reader   | SELECT | NO
-- postgres     | SELECT/INSERT/... | YES（属主）

SELECT r.rolname AS role, m.rolname AS member, am.admin_option
FROM pg_auth_members am
JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
WHERE r.rolname LIKE 'lab_%';
-- lab_reader | lab_role_user | f
-- lab_priv_noh | lab_user_noh | f
-- lab_priv_noh | lab_user_noh2 | f
```

### 13.6 模型差异总结

| | PostgreSQL | MySQL |
|---|---|---|
| 身份 | Role 全局唯一 | 'user'@'host' 二元组 |
| 来源/认证 | pg_hba.conf | 账号 host 匹配 + 认证插件 |
| 授权 | 对象 ACL | 集中权限表 |
| 成员继承 | 默认 INHERIT（自动生效） | 默认不激活（CURRENT_ROLE()=NONE） |

---

## 14. MySQL vs PostgreSQL 权限体系总表

| 项目 | PostgreSQL | MySQL |
|---|---|---|
| 用户模型 | Role 全局唯一，一个名字即身份，无 host 维度 | Account = 'user'@'host' 二元组，同名不同 host 是不同账号、不同密码、不同权限 |
| 来源限制 | pg_hba.conf 行决定来源与认证方式（trust/md5/scram），与角色本身无关 | host 是账号身份的一部分：socket→localhost，TCP→IP 按规则匹配，% 兜底 |
| 登录属性 | `CREATE ROLE ... LOGIN`（默认 NOLOGIN，可分开管理） | `CREATE USER`（账号+可登录）；`CREATE ROLE` 默认不可登录（角色） |
| 数据库权限 | CONNECT / CREATE / TEMP 三种 | Database 级（mysql.db）：DML+DDL 全谱，覆盖整库所有表 |
| Schema | 有独立 Schema 级 ACL（USAGE/CREATE），对象可跨 schema 组织 | SCHEMA=DATABASE，无独立 schema 层，权限层级直接到库 |
| Table | 对象级 ACL（r/w/a/d/D/x/t/m 等），逐表授权 | 表级存 tables_priv（set 列），表级授权不影响其他表 |
| Column | 支持（attacl），`GRANT SELECT(col)` | 支持（columns_priv），实测未授权列报 1143，`SELECT *` 报 1142 |
| Role membership | `GRANT role TO user`，默认 INHERIT 自动生效 | `GRANT role TO user`，默认不激活，需 SET ROLE / DEFAULT ROLE / activate_all_roles_on_login |
| 默认继承 | INHERIT 默认开启（成员权限自动可用）；NOINHERIT 要加在成员角色上 | 默认关闭：CURRENT_ROLE()=NONE；"授予"与"激活"是两件事 |
| SET ROLE | 支持，切换当前身份（current_user 变化） | 支持，激活/切换当前角色（CURRENT_ROLE() 变化） |
| Grant Option | 支持（WITH GRANT OPTION + REVOKE GRANT OPTION FOR；role 用 WITH ADMIN OPTION） | 支持，但只能授"持有且不超 scope"的权限（实测 INSERT 报 1142、*.* 报 1045） |
| 权限存储 | 对象内嵌 ACL（relacl/nspacl/datacl/attacl）+ pg_auth_members/pg_authid（超管可见） | 集中权限表 mysql.user/db/tables_priv/columns_priv/procs_priv/role_edges/default_roles/global_grants |
| 超级权限 | SUPERUSER 角色属性（rolsuper），预置 16 个 pg_* 系统角色 | `SUPER` 权限（mysql.user.Super_priv）+ 动态管理权限（global_grants，如 BACKUP_ADMIN） |
| 用户来源匹配 | HBA 逐行匹配（local/host/netmask） | user@host 排序匹配，越具体越优先，`%` 兜底 |

---

## 15. 用户登录成功但无权限的排查方法

### 15.1 固定排查流程

```text
1. 获取完整错误文本与错误码（1045=认证 / 1142=表 / 1143=列 / 1147=无此授权 / 1044=库）
2. 确认连接方式（socket 还是 TCP，从哪个来源来）
3. SELECT USER()           → 客户端声称的身份
4. SELECT CURRENT_USER()   → 实际匹配到的 Account（权限判断身份）
5. SELECT CURRENT_ROLE()   → 已激活的 role
6. SHOW GRANTS / SHOW GRANTS FOR CURRENT_USER → 实际授权
7. 判断 Account 是否匹配（localhost vs % vs IP，看 mysql.user 的 host）
8. 判断 Role 是否激活（CURRENT_ROLE()=NONE？）
9. 判断权限层级（Global/Db/Table/Column/Routine 哪一层缺失）
10. 判断对象名是否正确（库名.表名、大小写、默认库）
```

```sql
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
SHOW GRANTS;
SHOW GRANTS FOR CURRENT_USER;
```

### 15.2 Case 1：能登录但 SELECT denied → 根本没授权

```sql
-- trouble1 新建后从未 GRANT
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
-- trouble1@localhost | trouble1@localhost | NONE
SELECT * FROM mysql_priv_lab.employees;
-- ERROR 1142 (42000): SELECT command denied to user 'trouble1'@'localhost' for table 'employees'
SHOW GRANTS FOR CURRENT_USER;
-- GRANT USAGE ON *.* TO `trouble1`@`localhost`
```
**排查结论**：只有 USAGE → 确认没授权，GRANT 解决。

### 15.3 Case 2：已 GRANT Role 但 SELECT 仍失败 → Role 没激活

```sql
-- trouble2 已被授予 role_reader
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
-- trouble2@localhost | trouble2@localhost | NONE
SELECT * FROM mysql_priv_lab.employees;
-- ERROR 1142 ...
SHOW GRANTS FOR CURRENT_USER;
-- GRANT USAGE ON *.* ...
-- GRANT `role_reader`@`%` TO `trouble2`@`localhost`
SET ROLE 'role_reader';
SELECT CURRENT_ROLE();              -- `role_reader`@`%`
SELECT * FROM mysql_priv_lab.employees;   -- 成功
```
**排查结论**：role 已授予但未激活 → SET ROLE / SET DEFAULT ROLE / activate_all_roles_on_login。

### 15.4 错误分层

```text
Connection      ：socket/TCP 建立（如 mysqladmin ping）
Authentication  ：账号+密码匹配 → ERROR 1045 (28000)
Authorization   ：权限检查 → ERROR 1142(表)/1143(列)/1144(库)/1147(无此授权)/1044(库级拒绝)
Object          ：对象不存在/名称错（如 1146 Table doesn't exist）
SQL             ：语法/执行期错误
```
实测错误码集合见 `evidence/mysql-privilege-errors.txt`：1045（密码错/用户不存在）、1142、1143、1147、1044（CREATE DATABASE 被拒）。

---

## 16. DBA 实战总结

### 16.1 MySQL 权限判断心智模型

```text
连接
 ↓
'user'@'host' Account 匹配（越具体优先，% 兜底）
 ↓
Authentication（该 Account 的密码/插件）
 ↓
Direct Privileges + Active Roles
 ↓
Global / DB / Table / Column 权限综合判断（各层级并集）
 ↓
允许或拒绝 SQL
```

### 16.2 PostgreSQL 对照心智模型

```text
连接
 ↓
Role（全局唯一）
 ↓
pg_hba.conf（来源 + 认证方式）
 ↓
Authentication
 ↓
Role Membership（INHERIT 默认） / 对象 ACL
 ↓
Database / Schema / Object Privileges
 ↓
允许或拒绝 SQL
```

### 16.3 PG DBA 学 MySQL 权限体系，最需要改变的三个认知

1. **用户不是"用户"，是 'user'@'host' Account**：host 是身份的一部分；排查权限先确认 `CURRENT_USER()`，不能只按用户名查。同一个用户名可能同时存在 3 个互不相干的账号。
2. **MySQL 的 db 级权限是一把"整库伞"，且没有 DENY**：库级授权后无法用表级 REVOKE 单独排除（实测 ERROR 1147）；要对象级隔离只能靠表级授权/视图/独立库。PG 的权限粒度天然在对象上，没有"盖不住"的问题。
3. **MySQL Role 默认不激活**：GRANT role 之后 `CURRENT_ROLE()=NONE`，等于没给；PG 默认 INHERIT 是"给了就生效"。批量开通权限后必须确认激活方式（DEFAULT ROLE / SET ROLE / activate_all_roles_on_login）。

### 16.4 清理脚本（审阅通过后按需执行）

MySQL：
```sql
DROP DATABASE IF EXISTS mysql_priv_lab;
DROP USER IF EXISTS
  'lab_user'@'localhost','lab_user'@'%',
  'global_user'@'localhost','table_user'@'localhost',
  'column_user'@'localhost','mix_user'@'localhost',
  'grant_admin'@'localhost','grant_target'@'localhost',
  'role_user'@'localhost','routine_user'@'localhost',
  'trouble1'@'localhost','trouble2'@'localhost';
DROP ROLE IF EXISTS 'role_reader';
```

PostgreSQL（postgres 用户执行）：
```sql
DROP DATABASE IF EXISTS pg_priv_lab;
DROP ROLE IF EXISTS lab_reader, lab_role_user, lab_priv_noh, lab_user_noh, lab_user_noh2;
```

---

## Evidence 索引

| 文件 | 内容 |
|---|---|
| evidence/mysql-environment.txt | 环境探测（版本/端口/进程/登录身份） |
| evidence/mysql-setup.txt | 测试库/表/种子数据（两边） |
| evidence/mysql-accounts.txt | 实验 1-2：Account 独立性、USAGE、登录无权限 |
| evidence/mysql-grants.txt | 实验 3-10：db/table/column 级 GRANT/REVOKE、1147、GRANT OPTION |
| evidence/mysql-roles.txt | 实验 11-12：Role 激活语义、SET ROLE、DEFAULT ROLE |
| evidence/mysql-privilege-tables.txt | 实验 13：权限表结构与行数据、Routine 级 |
| evidence/mysql-host-matching.txt | 实验 14-15：USER()/CURRENT_USER()、socket vs TCP |
| evidence/mysql-privilege-errors.txt | 错误码集合（1045/1142/1143/1147/1044） |
| evidence/mysql-troubleshooting.txt | 排查 Case 1/2 完整输出 |
| evidence/postgres-role-tests.txt | PG 侧全部实验（hba/INHERIT/NOINHERIT/SET ROLE/REVOKE/Catalog） |
