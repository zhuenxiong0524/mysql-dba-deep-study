# ISO-001 理解验证题

1. InnoDB Record、Gap、Next-Key、Insert Intention Lock 分别保护什么？
2. 为什么说 Next-Key Lock 是“左开右闭”的索引区间？
3. MySQL RR 的普通 SELECT 与 `SELECT ... FOR UPDATE` 在锁行为上有何区别？
4. 为什么 MySQL RR 范围锁定读会阻塞 id=15 的插入，而 RC 不会？
5. PG RR 的范围 `FOR UPDATE` 为什么不阻塞不存在键 id=15 的插入？
6. PG RR 在 T2 插入提交后仍看不到 id=15，能否据此说 PG 使用了 Gap Lock？
7. 唯一索引等值命中时，InnoDB 为什么通常可以退化为 Record Lock？
8. Insert Intention Lock 的作用是什么？它是否让所有并发插入互斥？
9. 两行反序更新为什么形成死锁？避免和恢复死锁的通用办法是什么？
10. MySQL 1213 与 PG deadlock detected 之后，应用应该重试一条语句还是整个事务？
11. 为什么 MySQL RR 和 PG RR 都会出现 doctor_lab 写偏差？
12. PG SSI 的 SIReadLock 是否会像 InnoDB Gap Lock 一样阻塞写入？
13. PG SSI 所说的 dangerous structure 是什么？本实验为何在提交时取消一个事务？
14. MySQL SERIALIZABLE 如何处理显式事务里的普通 SELECT？本实验为何产生死锁？
15. PG SSI 与 MySQL SERIALIZABLE 都保住不变量，为什么仍不能说实现等价？
16. 两边默认隔离级别是什么？从 PG 迁移 MySQL 最容易误判什么？
17. 本机 P_S=OFF 时，MySQL 锁等待和死锁分别去哪里看？
18. 生产中看到 1205、1213、PG 40P01、PG 40001，各自表示什么处置方向？
