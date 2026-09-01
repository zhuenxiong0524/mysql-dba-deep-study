# MVCC-001 理解验证题

1. PG UPDATE 与 InnoDB UPDATE 分别把旧版本放在哪里？
2. PG tuple 的 xmin/xmax 与 InnoDB DB_TRX_ID/DB_ROLL_PTR 如何对应？
3. PG Snapshot 的 xmin/xmax/xip 判断规则是什么？
4. InnoDB ReadView 的 m_up_limit_id/m_low_limit_id/m_ids 判断规则是什么？
5. 为什么变量名 low_limit/up_limit 不能只按英文直觉理解？
6. 为什么 RR T1 在 201 次提交后仍读 v0，新会话读 v201？
7. PG VACUUM 的 `dead but not yet removable` 说明什么？
8. History List Length 是否等于旧行版本数量或 undo 字节数？
9. 只读长事务为什么也会拖住 purge？
10. 释放旧 ReadView 后 HLL 为什么可能不立即归零？
11. PG 与 MySQL 的默认隔离级别是什么，迁移风险是什么？
12. 两边排查长快照分别先看哪些视图/字段？
