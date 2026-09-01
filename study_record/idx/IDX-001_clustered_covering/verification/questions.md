# IDX-001 理解验证题

1. PG 声明 PRIMARY KEY 后，heap 会按主键组织吗？实验如何证明？
2. PG 普通 Index Scan 从索引到数据行依次传递什么定位信息？
3. PG 已经选择 Index Only Scan，为什么仍可能出现 Heap Fetches？
4. 本实验为什么在建 INCLUDE 索引后执行 VACUUM？
5. InnoDB PRIMARY 叶子与 PG 主键 B-tree 叶子最根本的差异是什么？
6. `idx_tenant` 只显式定义一列，为什么 `INNODB_INDEXES.N_FIELDS=2`？
7. 无主键 InnoDB 表是否没有聚簇索引？
8. MySQL `Using index` 与 `Using index condition` 是否同义？
9. MySQL 覆盖二级索引是否保证任何 MVCC 状态下都绝不访问聚簇记录？
10. 为什么宽 UUID 主键会放大所有二级索引？
11. PG 与 MySQL 各用什么执行计划证据判断覆盖效果？
12. 为什么即使观察到 PRIMARY 扫描返回主键顺序，业务 SQL 仍必须写 ORDER BY？
