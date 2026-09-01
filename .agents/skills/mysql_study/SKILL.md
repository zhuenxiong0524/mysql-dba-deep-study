---
name: mysql_study
description: MySQL 8.4 LTS 对照学习工作流（PG 18.4 基线 → MySQL 源码定位 → 双引擎同实验 → 对照文章）。适用于 MySQL/MariaDB/InnoDB 深度研究、PG↔MySQL 对照实验、心智迁移、study_record 维护。
---

# mysql_study — PG→MySQL 对照学习入口（v0.1）

## 最高目标

以已掌握的 PostgreSQL 能力为基线，通过"同一实验两边跑"系统性迁移到 MySQL 8.4 LTS。
AI 辅助研究、实验、源码阅读与写作，但最终理解由学习者完成。

## 闭环流程

```text
任务（learning-roadmap.md）
  ↓ 1. PG 基线：机制与结论（已有知识 + PG 源码定位）
  ↓ 2. MySQL 源码定位：storage/innobase、sql/ 对应实现 + 调用链
  ↓ 3. 对照实验：同一实验设计，PG 54184 与 MySQL 3306 各跑一遍
  ↓ 4. 证据验证：SQL 输出 / 执行计划 / 源码行号 / 日志，全部留档
  ↓ 5. 对照文章：PG 基线 + MySQL 机制 + 实验对照 + 差异分析 + 迁移表
  ↓ 6. 理解验证通过后标记完成（idx 系列状态 = ✅ 已完成，必要时补 verification/ 自测题）
```

## 路径契约

```text
PROJECT_ROOT = /data/myhome/myfuture/dba_one_year_mysql
MySQL 源码  = /data/myhome/mydata/mysql-src/mysql-8.4.10
PG 源码     = /data/soft/postgres/postgresql-18.4
MySQL 连接  = mysql -uroot -S /tmp/mysql.sock（socket）或 -h127.0.0.1 -P3306
PG 连接     = psql -U mysql -d mysql -h 127.0.0.1 -p 54184
study_record = PROJECT_ROOT/study_record/
```

## 不变原则

1. 每个主题先写 PG 基线，再研究 MySQL——顺序不可颠倒
2. 对照实验必须两边各跑一遍，记录行为差异；禁止只抄文档
3. 关键结论必须源码确认（MySQL 源码在本机），模型记忆不能替代本地源码事实
4. 不伪造 SQL 结果、执行计划、源码位置或日志
5. `study_record/**` 是学习资产，不覆盖、不清空；已完成主题不重复创建
6. MySQL 缺失/不同实现（GIN/GiST、SSI、逻辑复制、流复制）标注为"心智地图差异点"
7. 机器 1C/2G：实验参数保守（innodb_buffer_pool_size=64M 等），避免 OOM

## 对照文章模板

见 docs/comparison-design.md 第 5 节：PG 基线 → MySQL 机制 → 对照实验 → 差异分析 → 心智迁移要点 → Evidence

## 专题目录规范

```text
study_record/<category>/<TASK_ID>_<slug>/
├── <TASK_ID>.idx.md        # 任务状态与进度
├── evidence/               # SQL 输出、执行计划、源码取证 JSON
└── <主题>对照文章.md        # 最终交付物
```
