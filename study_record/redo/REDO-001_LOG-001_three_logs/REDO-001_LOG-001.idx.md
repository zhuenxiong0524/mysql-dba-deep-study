# REDO-001 + LOG-001 三日志职责与正常提交链

- 状态：`✅ 深度返工完成（2026-09-02）`
- 范围：三日志职责、提交/回滚、PG 五档同步提交、MySQL 双轴持久性、group commit/2PC、半同步边界
- 未包含：kill -9 crash recovery（计划 11）、PITR 恢复演练（计划 12）

## 已验证

- [x] MySQL/PG 同构提交与回滚实验
- [x] 回滚依赖 undo 恢复行；redo LSN 仍前进
- [x] 可回滚事务的 binlog cache 被截断，binlog position 不前进
- [x] 提交事务在 ROW binlog 中出现 Write_rows、Update_rows、Xid/COMMIT
- [x] PG WAL 同一范围出现 COMMIT 与 ABORT
- [x] redo 刷盘参数、binlog group commit 与 rollback cache 源码链
- [x] 完整 MySQL 命令、结果判断与清理
- [x] PG `synchronous_commit` 五档确认点与无同步备库时的行为边界
- [x] MySQL 6 组持久性参数矩阵（600 次独立提交）及 redo fsync 观测
- [x] `ordered_commit` FLUSH→SYNC→COMMIT 与半同步 AFTER_SYNC/AFTER_COMMIT 源码链
- [x] 半同步超时后关闭等待的降级语义，以及它不等价于 PG remote_apply

## 资产

- `三日志_Redo_Undo_Binlog与PG_WAL对照.md`
- `evidence/mysql-commands.md`
- `evidence/mysql-output.txt`、`pg-output.txt`、`source-locations.txt`
- `evidence/durability-matrix-output.txt`、`mysql-durability-matrix.sh`、`pg-commit-modes.sql`
