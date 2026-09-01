# MySQL 登录与认证：从 pg_hba.conf 与 trust/md5/scram 迁移

> 版本：v1.1（2026-09-01 修订：全部步骤改为"完整命令 → 真实输出"，可直接复制执行）
> 基线：PostgreSQL 18.4 @54184 → 目标：MySQL 8.4.10 @3306（socket /tmp/mysql.sock）
> 证据：`evidence/mysql-connection-host-plugin.txt`、`mysql-caching-sha2-tls.txt`、`mysql-caching-sha2-ssl-mode.txt`、`pg-hba-trust-md5-scram.txt`
> 本文所有输出均为 2026-09-01 本机实跑的真实输出，可复现。

---

## 0. 环境与约定（先读）

```text
MySQL 管理入口：mysql -uroot -S /tmp/mysql.sock        # root 仅 socket 空密码，本机专用
PG 管理入口：   psql -h 127.0.0.1 -p 54184 -U postgres  # 或 sudo -u postgres psql -p 54184
实验账号一律 lab_* 前缀，实验库 mysql_lab_*；做完全部实验后执行第 3 节清理 SQL
```

---

## 1. PostgreSQL 基线：先跑这些命令看结论

### 1.1 密码是怎么存的（scram-sha-256）

建一个实验角色（postgres 超管执行）：

```sql
CREATE ROLE lab_auth LOGIN PASSWORD 'pass_auth';
```

看默认加密算法：

```bash
sudo -u postgres psql -p 54184 -c "SHOW password_encryption;"
```

真实输出：

```text
 password_encryption
---------------------
 scram-sha-256
(1 row)
```

看密码实际存储格式（`rolpassword` 前缀）：

```bash
sudo -u postgres psql -p 54184 -tAc "SELECT rolname, rolcanlogin, substring(rolpassword,1,20) AS pwd_prefix FROM pg_authid WHERE rolname='lab_auth';"
```

真实输出：

```text
lab_auth|t|SCRAM-SHA-256$4096:w
```

结论：PG 18.4 密码用 SCRAM-SHA-256 加盐迭代存储，不是明文。

### 1.2 认证方式由 pg_hba.conf 决定（角色与来源解耦）

本机 `pg_hba.conf` 关键两行：

```text
host    all    all    127.0.0.1/32       trust   # 本机回环：免密
host    all    all    192.168.101.0/24   md5     # 局域网：密码认证
```

同一个角色 `lab_auth`，走不同来源行：

① trust 来源（127.0.0.1，免密直接成功）：

```bash
psql -h 127.0.0.1 -p 54184 -U lab_auth -d postgres -c "SELECT current_user;"
```

真实输出：

```text
 current_user
--------------
 lab_auth
(1 row)
```

② md5 来源（局域网 IP，需要密码；密码存 scram 时实际按 scram 交换）：

```bash
PGPASSWORD=pass_auth psql -h 192.168.101.129 -p 54184 -U lab_auth -d postgres -c "SELECT current_user;"
```

真实输出：

```text
 current_user
--------------
 lab_auth
(1 row)
```

③ 错误密码：

```bash
PGPASSWORD=wrong psql -h 192.168.101.129 -p 54184 -U lab_auth -d postgres -c "SELECT 1;"
```

真实输出：

```text
psql: error: connection to server at "192.168.101.129", port 54184 failed: FATAL:  password authentication failed for user "lab_auth"
```

④ 缺密码（hba 要密码但客户端没给）：

```bash
psql -h 192.168.101.129 -p 54184 -U lab_auth -d postgres -c "SELECT 1;"
```

真实输出：

```text
Password for user lab_auth:
psql: error: connection to server at "192.168.101.129", port 54184 failed: fe_sendauth: no password supplied
```

结论：**PG 的认证方法是"连接"的属性（由 pg_hba.conf 行决定），不是角色的属性**——同一个 lab_auth，回环免密、局域网密码，都成立。

---

## 2. MySQL：完整命令 + 真实输出

### 2.1 身份在哪看：mysql.user 表

```bash
mysql -uroot -S /tmp/mysql.sock -e "SELECT user, host, plugin FROM mysql.user WHERE user LIKE 'lab_%' OR user='root' ORDER BY user, host;"
```

真实输出（建了 lab_auth / lab_host / lab_sha2 / lab_empty 后的状态）：

