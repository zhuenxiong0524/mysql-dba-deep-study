# 聚簇索引、回表与覆盖索引：从 PostgreSQL Heap 迁移到 InnoDB

> 版本：v1.0（2026-09-01）
> 环境：PostgreSQL 18.4 @54184；MySQL 8.4.10 @3306
> 数据：同一结构、同样 30,000 行、主键按降序插入、同谓词命中 300 行
> 证据：`evidence/` 中 SQL、原始输出和源码摘录

## 0. 先记住四句话

1. PostgreSQL 普通表是 **heap + 若干独立索引**；主键 B-tree 叶子保存的是 heap TID，不保存整行。
2. InnoDB 表本身就是聚簇索引；显式主键通常是聚簇键，叶子记录保存整行。
3. InnoDB 二级索引会自动附加聚簇键。查询缺列时用它回到聚簇索引；所需列齐全时可做 covering index scan。
4. PG 的 Index Only Scan 还要依赖 visibility map；MySQL 没有同名机制，但二级记录无法独立判断 MVCC 可见性时仍可能访问聚簇记录。

## 1. PostgreSQL 基线：主键也不能改变 heap

### 1.1 物理模型

PG 普通表的数据行在 heap 中，索引条目指向 `(block, offset)` 形式的 TID。即使声明
`PRIMARY KEY(id)`，也只是创建唯一 B-tree；它不会把 heap 改造成按主键组织的表。

本实验故意按 `30000 → 1` 插入，heap 开头真实输出如下：

```text
 ctid  |  id
-------+-------
 (0,1) | 30000
 (0,2) | 29999
 (0,3) | 29998
 (0,4) | 29997
 (0,5) | 29996
```

这证明 heap 顺序跟随插入，而不是主键顺序。`idx_lab` heap 为 4,472,832 bytes；主键、
普通二级索引和 INCLUDE 索引分别是独立 relation/relfilenode。

### 1.2 普通 Index Scan 的回堆调用链

```text
ExecIndexScan
  → IndexNext                         nodeIndexscan.c:80
    → index_getnext_slot              nodeIndexscan.c:131
      → index_getnext_tid             indexam.c:729，先从 B-tree 得到 TID
      → index_fetch_heap              indexam.c:678
        → table_index_fetch_tuple     indexam.c:684，按 TID 取可见 heap tuple
```

主键等值查询也显示普通 `Index Scan`：

```text
Index Scan using idx_lab_pkey on idx_lab
  Index Cond: (id = 42)
  Buffers: shared hit=6
```

所以从 PG 迁移时必须去掉“PRIMARY KEY 就是数据”的想当然；那是 InnoDB 心智，不是 PG heap 心智。

### 1.3 PG Index Only Scan 并非永远不碰 heap

PG 的索引必须包含查询所需全部列。本实验显式定义：

```sql
CREATE INDEX idx_cover ON idx_lab(tenant_id, status) INCLUDE(id, created_at);
VACUUM (ANALYZE) idx_lab;
```

源码 `indxpath.c:2224 check_index_only()` 检查所需属性是否都可由索引返回；执行阶段
`nodeIndexonlyscan.c:121` 先取 TID，再于 `:161` 检查 `VM_ALL_VISIBLE`。若 heap 页不是
all-visible，`:169` 仍调用 `index_fetch_heap()` 验证可见性。

本次 VACUUM 后 `relpages=546, relallvisible=546`，执行计划为：

```text
Index Only Scan using idx_cover on idx_lab
  Index Cond: ((tenant_id = 42) AND (status = 2))
  Heap Fetches: 0
  rows=300
```

因此 PG DBA 看覆盖效果时，不能只看 `Index Only Scan` 节点，还要看 `Heap Fetches`。

## 2. MySQL/InnoDB：表就是聚簇索引

### 2.1 主键叶子保存整行

InnoDB handler 明确返回主键为聚簇索引：

```cpp
// storage/innobase/handler/ha_innodb.cc:6677
bool ha_innobase::primary_key_is_clustered() const { return (true); }
```

本实验同样按主键降序插入，但强制 PRIMARY 顺序扫描输出 `1,2,3,4,5`；执行树是：

```text
Limit: 5 row(s)
  -> Index scan on idx_lab using PRIMARY
```

注意：没有 `ORDER BY` 时 SQL 结果顺序仍无保证；实验用 `ORDER BY id` 只是验证 PRIMARY
可以直接提供该顺序，无额外 sort。

内部字典显示 `PRIMARY N_FIELDS=7`：5 个用户列加 InnoDB 聚簇记录的两个系统字段
`DB_TRX_ID/DB_ROLL_PTR`。这也连接到下一专题 MVCC。

### 2.2 无主键时仍然有聚簇索引

对没有 PRIMARY/合适唯一非空键的 `no_pk_lab(a,b)`，实测：

```text
NAME             TYPE  N_FIELDS
GEN_CLUST_INDEX     1         5
idx_a               0         2
```

`handler0alter.cc:3064-3074` 创建保留名 `GEN_CLUST_INDEX`。这里 5 个内部字段是两个用户列加
隐藏 `DB_ROW_ID/DB_TRX_ID/DB_ROLL_PTR`。隐藏键不可供业务 SQL 稳定引用，所以生产表仍应显式设计主键。

