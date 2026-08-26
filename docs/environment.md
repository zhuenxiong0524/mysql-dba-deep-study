# MySQL 8.4.10 LTS 环境（源码编译安装）

## 路径约定

```text
项目根：    /data/myhome/myfuture/dba_one_year_mysql
MySQL 二进制：/usr/local/mysql/mysql-8.4.10
数据目录：  /data/myhome/mydata/mysql
源码：      /data/myhome/mydata/mysql-src/mysql-8.4.10
构建目录：  /data/myhome/mydata/mysql-src/build
socket：    /tmp/mysql.sock
端口：      3306
运行用户：  mysql
```

> 注：`/usr/local/mysql` 由 mysql 用户所有（`sudo mkdir` + `chown mysql:mysql`），
> 源码/构建目录在 `/data/myhome/mydata`（mysql 用户可写），`/tmp` 空间小（601M）不可用于解压。

## 安装记录（2026-08-26）

1. 版本选择：MySQL 8.4 LTS 最新 **8.4.10**
   - 二进制包：`mysql-8.4.10-linux-glibc2.28-x86_64.tar.xz`（793MB，未使用）
   - 源码包：`mysql-8.4.10.tar.gz`（457MB，本方案采用）
2. 下载与校验：
   - 官方 CDN：`https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.10.tar.gz`
   - 国内镜像（更快）：清华 `https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/m/mysql-8.4/mysql-8.4_8.4.10.orig.tar.gz`（SHA256 与官方一致）
   - 校验：`sha256sum` = `d57a6730baef14ae118f7f4a6e02845b5b50933758df61fb06e104f27ccc8f96`
3. 解压：`tar -xzf mysql-8.4.10.tar.gz -C /data/myhome/mydata/mysql-src/`（解压后 1.2GB）
4. 构建配置（cmake 3.30.2 / gcc 10.2 / bison 3.7 / flex 2.6）：

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

   - 关键点：系统 zlib 1.2.11 < 1.2.13，必须 `-DWITH_ZLIB=bundled`
   - NUMA 缺失（可选，自动禁用）；Doxygen 缺失（文档，不影响）
5. 编译：`make -j1`（1 CPU，约 1.5–3 小时；编译前需 4G swap 防链接 OOM）
6. 安装：`make install` → `/usr/local/mysql/mysql-8.4.10`

## 初始化与启动（已完成）

```bash
# 初始化（root 空密码，后续收紧）
/usr/local/mysql/mysql-8.4.10/bin/mysqld \
  --initialize-insecure --user=mysql --datadir=/data/myhome/mydata/mysql

# my.cnf（保守参数，适配 1C/2G）
[mysqld]
datadir=/data/myhome/mydata/mysql
port=3306
socket=/tmp/mysql.sock
innodb_buffer_pool_size=64M
innodb_log_file_size=48M
performance_schema=OFF
skip-name-resolve
max_connections=100

# 启动
/usr/local/mysql/mysql-8.4.10/bin/mysqld_safe --user=mysql &
```

实际配置（/etc/my.cnf）：innodb_buffer_pool_size=64M、innodb_redo_log_capacity=96M、
performance_schema=OFF、skip-name-resolve、max_connections=100。

验证结果：socket /tmp/mysql.sock，8.4.10，系统库 information_schema/mysql/performance_schema/sys。
交叉用户：pg@localhost（socket）+ pg@127.0.0.1（TCP，skip-name-resolve 下 TCP 需显式 host），
密码认证 caching_sha2_password，授权库 cmp。

## 交叉访问矩阵

| 来源 \\ 目标 | PG 18.4 (54184) | MySQL 8.4 (3306) |
|---|---|---|
| postgres 用户 | 本机直连 | `pg@localhost` |
| mysql 用户 | `mysql` role @ 库 mysql（trust 免密） | 本机直连 |
