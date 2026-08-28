# environment-baseline：MySQL 8.4 / PG 18.4 学习环境基线

> 生成：2026-08-28（实机探测，证据：`study_record/env/ENV-005_mysql_instance_lifecycle/evidence/env-probe*.txt`）
> 原则：所有专题基于本基线，不假设 3306 / /etc/my.cnf / /var/lib/mysql / /tmp/mysql.sock 一定成立。

## 1. 主机

```text
OS:        Debian GNU/Linux 11 (bullseye)，Linux node01 5.10.0-38-amd64
资源:      1 CPU / 2GB RAM / 4G swap（实验参数必须保守）
主机名:    node01
本机 IP:   192.168.101.129
```

## 2. MySQL 8.4.10 LTS（学习主实例）

```text
二进制:     /usr/local/mysql/mysql-8.4.10/（源码编译安装，Source distribution）
mysql CLI:  /usr/local/bin/mysql（软链）→ mysql Ver 8.4.10
mysqld:     /usr/local/mysql/mysql-8.4.10/bin/mysqld
mysqldump:  /usr/local/bin/mysqldump；mysqladmin: /usr/local/bin/mysqladmin
mysqlbinlog:/usr/local/mysql/mysql-8.4.10/bin/mysqlbinlog
xtrabackup: 未安装（备份专题用 mysqldump + binlog 逻辑路线，物理备份按需评估）

运行用户:   mysql（mysqld_safe 托管，非 systemd：无 mysqld.service/mysql.service）
端口:       3306（TCP，*:3306）；33060（X Protocol）
Socket:     /tmp/mysql.sock（+ /tmp/mysqlx.sock）
datadir:    /data/myhome/mydata/mysql/
basedir:    /usr/local/mysql/mysql-8.4.10/
pid_file:   /data/myhome/mydata/mysql/mysql.pid
log_error:  /data/myhome/mydata/mysql/error.log（还有 mysqld_safe.log）
配置文件:   /etc/my.cnf（datadir/port/socket/pid/log_error/innodb_buffer_pool_size=64M/performance_schema=OFF/skip-name-resolve/max_connections=100/character_set_server=utf8mb4）
mysqld-auto.cnf: /data/myhome/mydata/mysql/mysqld-auto.cnf（SET PERSIST 持久化文件）
server_uuid: 1709cb6a-a133-11f1-b0cd-000c29951355

关键参数（实测）:
  innodb_buffer_pool_size = 67108864（64M）
  performance_schema      = OFF（P_S 表为空，排障用 SHOW PROCESSLIST / STATUS / information_schema 兜底）
  log_bin                 = ON
  skip-name-resolve       = ON（TCP 连接按 IP 匹配 host）
  max_connections         = 100
```

### datadir 构成（实例 = 这些文件/目录）

```text
mysql.ibd        数据字典（8.0+ 取代 .frm）
ibdata1          系统表空间（双写页所在，8.0 已迁移 dblwr）
#ib_16384_*.dblwr  doublewrite 文件
#innodb_redo/    redo log
#innodb_temp/    临时表空间
undo_001          undo 表空间
ibtmp1           临时表空间
binlog.00000x    binlog + binlog.index
mysql/ sys/ performance_schema/ cmp/ ...  数据库目录（.ibd 独立表空间）
auto.cnf         server_uuid
mysql.pid        进程 PID
error.log        error log
mysqld_safe.log  mysqld_safe 日志
*.pem            SSL 证书（ca/server/client/private/public）
ib_buffer_pool   buffer pool 预热文件
mysqld-auto.cnf  PERSIST 参数
```

## 3. PostgreSQL 18.4（PG 基线实例）

```text
二进制:     /usr/local/pgsql/pgsql18.4/（源码编译）
psql:       /usr/local/pgsql/pgsql18.4/bin/psql（psql 18.4）
端口:       54184（0.0.0.0 + ::）
运行用户:   postgres（postmaster 进程），mysql 用户 trust 免密连接
data_directory: /data/pgdata/pgdata18.4
config_file:    /data/pgdata/pgdata18.4/postgresql.conf
log_directory:  log（/data/pgdata/pgdata18.4/log）
pg_hba.conf:    local/127.0.0.1/::1 = trust；192.168.101.0/24 = md5

进程家族（ps 实测）:
  postgres -D /data/pgdata/pgdata18.4（postmaster）
  postgres: logger / io worker 0-2 / checkpointer / background writer / walwriter
  autovacuum launcher / logical replication launcher / backend（按连接生成）

注意: postgres 用户还运行 patroni(/etc/patroni.yml)、pgbouncer(/etc/pgbouncer)、redis(6379, DCS)
      —— PG 侧是带 HA 栈的环境；MySQL 学习实例是裸 mysqld_safe 单实例，管理方式不同。
```

## 4. 连接方式速查

```bash
# MySQL（root 空密码仅 socket；TCP 需匹配的 Account）
mysql -uroot -S /tmp/mysql.sock
mysql -uroot -h127.0.0.1 -P3306 -p
# PG（mysql 用户 trust）
psql -h 127.0.0.1 -p 54184 -U mysql -d mysql
```

## 5. 实验安全红线（详见 study_record/safety.md）

- 破坏性实验数据库统一 `mysql_lab_*`，账号 `lab_*`，表 `t_*`
- 不修改 root/postgres 等重要账号；不动现有业务库（cmp/db_compare/db_compare2/demo_schema）
- crash/kill 实验只允许在专用实验实例上做（当前 3306 是学习主实例，不执行 kill）
- 1C/2G：大表/并发实验控制规模，避免 OOM
