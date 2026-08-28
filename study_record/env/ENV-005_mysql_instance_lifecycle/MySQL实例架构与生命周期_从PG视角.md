# MySQL 实例架构与生命周期：从 PostgreSQL DBA 视角理解 mysqld

> 版本：v1.0（2026-08-28，实机验证于 1C/2G 学习机）
> 基线：PostgreSQL 18.4（端口 54184）→ 目标：MySQL 8.4.10 LTS（端口 3306）
> 系列：PG DBA → MySQL 生产 DBA 迁移项目 · 第一阶段专题 1（ENV-005）
> 证据：`evidence/env-probe*.txt`；项目基线 `study_record/environment-baseline.md`

---

## 1. 为什么 PG DBA 要学这个

接管一个陌生 MySQL 实例的第一件事不是写 SQL，而是**先搞清楚"这个实例是什么、由什么组成、现在活没活着、挂了去哪看"**。

PG DBA 对这套已经很熟（`ps` 看 postmaster、`pg_ctl status`、`postgresql.conf`、`pg_log`），
但直接套到 MySQL 上会踩坑：

- PG 是"一个 postmaster + 一连接一个 backend 进程"；MySQL 是"一个 mysqld 进程，里面一堆线程"——排查工具和心智完全不同。
- PG 的配置在 `postgresql.conf`（单一文件）；MySQL 有配置搜索路径、`mysqld --verbose --help`、`SET PERSIST` 等多处来源，且本机根本没有 systemd 单元。
- PG 的 `data_directory` 管实例；MySQL 的 `@@datadir` 更是"实例本体"——`datadir` 里除了数据还有 redo/undo/binlog/error log/pid/socket 的一切。

本文通过实机命令建立"实例生命周期"心智：实例在哪 → 由什么组成 → 怎么活着的 → 挂了先看哪。

---

## 2. PostgreSQL 已知模型（基线）

```text
Client
 ↓
Backend Process（一连接一进程，fork 自 postmaster）
 ↓
Parser → Planner → Executor
 ↓
Access Method（heap/index）
 ↓
Buffer Manager（shared_buffers）
 ↓
Heap / Index / WAL
```

- 实例 = postmaster + 数据目录 + postgresql.conf + WAL + 日志
- 一连接 = 一个 OS 进程（`ps -ef` 可见 `postgres: user db host idle`）
- 管理：`pg_ctl start/stop/reload`；生产常见 systemd/Patroni 托管
- 挂了看：`pg_isready`、`ps -ef`、`postgresql.log`、`pg_stat_activity`

本机 PG 实测（`ps -ef | grep postgres`）：

```text
postgres -D /data/pgdata/pgdata18.4          ← postmaster
postgres: logger / io worker 0-2 / checkpointer / background writer / walwriter
autovacuum launcher / logical replication launcher
postgres: <user> <db> <host> idle            ← backend，一连接一个
```

> 本机 PG 侧还跑着 `patroni`（/etc/patroni.yml）、`pgbouncer`、`redis`（Patroni DCS）——是带 HA 栈的环境。

---

## 3. MySQL 模型

### 3.1 一条 SQL 的旅程（Server Layer + Storage Engine）

```text
Application
 ↓
MySQL Protocol
 ↓
Connection / Authentication（连接线程，一连接一线程）
 ↓
Parser
 ↓
Optimizer
 ↓
Executor
 ↓
Storage Engine API（handler 接口，引擎可插拔）
 ↓
InnoDB
 ↓
Buffer Pool / Redo / Undo / Data File
```

与 PG 最大的结构差异：**PG 把执行器和存储耦合在一套进程里；MySQL 是"Server 层"与"引擎层"通过 handler API 解耦**。
Server 层管连接/解析/优化/执行，InnoDB 管数据和日志。这也解释了为什么 MySQL 有"引擎选型"概念（InnoDB/MyISAM/...），PG 没有。

### 3.2 一个 MySQL 实例由什么组成

实测 `ls /data/myhome/mydata/mysql/`（关键项）：

```text
mysql.ibd            数据字典（8.0+ 取代 .frm；系统库数据）
ibdata1              系统表空间
#ib_16384_*.dblwr    doublewrite 文件
#innodb_redo/        redo log
#innodb_temp/        临时表空间
undo_001             undo 表空间
ibtmp1               临时表空间
binlog.00000x        binlog（log_bin=ON）
mysql/ sys/ performance_schema/ cmp/ ...   各数据库目录（每表独立 .ibd）
auto.cnf             server_uuid（实例身份）
mysql.pid            PID 文件
error.log            error log（最重要）
mysqld_safe.log      mysqld_safe 托管日志
*.pem                SSL 证书（ca/server/client）
ib_buffer_pool       buffer pool 预热文件
mysqld-auto.cnf      SET PERSIST 持久化文件
```

