# study_record（MySQL 侧对照学习记录）

PG 18.4 → MySQL 8.4 对照学习记录与文章仓库。

- 任务全集：`learning-roadmap.md`（ENV/ENG/MVCC/ISO/REDO/BUF/IDX/OPT/MON/CONN/REP/BAK/UPG/SQL/CHA/DR + 生产向执行计划 v0.5）
- 目录结构：按主题分类，每专题 `<TASK_ID>_<slug>/` 含 `.idx.md`、`evidence/`、对照文章
- 学习工作流：`.agents/skills/mysql_study/SKILL.md`（默认深度快跑；MySQL 完整实操为硬性指标）
- 专题验收：`.agents/skills/mysql_study/scripts/validate_topic.sh <专题目录>`
- 横切资产：
  - `environment-baseline.md`：环境基线（实例/参数/连接方式）
  - `pg-mysql-map.md`：PG→MySQL 总映射表（随专题扩展）
  - `safety.md`：实验安全规范（mysql_lab_*/lab_*/t_* 命名、红线、资源约束）
  - `runbook/mysql-dba-cheatsheet.md`：生产命令手册（按问题分类）
  - `troubleshooting/`：故障案例库（CASE-001 ~ CASE-018，结构见 README）

## 已完成

- ENV-004 账号权限体系（对照文章 + 15+ 组实验 + 10 evidence）
- ENV-005 实例架构与生命周期（文章已产出，待理解验证）
- ENV-006 配置文件与参数体系（✅ 2026-09-01，含 SET PERSIST 重启验证 + variables_info 修正）
- ENV-007 登录与认证（✅ 2026-09-01，连接路线/host 匹配/caching_sha2-TLS/login-path）
- MYSQL-BASIC-001 基础命令对照（26 类实验 + 22 QA）
- troubleshooting CASE-001/002（✅ 2026-09-01，登录失败与权限拒绝实跑成文）
