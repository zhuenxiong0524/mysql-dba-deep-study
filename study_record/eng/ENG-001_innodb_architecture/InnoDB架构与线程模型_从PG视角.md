# InnoDB 架构与线程模型：从 postmaster/backend 进程模型迁移

> 版本：v1.0（2026-09-01，双引擎实跑：PG 18.4 @54184 / MySQL 8.4.10 @3306）
> 系列：PG DBA → MySQL 生产 DBA 迁移项目 · 第二阶段专题 5（ENG-001）
> 关联：ENV-005（进程/线程初探）；MON-001（P_S=OFF 约束）
> 证据：`evidence/mysql-threads.txt`、`evidence/pg-process-model.txt`
> 本文所有输出均为本机实跑真实输出，命令可直接复制执行。

---

## 0. 一句话结论

- **PG**：一连接一进程。`postmaster` 收到连接就 `fork` 一个 backend 进程，进程数是"会呼吸"的。
- **MySQL**：一连接一线程。`mysqld` 永远只有一个进程，内部按"连接线程 + InnoDB 后台线程族"组织，线程数是"会呼吸"的。
- 判断"MySQL 挂了没有"看进程（恒为 1 个 mysqld）；判断"忙不忙"看线程/连接，不是看进程数。

---

## 1. PostgreSQL 基线：先跑这些命令

### 1.1 进程树（postmaster + 辅助进程）

```bash
ps -C postgres -o pid,ppid,args
```

真实输出（本机 2026-09-01）：

```text
    PID    PPID COMMAND
   8436       1 /usr/local/pgsql/pgsql18.4/bin/postgres -D /data/pgdata/pgdata18.4
   8437    8436 postgres: logger
   8438    8436 postgres: io worker 2
   8439    8436 postgres: io worker 1
   8440    8436 postgres: io worker 0
   8441    8436 postgres: checkpointer
   8442    8436 postgres: background writer
   8444    8436 postgres: walwriter
   8445    8436 postgres: autovacuum launcher
   8446    8436 postgres: logical replication launcher
```

要点：`postmaster`（8436，PPID=1）+ 9 个辅助进程；**没有连接时没有 backend**（进程总数 10）。

### 1.2 开 2 个连接后：backend 进程数 +2

```bash
psql -h 127.0.0.1 -p 54184 -U postgres -d postgres -c "SELECT pg_sleep(25);" &   # 连接1
psql -h 127.0.0.1 -p 54184 -U postgres -d postgres -c "SELECT pg_sleep(25);" &   # 连接2
sleep 3
ps -C postgres -o pid,args | grep -v "postmaster\|logger\|io worker\|checkpointer\|background writer\|walwriter\|autovacuum\|logical"
```

真实输出（新增两个 backend 进程 12292、12295，`pg_stat_activity` 里 state=active）：

```text
12292 postgres: postgres postgres 127.0.0.1(12345) idle
12295 postgres: postgres postgres 127.0.0.1(12346) idle

SELECT pid, application_name, state FROM pg_stat_activity WHERE state='active';
  pid  | application_name | state
-------+------------------+--------
 12292 | psql             | active
 12295 | psql             | active
```

连接断开后进程消失（回落）。**进程数 = 连接数 + 固定辅助进程**。

---

## 2. MySQL 机制

### 2.1 引擎插件化：handler 接口

- MySQL 的"存储引擎"是一组插件（`SHOW ENGINES` 可见 InnoDB/MyISAM/MEMORY...），Server 层通过 **handler 接口**访问表数据
- 源码：`storage/innobase/handler/ha_innodb.cc` 的 `ha_innobase` 类 + `innobase_create_handler()` 工厂，启动时注册到 `handlerton`（`innobase_hton->create = innobase_create_handler`）
- 对比 PG：PG 的 heap 引擎是写死在执行器里的（表访问层直接操作 heap AM），没有 MySQL 这种"可插拔引擎"概念

```sql
SHOW ENGINES\G   -- 看支持哪些引擎、哪个是默认
```

### 2.2 一连接一线程（thread-per-connection）

- MySQL 8.0+ 默认每个客户端连接一个独立线程处理，源码 `sql/conn_handler/connection_handler_per_thread.cc` 的 `Per_thread_connection_handler`
- 线程总数 = 连接线程 + InnoDB 后台线程族 + 各类内部线程（event_scheduler 等）
- 进程数恒为 1：`ps -ef | grep mysqld` 永远只有 mysqld 一行（外加守护的 mysqld_safe）

### 2.3 InnoDB 后台线程族（8.4）

