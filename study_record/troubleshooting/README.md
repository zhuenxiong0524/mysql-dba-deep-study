# MySQL 故障案例库（troubleshooting）

> 统一案例结构：现象 → 告警/错误 → 第一步检查 → 第二步检查 → 证据 → 根因 → 处理 → 验证恢复 → PG 对照 → 生产经验。
> 每个案例必须有真实错误输出（错误码/错误文本），禁止脑补。
> 状态：⬜ 待做 / 🔶 已有证据待成文 / ✅ 已完成。

| CASE | 主题 | 状态 | 关联专题 | 已有证据 |
|---|---|---|---|---|
| CASE-001 | Login Failed（1045） | 🔶 | ENV-004/007 | ENV-004 evidence（mysql-privilege-errors.txt：1045 密码错/用户不存在/空密码 TCP） |
| CASE-002 | Access Denied（1142/1143/1147） | 🔶 | ENV-004 | ENV-004 evidence（1142 表/1143 列/1147 无此授权/1044 库） |
| CASE-003 | Too Many Connections | ⬜ | CONN-001 | - |
| CASE-004 | Lock Wait | ⬜ | ISO-001 | - |
| CASE-005 | Deadlock | ⬜ | ISO-001 | - |
| CASE-006 | Long Transaction | ⬜ | MON-001 | - |
| CASE-007 | Slow SQL | ⬜ | MON-001 | - |
| CASE-008 | CPU High | ⬜ | MON-001 | - |
| CASE-009 | IO High | ⬜ | MON-001 | - |
| CASE-010 | Disk Full | ⬜ | MON-001/DR-001 | - |
| CASE-011 | Binlog Growth | ⬜ | LOG-001 | - |
| CASE-012 | Replica Lag | ⬜ | REP-001 | - |
| CASE-013 | Replication Broken | ⬜ | REP-001 | - |
| CASE-014 | DDL Blocked（MDL） | ⬜ | ISO-002 | - |
| CASE-015 | Accidental DELETE | ⬜ | BAK-001/LOG-001 | - |
| CASE-016 | Accidental DROP TABLE | ⬜ | BAK-001/LOG-001 | - |
| CASE-017 | mysqld Crash | ⬜ | REDO-001 | - |
| CASE-018 | Buffer Pool Pressure | ⬜ | BUF-001 | - |

## 案例文件命名

```text
CASE-001-login-failed.md
CASE-002-access-denied.md
...
```
