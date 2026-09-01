# MYSQL-BASIC-001 PostgreSQL DBA 学 MySQL：基础命令与核心概念对照

- 任务 ID：`MYSQL-BASIC-001`
- 系列状态：`✅ 已完成（文章 + 22 验证题含答案 + 2026-09-01 环境清理）`
- 权重：`M`（标准研究，一次大而全的实机对照）
- 首次开始日期：`2026-08-27`
- 分类：`mysql/basic`

## 研究目标

以 PG 18.4 基线，通过"同命令两边实机执行"完成 MySQL 8.4 基础命令与核心概念对照：
连接/版本/当前连接/数据库与 Schema/表与结构/数据类型/自增/DML/SELECT/LIMIT/NULL/字符串/时间/
索引/用户权限/会话与 Kill/参数/事务与 DDL 事务性/EXPLAIN/psql vs mysql 元命令/Linux 命令。

## 完成清单

- [x] 环境识别（OS/PG 18.4/MySQL 8.4.10/端口/目录/字符集/时区/认证）
- [x] 独立实验对象 db_compare / t_user / compare_user（两边）
- [x] 26 类实验两边实机执行，输出存档 evidence/
- [x] 对照文章（含 16 条易踩坑 + 30+ 项概念映射表）
- [x] 验证题 22 道 + 答案（verification/）
- [x] 理解验证（verification/ 22 题 + answers.md 22 答案齐备，2026-09-01 核对通过）
- [x] 环境清理（2026-09-01 执行文章第 18 节 SQL + 扩展：db_compare/db_compare2/demo_schema、
      compare_user/cmp_demo/lab_user 已清；保留 pg@localhost 交叉用户与 cmp 库）

## 系列文章

- `MYSQL-BASIC-001_PGvsMySQL基础命令对照文章.md`（v1.0，2026-08-27）

## 关键证据

- evidence/environment.txt：环境信息
- evidence/connect_test.txt：连接方式与 user@host 账号匹配（USER()/CURRENT_USER() 实测）
- evidence/pg_commands.txt / mysql_commands.txt：全部命令真实输出
- evidence/transaction_test.txt：BEGIN/COMMIT/ROLLBACK + autocommit
- evidence/ddl_test.txt：DDL 事务性 + TRUNCATE（重点差异）
- evidence/linux_commands.txt：ps/ss/pg_ctl/mysqladmin/systemctl

## 关键结论（摘要）

1. MySQL database≠PG database（命名空间 vs 连接边界）；SCHEMA=DATABASE。
2. 账号模型是 'user'@'host' 二元组；USER() vs CURRENT_USER() 实测三种匹配。
3. DDL/TRUNCATE 隐式提交不可回滚（与 PG 相反，实机验证）。
4. 默认值即决策：||=OR、LENGTH=字节、utf8mb4_0900_ai_ci 不区分大小写、AUTO_INCREMENT 不连续。
5. performance_schema=OFF 时 P_S/sys 表不可用，用 PROCESSLIST 兜底。
6. PG 18 lc_collate 不再是 GUC；MySQL 8.4 移除 default_authentication_plugin（改 authentication_policy）。

## 后续深化方向

- ENV-002 双引擎对照实验工具链（本次手工流程脚本化）
- MVCC-001 事务版本链（PG xmin/xmax vs InnoDB undo/ReadView/purge）