> **datadir 即实例**：删 datadir = 删实例。实例身份是 `auto.cnf` 里的 server_uuid（本机 `1709cb6a-...`），不是主机名。

### 3.3 进程与线程模型

```text
mysqld（一个 OS 进程）
 ├── 连接线程（一连接一线程，线程池/thread cache 管理）
 └── InnoDB 后台线程族（本机 40 个 mysqld 线程）
      ├── io_read / io_write（async IO）
      ├── srv_purge / srv_worker
      ├── buf_flush / page_cleaner
      ├── log_writer / log_flusher / log_checkpointer
      └── dict_stats / lock_wait 等
```

实测：`ps -eLf | grep mysqld | wc -l` = **40**（1 主线程 + 连接线程 + InnoDB 后台线程）。
本机线程名未在 /proc 暴露（comm 均为 mysqld），线程级定位在后续 ENG-001 用 performance_schema 展开（注意本机 P_S=OFF）。

---

## 4. 两者关键差异（先给结论）

| 维度 | PostgreSQL 18.4 | MySQL 8.4.10 |
|---|---|---|
| 进程模型 | postmaster + 一连接一 backend 进程 | 单 mysqld 进程，一连接一线程 |
| 实例身份 | data_directory | datadir（auto.cnf 的 server_uuid） |
| 配置 | postgresql.conf（单文件） | my.cnf 搜索路径 + 启动参数 + SET PERSIST |
| 日志 | postgresql.log（log_directory=log） | error.log（@@log_error）+ mysqld_safe.log |
| 管理方式 | pg_ctl / systemd / Patroni | mysqld_safe / systemd / CM（本机 mysqld_safe） |
| 探活 | pg_isready | mysqladmin ping |
| 引擎 | 无引擎概念 | Server/Engine 解耦，InnoDB 默认 |
| 后台工作 | checkpointer/walwriter/autovacuum 等进程 | InnoDB 线程族（purge/page_cleaner/log_*/io_*） |

---

## 5. 本地实验环境（实测）

```text
OS:        Debian GNU/Linux 11 (bullseye)，Linux node01 5.10.0-38-amd64，1C/2G
MySQL:     mysql Ver 8.4.10（Source distribution），/usr/local/mysql/mysql-8.4.10/
PG:        psql 18.4，/usr/local/pgsql/pgsql18.4/
MySQL 端口: 3306（TCP）+ 33060（X Protocol），socket /tmp/mysql.sock（+ mysqlx.sock）
PG 端口:   54184
MySQL 运行用户: mysql（mysqld_safe 托管）
配置文件:  /etc/my.cnf；PERSIST 文件 datadir/mysqld-auto.cnf
```

---

## 6. 实验步骤与实际输出

### 实验 A：找到实例（进程 / 端口 / socket）

```bash
ps -ef | grep mysqld | grep -v grep
ss -lntp | grep -E "3306|33060"
ss -lx | grep mysql
```

实际输出：

```text
mysql 2622  1  /bin/sh mysqld_safe --defaults-file=/etc/my.cnf
mysql 2826  2622  mysqld --defaults-file=/etc/my.cnf --basedir=... --datadir=/data/myhome/mydata/mysql
      --plugin-dir=... --log-error=.../error.log --pid-file=.../mysql.pid --socket=/tmp/mysql.sock --port=3306

LISTEN *:33060  mysqld（X Protocol）
LISTEN *:3306   mysqld

u_str LISTEN /tmp/mysqlx.sock
u_str LISTEN /tmp/mysql.sock
```

解释：
- 两层进程：`mysqld_safe`（守护/自动重启）→ `mysqld`（真正实例）。PG 对应是 `pg_ctl` 拉起的 `postmaster`。
- mysqld 的启动命令行里直接可见 datadir/log_error/pid_file/socket/port——**ps 输出就是第一份实例信息**。

### 实验 B：实例关键变量

```sql
SELECT VERSION();
SELECT @@hostname, @@port, @@socket, @@datadir, @@basedir, @@pid_file, @@log_error;
SHOW VARIABLES LIKE 'version%';
```

实际输出：

```text
version          8.4.10
hostname         node01
port             3306
socket           /tmp/mysql.sock
datadir          /data/myhome/mydata/mysql/
basedir          /usr/local/mysql/mysql-8.4.10/
pid_file         /data/myhome/mydata/mysql/mysql.pid
log_error        /data/myhome/mydata/mysql/error.log
version_comment  Source distribution
```

解释：`@@datadir` / `@@log_error` / `@@pid_file` 与 `ps` 命令行一致——实例所有"位置信息"都能从 SQL 拿到（PG 的 `data_directory`/`config_file` 需超管，MySQL 普通用户也能看）。

