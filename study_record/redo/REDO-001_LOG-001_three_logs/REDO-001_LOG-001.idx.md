# REDO-001 + LOG-001 三日志职责与正常提交链

- 状态：`✅ 阶段 1 完成（2026-09-02）`
- 范围：Undo / InnoDB redo / binlog 职责、COMMIT/ROLLBACK、持久化参数
- 未包含：kill -9 crash recovery（计划 11）、PITR 恢复演练（计划 12）

## 已验证

- [x] MySQL/PG 同构提交与回滚实验
- [x] 回滚依赖 undo 恢复行；redo LSN 仍前进
- [x] 可回滚事务的 binlog cache 被截断，binlog position 不前进
- [x] 提交事务在 ROW binlog 中出现 Write_rows、Update_rows、Xid/COMMIT
- [x] PG WAL 同一范围出现 COMMIT 与 ABORT
- [x] redo 刷盘参数、binlog group commit 与 rollback cache 源码链
- [x] 完整 MySQL 命令、结果判断与清理

## 资产

- `三日志_Redo_Undo_Binlog与PG_WAL对照.md`
- `evidence/mysql-commands.md`
- `evidence/mysql-output.txt`、`pg-output.txt`、`source-locations.txt`
