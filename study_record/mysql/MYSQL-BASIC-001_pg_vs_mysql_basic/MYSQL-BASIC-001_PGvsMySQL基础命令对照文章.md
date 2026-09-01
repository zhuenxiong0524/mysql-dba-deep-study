# PostgreSQL DBA 学 MySQL：基础命令与核心概念对照

> 版本：v1.0（2026-08-27，实机验证于 1C/2G 学习机）
> 基线：PostgreSQL 18.4（端口 54184）→ 目标：MySQL 8.4.10 LTS（端口 3306）
> 方法：PG 已知做法 → MySQL 对应能力 → 实机命令验证 → 行为差异分析 → DBA 视角总结
> 所有关键命令均在本机真实执行，输出存档于 `evidence/`，文章只保留关键片段（多余输出以 `...` 省略）

---

## 1. 为什么以 PostgreSQL 为参照学习 MySQL

我已经熟悉 PG 的 DBA 操作（进程模型、`pg_stat_activity`、`pg_settings`、role 权限模型、事务与 DDL 语义），
如果按 MySQL 教程从零学，会重复记忆大量"看起来一样、其实不一样"的东西。

本对照实验的核心是回答两个问题：

1. **MySQL 里应该怎么做？**（命令翻译）
2. **它只是语法不同，还是数据库架构和行为本身就不同？**（本质差异）

本文所有结论来自同一台机器上的真实执行，不使用假设输出。

---

## 2. 实验环境

### 2.1 Linux 与资源

```text
OS:      Debian GNU/Linux 11 (bullseye)
Kernel:  Linux node01 5.10.0-38-amd64
CPU:     1 核
内存:    1935MB（实验时无 swap，swap=0 → 环境检查 WARN）
```

### 2.2 PostgreSQL 18.4

```text
服务端版本: PostgreSQL 18.4 on x86_64-pc-linux-gnu (gcc 10.2.1)
客户端版本: psql (PostgreSQL) 18.4
监听端口:   54184 (0.0.0.0 + ::)
数据目录:   /data/pgdata/pgdata18.4（ps -ef 中 -D 参数确认；非超管无法从 pg_settings 读取 data_directory）
配置文件:   非超管不可见（pg_settings 中 config_file/hba_file 需超管）
字符集:     server_encoding=UTF8；数据库级 lc 见 pg_database（en_US.UTF-8）
时区:       TimeZone=Asia/Shanghai；standard_conforming_strings=on
认证(hba):  local/127.0.0.1/::1 = trust；192.168.101.0/24 = md5
```

> PG 18 注意：`lc_collate`/`lc_ctype` 已不再是 GUC（`SHOW lc_collate` 报 `unrecognized configuration parameter`），
> 需查 `pg_database` 的 `datcollate`/`datctype`。

### 2.3 MySQL 8.4.10

```text
服务端版本: 8.4.10 (Source distribution)
客户端版本: mysql Ver 8.4.10 for Linux on x86_64
监听端口:   3306（另 33060 为 X Protocol）
数据目录:   /data/myhome/mydata/mysql
配置文件:   /etc/my.cnf（datadir/port/socket/innodb_buffer_pool_size=64M/performance_schema=OFF/skip-name-resolve/max_connections=100/character_set_server=utf8mb4）
字符集:     character_set_server=utf8mb4, collation_server=utf8mb4_0900_ai_ci
时区:       time_zone=SYSTEM（system_time_zone=CST，UTC 差 +08:00）
认证:       全部账号 caching_sha2_password；authentication_policy='*,,'；root@localhost 空密码
```

> MySQL 8.4 注意：`default_authentication_plugin` 变量已被移除（`Unknown system variable`），
> 认证策略由 `authentication_policy` 控制——迁移 5.7/8.0 旧文档时不要照抄。

### 2.4 统一实验对象

```text
database:      db_compare（PG / MySQL 各建一个）
user:          compare_user（PG role；MySQL 'compare_user'@'localhost' / @'127.0.0.1' / @'%'）
table:         t_user（id/name/age/created_at/status/amount/is_vip）
实验密码:      Compare#2026x（文中统一以 ****** 代替）
```

---

## 3. 客户端与数据库连接

### 3.1 PostgreSQL

```bash
psql -h 127.0.0.1 -p 54184 -U mysql -d mysql -c "SELECT 'ok';"
```

实机输出：

```text
PG 连接成功: host=127.0.0.1 port=54184 user=mysql db=mysql
```

- `-h` host、`-p` port、`-U` user、`-d` database，四个参数齐全才指得清连接目标。
- **默认行为**：无参数的 `psql` 走 Unix socket `/tmp/.s.PGSQL.5432`，用户=OS 用户、库=OS 用户名。
  本机实例在 54184，所以裸 `psql` 实测报错：

```text
psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed: No such file or directory
```

- **密码处理**：由 `pg_hba.conf` 决定。本机 `127.0.0.1/32 trust`，`\conninfo` 中 `Password Used: false`；
  192.168.101.0/24 网段是 `md5`，那里才需要口令。

### 3.2 MySQL

```bash
mysql -h HOST -P PORT -u USER -p
```

实机验证（注意：`mysql` 不在 PATH，需全路径或加入 PATH）：

```text
# 默认 mysql（无参数）：socket /tmp/mysql.sock，以 OS 用户身份登录
$ mysql -e "SELECT 1;"
1                                            ← 本机居然连上了！

# 查看到底是谁
$ mysql -Nse "SELECT USER(), CURRENT_USER(), DATABASE();"
root@localhost   root@localhost   NULL
```

> 本机 OS 用户是 mysql，但默认连接实际以 `root@localhost` 连上（root 空密码）。这是因为客户端默认用户解析
> + 本机 root 空密码 + socket 直连的组合。生产环境不要依赖这种"默认"。

- **socket vs TCP**：`mysql -uroot`（无 `-h`）走 socket 成功；`mysql -h 127.0.0.1 -u root` 实测失败：

```text
ERROR 1045 (28000): Access denied for user 'root'@'127.0.0.1' (using password: NO)
```

  原因：`skip-name-resolve` 开启时，TCP 来源按 IP 匹配账号，只有 `root@localhost` 没有 `root@127.0.0.1`。

### 3.3 核心差异（连接）

| 维度 | PostgreSQL | MySQL |
|---|---|---|
| 参数 | `-h -p -U -d` | `-h -P -u -p`（注意端口大写 `-P`） |
| 库参数 | `-d database` 必选/可选 | 无 `-d` 也能连，进库后再 `USE` |
| 默认连接 | socket 5432，报错直接失败 | socket /tmp/mysql.sock，可能以 root 空密码连上 |
| 认证点 | `pg_hba.conf`（trust/scram/md5） | 账号自带认证插件（caching_sha2_password） |
| 密码提示 | 视 hba 而定，可能完全不要 | 有密码就 `-p`，否则提示 |

等价程度：**B（语法不同，概念基本相同）**，但"默认连接行为"差异很大（PG 裸连必失败 vs MySQL 裸连可能意外连上）。

### 3.4 查看版本

```bash
psql --version                 # psql (PostgreSQL) 18.4
SELECT version();              # PostgreSQL 18.4 on x86_64-pc-linux-gnu ...

mysql --version                # mysql Ver 8.4.10 for Linux on x86_64 (Source distribution)
SELECT VERSION();              # 8.4.10
```

