# Optimizer / EXPLAIN：从 PostgreSQL Path 迁移到 MySQL AccessPath

> 专题 `OPT-001`，研究级别 S。实测 MySQL 8.4.10 与 PostgreSQL 18.4，日期 2026-09-03。
> 本文先建立 PG 心智基线，再深入 MySQL；所有耗时仅说明本机本次实验，不能当基准测试。

## 1. 先给结论

| 问题 | PostgreSQL 18.4 | MySQL 8.4.10 | 证据 |
|---|---|---|---|
| 可索引的 `id=19999` | Index Scan，估算/实际均 1 行 | 主键常量读取，实际 1 行 | 双引擎行为实验 |
| `id+0=19999` | Seq Scan，过滤 19999 行 | Table scan，扫描 20000 行 | 双引擎行为实验 |
| 11 个客户关联订单 | Hash Join，orders 全扫 20000 行 | Nested Loop + `idx_customer`，11×20 行 | 双引擎路径实验 |
| 候选为何落选 | Path/cost 与最终 plan；必要时调试器 | `optimizer_trace` 的 range/ref、cost、chosen/cause | 路径证据 |
| ANALYZE 是否执行 | 是；UPDATE 也执行并产生 WAL | 支持的 SELECT 会执行；本版 UPDATE 不支持 iterator executor | sleep 与事务内 DML 实验 |
| IO 证据 | `BUFFERS`、`WAL` 原生显示 | TREE 不给 PG 式 buffer 计数，需结合 P_S/状态量 | 输出能力差异 |

核心迁移关系不是“PG 节点名换成 MySQL 的 type”，而是：`Path` 对应候选物理路径，
`AccessPath` 承载 MySQL 的候选/最终访问方式，最终分别变成 PlanState 与 RowIterator 执行。
成本是各自模型内部的相对量，不能把 MySQL `query_cost=78.44` 与 PG `cost=411` 横向比较。

## 2. PostgreSQL 基线

PG 的主线是 `planner → standard_planner → subquery_planner → query_planner`。基础关系先创建
SeqScan Path，再由 `create_index_paths()` 把可匹配的 index clause 变成 IndexPath；`add_path()`
按照总成本、启动成本、排序和参数化等维度剪枝，cheapest Path 最终转成 Plan。

`EXPLAIN` 只展示计划；加 `ANALYZE` 后执行器真正运行，并把 instrumentation 汇总到节点。
因此 `actual rows` 与 `loops` 必须一起读：节点累计处理量近似为每循环 rows × loops。
`BUFFERS` 展示 shared/local/temp 的 hit/read/dirtied/written，MySQL TREE 没有一一对应字段。

## 3. MySQL 完整调用链

本实验 `@@optimizer_switch` 中 `hypergraph_optimizer=off`，所以证据对应经典优化器，不把
hypergraph 的 `FindBestQueryPlan()` 混进实测解释。

```text
Sql_cmd_dml::execute()
└─ Query_expression::optimize()
   └─ JOIN::optimize()                         sql/sql_optimizer.cc:362
      ├─ optimize_cond()                       等值传播/常量化
      ├─ make_join_plan()                      sql/sql_optimizer.cc:5359
      │  ├─ update_ref_and_keys()              构造 keyuse/sargable 信息
      │  ├─ extract_const_tables()
      │  ├─ estimate_rowcount()
      │  └─ Optimize_table_order::choose_table_order()
      ├─ create_access_paths()
      └─ set_root_access_path()
Query_expression::create_iterators()
└─ CreateIteratorFromAccessPath()              join_optimizer/access_path.cc:488
   └─ 各 RowIterator::Init()/Read()

EXPLAIN ANALYZE
└─ explain_query()                             opt_explain.cc:2247
   ├─ Query_result_null                        丢弃结果但强制求值
   ├─ unit->execute()                          仅 root_iterator 存在时
   └─ ExplainIterator() → PrintQueryPlan()
```

### 3.1 从谓词到候选访问方法

`JOIN::optimize()` 在 `join_optimization.steps` trace 域中记录优化步骤。经典分支调用
`make_join_plan()`；后者先 `update_ref_and_keys()`，注释直接说明这些 key access 信息是 ref
访问的基础。`customer_id=42` 能拆成“列、等号、常量”，产生 ref/range 候选；
`customer_id+0=42` 的左侧已是表达式，普通 `customer_id` 索引不能直接满足它。

