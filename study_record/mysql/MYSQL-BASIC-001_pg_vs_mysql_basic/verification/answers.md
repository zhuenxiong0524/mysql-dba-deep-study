# MYSQL-BASIC-001 验证题答案（基于本机实机实验）

1. PG `\c` 是重新建立连接：同一 psql 会话中 backend pid 从 5007 变为 5008。MySQL `USE` 不新建连接：
   `CONNECTION_ID()` 前后都是 41，只改变"当前默认数据库"。
2. `SHOW DATABASES` 里出现 `demo_schema`。说明 MySQL 的 SCHEMA 就是 DATABASE 的同义词，
   没有 PG 那种 database→schema→table 的三层结构。
3. 实例级。PG 的 database 有独立文件、独立系统目录、独立连接；MySQL 所有库共享一个数据字典、
   一个 buffer pool、一套后台线程，"隔离"主要靠账号权限和库名。
4. `root@localhost` 只匹配 socket/本机；`user@%` 匹配任意主机；`user@192.168.%` 匹配网段。
   匹配顺序：最精确的 host 优先（精确 IP > 网段 > %），本实验 socket→localhost、回环 TCP→127.0.0.1、
   LAN IP→% 三种结果验证了这一点。
5. `USER()` 是客户端声称的身份（user@来源IP）；`CURRENT_USER()` 是服务端实际匹配到的账号
   （可能带 % 通配）。本实验：`-h 192.168.101.129` 时 `USER()=compare_user@192.168.101.129`、
   `CURRENT_USER()=compare_user@%`。
6. PG role 是全局唯一的对象，"能否登录"只是 LOGIN 属性（CREATE USER 即 CREATE ROLE LOGIN）；
   MySQL 账号是 (user, host) 二元组，密码/权限都挂在二元组上，同一个用户名在不同 host 下是不同账号。
7. PG sequence/identity 是独立数据库对象：有 nextval/currval、可跨表共享、identity 更严格
   （不可手插除非 OVERRIDING SYSTEM VALUE）；MySQL AUTO_INCREMENT 没有独立对象，计数器在表元数据
   （SHOW TABLE STATUS 的 Auto_increment 列），取新 id 用 LAST_INSERT_ID()，8.0 起不保证连续。
8. MySQL `BOOLEAN` 只是 `tinyint(1)` 的别名（SHOW CREATE TABLE 直接显示 tinyint(1)），值域是 0/1，
   而 PG boolean 是独立类型（true/false）；行为差异体现在存储、比较、以及客户端驱动对返回值的解释。
9. `timestamptz` 存 UTC、按会话时区显示；`datetime` 无时区概念、存什么显示什么。MySQL `timestamp`
   会把会话时区换算成 UTC 存储、且有 2038 年上限；生产默认选 `datetime` 通常更省心。
10. 返回 `0`。默认 sql_mode 不含 `PIPES_AS_CONCAT`，`||` 是逻辑 OR；在 OR 的数值上下文中非数字字符串
    转为 0（实测 'hello'+0=0、' ' +0=0、'world'+0=0），所以 `0 OR 0 OR 0 = 0`。
    正确写法 `CONCAT('hello',' ','world')`。
11. PG `length('中文')=2`（字符数），`octet_length('中文')=6`（字节数）；MySQL `LENGTH('中文')=6`（字节数）、
    `CHAR_LENGTH('中文')=2`。MySQL 的 LENGTH 与 PG 的 octet_length 对应。
12. MySQL 默认 collation `utf8mb4_0900_ai_ci`（ci=case-insensitive，ai=accent-insensitive）使等值比较不区分大小写；
    PG 默认区分大小写。同一 collation 也作用于唯一索引判重和 ORDER BY 排序，建表必须显式选择。
13. MySQL：表还在（DDL 隐式提交，不可回滚），`SHOW TABLES LIKE 't_ddl_test'` 有结果；
    PG：表消失（DDL 事务性）。TRUNCATE 同理：MySQL 隐式提交后 ROLLBACK 无效（行数 0），
    PG 可回滚（行数 1）。
14. `Rows matched: 1 Changed: 0` 表示匹配 1 行但实际没有值变化（affected=0）；PG 的 `UPDATE 1`
    按匹配行数报告，不区分"匹配"与"实际修改"。这影响应用层受影响行数的解读（如 JDBC getUpdateCount）。
15. `pg_settings` ↔ system variables：PG 全部会话/实例参数一张表；MySQL 分 GLOBAL/SESSION 两级，
    且变量有"作用域属性"。`innodb_buffer_pool_size` 是 GLOBAL-only，`@@session.` 读取报
    `ERROR 1238: Variable ... is a GLOBAL variable`。
16. `SET PERSIST` = 立即改全局 + 写 `mysqld-auto.cnf`（重启保留）；`SET PERSIST_ONLY` = 只写配置文件
    （下次启动生效，当前值不变）。撤销用 `RESET PERSIST <var>`（实验后已还原为空 JSON）。
17. 可用：`SHOW PROCESSLIST`、`SHOW FULL PROCESSLIST`、`information_schema.PROCESSLIST`；
    不可用：`performance_schema.threads`、sys schema 大部分表（Table doesn't exist）。
18. MySQL 用 `KILL <connection_id>`（`CONNECTION_ID()` 获得）；PG 用 `pg_terminate_backend(<pid>)`。
    PG 的标识是 OS 进程号（ps 可见）；MySQL 是内部连接号，与 OS pid 无直接对应。
19. 显示 `<insufficient privilege>`（本实验实测）；MySQL 看全量会话需要 PROCESS 权限，否则只见自己。
20. PG EXPLAIN 是树形 + cost 估算（`EXPLAIN (ANALYZE, BUFFERS)` 给实际时间/Buffers）；
    MySQL 默认是表格式（type/key/rows/Extra，无 cost），`EXPLAIN ANALYZE`（8.0.18+）才是 TREE + 实际时间，
    `EXPLAIN FORMAT=JSON` 给结构化输出。
21. 两个配置：`skip-name-resolve=ON`（TCP 按 IP 匹配账号，不做反解）+
    root 只有 `root@localhost` 账号（socket 匹配 localhost 成功；TCP 127.0.0.1 无对应账号 → Access denied）。
22. PG 18 起 `lc_collate`/`lc_ctype` 不再是 GUC，改查 `pg_database.datcollate/datctype`；
    MySQL 8.4 移除了 `default_authentication_plugin`，替代是 `authentication_policy`（本机 `'*,,'`）。