DBA 必须区分 **Server Version** 与 **Client Version**：排查问题时客户端旧/服务端新会造成"语法不支持"误判；
MySQL 尤其如此（8.0 之后功能随小版本快速变化，如 `EXPLAIN ANALYZE` 需 8.0.18+）。

### 3.5 查看当前连接信息

PostgreSQL：

```sql
\conninfo
SELECT current_database(), current_user, session_user, inet_server_addr(), inet_server_port(), pg_backend_pid();
```

实机输出：

```text
 Database | mysql | Client User | mysql | Host | 127.0.0.1 | Server Port | 54184
 Backend PID | 4635 | Password Used | false
 current_database=mysql current_user=mysql session_user=mysql server_addr=127.0.0.1/32 server_port=54184
```

MySQL 对应：

```sql
SELECT CONNECTION_ID(), USER(), CURRENT_USER(), DATABASE(), @@hostname, @@port, VERSION();
```

实机输出：

```text
id  user_fn               cur_user              cur_db   hostname  port  sock              version
22  root@localhost        root@localhost        NULL     node01    3306  /tmp/mysql.sock   8.4.10
```

关键差异：

- PG 用 `pg_backend_pid()`（进程号）；MySQL 用 `CONNECTION_ID()`（连接号，不是 OS pid）。
- PG 有 `current_user` vs `session_user`；MySQL 有 `USER()`（客户端声称的身份）vs `CURRENT_USER()`（实际匹配到的账号）。
- MySQL 没有 `inet_server_addr()` 的直接对应，用 `@@hostname`（服务器主机名，不是客户端地址）。

### 3.6 MySQL 账号匹配（`'user'@'host'` 模型）

实机演示：同一用户 `compare_user` 建了三个账号 `@localhost` / `@127.0.0.1` / `@%`，不同来源匹配不同账号：

```text
# socket 连接
USER()=compare_user@localhost    CURRENT_USER()=compare_user@localhost
# TCP 回环 127.0.0.1
USER()=compare_user@127.0.0.1    CURRENT_USER()=compare_user@127.0.0.1
# 本机局域网 IP 192.168.101.129
USER()=compare_user@192.168.101.129  CURRENT_USER()=compare_user@%
```

这就是 PG 里不存在的概念：**PG 角色是全局的，MySQL 账号是 (user, host) 二元组**，
`%` 是通配主机。权限、密码全部挂在二元组上。

> 实验插曲：`mysql -h 127.0.0.2` 连接时 `USER()` 仍显示 `127.0.0.1`——因为本机连 127.0.0.2 时
> 内核选的源地址就是 127.0.0.1，服务端看到的来源确实是 127.0.0.1。MySQL 源码中对回环地址的处理
> 见 `sql/hostname_cache.cc` 的 `is_ip_loopback()`（仅精确匹配 127.0.0.1/::1）。不要误读为"服务端把整个 127/8 归一化"。

等价程度：**C（表面相似，底层模型不同）**。PG role 没有 host 维度；MySQL 没有 role 的"全局性"。

---

## 4. Database 与 Schema（本文重点之一）

### 4.1 数据库列表

```sql
-- PG
\l
SELECT datname FROM pg_database;
```

```sql
-- MySQL
SHOW DATABASES;
SHOW SCHEMAS;          -- 结果与 SHOW DATABASES 完全一致
```

实机结果（MySQL）：

```text
Database
cmp
db_compare
information_schema
mysql
performance_schema
sys
```

> MySQL 的 `information_schema`/`performance_schema`/`sys` 是"虚拟数据库"，不是真实数据目录。

### 4.2 创建/删除数据库

PostgreSQL：

```sql
CREATE DATABASE db_compare2 OWNER compare_user ENCODING 'UTF8' TEMPLATE template0 CONNECTION LIMIT 5;
DROP DATABASE IF EXISTS db_compare2;
```

MySQL：

```sql
CREATE DATABASE IF NOT EXISTS db_compare2 CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
DROP DATABASE IF EXISTS db_compare2;
```

差异点（实机验证）：

- **PG 不支持 `CREATE DATABASE IF NOT EXISTS`**：实测报 `ERROR: syntax error at or near "NOT"`；MySQL 支持。
- PG 的 `OWNER` / `TEMPLATE` / `CONNECTION LIMIT` / `ENCODING` 在 MySQL **没有直接对应物**：
  MySQL 只有 `CHARACTER SET` / `COLLATE`（等价程度 D：PG 有而 MySQL 无直接对应）。
- 8.4 中 `SHOW CREATE DATABASE db_compare2` 输出还带 `DEFAULT ENCRYPTION='N'`（表空间加密默认关闭）。

### 4.3 MySQL 的 SCHEMA 到底是谁

实机验证：

```sql
CREATE SCHEMA demo_schema;
SHOW DATABASES LIKE 'demo%';
-- 结果：demo_schema 出现在"数据库"列表里！
```

结论：**MySQL 中 `SCHEMA` 就是 `DATABASE` 的同义词**，`CREATE SCHEMA` 与 `CREATE DATABASE` 完全等价，
MySQL 没有 PG 那种 database→schema→table 的三层结构。

层级结构：

```text
PostgreSQL 18.4
Cluster（一个实例、一组进程、一个数据目录）
 └── Database（连接边界，\c 切换即重连）
      └── Schema（命名空间，search_path 决定可见性）
           └── Table

MySQL 8.4
Server Instance
 └── Database / Schema（同一概念的两个名字）
      └── Table
```

### 4.4 "切换数据库"的底层行为不同（本文重点）

PostgreSQL `\c dbname`：实测同一 psql 会话内 backend pid 从 `5007` 变为 `5008` ——

```text
before: db=mysql pid=5007
after:  db=db_compare pid=5008
```

MySQL `USE dbname`：实测 `CONNECTION_ID()` 不变（都是 41），只改变"当前默认数据库"：

```text
cid_before  db_before
41          NULL
cid_after   db_after
41          db_compare
```

本质差异：

- PG 的 database 是**连接边界**：换库必须重新连接（内部会新起 backend）；不同 database 物理隔离。
- MySQL 的 database 只是**命名空间**：`USE` 不新建连接，只是把默认 schema 切走；跨库访问还能用 `db.table` 限定名。

> 对应关系：PG 的 `\c db` ≈ MySQL 的 `USE db` 只是"表面像"（类别 C）。真正与 PG database 等价的
> 隔离单位，在 MySQL 里其实是"实例级"（所有库共享一个 buffer pool、一个数据字典）。

### 4.5 Schema 实验

PG：schema 是独立命名空间，可 `SET search_path` 切换可见性：

```sql
CREATE SCHEMA demo_schema;
\dn
SET search_path TO demo_schema, public;   SHOW search_path;  -- demo_schema, public
```

MySQL：没有独立 schema 概念，没有 `search_path`；"当前 schema"就是 `USE` 选中的 database。

等价程度：**D/E（互相没有直接对应概念）**——PG 的 schema 层在 MySQL 中不存在；MySQL 的 database/schema
二合一，是 PG 里没有的简化。

---

## 5. 表与对象管理

### 5.1 查看表

```sql
-- PG
\dt
\dt+
SELECT table_name FROM information_schema.tables WHERE table_schema='public';
-- MySQL
SHOW TABLES;
SELECT table_name, table_type, engine, table_rows, data_length
FROM information_schema.tables WHERE table_schema='db_compare';
```

实机输出（MySQL）：

```text
TABLE_NAME  TABLE_TYPE  ENGINE  TABLE_ROWS  DATA_LENGTH
t_ddl_test  BASE TABLE  InnoDB  0           16384
t_trunc     BASE TABLE  InnoDB  0           16384
t_user      BASE TABLE  InnoDB  2           16384
```

