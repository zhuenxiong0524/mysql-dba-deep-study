# PG → MySQL 对照实验与心智迁移设计

## 1. 背景与目标

- 已掌握 PostgreSQL 18.4（源码编译、DBA 运维、SQL 优化、MVCC/WAL/Buffer 等机制研究）
- 目标：用对照实验方式学习 MySQL 8.4 LTS，形成"PG 心智 → MySQL 心智"的迁移能力
- 交付物：每专题一篇对照文章（PG 基线 + MySQL 同实验 + 差异分析 + 迁移要点）

## 2. 环境现状（事实核查结论）

### PG 侧（已就绪）
- PostgreSQL 18.4，源码编译于 /usr/local/pgsql/pgsql18.4，数据 /data/pgdata/pgdata18.4，端口 54184，postgres 用户
- pg_hba.conf：local / 127.0.0.1 均为 trust，任何本地连接免密
- mysql 用户免密访问：`psql -U mysql -d mysql -p 54184`

### MySQL 侧（已就绪）
- MySQL 8.4.10 LTS，**源码编译安装**，二进制 /usr/local/mysql/mysql-8.4.10，数据 /data/myhome/mydata/mysql，端口 3306，mysql 用户运行
- 源码 /data/myhome/mydata/mysql-src/mysql-8.4.10（源码定位用）
- 保守参数：innodb_buffer_pool_size=64M、performance_schema=OFF 等

### 机器约束
- 1 CPU / 2GB 内存 / 4G swap → 双实例共存需保守参数

## 3. 学习方式（本机直连，无 MCP agent）

本机 Codex 直接操作两台引擎，不使用 MCP agent 访问 MySQL：

```text
┌───────────────────────────────────────────────┐
│  codex（mysql 用户，sudo 免密）                  │
│  ├─ mysql CLI → MySQL 8.4.10 @ localhost:3306  │
│  ├─ psql CLI  → PG 18.4 @ localhost:54184      │
│  └─ 源码检索 → /data/myhome/mydata/mysql-src/  │
│                /data/soft/postgres/postgresql-18.4│
└───────────────────────┬───────────────────────┘
                        ▼
       study_record/（PG↔MySQL 对照文章）
```

- 双子实例：MySQL 8.4（3306，mysql 用户）↔ PG 18.4（54184，postgres 用户）
- 交叉访问：mysql 用户免密连 PG；MySQL 内建 `pg@localhost` 供 postgres 侧反向查询
- 双源码：MySQL 源码与 PG 源码都在本地，关键结论须源码定位验证（Source Grounding）

## 4. 心智迁移主题映射表

| 主题 | PG 18.4 基线 | MySQL 8.4 对应 | 对照实验要点 |
|---|---|---|---|
| MVCC | xmin/xmax、snapshot、vacuum | undo log、ReadView、purge | 同事务隔离场景两边跑，观察版本链与清理 |
| 隔离级别 | RC / Serializable(SSI) | RR(默认)+next-key lock | 幻读实验、可重复读语义差异 |
| WAL | WAL/LSN/checkpoint | redo log/LSN/checkpoint | 日志结构、刷盘时机、恢复对比 |
| Buffer Pool | shared_buffers(时钟扫描) | innodb_buffer_pool_size(LRU) | 缓存命中率、换页策略实验 |
| 索引 | B-tree/INCLUDE/GIN/GiST | B-tree/covering/自适应哈希 | 同表同 SQL 执行计划对照；GIN/GiST 为差异点 |
| 锁与死锁 | 表锁/行锁/死锁检测 | 行锁/gap/next-key/死锁检测 | 锁等待与死锁实验 |
| 优化器 | ANALYZE/统计信息/EXPLAIN | ANALYZE TABLE/EXPLAIN ANALYZE | 同 SQL 计划差异、统计信息机制 |
| 复制 | streaming/logical | binlog 主从复制 | 主从搭建与故障切换对照 |
| 备份恢复 | pg_dump/pg_basebackup | mysqldump/逻辑与物理备份 | 同数据量备份恢复对比 |

## 5. 对照文章模板

```markdown
# <主题>：PG vs MySQL 对照实验
## 1. PG 基线（机制与结论）
## 2. MySQL 对应机制（源码定位）
## 3. 对照实验（同一实验设计，两边执行结果）
## 4. 差异分析
## 5. 心智迁移要点
## 6. Evidence
```

## 6. 落地步骤

1. ✅ 安装 MySQL 8.4.10 LTS（源码编译，见 docs/environment.md）
2. ⬜ 启动 MySQL、建交叉用户 pg@localhost
3. ⬜ 建立 study_record 结构与学习工作流（Skill + roadmap）
4. ⬜ 首个专题：MVCC（对照实验 + 迁移表）