```text
user	host	plugin
lab_auth	%	caching_sha2_password
lab_auth	127.0.0.1	caching_sha2_password
lab_auth	localhost	caching_sha2_password
lab_empty	localhost	caching_sha2_password
lab_host	%	caching_sha2_password
lab_host	127.0.0.1	caching_sha2_password
lab_host	192.168.%	caching_sha2_password
lab_host	192.168.101.129	caching_sha2_password
lab_host	localhost	caching_sha2_password
root	localhost	caching_sha2_password
```

要点：同一用户名可以有多行（不同 host）= **多个 Account**；每个 Account 自己的密码、自己的权限、自己的认证插件。

### 2.2 准备实验账号（root 执行，全文复现用）

```sql
CREATE USER 'lab_auth'@'localhost' IDENTIFIED BY 'pass_auth';
CREATE USER 'lab_auth'@'127.0.0.1' IDENTIFIED BY 'pass_auth';
CREATE USER 'lab_auth'@'%' IDENTIFIED BY 'pass_auth';
CREATE USER 'lab_host'@'localhost' IDENTIFIED BY 'pass_host';
CREATE USER 'lab_host'@'127.0.0.1' IDENTIFIED BY 'pass_host';
CREATE USER 'lab_host'@'192.168.101.129' IDENTIFIED BY 'pass_host';
CREATE USER 'lab_host'@'192.168.%' IDENTIFIED BY 'pass_host';
CREATE USER 'lab_host'@'%' IDENTIFIED BY 'pass_host';
CREATE USER 'lab_sha2c'@'127.0.0.1' IDENTIFIED BY 'pass_sha2c';
CREATE USER 'lab_sha2c'@'localhost' IDENTIFIED BY 'pass_sha2c';
CREATE USER 'lab_empty2'@'127.0.0.1' IDENTIFIED BY '';
CREATE USER 'lab_empty2'@'%' IDENTIFIED BY '';
```

### 2.3 实验 A：三种连接路线（socket / TCP 回环 / TCP 局域网）

① socket 连接（来源固定为 localhost）：

```bash
MYSQL_PWD=pass_auth mysql -ulab_auth -S /tmp/mysql.sock -e "SELECT USER() u, CURRENT_USER() cu;"
```

真实输出：

```text
u	cu
lab_auth@localhost	lab_auth@localhost
```

② TCP 回环 127.0.0.1（来源显示 127.0.0.1）：

```bash
MYSQL_PWD=pass_auth mysql -ulab_auth -h127.0.0.1 -P3306 -e "SELECT USER() u, CURRENT_USER() cu;"
```

真实输出：

```text
u	cu
lab_auth@127.0.0.1	lab_auth@127.0.0.1
```

③ TCP 局域网 IP（本机 192.168.101.129，命中 % 兜底账号）：

```bash
MYSQL_PWD=pass_auth mysql -ulab_auth -h192.168.101.129 -P3306 -e "SELECT USER() u, CURRENT_USER() cu;"
```

真实输出：

```text
u	cu
lab_auth@192.168.101.129	lab_auth@%
```

**结论**：`USER()`=客户端声称的身份（来源 IP）；`CURRENT_USER()`=服务端实际命中的 Account。第 ③ 种两者不一致 = 命中了 `%` 通配账号。排查登录身份先看这两个函数的差异。

### 2.4 实验 B：host 匹配顺序（同用户名 5 个 host 账号）

① socket 来源：

```bash
MYSQL_PWD=pass_host mysql -ulab_host -S /tmp/mysql.sock -e "SELECT USER() u, CURRENT_USER() cu;"
```

真实输出：

```text
u	cu
lab_host@localhost	lab_host@localhost
```

② TCP 127.0.0.1：

```bash
MYSQL_PWD=pass_host mysql -ulab_host -h127.0.0.1 -P3306 -e "SELECT USER() u, CURRENT_USER() cu;"
```

真实输出：

```text
u	cu
lab_host@127.0.0.1	lab_host@127.0.0.1
```

③ TCP 192.168.101.129（同时存在 192.168.101.129、192.168.%、% 三个账号）：

```bash
MYSQL_PWD=pass_host mysql -ulab_host -h192.168.101.129 -P3306 -e "SELECT USER() u, CURRENT_USER() cu;"
```

真实输出：

```text
u	cu
lab_host@192.168.101.129	lab_host@192.168.101.129
```

