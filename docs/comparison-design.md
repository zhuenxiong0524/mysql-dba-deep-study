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

## 5. 分级研究模式

研究质量由机制解释、双引擎证据和可复现操作决定。专题开始时在 idx 标记研究级别：

| 级别 | 定位 | 默认主题 | 文章形态 |
|---|---|---|---|
| S | 源码专著 | 崩溃恢复、MVCC、Buffer Pool、提交协议、复制、优化器 | 完整源码执行说明书 |
| D | 深度对照 | 索引、锁、隔离、重要参数 | 关键机制与同构实验 |
| R | Runbook | 配置、备份、诊断处置 | MySQL 操作与恢复护栏 |
| M | 快速映射 | 低风险语法和对象对应 | 最小验证与心智映射 |

历史专题未标记时按 D 验收。S 级不使用 160～280 行预算，也不接受用少量源码锚点替代完整调用链；
D/R/M 继续通过批处理、复用和证据去重快跑。

### 5.1 S 级完成模型

```text
PG 原文与 PG 18.4 源码基线
        ↓
MySQL 入口、结构、执行、状态、分支、观测六层模型
        ↓
行为实验（结果是否相同）
        +
路径实验（内部机制是否真正走过）
        ↓
源码状态变化 ↔ 实验输出 ↔ 生产故障映射
        ↓
源码专著 + 完整 MySQL 实操 + Evidence
```

S 级路径实验必须预先声明要制造的内部状态关系。例如恢复专题需要证明 checkpoint、commit、flush、
crash 与 recovery scan 的位置关系；最终 SELECT 正确不能单独证明 redo 路径。无法实测的机制必须标记
“源码确认但未实测”。进程崩溃、OS 掉电和存储损坏不得混为同一个实验结论。

### 5.2 D/R/M 快跑

1. 列出 3～7 条可证伪结论；
2. 对关键差异做最小同构实验；
3. D 级串起决策入口、关键分支和必要出口；
4. R 级优先保证操作、判断、停止条件和恢复；
5. M 级只验证稳定映射，不展开无关源码；
6. 从同一结论表派生文章、idx、map 和 Runbook。

速度不能通过削弱 MySQL 实操换取。所有级别的文章都必须提供连接/准备、顺序执行、结果判断和清理。

## 6. 分级文章模板

### 6.1 S 级源码专著

```markdown
# <主题>：PG vs MySQL 源码级对照
## 1. 问题边界与结论矩阵
## 2. PG 基线与现有心智模型
## 3. 完整调用链
## 4. 核心数据结构
## 5. 状态变化与关键分支
## 6. 双引擎实验
### 6.1 行为实验
### 6.2 路径实验
## 7. 源码—实验—生产映射
## MySQL 实操：命令与 SQL
## 9. 未验证范围与 Evidence
```

标题编号可以调整，但这些内容必须可识别。关键源码片段放正文并解释状态变化；源码全文不复制进文章。

### 6.2 D/R/M 精简模板

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

## 7. 专题交付与验收

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
# 显式按源码专著验收：
.agents/skills/mysql_study/scripts/validate_topic.sh --level S study_record/<category>/<TASK_ID>_<slug>
# 历史专题按旧模板回归：
.agents/skills/mysql_study/scripts/validate_topic.sh --legacy study_record/<category>/<TASK_ID>_<slug>
```

validator 只保证结构性下限：S 级章节、关键源码片段、双实验、双源码 evidence 和证据边界。人工评审
仍需检查源码版本、状态推导和实验真实性，不能把 `errors=0` 等同于机制已经被证明。

## 8. 项目落地状态

1. ✅ 安装 MySQL 8.4.10 LTS（源码编译，见 docs/environment.md）
2. ✅ 启动 MySQL、建交叉用户 pg@localhost（双向互通已验证）
3. ✅ 建立 study_record 结构与学习工作流（Skill + roadmap）
4. ✅ 已形成多项双引擎专题；后续按 S/D/R/M 分级，并强制交付完整 MySQL 实操