### 2.3 二级索引为什么携带主键

`dict0dict.cc:3169 dict_index_build_internal_non_clust()` 构造二级索引内部定义；
`:3228-3243` 将“唯一确定 clustered index entry 所需的列”追加到二级索引。

用户可见定义与内部字段数的差异是直接证据：

| 索引 | SHOW INDEX 中显式列 | INNODB_INDEXES.N_FIELDS | 隐式内容 |
|---|---:|---:|---|
| `idx_tenant` | 1：tenant_id | 2 | 自动追加 id |
| `idx_cover` | 3：tenant_id,status,created_at | 4 | 自动追加 id |

这意味着宽主键会被复制进每个二级索引，放大磁盘、Buffer Pool 和写放大；这不是 PG 主键的成本模型。

### 2.4 回表调用链

```text
Server handler 接口
  → ha_innobase::index_read                 ha_innodb.cc:10417
    → build_template(false)                 :10465
    → row_search_mvcc                       :10543
      → 在二级 B-tree 定位记录
      → 若 need_to_access_clustered
        → row_sel_get_clust_rec_for_mysql   row0sel.cc:5444-5465
          → 用二级叶子的聚簇键查 PRIMARY，取得整行/历史版本
```

查询 `SELECT payload ... FORCE INDEX(idx_tenant) WHERE tenant_id=42` 缺少 payload，真实执行树：

```text
Index lookup on idx_lab using idx_tenant (tenant_id=42)
  actual rows=300
```

传统 EXPLAIN 的 `Extra=NULL`，不是 `Using index`。源码在 `row0sel.cc:5444` 明确进入聚簇记录访问；
这就是 MySQL 语境的“回表”。

### 2.5 覆盖索引

相同谓词改为只投影 `id, tenant_id, status, created_at`。三个列显式在 `idx_cover`，`id` 隐式在二级叶子：

```text
Extra: Using index
Covering index lookup on idx_lab using idx_cover
  (tenant_id=42, status=2)
  actual rows=300
```

这里不需要为了 payload 做常规回表。但要加一个 MVCC 限定：`row0sel.cc:5353-5375` 说明，若二级记录
对当前 ReadView 不可直接判定，undo 又只能通过聚簇记录获得，覆盖扫描仍会转入 `requires_clust_rec`。
所以 `Using index` 表示投影被覆盖，不应被解释为任何并发状态下物理上绝对零聚簇访问。

## 3. 同实验结果总表

| 实验 | PostgreSQL 18.4 | MySQL 8.4.10 |
|---|---|---|
| 降序插入后的数据组织 | heap 前五行 id=30000..29996 | PRIMARY 扫描 id=1..5 |
| 主键 | 独立唯一 B-tree → TID → heap | 聚簇索引叶子就是整行 |
| 普通二级索引叶子定位 | 保存 heap TID | 保存聚簇键 id |
| 非覆盖查询 | `Index Scan idx_tenant`，shared hit=300/read=2 | `Index lookup idx_tenant`，300 行，需要聚簇记录 |
| 覆盖定义 | 必须显式 `INCLUDE(id,created_at)` | id 自动附加，只显式索引其余列 |
| 覆盖计划 | `Index Only Scan`, `Heap Fetches: 0` | `Covering index lookup`, `Using index` |
| 可见性例外 | VM 非 all-visible 时回 heap | 二级记录可见性不足时可能访问 cluster/undo |
| 没有显式主键 | 表仍是 heap | 创建隐藏 `GEN_CLUST_INDEX` |

## 4. 心智迁移与生产判断

| PG 经验 | 迁移到 MySQL 后的正确动作 |
|---|---|
| 主键只是一个唯一索引 | 主键还是所有二级索引的行定位符；优先短、稳定、单调、非业务可变键 |
| 索引保存 TID，主键宽度不进入每个索引 | 估算每个二级索引都复制聚簇键的容量放大 |
| `INCLUDE` 明确写覆盖列 | 记住 InnoDB 二级索引天然包含主键，不必重复把主键写进索引定义 |
| 看 `Index Only Scan` | 同时看 `Heap Fetches` 与 VACUUM/visibility map |
| 看 MySQL `Using index` | 它代表覆盖；`Using index condition` 是 ICP，不等于覆盖 |
| heap 顺序与主键无关 | InnoDB 聚簇键影响页分裂、局部性和随机写；随机 UUID 主键需谨慎 |

### DBA 执行计划速查

```sql
-- MySQL
EXPLAIN SELECT ...;          -- Extra=Using index 才是覆盖
EXPLAIN ANALYZE SELECT ...;  -- TREE 中看 Covering index lookup
SHOW INDEX FROM db.tbl;

-- PostgreSQL
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- Index Scan = 通常回 heap；Index Only Scan 后继续看 Heap Fetches
```

## 5. Evidence 与复现/清理

- `mysql-idx001.sql`、`pg-idx001.sql`：完整可重复实验命令
- `mysql-idx001-output.txt`、`pg-idx001-output.txt`：本机真实输出
- `source-locations.txt`：MySQL/PG 源码行号与关键实现摘录

清理命令：

```sql
-- MySQL
DROP DATABASE mysql_idx001;
-- PostgreSQL（从其他数据库执行）
DROP DATABASE pg_idx001;
```