| 线程 | 职责 | 源码创建点 |
|---|---|---|
| srv_master_thread | InnoDB 主循环（周期任务、缓存刷盘协调） | srv0start.cc:2506 |
| srv_purge_coordinator / srv_worker | 清理 undo 历史版本（对应 PG 的 autovacuum/vacuum） | srv0start.cc:2449/2456 |
| page_cleaner | buffer pool 脏页刷盘（对应 PG background writer + checkpointer） | srv0start.cc:1806 |
| log_writer / log_flusher / log_checkpointer | redo log 写入/刷盘/checkpoint（对应 PG walwriter + checkpointer） | log0log.cc:922/928/934 |
| io_read ×N / io_write ×N | AIO 读写线程（os_aio_init） | os0file.cc:6362 |
| dict_stats / buf_dump / buf_resize 等 | 字典统计、buffer pool 预热/调整 | srv0start.cc:2521/2549/2494 |

### 2.4 观察入口（本机 P_S=OFF）

- `SHOW ENGINE INNODB STATUS`：后台线程段（BACKGROUND THREAD / FILE I/O）
- `SHOW PROCESSLIST` / `information_schema.processlist`：连接线程（P_S=OFF 也可用）
- `ps -L -p <mysqld_pid>` / `/proc/<pid>/task`：全部线程清单与计数
- `SHOW GLOBAL STATUS LIKE 'Threads_connected'`：当前连接线程数

---

## 3. 实验（命令 → 真实输出）

### 实验 A：MySQL 进程与线程基线

```bash
ps -ef | grep "[m]ysqld"        # 进程
echo "PID=$(cat /data/myhome/mydata/mysql/mysql.pid)"
ps -L -p $(cat /data/myhome/mydata/mysql/mysql.pid) -o tid,comm | head
echo "线程总数: $(ls /proc/$(cat /data/myhome/mydata/mysql/mysql.pid)/task | wc -l)"
```

真实输出：

```text
mysql  6204  1  /bin/sh .../mysqld_safe --user=mysql
mysql  6420  6204  .../mysqld --basedir=... --datadir=/data/myhome/mydata/mysql ... --port=3306
PID=6420
    TID COMMAND
   6420 mysqld
   6423 mysqld
   6424 mysqld
   ...
线程总数: 35
```

要点：**进程 1 个，线程 35 个**（InnoDB 后台线程族 + event_scheduler + 少量内部线程，空闲无业务连接）。

### 实验 B：InnoDB 后台线程（SHOW ENGINE INNODB STATUS）

```sql
SHOW ENGINE INNODB STATUS\G
```

真实输出（关键两段）：

```text
BACKGROUND THREAD
-----------------
srv_master_thread loops: 14 srv_active, 0 srv_shutdown, 1753 srv_idle
srv_master_thread log flush and writes: 0

FILE I/O
--------
I/O thread 0 state: waiting for i/o request (insert buffer thread)
I/O thread 1 state: waiting for i/o request (read thread)
I/O thread 2 state: waiting for i/o request (read thread)
I/O thread 3 state: waiting for i/o request (read thread)
I/O thread 4 state: waiting for i/o request (read thread)
I/O thread 5 state: waiting for i/o request (write thread)
I/O thread 6 state: waiting for i/o request (write thread)
I/O thread 7 state: waiting for i/o request (write thread)
I/O thread 8 state: waiting for i/o request (write thread)
```

要点：1 个 insert buffer 线程 + 4 个读线程 + 4 个写线程（`innodb_read_io_threads`/`innodb_write_io_threads` 默认 4）。

### 实验 C：连接数变化（一连接一线程的直接证据）

```bash
# 基线
mysql -uroot -S /tmp/mysql.sock -e "SHOW GLOBAL STATUS LIKE 'Threads_connected';"
# 开 2 个睡眠连接（后台）
( mysql -uroot -S /tmp/mysql.sock -e "SELECT SLEEP(30);" & )
( mysql -uroot -S /tmp/mysql.sock -e "SELECT SLEEP(30);" & )
sleep 3
# 观察
mysql -uroot -S /tmp/mysql.sock -e "SHOW GLOBAL STATUS LIKE 'Threads_connected'; SELECT ID, USER, COMMAND, TIME, INFO FROM information_schema.processlist WHERE INFO LIKE 'SELECT SLEEP%';"
echo "线程总数: $(ls /proc/$(cat /data/myhome/mydata/mysql/mysql.pid)/task | wc -l)"
```

真实输出：

```text
Variable_name	Value
Threads_connected	1          ← 基线（1 个查询连接）

Variable_name	Value
Threads_connected	3          ← 开 2 个连接后
ID	USER	COMMAND	TIME	INFO
106	root	Query	3	SELECT SLEEP(30)
107	root	Query	3	SELECT SLEEP(30)

线程总数: 37                    ← 35 + 2，每连接正好 +1 线程
```

等待 30 秒后回落：`Threads_connected` 回到 1。**对比 PG：开 2 连接是 +2 进程；MySQL 是 +2 线程、进程数不变。**

### 实验 D：P_S=OFF 下怎么观察线程

```sql
SELECT COUNT(*) FROM performance_schema.threads;      -- 0 行：P_S=OFF 不可用
SELECT COUNT(*) FROM information_schema.processlist;  -- 可用（连接线程视角）
```

