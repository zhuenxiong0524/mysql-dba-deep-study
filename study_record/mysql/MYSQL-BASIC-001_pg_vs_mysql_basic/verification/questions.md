# MYSQL-BASIC-001 验证题（PostgreSQL DBA 视角）

> 做完本章实验后再回答。不要只背语法，要讲"模型差异"。答案单独在 `answers.md`。

## 概念与模型

1. PG 的 `\c db_compare` 与 MySQL 的 `USE db_compare` 在底层有什么本质区别？如何用命令证明（本实验用了哪两个指标）？
2. 在 MySQL 中执行 `CREATE SCHEMA demo;` 之后，`SHOW DATABASES` 会看到什么？这说明 SCHEMA 与 DATABASE 是什么关系？
3. PG 的 database 是"连接边界"。MySQL 的哪个层面最接近这个语义（实例/库/表）？为什么？
4. `root@localhost`、`user@%`、`user@192.168.%` 三个账号分别匹配什么样的连接来源？MySQL 按什么顺序选账号？
5. `USER()` 和 `CURRENT_USER()` 的区别是什么？什么场景下两者会不一样？
6. PG role 与 MySQL user 的模型差异核心是哪一点？`CREATE USER` 在两边各做了什么？
7. PG 的 `serial`/`GENERATED AS IDENTITY` 与 MySQL `AUTO_INCREMENT` 有哪些本质区别（对象、取值、连续性）？
8. 为什么说"MySQL 的 boolean 是 tinyint(1)"？它和 PG boolean 在哪些行为上会不一样？
9. `timestamptz` 与 `datetime` 的语义差异是什么？MySQL 里 timestamp 还有什么额外限制？

## 行为差异（本实验实测过）

10. MySQL 默认 sql_mode 下，`SELECT 'hello'||' '||'world';` 返回什么？为什么？正确写法是什么？
11. `LENGTH('中文')` 在 PG 与 MySQL 分别返回什么？为什么？
12. 为什么 `'abc'='ABC'` 在 MySQL 返回 1 而在 PG 返回 false？哪个参数/设置决定的？会影响索引吗？
13. 在一个 `START TRANSACTION` 里 `CREATE TABLE` 后 `ROLLBACK`，MySQL 里表还在吗？PG 呢？TRUNCATE 呢？
14. MySQL `UPDATE` 后显示 `Rows matched: 1 Changed: 0` 意味着什么？PG 的 `UPDATE 1` 与它有什么语义差异？
15. `SHOW VARIABLES`/`@@var` 与 `pg_settings` 的对应关系是什么？`@@session.innodb_buffer_pool_size` 为什么报错？
16. `SET PERSIST` 与 `SET PERSIST_ONLY` 的区别？用什么命令撤销持久化？重启后哪个生效？

## 运维排障

17. 本环境 `performance_schema=OFF` 时，查看会话有哪些可用的方法？哪些表/视图会直接不可用？
18. PG 用 `pg_terminate_backend(pid)` 杀会话；MySQL 用什么？这个标识在两边分别对应什么（进程号/连接号）？
19. 非超管查 `pg_stat_activity` 看其他用户会话时 query 列显示什么？MySQL 侧要看全量会话需要什么权限？
20. MySQL 的 EXPLAIN 默认输出与 PG 的 EXPLAIN 有什么结构差异？想看"实际执行时间"各用什么命令？
21. 本机 MySQL 为什么 `mysql -h 127.0.0.1 -u root` 连不上，而 `mysql -uroot`（socket）能连上？涉及哪两个配置？
22. PG 18 中 `SHOW lc_collate` 报错说明什么？应该去哪查？MySQL 8.4 中 `default_authentication_plugin` 报错说明什么？替代变量是什么？
