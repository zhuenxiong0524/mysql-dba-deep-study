# MySQL DBA Deep Study（PG → MySQL 对照迁移）

以已掌握的 PostgreSQL 18.4 DBA/DBRE 能力为基线，通过 **PG↔MySQL 双引擎对照实验 + 心智迁移** 系统性学习 MySQL 8.4 LTS。

本项目的核心假设：不把 MySQL 当全新知识学，而是先建立 PG 基线，再找到 MySQL 的对应机制，用**同一实验两边跑**验证差异，沉淀对照文章。

## 项目结构

```text
dba_one_year_mysql/
├── AGENTS.md                 # 学习工作流与环境约定（mysql 用户 + codex 使用）
├── README.md
├── docs/
│   ├── comparison-design.md  # 对照实验与心智迁移总体设计
│   └── environment.md        # 环境规划（路径/端口/用户/参数）
└── study_record/             # 全部学习记录与对照文章（规划中）
```

## 环境基线

| 项 | PostgreSQL 18.4 | MySQL 8.4 LTS（规划） |
|---|---|---|
| 数据目录 | /data/pgdata/pgdata18.4 | /data/myhome/mydata/mysql |
| 端口 | 54184 | 3306 |
| 运行用户 | postgres | mysql |
| 源码 | /data/soft/postgres/postgresql-18.4 | /data/soft/mysql/mysql-8.4.x（待下载） |

## 使用入口

- 项目由 **mysql 用户** 在本目录启动 codex 使用（codex 已装于 /home/mysql/.npm-global）
- mysql 用户已可免密访问 PG 对照实例：`psql -U mysql -d mysql -p 54184`