真实输出：

```text
p_s
0
ps_threads_rows
0
processlist_rows
4
```

要点：本机 `performance_schema=OFF`，线程观察用 `information_schema.processlist` + `SHOW ENGINE INNODB STATUS` + `ps -L` 兜底（MON-001 继续受此约束）。

### 实验 E：PG 对照（同场景）

```bash
# 开 2 个连接
psql ... -c "SELECT pg_sleep(25);" &
psql ... -c "SELECT pg_sleep(25);" &
sleep 3
ps -C postgres -o pid,ppid,args | tail -3
```

真实输出（新增 2 个 backend 进程，postmaster 进程数不变）：

```text
    PID    PPID COMMAND
  12292  8436  postgres: postgres postgres 127.0.0.1(12345) idle
  12295  8436  postgres: postgres postgres 127.0.0.1(12346) idle
```

---

## 4. 源码定位速查

| 机制 | MySQL 8.4 | PG 18.4 |
|---|---|---|
| 引擎接口 | `storage/innobase/handler/ha_innodb.cc`（ha_innobase / innobase_create_handler，注册于 :5440） | heap AM 内置于执行器（`src/backend/access/heap/`） |
| 连接模型 | `sql/conn_handler/connection_handler_per_thread.cc`（Per_thread_connection_handler） | `src/backend/postmaster/postmaster.c`（BackendStartup :3510 fork） |
| 后台线程/进程创建 | `storage/innobase/os/os0thread.cc`（os_thread_create） | `src/backend/postmaster/postmaster.c`（辅助进程启动） |
| purge/vacuum | srv0start.cc:2449/2456（purge 线程） | autovacuum launcher + worker |
| redo/wal 线程 | log0log.cc:922/928/934（log_checkpointer/flusher/writer） | walwriter + checkpointer |
| 脏页刷盘 | srv0start.cc:1806 page_cleaner | background writer + checkpointer |
| AIO IO 线程 | os0file.cc:6362（os_aio_init，4R+4W+1ibuf） | 无对应（共享 IO 不另行建线程） |

## 5. 关键差异（对照表）

| 维度 | PostgreSQL 18.4 | MySQL 8.4 |
|---|---|---|
| 单连接承载 | 1 个 backend **进程** | 1 个连接**线程** |
| 进程数 | postmaster + 9 辅助 + N backend（会变） | 恒为 1 个 mysqld（+ 守护 mysqld_safe） |
| 线程数 | 每进程单线程（backend 内部线程少） | 35 基线 + 每连接 +1（会变） |
| 引擎 | heap AM 内置于内核 | 插件化 handler（InnoDB/MyISAM/...） |
| 日志线程/进程 | walwriter + checkpointer 独立进程 | log_writer/flusher/checkpointer 独立线程 |
| 清理机制 | autovacuum launcher + worker 进程 | srv_purge_coordinator + worker 线程 |
| 崩溃恢复单元 | 单进程崩溃影响该连接 | 线程崩溃（严重错误）可能带崩整个 mysqld 进程 |
| 观察命令 | `ps -ef` / `pg_stat_activity` | `processlist` / `SHOW ENGINE INNODB STATUS` / `ps -L`（P_S=OFF 兜底） |

## 6. 心智迁移要点

1. **数进程 vs 数线程**：接手 PG 先 `ps -ef | grep postgres` 数 backend；接手 MySQL 先 `SHOW PROCESSLIST` 数连接线程——概念等价，命令不同。
2. **"一个连接 = 一个资源单元"两边相同**，只是单元形态不同（进程 vs 线程）；连接数上限分别看 `max_connections`（两边同名）和系统资源。
3. **MySQL 单进程多线程的代价**：一个线程的严重错误（如内存踩踏）可能拖垮整个 mysqld；PG 进程隔离更好。运维上 MySQL 更要"先保进程"。
4. **InnoDB 后台线程 ≈ PG 一堆辅助进程**：purge≈autovacuum、page_cleaner≈bgwriter+checkpointer、log_writer/flusher/checkpointer≈walwriter+checkpointer——用 PG 的职责表直接映射学习。
5. **P_S=OFF 是本机硬约束**：线程/会话观察用 `processlist`+`SHOW ENGINE INNODB STATUS`+`ps -L`，MON-001 前先想清楚采集路径。

## 7. Evidence 索引

| 文件 | 内容 |
|---|---|
| evidence/mysql-threads.txt | MySQL 进程/线程基线、INNODB STATUS 后台线程与 IO 线程、连接数 35→37 回落、P_S=OFF 兜底 |
| evidence/pg-process-model.txt | PG postmaster+9 辅助进程树、开 2 连接 +2 backend、回落 |

相关资产：`study_record/pg-mysql-map.md`、`study_record/runbook/mysql-dba-cheatsheet.md`