- PG 习惯：psql 元命令 + `pg_catalog`/`information_schema` 查询。
- MySQL 习惯：`SHOW` 系列命令仍是主流；`information_schema` 也能查，且直接带 `ENGINE`/`TABLE_ROWS`（估算值）。
- MySQL 表没有 owner 概念（归属 database），`SHOW TABLES` 不显示 owner，这与 `\dt` 的 Owner 列不同。

### 5.2 查看表结构

```sql
-- PG
\d t_user
\d+ t_user
-- MySQL
DESC t_user;
DESCRIBE t_user;      -- DESC 的同义词
SHOW COLUMNS FROM t_user;
SHOW CREATE TABLE t_user;
```

实机输出（PG）：

```text
                                Table "public.t_user"
   Column   |           Type           | Collation | Nullable | Default
------------+--------------------------+-----------+----------+------------------------------
 id         | bigint                   |           | not null | generated always as identity
 name       | character varying(50)    |           | not null |
 age        | integer                  |           |          |
 created_at | timestamp with time zone |           |          | now()
 status     | varchar(10)              |           |          | 'active'::character varying
 amount     | numeric(12,2)            |           |          |
 is_vip     | boolean                  |           |          | false
Indexes: "t_user_pkey" PRIMARY KEY, btree (id)
```

实机输出（MySQL `SHOW CREATE TABLE`，最重要的一条）：

```text
CREATE TABLE `t_user` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL,
  `age` int DEFAULT NULL,
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `status` varchar(10) DEFAULT 'active',
  `amount` decimal(12,2) DEFAULT NULL,
  `is_vip` tinyint(1) DEFAULT '0',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
```

`SHOW CREATE TABLE` 对 MySQL DBA 极其重要：它是**唯一能看到完整 DDL 的官方出口**——引擎、字符集、
自增计数器、列注释、外键都在里面。PG 想看完整 DDL 用 `pg_dump --schema-only -t t_user`，两者心智不同：
PG 的 DDL 存在系统目录里可随时重建；MySQL 的表定义虽然也在数据字典，但 `SHOW CREATE TABLE` 是 DBA 的第一工具。

### 5.3 MySQL 没有"整表 DDL"视图的等价物

PG 的 `\d`/`\d+` 一次给出列+索引+约束+存储参数；MySQL 需要 `DESC` + `SHOW INDEX` + `SHOW CREATE TABLE`
组合。等价程度：**B（概念相同，习惯不同）**。

---

## 6. 数据类型与建表

### 6.1 同一语义的建表

```sql
-- PG
CREATE TABLE t_user (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name varchar(50) NOT NULL,
  age integer,
  created_at timestamptz DEFAULT now(),
  status varchar(10) DEFAULT 'active',
  amount numeric(12,2),
  is_vip boolean DEFAULT false
);
```

```sql
-- MySQL
CREATE TABLE t_user (
  id bigint AUTO_INCREMENT PRIMARY KEY,
  name varchar(50) NOT NULL,
  age int,
  created_at datetime DEFAULT CURRENT_TIMESTAMP,
  status varchar(10) DEFAULT 'active',
  amount decimal(12,2),
  is_vip boolean DEFAULT false
);
```

两边 `information_schema.columns` 对比（实机）：

```text
PG:   id bigint | name character varying | age integer | created_at timestamp with time zone | amount numeric | is_vip boolean
MySQL: id bigint | name varchar            | age int     | created_at datetime                  | amount decimal | is_vip tinyint(1)
```

### 6.2 类型差异（PG DBA 需要知道的）

| 类型 | PostgreSQL | MySQL 8.4 | 说明 |
|---|---|---|---|
| 自增整数 | `bigserial` / `GENERATED ... AS IDENTITY` | `AUTO_INCREMENT` | 见 6.3 |
| 字符串 | `varchar(n)`（长度语义一致） | `varchar(n)` | 注意字符集/collation 影响比较与排序（见 7.5） |
| 整数 | `integer`/`bigint` | `int`/`bigint` | 几乎等价 |
| 小数 | `numeric(12,2)` | `decimal(12,2)` | MySQL 中 decimal 是定点数；float/double 是浮点 |
| 时间戳 | `timestamptz`（带时区） | `datetime`（无时区）/ `timestamp`（有时区换算，2038 限制） | **最常见踩坑**：PG 默认习惯 `timestamptz`，MySQL 最常用 `datetime`，两者语义不同 |
| 布尔 | `boolean` | `tinyint(1)`（`BOOLEAN` 只是别名） | 实机 `SHOW CREATE TABLE` 显示 `tinyint(1) DEFAULT '0'` |
| 自增默认值 | 列默认 `nextval(seq)` | `DEFAULT CURRENT_TIMESTAMP` 等 | PG 用函数表达式，MySQL 用字面量/CURRENT_TIMESTAMP |

> 等价程度：**B/C 混合**。`varchar`/`integer`/`decimal` 基本等价；`timestamptz` 与 `datetime`、
> `boolean` 与 `tinyint(1)` 是"表面相似、语义不同"（C）。

### 6.3 自增列：identity / serial / AUTO_INCREMENT（本文重点）

PostgreSQL 两种写法：

```sql
id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY   -- 现代写法
id serial PRIMARY KEY                                 -- 历史写法：自动建序列
```

- `serial` 本质是 `integer DEFAULT nextval('t_serial_id_seq')`，序列是**独立数据库对象**，可查 `pg_sequences`：

```text
t_user_id_seq last_value=2
```

- `GENERATED ALWAYS AS IDENTITY` 不允许手插 id（除非 `OVERRIDING SYSTEM VALUE`），更严格。

MySQL：

```sql
id bigint AUTO_INCREMENT PRIMARY KEY
```

- 没有独立序列对象；计数器存在**表元数据**里（`SHOW TABLE STATUS` 的 `Auto_increment: 3` 列，实机验证）。
- 取"刚插入的 id"用 `LAST_INSERT_ID()`（连接级，实机返回 1）；PG 用 `INSERT ... RETURNING id` / `currval()`。

```text
PG:   INSERT INTO t_user(...) RETURNING id;   → 1
MySQL: INSERT INTO t_user(...); SELECT LAST_INSERT_ID();  → 1
```

> 等价程度：**C（表面相似，本质不同）**。不要把 AUTO_INCREMENT 简单理解为 sequence：
> 没有 nextval/currval、没有独立对象、跨表无法共享；反过来 MySQL 的 INSERT 单语句多行只返回
> 第一个 id（`LAST_INSERT_ID()` 语义与 PG 的 `RETURNING` 不同）。MySQL 8.0 起 `innodb_autoinc_lock_mode=2`
> 使自增值不保证连续——"按 id 连续"的假设两边都要放弃。

---

## 7. 数据增删改查

### 7.1 INSERT / UPDATE / DELETE 的输出差异

PG 实机（连"值没变化"的 UPDATE 也是 `UPDATE 1`）：

```text
INSERT 0 1
UPDATE 1     -- UPDATE t_user SET age=age+1 ...
UPDATE 1     -- UPDATE t_user SET age=age ...（值没变，PG 仍报 1）
DELETE 1
```

MySQL 区分"匹配行"与"实际修改行"（`-vv` 模式才显示完整信息）：

```text
Query OK, 1 row affected
Rows matched: 1  Changed: 1  Warnings: 0

Query OK, 0 rows affected
Rows matched: 1  Changed: 0  Warnings: 0   -- 值没变时 Changed=0！
```