### 实验 C：启动管理方式（systemd？）

```bash
systemctl status mysqld; systemctl status mysql
```

实际输出：

```text
Unit mysqld.service could not be found.
Unit mysql.service could not be found.
```

解释：本机 MySQL **没有 systemd 单元**，由 `mysqld_safe` 托管。生产常见 systemd / CM（如脚本、Ansible）；PG 侧本机反而是 Patroni 托管。
"重启 MySQL"在本机 = `mysqladmin shutdown` + `mysqld_safe`（或 kill mysqld_safe 由它拉起 mysqld 失败后的重试逻辑）。

### 实验 D：实例构成（datadir）

```bash
ls -la /data/myhome/mydata/mysql/
```

实际输出见第 3.2 节。关键：**binlog 已开启（log_bin=ON）**，redo/undo/dblwr/binlog/error log 全在 datadir 内——磁盘规划、备份、恢复都围绕这个目录。

### 实验 E：连接模型（进程 vs 线程）

```bash
ps -eLf | grep mysqld | wc -l      # 40（mysqld 线程总数）
mysqladmin -uroot -S /tmp/mysql.sock status
```

实际输出：

```text
Uptime: 8193  Threads: 4  Questions: 578  Slow queries: 0  Opens: 505
Flush tables: 3  Open tables: 411  Queries per second avg: 0.070
```

解释：`Threads: 4` = 当前连接线程数（含 event_scheduler 等）；`ps` 的 40 = mysqld 全部线程。
PG 侧一连接一进程（`ps -ef` 可见 backend），MySQL 一连接一线程（进程数恒为 1）。

### 实验 F：error log（启动证据 / 挂了先看哪）

```bash
grep -E "ready for connections|Shutdown complete|started as process" /data/myhome/mydata/mysql/error.log | tail
```

实际输出：

```text
[InnoDB] InnoDB initialization has started.
[InnoDB] InnoDB initialization has ended.
[X Plugin] X Plugin ready for connections. Bind-address: '::' port: 33060, socket: /tmp/mysqlx.sock
[Server] mysqld: ready for connections. Version: '8.4.10'  socket: '/tmp/mysql.sock'  port: 3306  Source distribution.
```

解释：`ready for connections` = 实例可用信号（等价 PG 日志的 "database system is ready to accept connections"）。
本机还有 `mysqld_safe.log` 记录托管进程生命周期（"Starting mysqld daemon ... mysqld from pid file ... ended"）。

### 实验 G：当前会话与状态兜底（P_S=OFF 的现实）

```sql
SHOW VARIABLES LIKE 'performance_schema';   -- OFF
SHOW FULL PROCESSLIST;
```

实际输出：

```text
performance_schema  OFF

Id  User  Host  db  Command  Time  State  Info
5   event_scheduler  localhost  NULL  Daemon  8192  Waiting on empty queue  NULL
108 root  localhost  NULL  Sleep  544  NULL
128 root  localhost  NULL  Query  0  init  SHOW FULL PROCESSLIST
```

解释：本机 `performance_schema=OFF`（64M buffer pool 环境刻意关闭省内存），
P_S 表（threads/events_statements/...）查不了——**监控排障必须用 PROCESSLIST + STATUS 计数 + information_schema 兜底**。
这对后续 MON-001 是硬约束，也是"生产实例接手前先看 P_S 开没开"的真实案例。

---

## 7. 故障实验与故障排查

### 7.1 "实例挂了" 排查路径（本轮只做路径演练，不执行 kill）

安全规范：当前 3306 是学习主实例、非专用实验实例，**不执行 kill/crash**（crash 演练留给 REDO-001 专用实例）。本轮演练"如果 MySQL 连不上，按什么顺序查"：

```text
1. ps -ef | grep mysqld          → 进程在不在（mysqld_safe 在而 mysqld 不在 = 刚崩/启动失败）
2. cat <pid_file>                → PID 文件在不在、PID 是否存活
3. ls -la <socket>               → socket 文件在不在（存在但连不上 = 可能 stale）
4. mysqladmin ping               → 实例是否接受连接（ERROR 2002/1045 分层）
5. tail error.log                → 最后几条：崩溃原因 / 启动卡在哪 / ready for connections
6. mysqld_safe.log               → 托管进程干了什么
7. df -h / free -m / dmesg       → 磁盘满 / OOM 等外部原因
```

实测本机：pid 文件存在（`2826`）、socket 存在、`mysqladmin ping` → `mysqld is alive`，error log 尾部为 `ready for connections`——实例健康。

### 7.2 错误分层（连接问题先分层）

