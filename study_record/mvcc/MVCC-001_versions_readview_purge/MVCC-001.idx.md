# MVCC-001 事务版本链、可见性与清理（L，P0）

- 任务 ID：`MVCC-001`
- 系列状态：`✅ 已完成（v1.0，2026-09-01）`
- 权重：`L`（深度机制，3 分）
- 首次开始日期：`2026-09-01`
- 分类：`mvcc/undo-readview-purge`
- 关联：IDX-001（二级索引可见性）；ISO-001（隔离与锁）；ENG-002（undo 文件）

## 研究目标

以 PG tuple `xmin/xmax`、Snapshot、VACUUM/OldestXmin 为基线，掌握 InnoDB 聚簇记录
`DB_TRX_ID/DB_ROLL_PTR`、update undo 版本链、ReadView 边界算法、Purge/History List Length，
并能排查长事务/长查询造成的旧版本保留与 undo 膨胀。

## 完成清单

- [x] PG 基线：xmin/xmax/ctid、Snapshot xmin/xmax/xip、HeapTupleSatisfiesMVCC
- [x] MySQL：DB_TRX_ID/DB_ROLL_PTR、update undo、ReadView、旧版本重建
- [x] PG VACUUM/OldestXmin 对照 InnoDB Purge/oldest ReadView
- [x] 同一行、同一 201 次独立提交的 RR 双会话实验
- [x] 同一事务两次 SELECT 的 RC 双引擎实验
- [x] PG `dead but not yet removable=201` → 释放快照后 `n_dead_tup=0`
- [x] MySQL `History list length=203` → 释放 ReadView 后异步回落为 0
- [x] `pg_stat_activity.backend_xmin` / `information_schema.innodb_trx` 排查路径
- [x] 源码、SQL、原始输出完整留档
- [x] 对照文章、roadmap、map、runbook、验证题更新
- [x] 实验库与过程对象清理

## 后续

- `ISO-001`：Record/Gap/Next-Key Lock 与 PG row lock/SSI/deadlock 对照。
