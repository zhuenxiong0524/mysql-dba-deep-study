# REDO-001 Crash Recovery

- 状态：`✅ 完成（2026-09-02）`
- 环境：MySQL 8.4.10 专用实例 33311；PostgreSQL 18.4 专用实例 54185
- 故障模型：数据库主进程 `kill -9`，不是 OS 掉电或存储损坏

## 已验证

- [x] 已提交行在两引擎恢复后保留
- [x] 未提交行在事务内部可见、外部不可见，恢复后均不可见
- [x] PG checkpoint → WAL redo → ready 的日志与源码链
- [x] InnoDB checkpoint → redo apply → undo rollback/XA recovery → ready 的源码链
- [x] 专用实例隔离、强持久参数、自动化故障注入和清理护栏
- [x] 完整 MySQL 命令、判断标准、危险范围和清理步骤

## 资产

- `Crash_Recovery_PG_WAL与InnoDB_Redo_Undo对照.md`
- `evidence/mysql-crash-lab.sh`、`mysql-crash.cnf`
- `evidence/pg-crash-lab.sh`
- `evidence/mysql-output.txt`、`pg-output.txt`、`source-locations.txt`

## 未包含

- OS/存储断电、torn write、日志损坏
- `innodb_force_recovery` 抢救演练
- redo 容量与恢复时长基准