差异：

- PG：`UPDATE n` / `DELETE n` 按**受影响行**计数，非交互脚本里直接可读。
- MySQL：批处理模式默认只显示 `Query OK`（"affected"=Changed 数），`Rows matched/Changed` 要 `-vv` 才显示。
  影响行数语义也不一致——MySQL 的 affected 在"值未变化"时是 0，在 JDBC `getUpdateCount()` 这类场景会有坑。

### 7.2 SELECT 基础

```sql
SELECT * FROM t_user WHERE age>=25 ORDER BY id DESC LIMIT 10 OFFSET 0;
SELECT DISTINCT status FROM t_user ORDER BY status;
SELECT status, count(*) FROM t_user GROUP BY status HAVING count(*)>=1;
```

两边语法基本一致。MySQL 默认 `sql_mode` 含 `ONLY_FULL_GROUP_BY`（实机确认），
所以 `SELECT 非分组列 FROM t GROUP BY x` 会报错，和 PG 行为对齐了（旧 MySQL 的宽松 GROUP BY 已不是默认）。

### 7.3 LIMIT / OFFSET（语法差异实锤）

```sql
-- 两边都支持
SELECT id FROM t_user ORDER BY id LIMIT 1 OFFSET 1;

-- 仅 MySQL 支持
SELECT id FROM t_user ORDER BY id LIMIT 1,1;      -- LIMIT offset, count

-- PG 实测报错：
ERROR:  LIMIT #,# syntax is not supported
HINT:  Use separate LIMIT and OFFSET clauses.
```

> 迁移 SQL 时 `LIMIT 20,10` 这类老 MySQL 写法要改成 `LIMIT 10 OFFSET 20`（类别 B）。

### 7.4 NULL 行为

```sql
SELECT NULL=NULL, NULL IS NULL, NULL IS NOT NULL;
-- 两边：NULL=NULL 结果都是 NULL（未定义），IS NULL 为 1/true
SELECT count(*) FROM t_user WHERE NULL=NULL;   -- 两边都是 0
```

MySQL 独有 NULL-safe 等值比较 `<=>`：

```sql
SELECT NULL<=>NULL;   -- 1
```

PG 对应的是 `IS NOT DISTINCT FROM`。行为一致，语法不同（类别 B）。

### 7.5 字符串：`||`、LENGTH、大小写（全是坑）

实机验证（MySQL 默认 sql_mode）：

```text
sql_mode = ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,
           ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
SELECT 'hello'||' '||'world';   → 0        ← || 是逻辑 OR，不是拼接！
SELECT CONCAT('a','b','c');     → abc
SELECT LENGTH('中文');          → 6        ← 字节数
SELECT CHAR_LENGTH('中文');     → 2        ← 字符数
SELECT 'abc'='ABC';             → 1        ← collation utf8mb4_0900_ai_ci 不区分大小写！
```

对照 PG：

```text
SELECT 'hello'||' '||'world';   → hello world   （|| 是拼接）
SELECT length('中文');          → 2             （字符数）
SELECT octet_length('中文');    → 6             （字节数）
SELECT 'abc'='ABC';             → f             （区分大小写）
```

三条硬结论：

1. **`||` 在 MySQL 里默认是 OR**：`'hello'||' '||'world'` 结果是 `0`。原因是 OR 上下文里
   非数字字符串被转成数值 0（实测 `'hello'+0=0`），于是 `0 OR 0 OR 0 = 0`。除非 `SET sql_mode='PIPES_AS_CONCAT'`，
   否则拼接请用 `CONCAT()`。这是 PG DBA 最容易当场翻车的一条。
2. **`LENGTH()` 在 MySQL 返回字节数**：中文场景必须用 `CHAR_LENGTH()`；PG 的 `length()` 是字符数，`octet_length()` 才是字节数。
3. **大小写比较由 collation 决定**：`utf8mb4_0900_ai_ci` 下 `'abc'='ABC'` 为真，唯一索引同样视为冲突；
   PG 默认区分大小写。这影响**比较、排序、索引命中**三件事，建表选 collation 是 DBA 决策。

等价程度：**C（语法相同名字，行为本质不同）**。

### 7.6 时间函数

```sql
-- PG
SELECT now(), CURRENT_TIMESTAMP, CURRENT_DATE, CURRENT_TIME;
SELECT now() + interval '1 day', now() - interval '2 hour', date_trunc('hour', now());

-- MySQL
SELECT NOW(), CURRENT_TIMESTAMP, CURRENT_DATE, CURTIME(), UTC_TIMESTAMP();
SELECT DATE_ADD(NOW(), INTERVAL 1 DAY), DATE_SUB(NOW(), INTERVAL 2 HOUR), DATE_FORMAT(NOW(),'%Y-%m-%d %H:00:00');
```

实机输出（MySQL）：

```text
now                   cur_ts                cur_date    cur_time   utc
2026-08-27 09:41:41   2026-08-27 09:41:41   2026-08-27  09:41:41   2026-08-27 01:41:41
tomorrow              two_hours_ago         trunc_hour
2026-08-28 09:41:41   2026-08-27 07:41:41   2026-08-27 09:00:00
```

差异点：

- interval 语法：PG `interval '1 day'`；MySQL `INTERVAL 1 DAY`（无引号，且要配合 `DATE_ADD/DATE_SUB`）。
- 没有 `date_trunc`：用 `DATE_FORMAT(ts, 格式串)` 代替（类别 D：PG 有、MySQL 无直接对应）。
- `NOW()` 返回**会话时区**的 datetime；`UTC_TIMESTAMP()` 才是 UTC。PG 的 `now()` 返回 timestamptz（内部 UTC、显示按会话时区）。
- MySQL `timestamp` 列有 2038 问题且会随会话时区换算；`datetime` 不做时区换算——生产环境先想清楚用哪个。

---

## 8. 索引

### 8.1 查看索引

```sql
-- PG
\di
SELECT indexname, indexdef FROM pg_indexes WHERE tablename='t_user';
-- MySQL
SHOW INDEX FROM t_user;
SELECT index_name, seq_in_index, column_name, non_unique, index_type
FROM information_schema.statistics WHERE table_schema='db_compare' AND table_name='t_user';
```

实机输出（PG）：

```text
idx_t_user_age | CREATE INDEX idx_t_user_age ON public.t_user USING btree (age)
t_user_pkey    | CREATE UNIQUE INDEX t_user_pkey ON public.t_user USING btree (id)
uq_t_user_name | CREATE UNIQUE INDEX uq_t_user_name ON public.t_user USING btree (name)
```

实机输出（MySQL `SHOW INDEX`，列名是 MySQL 特有）：

```text
Key_name        Seq_in_index  Column_name  Non_unique  Index_type
PRIMARY         1             id           0           BTREE
uq_t_user_name  1             name         0           BTREE
```

MySQL 的索引是**表内对象**（`Key_name` 在表内唯一），PG 的索引是**独立 schema 对象**
（全 schema 内唯一，`\di` 单独列出）。`Non_unique=0` 表示唯一索引。

### 8.2 创建 / 删除索引

```sql
-- 两边相同
CREATE INDEX idx_t_user_age ON t_user(age);
CREATE UNIQUE INDEX uq_t_user_name ON t_user(name);

-- 删除：语法不同！
DROP INDEX idx_t_user_age;            -- PG
DROP INDEX idx_t_user_age ON t_user;  -- MySQL（必须带 ON 表名）
```

