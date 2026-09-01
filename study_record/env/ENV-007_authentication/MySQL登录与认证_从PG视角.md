# MySQL 登录与认证：从 pg_hba.conf 与 trust/md5/scram 迁移

> 版本：v1.0（2026-09-01，双引擎实跑：PG 18.4 @54184 / MySQL 8.4.10 @3306）
> 系列：PG DBA → MySQL 生产 DBA 迁移项目 · 第一阶段专题 3（ENV-007）
> 关联：troubleshooting CASE-001（1045 排查）；ENV-004（Account 模型）
> 证据：`evidence/mysql-connection-host-plugin.txt`、`mysql-caching-sha2-tls.txt`、`mysql-caching-sha2-ssl-mode.txt`、`pg-hba-trust-md5-scram.txt`

---

## 1. PostgreSQL 已知模型（基线）

```text
角色（role）：全局唯一对象，"能否登录"是 LOGIN 属性；与连接来源无关
pg_hba.conf：按 (来源IP/socket, 数据库, 用户名) 逐行匹配 → 决定认证方法
   trust         免密（本机 local/127.0.0.1）
   md5           密码认证（8.0 起兼容写法；密码按 scram 存储时自动走 scram 交换）
   scram-sha-256 默认 password_encryption（18.4 实测：SCRAM-SHA-256$4096:...）
认证方法属于"连接"而非"角色"：同一角色，走 127.0.0.1 行=trust，走 192.168.101.0/24 行=md5
```

本机 PG 实测（`pg-hba-trust-md5-scram.txt`）：

```text
SHOW password_encryption;        → scram-sha-256
pg_authid.rolpassword 前缀       → SCRAM-SHA-256$4096:w...（加盐迭代存储）

trust 来源：psql -h 127.0.0.1 -U lab_auth        → 免密成功（current_user=lab_auth）
md5 来源：  PGPASSWORD=pass_auth psql -h 192.168.101.129 -U lab_auth → 成功
错误密码：  → FATAL: password authentication failed for user "lab_auth"
缺密码：    → fe_sendauth: no password supplied
同一角色两种来源都成功 = 角色与来源解耦（认证由 hba 行决定）
```

---

## 2. MySQL 对应机制（含源码定位）

### 2.1 身份 = Account（user@host 二元组）

- 不是"角色 + 独立 hba"，而是**每个来源一个账号**：`mysql.user` 的 `(user, host)` 联合唯一
- host 支持通配：`%`、`192.168.%`、具体 IP、`localhost`、`127.0.0.1`
- 匹配时**最精确优先**（具体 IP > 网段 > %），源码实现：`sql/auth/sql_auth_cache.cc` 的 `wild_compare`（hostname/IP 通配比较）

### 2.2 连接路线

- socket（unix_socket）：来源固定为 `localhost`，文件通道，认证不需 TLS/RSA
- TCP：`-h 127.0.0.1`（来源显示 127.0.0.1）、`-h <局域网 IP>`（来源显示该 IP）
- 本机 `skip-name-resolve=ON`：TCP 来源按 **IP 字面量** 匹配 host（不做反解）

### 2.3 认证插件与 caching_sha2_password

- 默认插件 `caching_sha2_password`（`mysql.user.plugin` 实测全为该插件）
- 认证分两段（源码 `sql/auth/sha2_password.cc`）：
  - `Caching_sha2_password::fast_authenticate`（:351）：服务器缓存命中 → scramble 校验快路径
  - `Caching_sha2_password::authenticate`（:236）：完整认证，非安全通道需 TLS 或 RSA 公钥
- 空密码账号走 fast path，无需 TLS/RSA
- 8.4 客户端默认 `--ssl-mode=PREFERRED`：服务器支持 TLS 时自动加密 → caching_sha2 免 RSA

### 2.4 客户端凭据

- `mysql_config_editor` → login-path（加密文件 `~/.mylogin.cnf`，`print` 显示掩码）
- `~/.my.cnf` / 各选项文件 `[client]` 组：`user`/`password` 免输参数

---

## 3. 对照实验（同一设计，两边各跑）

### 实验 A：连接路线三式 + 身份验证（MySQL）

```text
socket：           USER()=lab_auth@localhost      CURRENT_USER()=lab_auth@localhost
TCP 127.0.0.1：    USER()=lab_auth@127.0.0.1      CURRENT_USER()=lab_auth@127.0.0.1
TCP 192.168.101.129：USER()=lab_auth@192.168.101.129  CURRENT_USER()=lab_auth@%   ← 命中 % 兜底账号
```

