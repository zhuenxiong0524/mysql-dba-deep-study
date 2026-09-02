# ISO-001 理解验证答案

1. Record 锁索引记录；Gap 锁记录前的空隙；Next-Key=记录锁+其前方 Gap；Insert Intention 是插入者申请某个 Gap 中位置时的等待标志。
2. 锁落在“右端索引记录”上并连同其前方间隙，例如记录 20 上的 Next-Key 表示 `(10,20]`；边界还可能涉及 supremum。
3. RR 普通 SELECT 是一致性读，走 ReadView、不加记录范围锁；`FOR UPDATE` 是当前读，要对搜索路径上的索引记录/间隙加锁。
4. RR 的 `skip_gap_locks()` 为 false，范围扫描使用 Next-Key；RC 为 true，普通搜索通常只锁记录，id=15 所在间隙可插入。唯一/外键检查等有例外。
5. PG 的 tuple lock 锁已找到的 CTID，没有 InnoDB 那种 B-tree gap lock；因此不存在的 id=15 没有被 `FOR UPDATE` 锁住。
6. 不能。它是固定 MVCC snapshot 的结果可见性，不是插入被阻塞；T2 实际已经立即提交。
7. 唯一等值命中已精确定位，不需要保护前方间隙来防止同一谓词出现另一条记录，源码使用 `LOCK_REC_NOT_GAP`。
8. 它让插入在冲突 gap/next-key 锁后排队；不同位置的 insert intention 通常彼此兼容，不是把整个间隙串行化。
9. T1 持有行1等行2，T2持有行2等行1，等待图成环。统一加锁顺序、缩短事务、一次锁齐可降低概率；发生后回滚 victim 并带退避重试整个事务。
10. 重试整个事务，因为 victim 的事务上下文已被回滚或标记 aborted，单独重放失败语句不能恢复原子语义。
11. 两者 RR 都是 snapshot-isolation 风格：各事务读取相同旧快照，却更新不同行，没有 write-write 冲突，跨行不变量无人保护。
12. 不会。SIReadLock 是检测 rw-conflict 的非阻塞 predicate lock；写入可以先完成，SSI 随后判断是否出现危险结构。
13. 典型结构为 `Tin --rw--> Tpivot --rw--> Tout`。若可能形成序列化环，SSI 标记/取消 pivot；本实验一个事务在 COMMIT 报 serialization failure。
14. 显式事务中普通 SELECT 被转成共享锁（LOCK_S）。两会话先读完、互持所有匹配行 S 锁，再各自升级目标行为 X，等待成环。
15. PG 是乐观的非阻塞冲突跟踪、提交期取消；MySQL 是悲观的 S/X 锁阻塞与死锁检测。吞吐、等待形态、诊断证据都不同。
16. PG 默认 RC，MySQL 默认 RR。迁移时若未显式配置，事务内第二次读的快照语义、锁范围和冲突方式都可能改变。
17. 活跃事务看 `information_schema.innodb_trx` 与 `SHOW FULL PROCESSLIST`；锁细节和最近死锁看 `SHOW ENGINE INNODB STATUS\G`。
18. MySQL 1205 是锁等待超时，先找阻塞链；1213 是死锁 victim。PG 40P01 是死锁，40001 是序列化失败；后两类都应回滚并重试整个事务，同时修正访问顺序/事务设计。
