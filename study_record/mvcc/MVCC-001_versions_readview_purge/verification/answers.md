# MVCC-001 理解验证答案

1. PG 在 heap 中创建新 tuple、旧 tuple 留在 heap/HOT 链；InnoDB 当前值在聚簇记录，旧值写入 update undo。
2. 两组字段都参与版本身份/可见性；PG xmax 标记删除或更新者，InnoDB roll_ptr 指向可重建上一版的 undo。
3. xid<xmin 已结束；xid>=xmax 按运行中；中间范围查 xip，存在则按运行中。
4. id<up 可见；id>=low 不可见；中间查 m_ids，存在不可见；创建者自己的修改可见。
5. 源码中 low_limit 是高端 next-trx 边界，up_limit 是低端最小活跃边界，名字容易造成反向记忆。
6. RR 固定快照/ReadView 按事务开始后的可见性规则选择旧版本；新会话取得新快照。
7. tuple 已逻辑死亡，但仍可能被 OldestXmin 所代表的旧快照看到，VACUUM 不能物理移除。
8. 都不是。它是实例级 rollback-segment history 中的 undo log header 数，应观察趋势。
9. 只要持有旧 ReadView，即便 0 行修改，也可能需要旧 undo 来重建可见版本。
10. Purge 是异步分批的，允许清理、处理 undo 与移除 history header 不是同步完成。
11. PG 默认 RC、MySQL 默认 RR；未显式配置时，同事务多次读的结果可能从“新快照”变成“固定快照”。
12. PG 看 pg_stat_activity 的 xact_start/backend_xmin 和 n_dead_tup；MySQL 看 INNODB_TRX、PROCESSLIST、HLL 与 undo 空间趋势。