**结论**：host 匹配**精确优先**：具体 IP > 网段 `192.168.%` > `%`，命中即停。源码：`sql/auth/sql_auth_cache.cc` 的 `wild_compare`。

### 2.5 实验 C：caching_sha2_password 与 TLS（8.4 关键差异）

① 默认连接（客户端默认 `--ssl-mode=PREFERRED`，服务器有 TLS 就自动加密）：

```bash
MYSQL_PWD=pass_sha2c mysql -ulab_sha2c -h127.0.0.1 -P3306 -e "SHOW SESSION STATUS LIKE 'Ssl_cipher'; SHOW SESSION STATUS LIKE 'Ssl_version'; SELECT 1 AS ok;"
```

真实输出：

```text
Variable_name	Value
Ssl_cipher	TLS_AES_128_GCM_SHA256
Variable_name	Value
Ssl_version	TLSv1.3
ok
1
```

② 强制关 TLS（`--ssl-mode=DISABLED`），caching_sha2 非安全通道就需要 RSA 公钥，不给就报错：

```bash
MYSQL_PWD=pass_sha2c mysql -ulab_sha2c -h127.0.0.1 -P3306 --ssl-mode=DISABLED -e "SELECT 1;"
```

真实输出：

```text
ERROR 2061 (HY000): Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.
```

③ 关 TLS 但显式请求服务器公钥：

```bash
MYSQL_PWD=pass_sha2c mysql -ulab_sha2c -h127.0.0.1 -P3306 --ssl-mode=DISABLED --get-server-public-key -e "SELECT 1 AS ok;"
```

真实输出：

```text
ok
1
```

④ socket 连接（文件通道，无 TLS 也无需 RSA）：

```bash
MYSQL_PWD=pass_sha2c mysql -ulab_sha2c -S /tmp/mysql.sock -e "SHOW SESSION STATUS LIKE 'Ssl_cipher';"
```

真实输出（Ssl_cipher 为空 = 没有 TLS，认证仍成功）：

```text
Variable_name	Value
Ssl_cipher
```

⑤ 空密码账号 TCP（fast path，无需 TLS/RSA）：

```bash
MYSQL_PWD= mysql -ulab_empty2 -h127.0.0.1 -P3306 -e "SELECT USER() u, CURRENT_USER() cu;"
```

真实输出：

```text
u	cu
lab_empty2@127.0.0.1	lab_empty2@127.0.0.1
```

⑥ 密码错误：

```bash
MYSQL_PWD=wrong mysql -ulab_sha2c -S /tmp/mysql.sock -e "SELECT 1;"
```

真实输出：

```text
ERROR 1045 (28000): Access denied for user 'lab_sha2c'@'localhost' (using password: YES)
```

**结论**：8.4 下 caching_sha2 "无 RSA 也成功"是因为默认走了 TLS；排障先看 `Ssl_cipher` 判断当前通道，再用 `--ssl-mode=DISABLED` 复现 2061。

### 2.6 实验 D：客户端凭据（login-path 与 .my.cnf）

① 生成 login-path（`--password` 后不带值，会交互提示输入；`mysql_config_editor` 在 MySQL bin 目录）：

```bash
printf 'pass_sha2c\n' | /usr/local/mysql/mysql-8.4.10/bin/mysql_config_editor set --login-path=demo --host=127.0.0.1 --user=lab_sha2c --password
```

② 查看（口令显示为掩码）：

```bash
/usr/local/mysql/mysql-8.4.10/bin/mysql_config_editor print --all
```

真实输出：

```text
[demo]
user = "lab_sha2c"
password = *****
host = "127.0.0.1"
```

③ 使用 login-path 连接（免输主机/用户/密码）：

```bash
mysql --login-path=demo -e "SELECT USER() u, CURRENT_USER() cu; SHOW SESSION STATUS LIKE 'Ssl_cipher';"
```

真实输出：

```text
u	cu
lab_sha2c@127.0.0.1	lab_sha2c@127.0.0.1
Variable_name	Value
Ssl_cipher	TLS_AES_128_GCM_SHA256
```

④ 删除：

```bash
/usr/local/mysql/mysql-8.4.10/bin/mysql_config_editor remove --login-path=demo
/usr/local/mysql/mysql-8.4.10/bin/mysql_config_editor print --all   # 应为空
```

⑤ `.my.cnf` 的 `[client]` 组（写文件 → 无参数连接）：

