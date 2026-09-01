# 表空间、文件布局与容量管理：从 PG 文件布局迁移

> 版本：v1.0（2026-09-01，双引擎实跑：PG 18.4 @54184 / MySQL 8.4.10 @3306）
> 系列：PG DBA → MySQL 生产 DBA 迁移项目 · 第二阶段专题 6（ENG-002）
> 关联：ENG-001（进程/线程基线）；BAK-001（备份前必须懂文件布局）
> 证据：`evidence/pg-file-layout.txt`、`evidence/mysql-file-layout.txt`
> 本文所有输出均为本机实跑真实输出，命令可直接复制执行。

---

## 0. 一句话结论

- **PG**：一个数据库 = `base/<oid>/` 一个目录，一张表 = 一个按 `relfilenode` 命名的文件；DELETE 不缩文件，`VACUUM FULL` 换新 relfilenode 重写，`TRUNCATE` 也是换新文件。
- **MySQL**：`innodb_file_per_table=ON`（默认）时一张 InnoDB 表 = 一个 `库名/表名.ibd` 文件；DELETE 不缩文件，`OPTIMIZE TABLE`（实际是 ALTER 重建）收缩，`TRUNCATE` 重建 `.ibd` 回到初始 7 页。
- **8.4 关键差异**：数据字典在 `mysql.ibd`，`ibdata1` 不再是"无底洞"（主要放 change buffer 等系统数据，本机 `innodb_change_buffering=none`）；undo 独立 `undo_001/undo_002`，redo 独立 `#innodb_redo/` 目录，doublewrite 独立 `#ib_16384_*.dblwr`。

---

## 1. PostgreSQL 基线：文件布局与"空间不回收"

### 1.1 datadir 结构

```bash
ls /data/pgdata/pgdata18.4/          # base/ pg_wal/ pg_xact/ ...（权限属 postgres）
```

真实输出（本机 2026-09-01，节选）：

```text
base  pg_wal  pg_xact  pg_multixact  pg_subtrans  pg_commit_ts
global  log  pg_logical  pg_replslot  pg_stat  pg_tblspc  ...
```

要点：`base/` 每个子目录是一个数据库（目录名 = 数据库 OID）；`pg_wal/` 是 WAL；`global/` 是共享 catalog。

### 1.2 一张表对应一个文件（relfilenode）

```sql
CREATE DATABASE lab_eng002;
\c lab_eng002
CREATE TABLE lab_files (id serial PRIMARY KEY, v text DEFAULT repeat('x',100));
SELECT c.relname, c.relkind, c.relfilenode, pg_size_pretty(pg_relation_size(c.oid)) AS size
  FROM pg_class c WHERE c.relname IN ('lab_files','lab_files_id_seq','lab_files_pkey');
```

真实输出：

```text
     relname      | relkind | relfilenode |    size
------------------+---------+-------------+------------
 lab_files_id_seq | S       |       93292 | 8192 bytes
 lab_files        | r       |       93293 | 0 bytes
 lab_files_pkey   | i       |       93301 | 8192 bytes
```

对应文件（`ls -l base/93291/` 中）即 `93292`（序列）、`93293`（表堆）、`93301`（主键索引）等裸数字文件。**表文件路径 = `base/<dboid>/<relfilenode>`**（`pg_relation_filepath('lab_files')` = `base/93291/93293`）。

### 1.3 容量行为实验（关键结论）

```bash
# 插入 2 万行
INSERT INTO lab_files(v) SELECT repeat('x',100) FROM generate_series(1,20000);
# 文件大小
sudo -u postgres stat -c '%s' /data/pgdata/pgdata18.4/base/93291/93293
```

| 操作 | 文件大小 | 说明 |
|---|---|---|
| 建表后 | 0 bytes | 空表无页 |
| INSERT 2 万行 | 2,826,240 bytes（2760 kB） | 页按需扩展 |
| DELETE 一半行（`WHERE id % 2 = 0`） | 2,826,240 bytes 不变 | 死元组占位，不还给文件系统 |
| `VACUUM`（普通） | 2,826,240 bytes 不变 | 死元组与活元组交错，文件不缩 |
| `VACUUM (FULL)` | 1,417,216 bytes（relfilenode 93293→93303，旧文件删除） | 重写表，换新文件 |
| `TRUNCATE` | 0 bytes（relfilenode 93303→93309） | 换新 relfilenode，文件归零 |