结论：`USER()`=客户端声称身份；`CURRENT_USER()`=服务端实际匹配的 Account。局域网 IP 连接命中 `%` 时两者不一致——排查登录身份最实用的一招。

### 实验 B：host 匹配顺序（同用户名建 5 个 host 账号）

```text
socket 来源              → CURRENT_USER()=lab_host@localhost
TCP 127.0.0.1            → CURRENT_USER()=lab_host@127.0.0.1
TCP 192.168.101.129      → CURRENT_USER()=lab_host@192.168.101.129   ← 精确 IP 优先于 192.168.% 与 %
```

结论：MySQL 按来源从最精确到最宽依次匹配，命中即停。

### 实验 C：caching_sha2_password 与 TLS（8.4 实测）

```text
默认连接（PREFERRED）      → 成功；SHOW STATUS: Ssl_cipher=TLS_AES_128_GCM_SHA256, Ssl_version=TLSv1.3
--ssl-mode=DISABLED 无 RSA → ERROR 2061: Authentication plugin 'caching_sha2_password'
                             reported error: Authentication requires secure connection.
--ssl-mode=DISABLED + --get-server-public-key → 成功
socket 连接                → 成功；Ssl_cipher 为空（文件通道无需 TLS/RSA）
空密码账号 TCP             → 成功（fast path，无需 RSA）
密码错误                   → ERROR 1045 (28000) (using password: YES)
```

结论：**8.4 下 caching_sha2 "无 RSA 也成功" 是因为默认走了 TLS**；关掉 TLS 才看到经典的 2061。生产排障先看 `Ssl_cipher` 区分"TLS 通道"与"RSA 公钥通道"。

### 实验 D：客户端凭据（MySQL）

```text
mysql_config_editor set --login-path=demo --host=127.0.0.1 --user=lab_sha2c --password（交互输入）
mysql_config_editor print --all    → user = "lab_sha2c", password = *****, host = "127.0.0.1"
mysql --login-path=demo            → 成功（走 TLS）
mysql_config_editor remove --login-path=demo

~/.my.cnf [client] user/password   → 无参数 mysql -h127.0.0.1 直接连接成功
```

### 实验 E：PG 对照（同场景）

```text
trust 来源（127.0.0.1）    → 免密成功
md5 来源（192.168.101.129）→ 密码成功（scram 交换）
错误密码                  → FATAL: password authentication failed
缺密码                    → fe_sendauth: no password supplied
同一角色两种来源都成功     → 角色与来源解耦
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

---

## 5. 心智迁移要点

1. **先分清"认证"与"授权"**：1045=认证失败（身份环节），1142/1143=授权不足（权限环节），排查路径不同
2. **MySQL 排登录第一问：连接走 socket 还是 TCP？** 决定了 host 匹配方向（localhost vs IP）；`USER()` 与 `CURRENT_USER()` 不一致 = 命中了通配账号
3. **PG 改 hba 加行 vs MySQL 建账号**：PG 加一条 hba 行给已有角色换认证；MySQL 必须为每个来源建对应 host 的账号（或统一 `%`）
4. **caching_sha2 报 2061 先看 TLS**：`--ssl-mode=DISABLED` 是复现"经典 RSA 需求"的开关；生产连接串务必走 TLS 或预置公钥
5. **凭据文件是双刃剑**：login-path 加密优于明文 `.my.cnf`；但 `.mylogin.cnf` 权限/残留要管好（`print --all` 会暴露账号清单）
6. **8.4 无 mysql_native_password 默认**：老客户端连不上时查 `plugin` 列与客户端版本（差异点，PG 的 md5 兼容思路类似但不完全相同）

---

## 6. Evidence 索引

| 文件 | 内容 |
|---|---|
| evidence/mysql-connection-host-plugin.txt | 连接路线三式、host 匹配顺序、plugin 矩阵、login-path/`.my.cnf`、密码错误 |
| evidence/mysql-caching-sha2-tls.txt | caching_sha2 首连/缓存/空密码（无干扰场景） |
| evidence/mysql-caching-sha2-ssl-mode.txt | `--ssl-mode=DISABLED` 复现 ERROR 2061、TLS 下 Ssl_cipher、login-path 修正版 |
| evidence/pg-hba-trust-md5-scram.txt | PG trust/md5(scram)/错误密码/缺密码/角色来源解耦 |

相关资产：`study_record/pg-mysql-map.md`、`study_record/runbook/mysql-dba-cheatsheet.md`、`study_record/troubleshooting/CASE-001-login-failed.md`
