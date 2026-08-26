# MySQL 8.4.10 源码编译安装与双引擎对照环境就绪

> 任务：`ENV-001`
> 主文章类型：`environment`
> MySQL 版本：`8.4.10 LTS（Source distribution）`
> 对照基线：PostgreSQL 18.4（/usr/local/pgsql/pgsql18.4，端口 54184）
> 证据类型：实际执行 / 配置文件确认 / 运行状态确认 / 双向连接验证

## 1. 目标与环境基线

本专题记录 MySQL 8.4.10 LTS 从源码到可用学习实例的完整搭建过程，形成与 PG 18.4
并行的双引擎对照学习环境（MySQL:3306 ↔ PG:54184）。

### 1.1 操作系统与硬件

```text
OS:      Debian GNU/Linux 11 (bullseye)
Arch:    x86_64
CPU:     1 核
内存:    2 GB（编译期额外 4G swap）
磁盘:    /data 78G 可用（/tmp 仅 601M，不可用于解压）
```

### 1.2 与 PG 对照环境布局

| 项 | PostgreSQL 18.4 | MySQL 8.4.10 |
|---|---|---|
| 安装方式 | 源码编译 | 源码编译 |
| 安装路径 | /usr/local/pgsql/pgsql18.4 | /usr/local/mysql/mysql-8.4.10 |
| 数据目录 | /data/pgdata/pgdata18.4 | /data/myhome/mydata/mysql |
| 端口 | 54184 | 3306 |
| 运行用户 | postgres | mysql |
| 源码 | /data/soft/postgres/postgresql-18.4 | /data/myhome/mydata/mysql-src/mysql-8.4.10 |

## 2. 源码获取与校验

版本选择：MySQL 8.4 LTS 最新小版本 **8.4.10**（2026-06 发布）。

```bash
# 官方 CDN 与清华镜像（SHA256 一致，走镜像提速）
curl -C - -fL -o mysql-8.4.10.tar.gz \
  "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/m/mysql-8.4/mysql-8.4_8.4.10.orig.tar.gz"
sha256sum mysql-8.4.10.tar.gz
# d57a6730baef14ae118f7f4a6e02845b5b50933758df61fb06e104f27ccc8f96
# 与 FreeBSD ports / Launchpad 官方记录一致
```

- 源码包大小：457MB（解压后 1.2G）
- 官方 CDN 直连约 200KB/s，清华镜像 2-3MB/s（本机选镜像）

## 3. 构建配置（cmake）

工具链实测：cmake 3.30.2 / gcc 10.2.1 / bison 3.7.5 / flex 2.6.4 / openssl 1.1.1 / ICU 67。

```bash
cmake -S /data/myhome/mydata/mysql-src/mysql-8.4.10 \
      -B /data/myhome/mydata/mysql-src/build \
      -DCMAKE_INSTALL_PREFIX=/usr/local/mysql/mysql-8.4.10 \
      -DCMAKE_BUILD_TYPE=Release \
      -DWITH_SSL=system \
      -DWITH_ZLIB=bundled \
      -DWITH_ICU=system \
      -DWITH_UNIT_TESTS=OFF \
      -DWITH_TESTS=OFF \
      -DMYSQL_MAINTAINER_MODE=OFF \
      -DDOWNLOAD_BOOST=0
```

### 3.1 关键决策与坑

| 问题 | 处理 |
|---|---|
| 系统 zlib 1.2.11 < 1.2.13（MySQL 最低要求） | `-DWITH_ZLIB=bundled` 用源码自带 zlib |
| NUMA 头文件缺失 | 可选，cmake 自动禁用（不影响） |
| Doxygen 缺失 | 仅文档，不影响编译 |
| 1C/2G 编译 OOM 风险 | 先加 4G swap（`fallocate`+`mkswap`+`swapon`），链接峰值实测 swap 用到 1.3G |
| cmake 输出确认 | `MySQL 8.4.10`、`C++20`、`HAVE_TLSv13` |

## 4. 编译与安装

```bash
make -j1            # 1 核，约 3 小时；后台 setsid 运行，日志 build.log
make install        # 安装到 /usr/local/mysql/mysql-8.4.10
```