真实输出（节选）：

```text
===== 4. 普通 VACUUM =====
VACUUM 后 heap 大小=2826240 bytes relpath=base/93291/93293

===== 5. VACUUM FULL =====
VACUUM FULL 前 relpath=base/93291/93293 大小=2826240
VACUUM FULL 后 relpath=base/93291/93303 大小=1417216
旧 relfilenode 文件: 已删除

===== 6. TRUNCATE =====
TRUNCATE 前 relpath=base/93291/93303 大小=4243456
TRUNCATE 后 relpath=base/93291/93309 大小=0（旧文件已删除）
```

PG 心智模型：**VACUUM FULL / TRUNCATE 都走"换新 relfilenode"**（VACUUM FULL = CLUSTER 变体，源码 `vacuum.c:2311 → cluster_rel`；TRUNCATE `tablecmds.c:1861 ExecuteTruncate → :2228 RelationSetNewRelfilenumber`）。普通 VACUUM 只在文件尾部整页全空时才会截断，中间有活元组就缩不动。

---

## 2. MySQL 文件布局（8.4，本机实测）

### 2.1 datadir 里每样东西是什么

```bash
ls -la /data/myhome/mydata/mysql/
```

真实输出（节选）：

```text
-rw-r----- 1 mysql mysql  12582912 Sep  1 10:24 ibdata1          # 系统表空间（12M，autoextend）
-rw-r----- 1 mysql mysql  12582912 Sep  1 09:51 ibtmp1           # 临时表空间
-rw-r----- 1 mysql mysql  27262976 Sep  1 10:24 mysql.ibd        # 数据字典（8.0+ 字典不在 ibdata1）
-rw-r----- 1 mysql mysql  33554432 Sep  1 10:24 undo_001         # undo 表空间（独立）
-rw-r----- 1 mysql mysql  16777216 Sep  1 10:24 undo_002
-rw-r----- 1 mysql mysql   4194304 Sep  1 10:24 #ib_16384_0.dblwr  # doublewrite 文件（独立）
-rw-r----- 1 mysql mysql  12582912 Aug 27 12:45 #ib_16384_1.dblwr
drwxr-x--- 2 mysql mysql      4096 Sep  1 09:51 #innodb_redo     # redo log 目录（容量由 innodb_redo_log_capacity 管）
drwxr-x--- 2 mysql mysql      4096 Sep  1 09:51 #innodb_temp     # 临时表
-rw-r----- 1 mysql mysql   27272 Sep  1 10:24 binlog.000015     # binlog（复制+PITR 用）
drwxr-x--- 2 mysql mysql      4096 Aug 26 17:47 mysql            # mysql 库（账号/权限表）
```

```sql
SELECT @@innodb_data_file_path, @@innodb_undo_directory,
       @@innodb_redo_log_capacity, @@innodb_change_buffering;
```

真实输出：

```text
datafile_path            undo_dir   redo_capacity  change_buffering
ibdata1:12M:autoextend   ./         100663296      none
```

### 2.2 全部 InnoDB 表空间清单

```sql
SELECT SPACE, NAME, SPACE_TYPE, FILE_SIZE, ROW_FORMAT
  FROM information_schema.INNODB_TABLESPACES ORDER BY SPACE_TYPE, NAME;
```

真实输出（本机无业务表时）：

```text
SPACE       NAME            SPACE_TYPE  FILE_SIZE   ROW_FORMAT
4294967294  mysql           General     27262976    Any
1           sys/sys_config  Single      114688      Dynamic
4294967293  innodb_temporary System     12582912    Compact or Redundant
4294967279  innodb_undo_001 Undo        33554432    Undo
4294967278  innodb_undo_002 Undo        16777216    Undo
```

对照理解：SPACE_TYPE 分 `General`（mysql.ibd）、`Single`（每表一个 .ibd）、`System`（ibtmp1/ibdata1）、`Undo`（undo_001/002）。**ibdata1 不再充当字典，8.4 里字典在 `mysql.ibd`**。

---

## 3. 容量实验（命令 → 真实输出）

### 实验 A：.ibd 文件定位