```bash
cat > ~/.my.cnf <<'CNF'
[client]
user=lab_empty2
password=
CNF
mysql -h127.0.0.1 -e "SELECT USER() u, CURRENT_USER() cu;"
rm -f ~/.my.cnf
```

真实输出：

```text
u	cu
lab_empty2@127.0.0.1	lab_empty2@127.0.0.1
```

**结论**：login-path（`~/.mylogin.cnf` 加密、print 掩码）比明文 `.my.cnf` 安全；两者都是"免输参数"手段，凭据文件权限要管好。

---

## 3. 清理（实验收尾，root 执行）

```sql
DROP USER 'lab_auth'@'localhost','lab_auth'@'127.0.0.1','lab_auth'@'%';
DROP USER 'lab_host'@'localhost','lab_host'@'127.0.0.1','lab_host'@'192.168.101.129','lab_host'@'192.168.%','lab_host'@'%';
DROP USER 'lab_sha2c'@'127.0.0.1','lab_sha2c'@'localhost';
DROP USER 'lab_empty2'@'127.0.0.1','lab_empty2'@'%';
SELECT user, host FROM mysql.user WHERE user LIKE 'lab_%';   -- 应为空
```

```sql
-- PG 侧
DROP ROLE IF EXISTS lab_auth;
```

---

## 4. 关键差异（对照表）

| 维度 | PostgreSQL 18.4 | MySQL 8.4 |
|---|---|---|
| 身份对象 | role 全局唯一（LOGIN 属性） | Account = `user@host` 二元组，每来源一账号 |
| 来源/认证 | pg_hba.conf 独立控制（trust/md5/scram/peer） | host 焊死在账号里；无匹配 Account 即 1045 |
| 通配 | 无（来源按 CIDR 匹配 hba 行） | host 列 `%` / `192.168.%` / IP，`wild_compare` 精确优先 |
| 密码存储 | `SCRAM-SHA-256$4096:...`（password_encryption） | `mysql.user.authentication_string`（插件相关） |
| 认证方法 | 连接时由 hba 行选择 | 账号自带 `plugin` 列（caching_sha2_password 默认） |
| 加密通道 | libpq 默认 `sslmode=prefer`（同向） | 客户端默认 `--ssl-mode=PREFERRED`，TLS 时免 RSA |
| 身份查询 | `current_user/session_user` | `USER()`（声称）/ `CURRENT_USER()`（实际）/ `CURRENT_ROLE()` |
| 客户端凭据 | `~/.pgpass` | `~/.mylogin.cnf`（login-path）/ `[client]` 组 |

## 5. 心智迁移要点

1. **先分清"认证"与"授权"**：1045=认证失败（身份环节），1142/1143=授权不足（权限环节），排查路径不同
2. **MySQL 排登录第一问：连接走 socket 还是 TCP？** 决定了 host 匹配方向（localhost vs IP）；`USER()` 与 `CURRENT_USER()` 不一致 = 命中了通配账号
3. **PG 改 hba 加行 vs MySQL 建账号**：PG 加一条 hba 行给已有角色换认证；MySQL 必须为每个来源建对应 host 的账号（或统一 `%`）
4. **caching_sha2 报 2061 先看 TLS**：`--ssl-mode=DISABLED` 是复现"经典 RSA 需求"的开关；生产连接串务必走 TLS 或预置公钥
5. **凭据文件是双刃剑**：login-path 加密优于明文 `.my.cnf`；但 `.mylogin.cnf` 权限/残留要管好
6. **8.4 无 mysql_native_password 默认**：老客户端连不上时查 `plugin` 列与客户端版本（差异点）

## 6. Evidence 索引

| 文件 | 内容 |
|---|---|
| evidence/mysql-connection-host-plugin.txt | 连接路线三式、host 匹配顺序、plugin 矩阵、密码错误 |
| evidence/mysql-caching-sha2-tls.txt | caching_sha2 首连/缓存/空密码（无干扰场景） |
| evidence/mysql-caching-sha2-ssl-mode.txt | `--ssl-mode=DISABLED` 复现 ERROR 2061、TLS 下 Ssl_cipher、login-path |
| evidence/pg-hba-trust-md5-scram.txt | PG trust/md5(scram)/错误密码/缺密码/角色来源解耦 |

相关资产：`study_record/pg-mysql-map.md`、`study_record/runbook/mysql-dba-cheatsheet.md`、`study_record/troubleshooting/CASE-001-login-failed.md`
