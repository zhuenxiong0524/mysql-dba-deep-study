# 实验安全规范（PG DBA → MySQL 生产 DBA 迁移项目）

> 适用范围：本机所有 MySQL/PG 对照实验。违反红线 = 停止实验并记录，不得继续。

## 1. 命名红线

```text
破坏性/独立实验数据库:  mysql_lab_*（如 mysql_lab_mvcc）
测试账号:              lab_*
测试表:                t_*
实验角色(PG):          lab_*
复制实例:              独立端口（如 3307），禁止用 3306 主实例做破坏
```

## 2. 禁止行为

- 不伪造/不脑补实验结果：命令失败后不许"假设预期结果"，必须保留真实输出
- 不修改 `root` / `postgres` 等重要账号做破坏性实验（如 DROP/ALTER root）
- 不动现有业务库：`cmp`（ENV-001 交叉访问库）等
- 历史实验库 `db_compare` / `db_compare2` / `demo_schema`（MYSQL-BASIC-001 实验对象）已于 2026-09-01 清理；
  新实验一律用 `mysql_lab_*`，不重复占用旧名
- 不在非专用实例上执行 `kill -9` / crash 模拟（当前 3306 是学习主实例，crash 演练留给 REDO-001 专用实例）
- 不把 PG 机制"改个名字"当 MySQL 讲（WAL≠Binlog、VACUUM≠Purge、shared_buffers≠Buffer Pool、Role≠User）

## 3. 资源约束（1C/2G + 4G swap）

- 大表/并发实验控制规模（示例：t_* 表 ≤ 10 万行级别，先小后大）
- 不改大 `innodb_buffer_pool_size`；改动态参数前先 `SET PERSIST_ONLY` 评估
- 制造"Too many connections / OOM / 磁盘满"实验时，必须有恢复预案并先记录当前状态

## 4. 破坏性实验流程

```text
1. 确认目标 = mysql_lab_* / lab_* / t_*
2. 实验前记录现场（SHOW PROCESSLIST、磁盘 df、error log 尾部）
3. 执行实验（保留完整输出到 evidence/）
4. 验证影响范围（仅限实验对象）
5. 清理（DROP DATABASE/USER/TABLE，按需）
6. 记录结果与教训
```

## 5. 环境安全性无法确认时

```text
停止实验 + 记录"环境安全性无法确认"，不得执行 kill/crash/破坏性 DDL。
```

## 6. 证据要求

- 每个实验保留：command + output + timestamp（写进 evidence/ 文件或文章代码块）
- 失败实验尤其不能删（错误码/错误文本是学习资产）