验证：

```bash
/usr/local/mysql/mysql-8.4.10/bin/mysqld --version
# mysqld  Ver 8.4.10 for Linux on x86_64 (Source distribution)
```

编译阶段观察：abseil/protobuf（bundled）→ sql/ 主体（最慢，单文件 1-3 分钟）→
InnoDB（文件多但快）→ Router → 链接（最后内存峰值）。`mysqld` 二进制 98MB。

## 5. 初始化与启动

### 5.1 my.cnf（保守参数，适配 1C/2G 双实例共存）

```ini
[mysqld]
datadir=/data/myhome/mydata/mysql
port=3306
socket=/tmp/mysql.sock
pid-file=/data/myhome/mydata/mysql/mysql.pid
log_error=/data/myhome/mydata/mysql/error.log
innodb_buffer_pool_size=64M
innodb_redo_log_capacity=96M
performance_schema=OFF
skip-name-resolve
max_connections=100
character_set_server=utf8mb4
```

> 注意：MySQL 8.0.30+ 已用 `innodb_redo_log_capacity` 替代旧 `innodb_log_file_size`。

### 5.2 初始化与启动

```bash
mysqld --initialize-insecure --user=mysql --datadir=/data/myhome/mydata/mysql
mysqld_safe --user=mysql &        # setsid 后台
mysql -uroot -S /tmp/mysql.sock -e "SELECT VERSION(), @@port;"
# 8.4.10 | 3306
```

系统库就绪：information_schema / mysql / performance_schema / sys。

## 6. 双引擎交叉访问

### 6.1 用户建立

```sql
CREATE DATABASE IF NOT EXISTS cmp;
CREATE USER 'pg'@'localhost' IDENTIFIED BY '***';        -- socket
CREATE USER 'pg'@'127.0.0.1' IDENTIFIED BY '***';        -- TCP（skip-name-resolve 必需）
GRANT ALL PRIVILEGES ON cmp.* TO 'pg'@'localhost', 'pg'@'127.0.0.1';
```

认证插件默认 `caching_sha2_password`（8.4 默认，PG 侧 trust/scram 对照）。

### 6.2 双向验证

```text
mysql 用户 → PG:    psql -U mysql -d mysql -h 127.0.0.1 -p 54184 → OK (18.4)
postgres 用户 → MySQL: mysql -upg -h127.0.0.1 -P3306 cmp → OK (8.4.10, pg@127.0.0.1)
```

## 7. 环境检查

```bash
./scripts/check_environment.sh
# PASS=13 WARN=0 FAIL=0（软件/MySQL/PG/资源/项目 5 组全绿）
```

## 8. 关键结论与 DBA 意义

1. **MySQL 源码包比预想大得多**（457MB），1 核机器全量编译约 3 小时；核心结论：
   编译链路依赖 cmake/ICU/SSL，zlib 必须 bundled 版本。
2. **内存规划**：2G 内存编译链接峰值需要 4G swap 兜底；实例运行期 PG+MySQL 双实例
   共存约 500MB 内可接受，但实验须控制连接数。
3. **8.4 参数语义变化**：`innodb_redo_log_capacity` 取代 `innodb_log_file_size`，
   `caching_sha2_password` 取代 `mysql_native_password` 默认位——迁移时不能照抄 5.7/8.0 旧文档。
4. **skip-name-resolve 对账号匹配的影响**：TCP 连接需显式建 `'user'@'127.0.0.1'`，
   否则 `ERROR 1130`（这是生产环境常见配置与排障点）。

## 9. Evidence

- evidence/download-verify.json：下载 URL / SHA256 / 大小
- evidence/cmake-config.txt：构建参数与结果
- evidence/install-verify.json：安装路径、实例状态、交叉访问验证

## 10. 后续深化方向

- ENV-002 双引擎交叉访问与对照实验工具链（同 SQL 两边跑脚本模板）
- MVCC-001 事务版本链对照（PG xmin/xmax vs InnoDB undo/ReadView）——首篇对照文章
