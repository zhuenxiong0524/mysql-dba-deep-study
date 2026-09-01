# CASE-001 登录失败：ERROR 1045 (28000) Access denied

> 状态：✅ 已完成（2026-09-01 实跑）
> 关联：ENV-004（Account 模型）/ ENV-007（登录与认证）
> 证据：`study_record/troubleshooting/evidence/case001-login-failed-mysql.txt`、`case001-002-pg-comparison.txt`
> 环境：MySQL 8.4.10 @3306（socket /tmp/mysql.sock）；PG 18.4 @54184（对照）

## 现象

- `mysql -u<user> -p ...` 直接报错退出，登录不进去
- 错误码统一为 `ERROR 1045 (28000): Access denied for user 'xxx'@'host' (using password: YES/NO)`
- 注意：**密码错、账号不存在、host 不匹配三种根因的错误文本完全相同**，只靠 `'user'@'host'` 中的 host 与 `using password:` 提示区分方向

## 告警/错误（本机实跑）

```text
# 1) 密码错误
ERROR 1045 (28000): Access denied for user 'lab_case001'@'localhost' (using password: YES)

# 2) 用户不存在
ERROR 1045 (28000): Access denied for user 'nobody_user'@'localhost' (using password: YES)

# 3) host 不匹配：Account 是 lab_case001@localhost，但走 TCP 127.0.0.1
ERROR 1045 (28000): Access denied for user 'lab_case001'@'127.0.0.1' (using password: YES)
```

## 第一步检查：读错误文本里的 `'user'@'host'`

- `@` 前的 user：如果是你**没建过的名字** → 账号不存在（`mysql.user` 里没有）
- `@` 后的 host：和连接方式对不上 → host 不匹配
  - 用 socket 连 → 匹配 `localhost`（或 `%`）
  - 用 `-h 127.0.0.1` 连 → 匹配 `127.0.0.1` / `%`，**不匹配** `localhost`
  - 用局域网 IP 连 → 匹配具体 IP / 网段 / `%`
- `using password: YES` 但密码确实对 → 转向账号/plugin 检查

## 第二步检查：账号与授权

```sql
-- 账号是否存在、匹配哪个 host、用哪个认证插件
SELECT user, host, plugin FROM mysql.user WHERE user LIKE '目标%';
-- 账号实际权限
SHOW GRANTS FOR 'user'@'host';
```

本机实测（socket 正确密码 + 匹配 host）：

```text
USER()            CURRENT_USER()
lab_case001@localhost  lab_case001@localhost
```

- `USER()` = 客户端声称的身份；`CURRENT_USER()` = 服务端实际匹配到的 Account
- 两者不一致 = 命中了 `%` 或通配 host

## 根因

1. 密码错误（最常见）：`ALTER USER 'u'@'h' IDENTIFIED BY '...'` 或登录命令打错
2. 账号不存在：`CREATE USER 'u'@'h' IDENTIFIED BY '...'`（注意 host 也要匹配连接来源）
3. host 不匹配：账号 host 与连接来源 IP/socket 对不上
   - 本机 `skip-name-resolve=ON`：TCP 连接按 **IP 字面量** 匹配 host（`localhost` 匹配不到 `127.0.0.1`）
4. 认证插件不匹配：`plugin` 列与客户端能力不符（本机默认 `caching_sha2_password`）

## 处理

```sql
-- 密码错 → 重置密码
ALTER USER 'lab_case001'@'localhost' IDENTIFIED BY 'newpass';
-- 账号不存在 → 建号（host 按连接来源选 localhost / 127.0.0.1 / %）
CREATE USER 'lab_case001'@'localhost' IDENTIFIED BY 'pass001';
-- host 不匹配 → 建匹配来源的账号，或统一用 %
CREATE USER 'lab_case001'@'%' IDENTIFIED BY 'pass001';
```

## 验证恢复

```sql
mysql -ulab_case001 -ppass001 -S /tmp/mysql.sock -e "SELECT USER(), CURRENT_USER();"
-- 能返回结果即恢复
```

## PG 对照（同实验两边跑）

| 场景 | PostgreSQL 18.4 | MySQL 8.4 |
|---|---|---|
| 角色/账号不存在 | `FATAL: role "nobody_user" does not exist` | `ERROR 1045 ... user 'nobody_user'@'localhost'` |
| 密码错误 | `FATAL: password authentication failed for user ...` | `ERROR 1045 ... (using password: YES)` |
| 来源/认证 | pg_hba.conf 决定认证方式，**角色与来源解耦**（trust/md5/scram 按连接行匹配） | host 是 Account 身份的一部分（`user@host` 二元组），无匹配 Account 即 1045 |
| 身份查询 | `current_user / session_user` | `USER() / CURRENT_USER()` |

PG 的关键差异：PG 里"用户"是全局唯一对象，连接来源由 `pg_hba.conf` 单独控制；MySQL 里 **host 直接焊死在账号里**，同一用户名不同 host 是不同账号。这是 1045 排查看起来最"绕"的地方。

## 生产经验

1. 1045 排查顺序固定：**看错误文本 host → 查 `mysql.user` → 对连接方式 → 查密码/plugin**，不要一上来就重置密码
2. `localhost` 与 `127.0.0.1` 是两个不同 host：应用走 socket/TCP 要各自建账号或统一 `%`
3. 本机 root 是"仅 socket 空密码"，`mysql -uroot`（socket）能连，`-h 127.0.0.1` 连不上 = 无匹配 Account（ENV-004 EXP16 验证）
4. 生产规范：不用 root 直连应用，建强口令账号 + login-path（ENV-007 展开）
