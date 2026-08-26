# AGENTS.md

## Project Goal

这是一个基于 PostgreSQL 经验迁移的 MySQL DBA / DBRE 深度学习项目。

学习不是单纯问答。每个重要专题应形成闭环：

```text
理论（PG 基线）
  ↓
MySQL 源码定位
  ↓
调用链
  ↓
对照实验（同一实验 PG / MySQL 两边跑）
  ↓
证据验证
  ↓
对照文章（含心智迁移差异表）
  ↓
study_record
```

## MySQL Environment（已就绪）

```text
MySQL 8.4.10 LTS（源码编译安装）
二进制：/usr/local/mysql/mysql-8.4.10（/usr/local/mysql 为 mysql 用户所有）
数据目录：/data/myhome/mydata/mysql
端口：3306
socket：/tmp/mysql.sock
运行用户：mysql
源码：/data/myhome/mydata/mysql-src/mysql-8.4.10（源码定位用，勿改）
构建目录：/data/myhome/mydata/mysql-src/build
```

## PostgreSQL 对照实例（已就绪）

```text
PostgreSQL 18.4
源码：/data/soft/postgres/postgresql-18.4
数据：/data/pgdata/pgdata18.4
bin：/usr/local/pgsql/pgsql18.4
端口：54184
```

## 环境与权限约定

- `mysql` 用户已配置免密 sudo（`/etc/sudoers.d/mysql`），需要 root 的操作直接 `sudo` 即可
- 机器为 1 CPU / 2GB 内存 + 4G swap，MySQL 需保守参数（`innodb_buffer_pool_size=64M` 等）
- 本机不使用 MCP agent 访问 MySQL；源码检索直接在 `/data/myhome/mydata/mysql-src/mysql-8.4.10` 进行
- Git 仓库：https://github.com/zhuenxiong0524/mysql-dba-deep-study

## 心智迁移原则

- 每个主题先写 PG 侧的机制与结论（基线），再找 MySQL 对应机制
- 对照实验必须"同一实验设计、两边各跑一遍"，记录行为差异而非仅抄文档
- MySQL 缺失或实现不同的能力（如 GIN/GiST、SSI、逻辑复制）单独标注为"心智地图差异点"