概念化的数据结构如下，字段只保留本文需要的边界：

```cpp
class JOIN {
  Query_block *query_block;       // 一个逻辑查询块
  JOIN_TAB **best_ref;            // 经典优化器选定的表顺序
  AccessPath *m_root_access_path; // 最终物理路径根
  ha_rows best_rowcount;
};

struct AccessPath {
  Type type;                      // TABLE_SCAN / REF / INDEX_RANGE_SCAN / JOIN...
  double m_num_output_rows;
  double m_cost;
  double m_init_cost;
};
```

这些是源码语义的裁剪表示，不是可编译的完整定义。`JOIN_TAB`/keyuse 偏经典优化器，
`AccessPath`/iterator 是后续统一执行表示；不要误认为 EXPLAIN 文本本身就是执行对象。

### 3.2 从 AccessPath 到 iterator

`CreateIteratorFromAccessPath()` 按 `AccessPath::type` 建造 TableScanIterator、RefIterator、
NestedLoopIterator、AggregateIterator 等。iterator 是 pull 模型：父节点反复调用子节点 `Read()`。
MySQL TREE 从父到子展示这棵树；`EXPLAIN ANALYZE` 包装 iterator 采集 first-row、last-row、rows、loops。

```cpp
class Query_result_null : public Query_result_interceptor {
 public:
  bool send_data(THD *thd, const mem_root_deque<Item *> &items) override {
    for (Item *item : VisibleFields(items)) item->val_str(&m_str);
    return false;
  }
};
```

源码 `opt_explain.cc:2258-2286` 的关键边界是：iterator-based 且 ANALYZE 时，先检查
`root_iterator()`；存在才把结果改成 `Query_result_null` 并执行 `unit->execute()`，随后打印计划。
所以 ANALYZE 不是“更详细的静态 EXPLAIN”。本版单表 UPDATE 没有可执行 root iterator，实测
返回 `<not executable by iterator executor>`，金额在事务内也未变化。

## 4. 核心数据结构

| 层次 | PostgreSQL | MySQL | DBA 可见物 |
|---|---|---|---|
| 逻辑查询 | Query | Query_block / Query_expression | SQL 与重写后的条件 |
| 关系统计 | RelOptInfo | TABLE/TABLE_LIST、handler stats | rows、filtered、统计表 |
| 候选路径 | Path/IndexPath/JoinPath | keyuse、POSITION、AccessPath | optimizer_trace |
| 最终计划 | Plan | root AccessPath | EXPLAIN JSON/TREE |
| 执行节点 | PlanState | RowIterator | actual time/rows/loops |

估算误差会逐层放大，尤其 join 内表。看到 `(rows=20 loops=11)` 应读作约 220 行，而非 20 行。
先找“第一处估算显著偏离实际”的节点，再检查统计、谓词相关性和数据倾斜。

## 5. 状态变化与关键分支

```text
prepared Query_block
  → optimized conditions
  → 候选 key/range/ref/table scan
  → 估算 rows + cost
  → 选择 join order/access method
  → root AccessPath
  → RowIterator tree
  → [EXPLAIN] 只打印
     [EXPLAIN ANALYZE 且可执行] 执行、采样、打印
     [无 root iterator] 报 not executable
```

关键分支一是 sargability；二是经典与 hypergraph 优化器；三是普通 EXPLAIN 与 ANALYZE；
四是 format。8.4 的 ANALYZE 使用 iterator/TREE 路径，不能想当然追加 JSON 并期待相同能力。

## 6. 行为实验：同一谓词，两条物理路径

MySQL 主键等值被优化为执行前取得一行；表达式版本变成全表扫描：

```text
id=19999    → Rows fetched before execution → actual rows=1
id+0=19999  → Table scan on orders → actual rows=20000, filter rows=1
```

PG 同构结果为 Index Scan 对 Seq Scan，后者明确 `Rows Removed by Filter: 19999`。两边共同证明
“结果只有一行”不等于“只读取一行”。若业务必须写表达式，可考虑等价改写或经过验证的表达式/
生成列索引，而不是先用 hint 压住症状。