MySQL 不带 `ON` 实测报错：

```text
ERROR 1064 (42000): ... near '' at line 1
```

> 类别 B：功能相同、语法不同。另外 MySQL 在 InnoDB 里索引类型只有 BTREE（主键即聚簇索引），
> 没有 PG 的 GIN/GiST/BRIN 等（差异点清单见后续专题）。

---

## 9. 用户与权限

### 9.1 查看用户

```sql
-- PG
\du
SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolcanlogin FROM pg_roles;
-- MySQL
SELECT user, host, plugin FROM mysql.user;
```

实机输出（PG）：

```text
  Role name   |                         Attributes
--------------+------------------------------------------------------------
 compare_user |
 mysql        |
 postgres     | Superuser, Create role, Create DB, Replication, Bypass RLS
```

实机输出（MySQL）：

```text
user           host       plugin
compare_user   %          caching_sha2_password
compare_user   127.0.0.1  caching_sha2_password
compare_user   localhost  caching_sha2_password
root           localhost  caching_sha2_password
```

### 9.2 模型差异：role vs 'user'@'host'（本文重点）

- PG：**role 全局唯一**。能不能登录只是 `LOGIN` 属性；`CREATE USER` 就是 `CREATE ROLE ... LOGIN` 的别名
  （实机验证：`CREATE USER cmp_demo PASSWORD '******'` 后 `\du` 出现新角色）。
- MySQL：**账号是 (user, host) 二元组**。`compare_user@localhost` 和 `compare_user@%` 是两个不同账号，
  各自有独立密码和权限；连接时按来源 IP 精确匹配最具体的账号（见 3.6）。

```text
root@localhost      ← 只能 socket/本机（hba 语义里"本机"）
user@%              ← 任何主机
user@192.168.%      ← 网段通配（生产常用）
```

### 9.3 创建用户与密码

```sql
-- PG
CREATE USER compare_user LOGIN PASSWORD '******';
-- MySQL
CREATE USER 'compare_user'@'localhost' IDENTIFIED BY '******';
```

- PG 密码认证方式由 hba + `password_encryption` 决定（scram-sha-256 默认）。
- MySQL 8.4 全部账号默认 `caching_sha2_password`（比 mysql_native_password 更安全，但部分老客户端不兼容，
  这是"客户端版本与服务端认证兼容性"排查点）。

### 9.4 GRANT / REVOKE / SHOW GRANTS

```sql
-- PG
GRANT SELECT ON t_user TO cmp_demo;
REVOKE SELECT ON t_user FROM cmp_demo;
-- 查看：\dp t_user

-- MySQL
GRANT SELECT ON db_compare.t_user TO 'cmp_demo'@'localhost';
REVOKE SELECT ON db_compare.t_user FROM 'cmp_demo'@'localhost';
SHOW GRANTS FOR 'cmp_demo'@'localhost';
```

实机输出（MySQL）：

```text
GRANT USAGE ON *.* TO `cmp_demo`@`localhost`
GRANT SELECT ON `db_compare`.`t_user` TO `cmp_demo`@`localhost`
```

差异：

- MySQL 的授权是**分层级**的：`*.*`（全局）→ `db.*`（库级）→ `db.table`（表级）→ 列级。
  `USAGE` 是"只有登录权限"的占位授权。
- PG 的授权默认作用于表级，角色成员关系用 `GRANT role TO role`。
- **不能把 PG role 模型直接套到 MySQL**：PG 里"把角色授予用户"是继承权限，MySQL 里要
  `GRANT role TO user` + `SET DEFAULT ROLE`（8.0 引入的角色功能，与 PG 的 role 语义仍不同）。

等价程度：**C（名字相同，模型不同）**。

---

## 10. Session 与进程（活跃会话）

### 10.1 查看当前会话

```sql
-- PG
SELECT pid, usename, datname, client_addr, state, wait_event_type, wait_event, query
FROM pg_stat_activity WHERE datname='db_compare';
-- MySQL
SHOW PROCESSLIST;
SHOW FULL PROCESSLIST;                     -- 显示完整 SQL
SELECT id, user, host, db, command, time, state, info FROM information_schema.PROCESSLIST;
```

实机输出（MySQL，P_S 关闭时仍可用）：

```text
Id  User             Host          db        Command  Time  State        Info
5   event_scheduler  localhost     NULL      Daemon   1247  Waiting on empty queue  NULL
69  root             localhost     NULL      Query    0     init         SHOW PROCESSLIST
```

**本环境重要事实**：`performance_schema=OFF`（my.cnf 为省内存关闭）。此时：
- `SHOW PROCESSLIST` / `information_schema.PROCESSLIST` 正常可用；
- `performance_schema.threads`、`sys` schema 大部分表不可用（监控脚本会报 `Table 'performance_schema.threads' doesn't exist`）。
  生产环境要跑 P_S 监控，必须 `performance_schema=ON`（需重启）。

### 10.2 等待事件：两个引擎都在"等待什么"

同一实验（各自跑一个 60 秒的睡眠查询），两边视角：

PG（超管视角）：

```text
 pid  |   usename    | state  | wait_event_type | wait_event | query
 6398 | compare_user | active | Timeout         | PgSleep    | SELECT pg_sleep(60);
```

MySQL：

```text
id  user          command  time  state       info
71  compare_user  Query    2     User sleep  SELECT SLEEP(60)
```

- PG：`wait_event_type=Timeout, wait_event=PgSleep`；MySQL：`state='User sleep'`。
- 概念对应：PG `wait_event` ≈ MySQL `STATE` 列（等待原因），但 MySQL 更细的等待事件在 P_S 的
  `events_waits_*` 里（本环境关闭）。

### 10.3 一个必须知道的 PG 限制（实测）

非超管查 `pg_stat_activity` 时，**其他用户的 query/state 列显示 `<insufficient privilege>`**：

```text
 pid  |   usename    | state | wait_event_type | wait_event | left
------+--------------+-------+-----------------+------------+--------------------------
 6398 | compare_user |       |                 |            | <insufficient privilege>
```

MySQL 侧对应：普通用户 `SHOW PROCESSLIST` 只看到自己；有 `PROCESS` 权限才能看全部。

### 10.4 Kill 会话

```sql
-- PG：用 backend pid
SELECT pg_terminate_backend(6398);     -- 返回 t
-- MySQL：用 connection id
KILL 71;
```

实机验证：

```text
PG:   pg_terminate_backend(6398) → t
MySQL: KILL 71 → 之后 information_schema.PROCESSLIST 中 compare_user 会话数为 0
```

- PG 的"会话标识"是**进程号**（ps 里能看到对应 postgres 进程）；MySQL 的 connection id 是**连接号**
  （不是 OS pid，ps 里看不到对应关系）。
- 权限：PG 终止别人会话需要超管/`pg_signal_backend`；MySQL `KILL` 需要 `CONNECTION_ADMIN`/`SUPER`。

---

## 11. 参数配置

### 11.1 查看

```sql
-- PG
SHOW ALL;
SELECT name, setting, unit, context FROM pg_settings WHERE name IN ('work_mem','shared_buffers','max_connections');
-- MySQL
SHOW VARIABLES;
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SELECT @@global.innodb_buffer_pool_size/1024/1024 AS buf_pool_mb;
```

实机输出：

```text
PG:    work_mem=4096(kB) shared_buffers=16384(8kB) max_connections=100
MySQL: innodb_buffer_pool_size=67108864 (64MB) max_connections=100 autocommit=ON
```

