# MySQL 生产命令手册（按问题分类，不按命令分类）

> 持续扩展：每完成一个专题填充对应问题段。证据来自本机实测（study_record/env/ENV-00x/evidence）。
> 通用：`mysql -uroot -S /tmp/mysql.sock`（本机 root 仅 socket 空密码；生产必须用强口令账号 + login-path）

## 实例是否正常 / 实例在哪？

```bash
# 进程
ps -ef | grep mysqld | grep -v grep        # mysqld_safe → mysqld 两行
# 端口
ss -lntp | grep 3306
# socket
ss -lx | grep mysql
# 存活探针（等价 pg_isready）
mysqladmin -uroot -S /tmp/mysql.sock ping
# 状态计数（Uptime/Threads/Questions/Opens/Queries per second）
mysqladmin -uroot -S /tmp/mysql.sock status
```

```sql
SELECT @@hostname, @@port, @@socket, @@datadir, @@basedir, @@pid_file, @@log_error;
SELECT VERSION();
```

结果解释：
- `mysqld is alive` = 实例接受连接
- `ERROR 2002 ... Can't connect` = socket 不存在/实例未启动
- `ERROR 1045 (28000)` = 认证失败（Account 匹配/密码，见 ENV-004/007）
- 本机无 systemd 单元（`systemctl status mysqld` → Unit not found），由 mysqld_safe 托管

## 实例挂了，先看哪里？

```text
1. ps/pid 文件（/data/myhome/mydata/mysql/mysql.pid）→ mysqld 在不在
2. mysqladmin ping → 探活
3. error log 尾部（log_error 指向 /data/myhome/mydata/mysql/error.log）
4. mysqld_safe.log（托管进程日志）
5. 系统资源（df -h 磁盘满？free -m OOM？dmesg | tail）
```

```bash
tail -50 /data/myhome/mydata/mysql/error.log
grep -E "ready for connections|Shutdown complete|ERROR|FATAL" /data/myhome/mydata/mysql/error.log | tail
```

## 当前连接多少 / 谁在跑 SQL？

```sql
SHOW FULL PROCESSLIST;               -- 当前连接 + 正在执行的 SQL（P_S OFF 时兜底）
SHOW GLOBAL STATUS LIKE 'Threads%';  -- Threads_connected / Threads_running
SHOW VARIABLES LIKE 'max_connections';
```

## 当前用户是谁 / 有什么权限？

```sql
SELECT USER(), CURRENT_USER(), CURRENT_ROLE();
SHOW GRANTS;
SHOW GRANTS FOR CURRENT_USER;
```

## 参数从哪里来的？

```sql
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';   -- 当前生效值
SELECT * FROM performance_schema.variables_info; -- 来源（需 P_S=ON，本机 OFF）
-- 配置文件 /etc/my.cnf；PERSIST 文件 /data/myhome/mydata/mysql/mysqld-auto.cnf
```

## 待填充（随专题扩展）

- 数据库/表大小 → BAK/ENG-002
- 长事务/锁等待/deadlock → ISO-001/MON-001
- Buffer Pool/Redo 状态 → BUF-001/REDO-001
- Binlog/复制状态 → LOG-001/REP-001
- 慢 SQL → MON-001
- CPU/IO/磁盘 → MON-001/DR-001
- 备份恢复 → BAK-001/002