## 7. 路径实验：为什么 MySQL 走索引，PG 走 Hash Join

数据为 1000 个客户、20000 个订单，每客户恰好 20 单，筛选客户 10..20。

MySQL JSON 估算 query cost 78.44；实际 Nested Loop 外层 11 行，内层 `idx_customer` 每轮 20 行，
合计 220 行。PG 选择 Hash Join：customers 主键取 11 行构建 hash，orders 顺序读 20000 行。
两者都得到 220 行，但成本常量、缓存假设、随机访问估价及候选 join 实现不同，所以计划不同。

这不是判断谁“更聪明”的证据。表仅 20000 行且全在缓存，本实验目的只是证明：同构 SQL 和数据
并不保证计划树同构；迁移后必须重新 EXPLAIN，而不能翻译旧计划。

## 8. optimizer_trace：回答“为什么”

可索引条件的 trace 同时比较 table scan 与 range/ref：table scan cost 1999.75，range 估算 20 行、
cost 2.26463，最终 ref access cost 2.25463 且 chosen。表达式条件没有形成可用 range，最终 scan
估算 19734 行、cost 1997.65 被选择。

trace 是一次会话中最近语句的优化过程，不是长期历史；读取 trace 的查询本身也可能覆盖上下文，
因此紧跟目标 SQL 读取，并关注 `MISSING_BYTES_BEYOND_MAX_MEM_SIZE`。

## 9. ANALYZE 安全边界

sleep 实验中普通 EXPLAIN 没等待执行，MySQL ANALYZE 对 10 行累计约 105ms；PG ANALYZE 约 168ms。
这证明支持的 SELECT 被真实执行。生产使用前必须评估锁、CPU、IO、外部函数与查询时长。

DML 更不能跨库类推：PG 事务内 UPDATE 从 1.70 变为 101.70，EXPLAIN 显示 5 条 WAL record、352
bytes，ROLLBACK 后恢复 1.70；MySQL 8.4.10 同语句返回不可由 iterator executor 执行，金额始终
1.70。结论限于本次版本/语句形态，安全操作仍应使用测试环境或显式事务验证。

## MySQL 实操：命令与 SQL

### 10.1 连接与建模

```bash
/usr/local/mysql/mysql-8.4.10/bin/mysql \
  --no-defaults -uroot -S /tmp/mysql.sock
```

```sql
CREATE DATABASE opt_lab;
USE opt_lab;
CREATE TABLE customers (
  id INT PRIMARY KEY, region VARCHAR(8) NOT NULL,
  KEY idx_region(region)
) ENGINE=InnoDB;
CREATE TABLE orders (
  id INT PRIMARY KEY, customer_id INT NOT NULL,
  status VARCHAR(12) NOT NULL, amount DECIMAL(10,2) NOT NULL,
  created_at DATETIME NOT NULL,
  KEY idx_customer(customer_id), KEY idx_status(status)
) ENGINE=InnoDB;

SET SESSION cte_max_recursion_depth=25000;
INSERT INTO customers
WITH RECURSIVE n AS (SELECT 1 i UNION ALL SELECT i+1 FROM n WHERE i<1000)
SELECT i, CONCAT('r',MOD(i,10)) FROM n;
INSERT INTO orders
WITH RECURSIVE n AS (SELECT 1 i UNION ALL SELECT i+1 FROM n WHERE i<20000)
SELECT i,MOD(i,1000)+1,IF(MOD(i,200)=0,'rare','common'),
       MOD(i*17,10000)/10,TIMESTAMP('2026-01-01')+INTERVAL MOD(i,365) DAY
FROM n;
ANALYZE TABLE customers,orders;
```

### 10.2 先静态，再实际

```sql
EXPLAIN FORMAT=TREE SELECT * FROM orders WHERE id=19999;
EXPLAIN FORMAT=JSON SELECT * FROM orders WHERE id=19999;
EXPLAIN ANALYZE SELECT * FROM orders WHERE id=19999;

EXPLAIN ANALYZE SELECT * FROM orders WHERE id+0=19999;
EXPLAIN ANALYZE
SELECT c.region,COUNT(*),SUM(o.amount)
FROM customers c JOIN orders o ON o.customer_id=c.id
WHERE c.id BETWEEN 10 AND 20 GROUP BY c.region;
```