概念映射：`pg_settings` ↔ MySQL **system variables**（GLOBAL/SESSION 两级）。

### 11.2 MySQL 变量的三级读写（与 PG 不同）

MySQL 变量有 **GLOBAL / SESSION** 之分，还分"变量本身是否 session 可写"：

```sql
SET SESSION group_concat_max_len = 2048;
SELECT @@session.group_concat_max_len, @@global.group_concat_max_len;   -- 2048 | 1024
```

实机踩坑：`innodb_buffer_pool_size` 是 **GLOBAL-only**，用 `@@session` 读直接报错：

```text
ERROR 1238 (HY000): Variable 'innodb_buffer_pool_size' is a GLOBAL variable
```

PG 侧 `SET work_mem='8MB'` 是会话级，`RESET work_mem` 还原（实机验证 8MB→4MB），没有"全局变量"
这套双轨体系（PG 的 `ALTER SYSTEM` 是改配置文件 + `pg_reload_conf()`）。

### 11.3 SET PERSIST / PERSIST_ONLY（8.0+）

- `SET GLOBAL`：只影响新会话，**重启丢失**。
- `SET PERSIST`：改全局 + 写入 `mysqld-auto.cnf`，**重启保留**。
- `SET PERSIST_ONLY`：只写配置文件，立即值不变，下次启动生效。
- `RESET PERSIST`：清掉持久化项。

实机安全演示（用完即清，不留痕迹）：

```bash
SET PERSIST_ONLY max_connections = 100;   # 生成 mysqld-auto.cnf（174 字节）
RESET PERSIST max_connections;            # 文件缩为 14 字节（空 JSON {}）
```

> PG 对照：`ALTER SYSTEM SET ...` + `SELECT pg_reload_conf()`。MySQL 8.0 的 PERSIST 机制在"细粒度、免 reload"
> 上比 `ALTER SYSTEM` 更接近"配置即代码"，但也更容易留下意外持久化——`RESET PERSIST` 是必备操作。

---

## 12. 事务（含 DDL 事务性，本文重点）

### 12.1 autocommit 的默认行为

```sql
-- PG：没有 autocommit 参数（实机报错）
SHOW autocommit;
```

真实输出：

```text
ERROR:  unrecognized configuration parameter "autocommit"
```

PG 的 autocommit 是隐式约定（每个语句自动提交，除非显式 BEGIN）；MySQL 有真实参数 `@@autocommit=1`（默认开）：

```sql
SELECT @@autocommit;
SET autocommit=0;
SELECT @@autocommit;
```

真实输出：

```text
@@autocommit
1
@@autocommit
0
```

### 12.2 BEGIN / COMMIT / ROLLBACK（DML）

```sql
-- 两边等价
BEGIN; INSERT INTO t_user(name,age) VALUES ('rollback_test',99); ROLLBACK;
BEGIN; INSERT INTO t_user(name,age) VALUES ('commit_test',99); COMMIT;
```

PG 侧真实输出（回滚后行数 0、提交后能查到）：

```text
BEGIN
INSERT 0 1
ROLLBACK
0
BEGIN
INSERT 0 1
COMMIT
commit_test
```

MySQL 侧真实输出（同样回滚后 0 行、提交后能查到）：

```text
cnt
0
name
commit_test
```

实机结论：**DML 事务语义一致**（InnoDB 与 PG 堆表都支持 MVCC 回滚）。

### 12.3 DDL 是否可回滚（实测，重点中的重点）

```sql
-- PG：DDL 是事务性的！
BEGIN; CREATE TABLE t_ddl_test(id int PRIMARY KEY); ROLLBACK;
```

真实输出（回滚后 `\dt` 无 t_ddl_test，`pg_tables` 计数 = 0）：

```text
ROLLBACK
              List of tables
 Schema |   Name   | Type  |    Owner
--------+----------+-------+--------------
 public | t_serial | table | compare_user
 public | t_user   | table | compare_user
(2 rows)
```

```sql
-- MySQL：DDL 隐式提交，不可回滚！
START TRANSACTION; CREATE TABLE t_ddl_test(id INT PRIMARY KEY); ROLLBACK;
SHOW TABLES LIKE 't_ddl_test';
```

真实输出（回滚后表还在，计数 = 1）：

```text
Tables_in_db_compare (t_ddl_test)
t_ddl_test
```

TRUNCATE 同样（两边真实输出）：

```text
PG:    BEGIN; TRUNCATE t_trunc; ROLLBACK;   → 行数 1（回滚成功）
MySQL: START TRANSACTION; TRUNCATE t_trunc; ROLLBACK; → 行数 0（TRUNCATE 隐式提交）
```

> 对 PG DBA 这是最危险的心智迁移点：**PG 里"先建表、写坏、ROLLBACK"的习惯在 MySQL 里会留下半成品表**。
> 上线脚本必须显式 `DROP TABLE IF EXISTS`/`IF NOT EXISTS`，或先检查存在性。DDL 自动提交也意味着
> `ALTER TABLE` 中途失败可能留下部分变更（MySQL 8.0 的 INSTANT/INPLACE 是另一套机制，后续 ISO 专题）。

---

## 13. EXPLAIN

### 13.1 基础映射

```sql
-- PG
EXPLAIN SELECT * FROM t_user WHERE age > 20;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM t_user WHERE age > 20;
-- MySQL
EXPLAIN SELECT * FROM t_user WHERE age > 20;
EXPLAIN ANALYZE SELECT * FROM t_user WHERE age > 20;   -- 8.0.18+，TREE 格式
EXPLAIN FORMAT=JSON SELECT ...;
```

实机输出：

```text
PG:
 Seq Scan on t_user  (cost=0.00..1.02 rows=1 width=193)
   Filter: (age > 20)

MySQL:
 id  select_type  table   type  possible_keys  key  key_len  ref  rows  filtered  Extra
 1   SIMPLE       t_user  ALL   NULL           NULL NULL     NULL 3     33.33     Using where

MySQL EXPLAIN ANALYZE:
 -> Filter: (t_user.age > 20)  (cost=0.55 rows=1) (actual time=2.6..2.6 rows=3 loops=1)
     -> Table scan on t_user  (cost=0.55 rows=3) (actual time=2.59..2.6 rows=3 loops=1)
```

### 13.2 差异

- PG：树形输出，有 **cost 估算**（`cost=0.00..1.02`），`EXPLAIN (ANALYZE, BUFFERS)` 给实际时间与 buffer 命中。
- MySQL：默认是**表格式**（type/key/rows 列），没有 cost 列；`EXPLAIN ANALYZE` 才是树形 + 实际时间。
- `rows` 是估算扫描行数；`type=ALL`（全表扫描）、`key=NULL`（没走索引）是 MySQL 排障第一眼看的字段。
- `EXPLAIN FORMAT=JSON` 输出 `query_block`（实机解析得到 `access_type=ALL`、`rows_examined_per_scan=3`）。

> 等价程度：**B（入口相同，输出结构不同）**。**不要**把 PG 的 cost 字段直接映射到 MySQL 的 rows——
> MySQL 没有等价的代价数值（`cost` 只在 FORMAT=TREE/JSON 中局部出现），两者优化器模型不同（后续 OPT 专题）。

---

## 14. Linux DBA 高频命令

### 14.1 进程

```bash
# PG：一连接一进程，一眼看到 postmaster + 各 backend
ps -ef | grep postgres
# 关键行：postgres -D /data/pgdata/pgdata18.4（postmaster），后面是 logger/io worker/checkpointer/background writer...

# MySQL：一连接一线程，进程只有一个 mysqld
ps -ef | grep mysqld
# mysqld_safe（守护）→ mysqld（真正服务，--datadir=... --port=3306）
```