```text
ERROR 2002 (HY000): Can't connect to local MySQL server through socket ... (111)
    → socket 层：实例没起/没监听
ERROR 2002 ... (2) No such file or directory
    → socket 层：路径不对/socket 文件不存在
ERROR 1045 (28000): Access denied ... (using password: ...)
    → 认证层：Account 匹配/密码（ENV-004/007 专题）
ERROR 1040: Too many connections
    → 资源层：连接数打满（CONN-001 专题）
```

PG 对照：`pg_isready` 探活、`psql: error: could not connect` 分层思路一致，但 MySQL 的 socket/TCP 两套入口让"连不上"原因更多样。

---

## 8. 生产环境意义

1. **接手陌生实例第一步**：`ps` → `ss` → `mysqladmin ping` → `@@datadir/@@log_error` → `tail error.log`，5 分钟建立"实例在哪、活没活、日志在哪"。
2. **datadir 就是实例**：备份/迁移/克隆都以 datadir 为对象；`@@datadir` 与 ps 命令行、my.cnf 三处对不上时，说明配置混乱，要警惕。
3. **日志优先级**：error.log 是故障第一现场（启动失败/崩溃/连接拒绝都有记录）；general/slow log 默认关，按需开。
4. **P_S=OFF 是本环境的既定事实**：接手任何实例先 `SHOW VARIABLES LIKE 'performance_schema'`——监控方案会完全不同。
5. **无 systemd ≠ 没管理**：mysqld_safe 也是托管；生产常见 systemd/CM，理解"谁拉起 mysqld"才能安全重启。

---

## 9. 常见误区（PG DBA 视角）

- ❌ "MySQL 和 PG 一样是一堆进程" → 单进程多线程，`ps -ef` 只看到 1 个 mysqld。
- ❌ "配置文件一定在 /etc/my.cnf" → 是搜索路径 + 启动参数 + PERSIST 的多来源；用 `mysqld --verbose --help` 看默认顺序（ENV-006 展开）。
- ❌ "datadir 一定在 /var/lib/mysql" → 本机在 `/data/myhome/mydata/mysql/`，以 `@@datadir` 为准。
- ❌ "systemctl restart mysql 就行" → 本机没有 systemd 单元，盲执行会失败。
- ❌ "P_S 表随时能查" → 本机 OFF；先确认开关再选工具。
- ❌ "一连接一进程" → 一连接一线程；排查并发要看线程/线程栈，不是进程列表。

---

## 10. DBA Checklist（实例接手清单）

```text
[ ] ps -ef | grep mysqld           确认 mysqld_safe/mysqld 都在
[ ] ss -lntp | grep 3306           确认监听与端口
[ ] mysqladmin ping                确认实例存活
[ ] SELECT @@version, @@port, @@socket, @@datadir, @@basedir, @@pid_file, @@log_error
[ ] SHOW VARIABLES LIKE 'performance_schema'   监控可用性
[ ] SHOW VARIABLES LIKE 'log_bin'              复制/PITR 前提
[ ] SHOW VARIABLES LIKE 'innodb_buffer_pool_size'
[ ] df -h + datadir 大小                       磁盘余量
[ ] tail -20 error.log                         最近异常
[ ] SHOW FULL PROCESSLIST                      当前连接/长 SQL
[ ] 确认启动托管方式（systemd/mysqld_safe/CM）→ 明确"重启"操作路径
```

---

## 11. PG → MySQL 心智模型更新

```text
PG:  postmaster + backend 进程家族
     postgresql.conf（单文件）
     pg_ctl / systemd / Patroni
     pg_isready / postgresql.log
     data_directory（超管可见）

MySQL: mysqld 单进程多线程
     my.cnf 搜索路径 + 启动参数 + SET PERSIST
     mysqld_safe / systemd / CM（本机无 systemd）
     mysqladmin ping / error.log（@@log_error 普通用户可见）
     datadir = 实例本体（redo/undo/binlog/log/pid/socket 全在）
```

一句话：**PG 用"进程家族"思考实例，MySQL 用"一个进程 + datadir 目录"思考实例；排查入口是 error.log，身份入口是 @@datadir + server_uuid。**

---

## 12. Evidence 索引

| 文件 | 内容 |
|---|---|
| evidence/env-probe.txt | 工具版本、进程、端口/socket、@@变量、datadir 构成、PG 对照 |
| evidence/env-probe2.txt | systemd 缺失、error log 启动行、实例定位、PG 配置/进程、线程计数 |
| evidence/env-probe3.txt | P_S=OFF、log_bin=ON、PROCESSLIST、mysqladmin status、40 线程 vs 1 backend |

相关资产：`study_record/environment-baseline.md`、`study_record/pg-mysql-map.md`、`study_record/runbook/mysql-dba-cheatsheet.md`（实例段）