预期结果与阅读顺序：先访问方法和 join 顺序，再估算 rows，接着 actual rows/loops，最后 time。首次执行与热缓存
差异很大；不要只按最后一个毫秒数字优化，也不要直接比较两种数据库的 cost。

### 10.3 采集 optimizer_trace

```sql
SET optimizer_trace='enabled=on', optimizer_trace_max_mem_size=1048576;
SELECT COUNT(*) FROM orders WHERE customer_id=42;
SELECT TRACE,MISSING_BYTES_BEYOND_MAX_MEM_SIZE
FROM information_schema.optimizer_trace\G
SET optimizer_trace='enabled=off';
```

然后将谓词替换为 `customer_id+0=42` 重复。依次查找 `ref_optimizer_key_uses`、
`potential_range_indexes`、`analyzing_range_alternatives`、`considered_access_paths`、`chosen` 和 `cause`。

### 10.4 DML 验证与清理

```sql
SELECT amount FROM orders WHERE id=1;
START TRANSACTION;
EXPLAIN ANALYZE UPDATE orders SET amount=amount+100 WHERE id=1;
SELECT amount FROM orders WHERE id=1;
ROLLBACK;
SELECT amount FROM orders WHERE id=1;

DROP DATABASE opt_lab;
```

不要在生产上用这一段探测未知版本。先在同版本测试库确认支持边界；即使本版拒绝该 UPDATE，也不
能推出未来版本、multi-table UPDATE 或其他 DML 永远不会执行。

## 11. 源码—实验—生产映射

| 源码事实 | 实验证据 | 生产判断/动作 |
|---|---|---|
| `update_ref_and_keys()` 建 key/ref 信息 | 表达式谓词无 range/ref 候选 | 先改写谓词，再考虑索引/hint |
| `make_join_plan()` 估行并选表序 | MySQL 11×20 Nested Loop | rows×loops 检查放大倍数 |
| `AccessPath` 创建 RowIterator | TREE 与 ANALYZE 节点一致并有 actual | 静态计划与实际执行配对保存 |
| ANALYZE 调 `unit->execute()` | sleep 产生约百毫秒 | 当真实查询控制风险 |
| 缺 root iterator 则拒绝 | MySQL UPDATE 未执行 | 不跨版本/语句推断安全性 |
| PG ANALYZE 执行 ModifyTable | 金额变化并产生 WAL | PG DML 必须 BEGIN/ROLLBACK |

## 12. DBA 排障顺序

1. 保存 SQL、绑定值、表定义、索引和版本；确认是否同一 Query_block/谓词。
2. 先 `EXPLAIN FORMAT=TREE/JSON`，避免一上来执行重查询。
3. 找全表扫描、大 rows、临时表/排序、异常 join 顺序。
4. 在安全环境跑 ANALYZE，按 rows×loops 找第一处估算偏差。
5. 检查 `ANALYZE TABLE`、数据倾斜、相关列、隐式转换和不可 sargable 表达式。
6. 用 optimizer_trace 验证候选路径为何落选。
7. 最后才验证新索引、SQL 改写或 hint，并复测写入成本与不同参数值。

## 13. 证据边界与可复现资产

本次只证明 1000/20000 行、均匀 customer_id、单机热缓存下的选择；不证明大表、冷缓存、并发或
数据倾斜时仍选同一路径。未开启 hypergraph optimizer，相关源码仅标注分支而未据此解释输出。

- `evidence/mysql-optimizer-explain-lab.sh`：独立 33341 实例、完整建模和 MySQL 实验。
- `evidence/mysql-optimizer-explain-output.txt`：版本、计划、trace 和 DML 边界原始输出。
- `evidence/pg-optimizer-explain-lab.sh`：独立 54351 集群的同构对照。
- `evidence/pg-optimizer-explain-output.txt`：PG BUFFERS/WAL/回滚原始输出。

源码锚点基于本机 MySQL 8.4.10：`sql_optimizer.cc:362,722,5359,5393`，
`opt_explain.cc:2105,2152,2247,2258-2286`，`join_optimizer/access_path.cc:488`；PG 18.4：
`planner.c:321,453,669,1896`，`allpaths.c:791-798`，`indxpath.c:240`，`pathnode.c:464`。