### 14.2 端口

```bash
ss -ltnp | grep 54184    # PG：0.0.0.0:54184
ss -ltnp | grep 3306     # MySQL：*:3306（还有 33060 X Protocol）
```

### 14.3 服务状态

```bash
# PG：pg_ctl status（本机由 postgres 用户以 pg_ctl 启动）
sudo -u postgres /usr/local/pgsql/pgsql18.4/bin/pg_ctl -D /data/pgdata/pgdata18.4 status
# → server is running (PID: 3161)

# MySQL：本机无 systemd 单元！实测：
systemctl status mysqld   # Unit mysqld.service could not be found.
systemctl status mysql    # Unit mysql.service could not be found.
# 实例由 mysql 用户手动 mysqld_safe 启动，日常状态用：
/usr/local/mysql/mysql-8.4.10/bin/mysqladmin -uroot -S /tmp/mysql.sock ping   # mysqld is alive
/usr/local/mysql/mysql-8.4.10/bin/mysqladmin -uroot -S /tmp/mysql.sock status # Uptime/Threads/Questions...
```

> 服务管理差异：PG 源码安装也常见 `pg_ctl` 管理（或 systemd 包装）；MySQL 源码安装默认没有 systemd
> 单元，`mysqld_safe` 是传统守护方式。**不要假设 service name**——先 `systemctl status` / `ps` 确认真实方式。
> 另一个差异：MySQL 默认把 `max_connections` 之外还会有 `mysqlx`（33060）端口，排查端口时注意。

---

## 15. psql 与 mysql 客户端元命令速查

### 15.1 高频对照表

| PostgreSQL `psql` | MySQL `mysql` | 用途 | 实测结论 |
|---|---|---|---|
| `\l` | `SHOW DATABASES` | 数据库列表 | 等价 |
| `\c db` | `USE db` | 切换数据库 | 表面等价，行为不同（见 4.4） |
| `\dt` | `SHOW TABLES` | 表列表 | 等价 |
| `\d table` | `DESC table` | 表结构 | 等价（MySQL 另有 SHOW CREATE TABLE） |
| `\du` | `SELECT user,host FROM mysql.user` | 用户列表 | 模型不同（role vs user@host） |
| `\dp` | `SHOW GRANTS` | 权限 | 语法不同 |
| `\conninfo` | `SELECT CONNECTION_ID(), USER(), ...` | 当前连接 | MySQL 无单条元命令 |
| `\x` | `\G` | 纵向显示 | 行为类似，语法不同 |
| `\q` | `quit` / `\q` | 退出 | 等价 |

### 15.2 `\G` 与 `\x` 实测

```bash
# MySQL：语句结尾用 \G 代替分号 → 纵向显示
mysql -e "SELECT * FROM t_user WHERE id=1\G"
# 输出：*************************** 1. row ***************************
#         id: 1 / name: alice / ...

# 一个语句里还能混用：...; SELECT ...\G

# PG：\x on 后所有结果纵向显示（-x 一次性开启）
psql -x -c "SELECT * FROM t_user WHERE id=1;"
# 输出：-[ RECORD 1 ]-- id | 1 / name | alice / ...
```

差异：MySQL 的 `\G` 是**逐条语句**控制（想横想纵自己挑）；PG 的 `\x` 是**会话级开关**（开/关/auto）。
`\G` 多用于"一行太长"的排障输出；`\x auto` 则按列数自动切换。

---

## 16. PostgreSQL DBA 学 MySQL 最容易踩的坑

以下全部基于本次实机实验，不是理论清单：

1. **把 MySQL database 当成 PG database**：PG 里换库 = 重连（backend pid 都变）；MySQL 里 `USE` 只是
   换命名空间，连接不变。隔离边界在 PG 是 database，在 MySQL 是"实例 + 账号权限"。
2. **把 MySQL schema 当成 PG schema**：MySQL 没有 schema 层，`CREATE SCHEMA` = `CREATE DATABASE`
   （实测 `demo_schema` 直接出现在数据库列表里）。
3. **认为 `USE db` 等同 `\c db`**：连接 id 不变（实测都是 41），只是切默认库；跨库照样 `db.table` 访问。
4. **忽略 `'user'@'host'` 账户模型**：`root@localhost` 走 TCP 127.0.0.1 直接 `Access denied`；
   `compare_user@%` 才是"所有主机"。USER() 与 CURRENT_USER() 不一样。
5. **默认认为 DDL 可以 rollback**：实测 MySQL `START TRANSACTION; CREATE TABLE; ROLLBACK` 表还在；
   TRUNCATE 同样隐式提交。上线脚本必须显式处理存在性。
6. **把 AUTO_INCREMENT 当成 sequence**：没有独立序列对象、没有 nextval/currval、多行插入只回
   第一个 id、8.0 起不保证连续。需要精确控制时 PG 的 identity/serial 语义更强。
7. **忽略 autocommit**：MySQL 有 `@@autocommit=1` 默认值，连接级可改；PG 没有这个参数，
   但两者"显式 BEGIN 才成事务"的心智是共通的——注意某些驱动（JDBC）默认行为差异。
8. **忽略字符集和 collation**：`utf8mb4_0900_ai_ci` 下 `'abc'='ABC'` 为真、唯一索引判重失效、
   排序结果不同。建表不选 collation 等于把默认当决策。
9. **`||` 当拼接符**：MySQL 默认 `||` 是逻辑 OR，字符串会先转数值（'hello'→0），
   `'hello'||' '||'world'` 实测返回 `0`；拼接必须用 `CONCAT()`。
10. **`LENGTH()` 当字符数**：MySQL 返回字节数（'中文'=6），要用 `CHAR_LENGTH()`。
11. **把 `pg_settings` 习惯直接套到 `SHOW VARIABLES`**：MySQL 变量有 SESSION/GLOBAL 两级，
    `@@session.innodb_buffer_pool_size` 直接报 `GLOBAL variable` 错误；PERSIST/PERSIST_ONLY 是 8.0 新增。
12. **把 PG EXPLAIN 字段直接映射 MySQL**：MySQL 默认表格式 EXPLAIN 没有 cost 列，
    看 `type/key/rows/filtered/Extra`；`EXPLAIN ANALYZE` 才有 TREE 实际时间。
13. **监控脚本默认 P_S 可用**：本环境 `performance_schema=OFF`，`performance_schema.threads`、
    `sys` 表直接不存在；生产小内存实例常关 P_S，排障要回退到 `SHOW PROCESSLIST`/`SHOW ENGINE INNODB STATUS`。
14. **`LIMIT 20,10` 直接搬**：PG 报 `LIMIT #,# syntax is not supported`，MySQL 才支持。
15. **非超管也能看全量会话 SQL**：PG 里其他用户的 query 显示 `<insufficient privilege>`；
    MySQL 里要看全量需要 PROCESS 权限。两边都有权限墙，别拿"我看得见"当默认。
16. **裸 `mysql` 连接"意外成功"**：本机 root 空密码 + socket 下裸连成功；生产环境可能反而连不上，
    或连到一个预期外的账号——连接参数（host/port/user/socket）永远写全。

---

## 17. PostgreSQL → MySQL 概念映射总表

