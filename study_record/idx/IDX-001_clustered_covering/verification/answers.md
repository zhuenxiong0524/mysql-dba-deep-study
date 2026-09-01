# IDX-001 理解验证答案

1. 不会。heap 仍按插入顺序；降序插入后 `(0,1)..(0,5)` 对应 id 30000..29996。
2. B-tree 返回 heap TID；`index_getnext_slot` 再通过 `index_fetch_heap/table_index_fetch_tuple` 获取可见 tuple。
3. 索引没有普通 heap tuple 的完整 MVCC 可见性；visibility map 页不是 all-visible 时必须访问 heap 检查。
4. VACUUM 设置 all-visible 位，使实验稳定得到 `Heap Fetches: 0`，同时展示其先决条件。
5. InnoDB PRIMARY 叶子保存整行；PG 主键叶子保存键和指向独立 heap 的 TID。
6. InnoDB 构造二级索引时自动追加聚簇键 id，用它唯一定位 PRIMARY 记录。
7. 不是。InnoDB 创建隐藏 `GEN_CLUST_INDEX`，并使用隐藏 `DB_ROW_ID`。
8. 不同义。`Using index` 是覆盖；`Using index condition` 是 Index Condition Pushdown，仍可能回表。
9. 不保证。二级记录对 ReadView 不可直接判断时，undo 只能从聚簇记录进入，源码会跳到 `requires_clust_rec`。
10. 聚簇键被复制到每个二级索引叶子；键越宽，所有二级索引、缓存和写 IO 越大。
11. PG 看 `Index Only Scan` 及 `Heap Fetches`；MySQL 看 `Extra=Using index` 或 TREE 的 `Covering index lookup`。
12. SQL 无 ORDER BY 不承诺结果顺序；当前访问路径、优化器选择、并发和版本变化都可能改变返回次序。