```sql
CREATE DATABASE mysql_lab_eng002;
CREATE TABLE mysql_lab_eng002.lab_files (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  v VARCHAR(200) NOT NULL DEFAULT 'x') ENGINE=InnoDB;
SELECT t.NAME, t.SPACE_TYPE, t.FILE_SIZE, d.PATH
  FROM information_schema.INNODB_TABLESPACES t
  JOIN information_schema.INNODB_DATAFILES d USING (SPACE)
  WHERE t.NAME LIKE 'mysql_lab_eng002/%';
```

真实输出：

```text
tablespace                 SPACE_TYPE  FILE_SIZE  PATH
mysql_lab_eng002/lab_files Single      114688     ./mysql_lab_eng002/lab_files.ibd
```

`.ibd` 初始 114,688 bytes = 7 页 × 16KB（源码 `fil0fil.h:1153 FIL_IBD_FILE_INITIAL_SIZE = 7`，`fil0fil.cc:5758 fil_ibd_create`）。表空间名 = `库名/表名`。

### 实验 B：INSERT 增长 / DELETE 不回收 / OPTIMIZE 回收 / TRUNCATE 归零

```sql
-- 插入 2 万行
INSERT INTO lab_files(v) SELECT RPAD('x',200,'x') FROM ...(笛卡尔积)... LIMIT 20000;
-- DELETE 一半行
DELETE FROM lab_files WHERE id % 2 = 0;
-- 回收碎片
OPTIMIZE TABLE lab_files;
-- 重置
TRUNCATE TABLE lab_files;
```

真实输出（节选，`ls -l .../lab_files.ibd` 与 `INNODB_TABLESPACES.FILE_SIZE`）：

```text
lab_files.ibd 初始大小: 114688 bytes
rows_cnt: 20000
lab_files.ibd 插入后大小: 13631488 bytes     ← 13MB（页按需分配）
rows_left: 10000
DELETE 后 lab_files.ibd: 13631488 bytes      ← 不缩小（页内死记录占位）
OPTIMIZE TABLE → note: Table does not support optimize, doing recreate + analyze instead
OPTIMIZE 后 lab_files.ibd: 9437184 bytes     ← 重建后收缩到一半行该有的大小
TRUNCATE 前 lab_files.ibd: 15728640 bytes
TRUNCATE 后 lab_files.ibd: 114688 bytes      ← 回到初始 7 页
```

要点：
- **DELETE 不回收空间**（页内标记删除，类似 PG 死元组）
- **`OPTIMIZE TABLE` = ALTER 重建**（源码 `ha_innodb.cc:18355 ha_innobase::optimize` 返回 `HA_ADMIN_TRY_ALTER`，走 recreate + analyze）
- **`TRUNCATE` 重建表空间**（源码 `ha_innodb.cc:15499 truncate_impl` → `fil0fil.cc:4725 fil_truncate_tablespace`），回到初始 7 页而不是 0 字节

### 实验 C：MySQL 侧等价"空间回收"对照表

| 场景 | PG 命令 | MySQL 命令 | 行为差异 |
|---|---|---|---|
| 清死元组/碎片但保留数据 | `VACUUM` | 无直接对应（purge 后台自动做） | PG 普通 VACUUM 通常不缩文件；MySQL 无需手动 |
| 压缩重写表 | `VACUUM (FULL)` | `OPTIMIZE TABLE` | 都重写；PG 换 relfilenode，MySQL 重建 .ibd |
| 清空并重置 | `TRUNCATE` | `TRUNCATE TABLE` | 都换新文件；PG 归 0，MySQL 归 7 页初始 |

---

## 4. 源码定位速查

| 机制 | MySQL 8.4 | PG 18.4 |
|---|---|---|
| 建表文件 | `fil0fil.cc:5758 fil_ibd_create`（初始 7 页，`fil0fil.h:1153`） | heap 文件创建（relfilenode 分配） |
| 空间扩展 | `fsp0fsp.cc:3262 fsp_extend_by_default_size` | 页分配器扩展文件 |
| 重写/压缩 | `ha_innodb.cc:18355 optimize`（→ ALTER 重建） | `vacuum.c:2311 cluster_rel`（VACUUM FULL = CLUSTER 变体） |
| TRUNCATE | `ha_innodb.cc:15499 truncate_impl` → `fil0fil.cc:4725 fil_truncate_tablespace` | `tablecmds.c:1861 ExecuteTruncate` → `:2228 RelationSetNewRelfilenumber` |
| doublewrite | `buf0dblwr.cc:2752 dblwr::open`（启动 srv0start.cc:1850） | 无（WAL 保证原子性） |
| change buffer | `ibuf0ibuf.cc:458 ibuf_init_at_db_start` | 无（PG 无二级索引延迟合并） |
| 字典/元数据 | `mysql.ibd`（Data Dictionary） | `pg_catalog` 系统表（base/global/ 内文件） |