| PostgreSQL | MySQL | 等价程度 | 说明 |
|---|---|---|---|
| Cluster / Instance | Server Instance | ⚠️ | 概念接近；PG 实例=数据目录+进程组，MySQL=mysqld |
| Database | Database/Schema | ⚠️ | 名字同，语义不同：PG 是连接边界，MySQL 是命名空间 |
| Schema | （无） | ❌ | MySQL 的 SCHEMA 就是 DATABASE |
| search_path | （无） | ❌ | MySQL 用 USE 的"当前库"代替 |
| `\c db`（重连） | `USE db`（不重连） | ❌ | 连接 id 不变 vs backend pid 变化 |
| Role | User（user@host） | ⚠️ | 模型不同：全局 vs 二元组+通配 |
| `CREATE USER`（=ROLE LOGIN） | `CREATE USER 'u'@'h'` | ⚠️ | 语法像，对象模型不同 |
| GRANT（表级/角色成员） | GRANT（*.* / db.* / db.tbl） | ⚠️ | 授权层级不同 |
| Sequence / identity | AUTO_INCREMENT | ⚠️ | 无独立对象，语义不同 |
| `INSERT ... RETURNING` | `LAST_INSERT_ID()` | ⚠️ | 取新 id 方式不同 |
| `boolean` | `tinyint(1)` | ⚠️ | BOOLEAN 只是别名 |
| `timestamptz` | `datetime` / `timestamp` | ⚠️ | 时区语义不同，timestamp 有 2038 |
| `numeric(12,2)` | `decimal(12,2)` | ✅ | 基本等价 |
| `varchar(n)` | `varchar(n)` | ✅ | 注意 collation |
| `length()`=字符数 | `LENGTH()`=字节数 | ❌ | 中文场景直接翻车 |
| `||` 拼接 | `CONCAT()`（`||`=OR） | ❌ | 默认行为不同 |
| `IS NOT DISTINCT FROM` | `<=>` | ✅ | NULL 安全比较 |
| `interval '1 day'` | `INTERVAL 1 DAY` + DATE_ADD | ⚠️ | 语法不同 |
| `date_trunc()` | `DATE_FORMAT()` | ⚠️ | 无直接等价 |
| `\l` | `SHOW DATABASES` | ✅ | 等价 |
| `\dt` | `SHOW TABLES` | ✅ | 等价 |
| `\d table` | `DESC` / `SHOW CREATE TABLE` | ⚠️ | SHOW CREATE TABLE 是 MySQL 特色 |
| `\du` | `mysql.user` 查询 | ⚠️ | 模型不同 |
| `\x` | `\G` | ⚠️ | 会话开关 vs 语句级 |
| `pg_stat_activity` | `SHOW PROCESSLIST` / P_S.threads | ⚠️ | 列结构完全不同 |
| `pg_terminate_backend(pid)` | `KILL connection_id` | ⚠️ | pid vs 连接号 |
| `pg_settings` / `SHOW ALL` | `SHOW VARIABLES` / `@@var` | ⚠️ | 有 SESSION/GLOBAL 两级 |
| `ALTER SYSTEM` | `SET PERSIST` / `SET PERSIST_ONLY` | ⚠️ | 8.0+ 持久化机制 |
| `BEGIN;...ROLLBACK`（DDL 可回滚） | 隐式提交（DDL 不可回滚） | ❌ | 最重要行为差异之一 |
| autocommit（隐式约定） | `@@autocommit`（真实参数） | ⚠️ | 默认都是自动提交 |
| `EXPLAIN`（cost 树） | `EXPLAIN`（表格式） | ⚠️ | 列结构不同，别硬映射 |
| `pg_catalog` 系统目录 | 数据字典（mysql.ibd + DD API） | ⚠️ | 查询入口不同 |
| `psql` | `mysql` | ⚠️ | 默认连接行为都不同 |

> ✅=基本等价（A） ⚠️=语法/结构不同但概念可映射（B/C） ❌=无直接对应（D/E）
> 至少 30 项映射已覆盖，后续专题（MVCC/ISO/REDO/BUF/IDX/OPT...）会继续细化。

---

## 18. 实验环境清理

实验对象独立于业务库，清理 SQL 如下（本文档暂不执行，供复盘与后续复用）：

```sql
-- PostgreSQL（postgres 超管执行）
DROP DATABASE IF EXISTS db_compare;
DROP ROLE IF EXISTS compare_user;
DROP ROLE IF EXISTS cmp_demo;

-- MySQL（root 执行）
DROP DATABASE IF EXISTS db_compare;
DROP USER IF EXISTS 'compare_user'@'localhost';
DROP USER IF EXISTS 'compare_user'@'127.0.0.1';
DROP USER IF EXISTS 'compare_user'@'%';
DROP USER IF EXISTS 'cmp_demo'@'localhost';
```

> 实验中的临时对象（PG `demo_schema`、`t_serial`、`t_trunc`；MySQL `t_ddl_test`、`t_trunc`）随库删除一并清理。
> 本实验未创建/修改任何业务对象，未 Kill 非实验连接，未修改危险 GLOBAL 参数
> （`SET PERSIST_ONLY` 演示后已 `RESET PERSIST` 清理，`mysqld-auto.cnf` 已还原为空 JSON）。

---

## 19. 本章总结

从"命令翻译"角度看，PG→MySQL 大多数操作都能找到对应；但**行为差异集中在四件事**：

1. **对象模型**：database/schema 层级、role vs user@host、索引归属表内 vs schema 内——"看起来同名，本质不同"。
2. **事务边界**：MySQL DDL/TRUNCATE 隐式提交、autocommit 是真实参数——PG 的"什么都能回滚"心智要主动放弃。
3. **默认值即决策**：`||`=OR、`LENGTH()`=字节、`utf8mb4_0900_ai_ci` 不区分大小写、`AUTO_INCREMENT` 不连续——
   这些默认值决定生产行为，必须知道而不是猜。
4. **监控与配置入口**：`PROCESSLIST` vs `pg_stat_activity`、`SHOW VARIABLES` 的 SESSION/GLOBAL 双轨、
   `performance_schema` 开关、`mysqladmin`/`mysqld_safe` 的管理方式。

## 20. 下一阶段学习方向

- **ENV-002** 双引擎对照实验工具链：把"同 SQL 两边跑"固化成脚本模板（本次已手工完成，可脚本化）。
- **MVCC-001** 事务版本链：PG `xmin/xmax` + snapshot vs InnoDB undo log + ReadView + purge（本文事务行为的基础机制）。
- **ISO-001** 隔离级别与锁：next-key lock、死锁检测 vs PG 行锁/SSI。
- **ENG-001** InnoDB 架构与线程模型：一连接一线程 vs PG 一连接一进程。

---

## Evidence 索引

- `evidence/environment.txt`：OS/内核/进程/端口/字符集/时区
- `evidence/connect_test.txt`：连接方式、USER()/CURRENT_USER()、账号匹配实验
- `evidence/pg_commands.txt`：PG 全部命令真实输出（库/schema/建表/自增/DML/SELECT/NULL/字符串/时间/索引/用户/会话/参数/EXPLAIN/元命令）
- `evidence/mysql_commands.txt`：MySQL 全部命令真实输出（同结构）
- `evidence/transaction_test.txt`：BEGIN/COMMIT/ROLLBACK + autocommit 对照
- `evidence/ddl_test.txt`：DDL 事务性 + TRUNCATE 对照
- `evidence/linux_commands.txt`：ps/ss/pg_ctl/mysqladmin/systemctl 对照
- `verification/questions.md` / `verification/answers.md`：验证题与答案
