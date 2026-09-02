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
- MySQL 8.4.10 LTS，**源码编译安装**，二进制 /usr/local/mysql/mysql-8.4.10，数据 /data/myhome/mydata/mysql，端口 3306，mysql 用户运行（已启动，见 check_environment.sh）
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

## 5. 默认工作模式：深度快跑

核心机制保持深度，过程通过批处理、自动化和去重提速。研究质量由因果解释、双引擎实验、
源码证据和可复现操作决定，不由文章或 evidence 的长度决定。

默认流程：

1. 先列 3～7 条可证伪的待证明结论；
2. 每个关键差异设计一个最小同构实验，PG/MySQL 各跑一次；
3. 每条核心机制保留 1～3 个源码锚点，串起决策入口、关键分支和必要出口；
4. 先形成唯一结论表，再派生文章、idx 和必要的横切资产；
5. 清理实验环境并运行专题验收脚本。

默认预算：

- 文章通常 160～280 行，必须覆盖原因、边界、失败形态和生产影响；
- 源码摘录通常为每个锚点上下各 10～15 行；
- verification 仅在用户要求或理解风险高时创建；
- map 只写新的心智映射，Runbook 只写新的生产处置内容；
- 观察到锁等待等目标状态后主动释放，不等待超时。

速度不能通过削弱 MySQL 实操换取。文章必须提供从连接/准备到执行、判断、清理的完整 MySQL
命令或 SQL；PG 侧仍需实测留档，但正文可以只保留机制、结果和差异。

## 6. 精简对照文章模板

```markdown
# <主题>：PG vs MySQL 对照实验
## 1. 结论速览（PG / MySQL / 迁移含义 / Evidence）
## 2. PG 基线
## 3. MySQL 机制与源码锚点
## 4. 最小对照实验
## MySQL 实操：命令与 SQL
## 6. 心智迁移与生产处置
## 7. Evidence 索引
```

MySQL 实操章节必须自包含：连接/前置条件、完整执行步骤、关键结果判断和 cleanup/rollback；
多会话必须标明 T1/T2 时序。文章引用 evidence，但不能用链接代替 MySQL 操作步骤。

## 7. 专题最小交付

```text
<TASK_ID>_<slug>/
├── <TASK_ID>.idx.md
├── evidence/                 # MySQL 完整操作、双引擎关键输出、源码锚点
└── <主题>对照文章.md
```

`verification/`、独立 Runbook、额外图表均为按需资产，不是每篇必选项。

验收：

```bash
.agents/skills/mysql_study/scripts/validate_topic.sh study_record/<category>/<TASK_ID>_<slug>
# 历史专题按旧模板回归：
.agents/skills/mysql_study/scripts/validate_topic.sh --legacy study_record/<category>/<TASK_ID>_<slug>
```

## 8. 项目落地状态

1. ✅ 安装 MySQL 8.4.10 LTS（源码编译，见 docs/environment.md）
2. ✅ 启动 MySQL、建交叉用户 pg@localhost（双向互通已验证）
3. ✅ 建立 study_record 结构与学习工作流（Skill + roadmap）
4. ✅ 已形成多项双引擎专题；后续默认深度快跑，并强制交付完整 MySQL 实操