---

## 5. 关键差异（对照表）

| 维度 | PostgreSQL 18.4 | MySQL 8.4 |
|---|---|---|
| 库对应目录 | `base/<oid>/` | 无目录对应（库是逻辑概念，表文件在 `库名/表.ibd`） |
| 表对应文件 | `base/<dboid>/<relfilenode>`（裸数字，需查 pg_class） | `datadir/库名/表.ibd`（一眼可读） |
| 数据字典 | 系统 catalog（表内数据） | `mysql.ibd`（8.0+ 独立文件） |
| 系统表空间 | 无（每个库独立目录） | `ibdata1`（8.4 里主要装 change buffer 等，不再装字典） |
| redo/wal | `pg_wal/` 按段文件 | `#innodb_redo/` 按 `innodb_redo_log_capacity` 循环 |
| undo | 无独立 undo（MVCC 在堆内 xmin/xmax） | `undo_001/undo_002` 独立文件 |
| 崩溃恢复双写 | WAL 足够，无 doublewrite | `#ib_16384_*.dblwr`（page_size=16K 时） |
| DELETE 后 | 死元组占位，VACUUM 清 | 页内标记删除，purge 清，都不缩文件 |
| 收缩手段 | `VACUUM (FULL)` | `OPTIMIZE TABLE`（= ALTER 重建） |
| 清空重置 | `TRUNCATE`（换 relfilenode） | `TRUNCATE TABLE`（重建 .ibd） |

## 6. 心智迁移要点

1. **"表是一个文件"两边都成立**，但 MySQL 的文件名可读（`库/表.ibd`），PG 是 `relfilenode` 裸数字——排查空间先 `ls -lhS datadir/*/*.ibd` 找大户，PG 则 `pg_relation_filepath()` + `pg_size_pretty()`。
2. **DELETE 不还空间是两边共性**：磁盘报警时先分清"逻辑大小"和"物理大小"。MySQL `information_schema.tables.data_length+index_length` vs 磁盘 `du -sh *.ibd`；PG `pg_total_relation_size` vs 实际文件。
3. **回收手段的映射**：PG `VACUUM FULL`（会锁表、换文件）↔ MySQL `OPTIMIZE TABLE`（也是 ALTER 重建、锁表）。低峰执行，大表考虑 `pt-online-schema-change`/gh-ost 思路（后续 OPT-00x）。
4. **8.4 的 ibdata1 不再是坑**：老教材"ibdata1 无限膨胀"主要指 5.7 之前字典+undo 都塞里面；8.4 字典在 `mysql.ibd`、undo/redo/dblwr 全独立。DBA 要盯的是 `undo_*`（长事务撑大）、`#innodb_redo`（容量上限）、`binlog`（保留策略）。
5. **观察命令变了**：PG 用 `df` + `pg_relation_filepath`；MySQL 用 `INFORMATION_SCHEMA.INNODB_TABLESPACES`（FILE_SIZE/ALLOCATED_SIZE）一键看所有表空间文件大小，P_S=OFF 也可用（MON-001 约束下这是更可靠的容量入口）。

## 7. Evidence 索引

| 文件 | 内容 |
|---|---|
| evidence/pg-file-layout.txt | PG 建表/定位 relfilenode、INSERT/DELETE/VACUUM/VACUUM FULL/TRUNCATE 全流程文件大小与 relfilenode 变化 |
| evidence/mysql-file-layout.txt | MySQL datadir 布局、INNODB_TABLESPACES 定位、INSERT/DELETE/OPTIMIZE/TRUNCATE 的 .ibd 大小变化 |

相关资产：`study_record/pg-mysql-map.md`、`study_record/runbook/mysql-dba-cheatsheet.md`
