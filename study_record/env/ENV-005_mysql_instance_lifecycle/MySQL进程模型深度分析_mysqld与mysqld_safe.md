# MySQL 进程模型深度分析：mysqld_safe 与 mysqld 的角色分工

> 版本：v1.0（2026-08-28，实机验证 + 源码脚本走读）
> 位置：ENV-005（实例架构与生命周期）专题子文章
> 关联：主文章《MySQL 实例架构与生命周期：从 PostgreSQL DBA 视角理解 mysqld》第 3.3 节
> 依据：本机 `ps` 进程树实测 + `/usr/local/mysql/mysql-8.4.10/bin/mysqld_safe` 脚本源码走读 + 受控重启实验日志

---

## 1. 为什么值得单独分析

PG DBA 看到 `ps -ef` 里 MySQL 有**两个进程**会本能地问：哪个是数据库本体？哪个该"重启"？

这个问题的答案直接关系运维操作正确性：

- `kill -9 mysqld` 想停库 → **无效**（mysqld_safe 会重新拉起）
- 看到 mysqld 反复"自己起来" → 不是闹鬼，是 mysqld_safe 的主循环在干活
- `mysqladmin shutdown` 明明成功了，`ps` 里还有个进程 → 可能是 mysqld_safe 在收尾/或者没退干净

本机就是 `mysqld_safe` 托管的典型源码安装形态（无 systemd 单元），是分析这个问题的真实样本。

---

## 2. 本机实测：进程树与证据

```text
mysql 14587  1  /bin/sh mysqld_safe --defaults-file=/etc/my.cnf          ← 守护脚本（PPID=1）
mysql 14787  14587  mysqld --defaults-file=/etc/my.cnf --basedir=...      ← 服务本体（PPID=14587）
      --datadir=/data/myhome/mydata/mysql --socket=/tmp/mysql.sock --port=3306
```

- `mysqld_safe`：POSIX shell 脚本（`file` 确认：`POSIX shell script, ASCII text executable`）
- `mysqld`：真正的二进制服务进程
- 父子关系：mysqld_safe 是 mysqld 的父进程——mysqld 死了它会知道

mysqld_safe.log（受控重启实验记录）：

```text
mysqld_safe Starting mysqld daemon with databases from /data/myhome/mydata/mysql
mysqld_safe mysqld from pid file /data/myhome/mydata/mysql/mysql.pid ended
```

error.log（mysqld 本体视角）：

```text
[Server] mysqld: ready for connections. Version: '8.4.10'  socket: '/tmp/mysql.sock'  port: 3306
```

---

## 3. mysqld_safe 是什么：脚本职责拆解

脚本文件头自述（第 5 行）：

```sh
# Script to start the MySQL daemon and restart it if it dies unexpectedly
```

四个核心职责：

### 3.1 拉起 mysqld（启动器）

```sh
NOHUP_NICENESS="nohup"                 # 用 nohup 启动，脱离终端会话
...
eval_log_error "$cmd"                  # 执行 mysqld 启动命令
```

- 用 `nohup` 让 mysqld 不随终端退出而死（本机我们手动管理时也用了 `setsid nohup`，同一个道理）
- 启动前做 datadir 检查、权限校验、日志目录准备
- 追加 `--pid-file`、`--log-error` 等参数到 mysqld 命令行

### 3.2 监控与自动重启（守护器）——主循环走读

```sh
while true
do
  eval_log_error "$cmd"                # 前台等待 mysqld 退出
  if [ $? -eq 16 ] ; then              # 退出码 16 = 请求重启（RESTART 语句用）
    dont_restart_mysqld=false
    echo "Restarting mysqld..."
  else
    dont_restart_mysqld=true           # 其他退出码：默认不再重启
  fi

  if $dont_restart_mysqld; then
    if test ! -f "$pid_file"           # pid 文件被移除 = 正常 shutdown → 退出
    then
      break
    else                               # pid 文件还在 = 崩溃 或 别的 mysqld 在跑
      PID=`cat "$pid_file"`
      if kill -0 $PID > /dev/null ...  # 进程还活着 = 重复启动 → 拒绝
      then
        log_error "A mysqld process with pid=$PID is already running. Aborting!!"
        exit 1
      fi
    fi
  fi

  if test -f "$pid_file.shutdown"       # shutdown 标记文件 → 不再重启
  then
    log_notice "$pid_file.shutdown present. The server will not restart."
    break
  fi
  ...
  log_notice "mysqld restarted"
done
log_notice "mysqld from pid file $pid_file ended"
```

关键语义（全部来自脚本原文）：

| 场景 | mysqld 退出码/状态 | mysqld_safe 行为 |
|---|---|---|
| 正常 shutdown（`mysqladmin shutdown`） | 退出码 0，删除 pid 文件 | `break`，自己也退出 |
| 崩溃（`kill -9` / OOM / panic） | 异常退出，pid 文件残留 | 进入循环 → `mysqld restarted` 自动拉起 |
| `RESTART` 语句（MySQL 8） | 退出码 **16** | `Restarting mysqld...` 立即重启 |
| 重复启动（已有 mysqld 在跑） | pid 文件里进程还活着 | `Aborting!!` exit 1，拒绝双实例 |
| 手动停止标记 | 出现 `pid_file.shutdown` | `will not restart`，退出 |

### 3.3 崩溃风暴节流

```sh
max_fast_restarts=5                    # 1 秒内最多 5 次快速重启
...
log_notice "The server is respawning too fast. Sleeping for 1 second."
sleep 1
```

mysqld 反复秒崩时，mysqld_safe 会 `sleep 1` 节流，避免重启风暴打满 CPU。

### 3.4 残留进程清理

```sh
KILL_MYSQLD=1                          # 默认开启；--skip-kill-mysqld 关闭
...
if kill -9 $T                          # 清理"挂起"的旧 mysqld 进程
then
  log_error "$MYSQLD process hanging, pid $T - killed"
```

另外 `trap '' 1 2 3 15`：mysqld_safe 忽略 HUP/INT/QUIT/TERM——"我们不该被任何人 kill"。
这就是为什么本机实验时普通方式杀不掉它、必须 `setsid nohup` 管理的原因。

---

## 4. mysqld 是什么：服务本体职责

- 真正的数据库实例：监听 3306/33060、/tmp/mysql.sock、写 pid 文件
- Server 层：连接线程、Parser、Optimizer、Executor
- InnoDB：Buffer Pool、Redo/Undo、数据文件、后台线程族（io_read/io_write/srv_purge/page_cleaner/log_writer...）
- 它退出 = 数据库不可用；它启动时按 datadir 做恢复（redo 前滚 + undo 回滚）
- `mysqladmin ping` 探活的是它；`SHOW PROCESSLIST` 看到的是它的线程

本机实测它的启动命令行自带全部关键位置参数（这就是"ps 输出 = 第一份实例信息"）：

```text
mysqld --defaults-file=/etc/my.cnf --basedir=/usr/local/mysql/mysql-8.4.10
       --datadir=/data/myhome/mydata/mysql --plugin-dir=.../plugin
       --log-error=.../error.log --pid-file=.../mysql.pid
       --socket=/tmp/mysql.sock --port=3306
```

---

## 5. 生命周期互动：一张时序图

```text
启动:
  mysqld_safe (nohup) ──拉起──> mysqld ──初始化 InnoDB──> ready for connections
  正常关闭:
  mysqladmin shutdown ──> mysqld 优雅退出(删 pid 文件) ──> mysqld_safe 看到 pid 文件没了 → break 退出
  崩溃:
  mysqld 异常退出(pid 文件残留) ──> mysqld_safe 循环 → log "mysqld restarted" → 拉起新 mysqld
  RESTART 语句:
  mysqld exit code 16 ──> mysqld_safe "Restarting mysqld..." → 拉起
  双实例防护:
  手动再启 mysqld_safe → 发现 pid 文件进程存活 → "already running. Aborting!!"
```

本机已验证：受控 `mysqladmin shutdown` 后 `ps` 中 mysqld 与 mysqld_safe 都消失（mysqld_safe 正常退出）。

---

## 6. 与 PostgreSQL 对照

| 维度 | PostgreSQL 18.4 | MySQL 8.4（本机） |
|---|---|---|
| 服务本体 | postmaster（postgres 二进制） | mysqld |
| 启动工具 | `pg_ctl start`（跑完即退的命令） | mysqld_safe（常驻守护脚本） |
| 守护语义 | systemd/Patroni 管；pg_ctl 不常驻 | mysqld_safe 常驻 + 崩溃自动重启 |
| 子进程/线程 | backend 一连接一进程 | 一连接一线程（在 mysqld 内） |
| 优雅停止 | `pg_ctl stop -m fast` | `mysqladmin shutdown` |
| 重启 | `pg_ctl restart` | `mysqladmin shutdown` + 拉起 mysqld_safe（或 RESTART） |
| 崩溃恢复 | 重启时重放 WAL | 重启时 redo 前滚 + undo 回滚（REDO-001 专题） |
| 双实例防护 | 数据目录锁（postmaster.pid） | mysqld_safe 检查 pid 文件 + "already running. Aborting!!" |

**最大差异**：`pg_ctl` 是"一次性命令"，跑完就退；`mysqld_safe` 是"常驻监护进程"，mysqld 生命周期内一直存在。PG 的"崩溃自动重启"职责通常交给 systemd（`Restart=on-failure`）或 Patroni；MySQL 源码安装默认把这件事放在 mysqld_safe 里。

---

## 7. 生产形态差异

| 形态 | 谁拉起 mysqld | 崩溃自动重启 | 典型场景 |
|---|---|---|---|
| mysqld_safe（本机） | shell 脚本常驻 | ✅ 有（主循环 + 节流） | 源码安装、手工部署 |
| systemd 单元 | mysqld.service | ✅ systemd Restart=on-failure | 发行版包安装、现代生产 |
| 裸启动 | 手工/脚本 nohup | ❌ 没有 | 容器（通常由 orchestrator 管） |
| 集群管理 | CM/编排（如 Patroni 之于 PG） | ✅ 按 CM 策略 | 大规模/云环境 |

**运维含义**：接手机器先确认"谁在管 mysqld 的生死"——这决定：
- 崩溃后会不会自动拉起（mysqld_safe / systemd → 会；裸启动 → 不会）
- 安全重启的方式（systemd 用 `systemctl restart`；mysqld_safe 用 `mysqladmin shutdown` + 重启脚本）
- 日志位置（systemd 可能走 journald；mysqld_safe 走 `--log-error` 文件）

---

## 8. 排障路径："进程怎么又起来了？"

```text
现象:  mysqld 进程反复出现 / 想停停不下来

1. ps -ef | grep mysqld           确认 mysqld_safe 是否在（在 → 它在拉进程）
2. 看 mysqld_safe 日志/error log  找 "mysqld restarted" / "respawn too fast" / 崩溃栈
3. 判断根因：为什么 mysqld 起不来/反复崩
   - tail -100 error.log（启动失败原因：参数错、磁盘满、权限、InnoDB 恢复失败）
   - df -h / free -m（资源）
4. 决定处置：
   - 要停：mysqladmin shutdown（不是 kill -9）
   - 要排查反复崩溃：先 --skip-kill-mysqld 或停 mysqld_safe 再单跑 mysqld 前台看报错
5. 验证：ps + mysqladmin ping + error.log 尾部
```

误区警示：`kill -9 mysqld` 在 mysqld_safe 托管下 = "帮它做了一次崩溃恢复演练"，几秒后进程会回来。

---

## 9. 常见误区

- ❌ "mysqld_safe 是数据库服务" → 是 shell 守护脚本，服务本体是 mysqld
- ❌ "kill -9 mysqld 能停库" → mysqld_safe 会立刻拉起（除非先停守护）
- ❌ "RESTART 是重启 mysqld_safe" → 是让 mysqld 以退出码 16 退出，由 mysqld_safe 完成重启
- ❌ "两个进程都要 systemctl 管" → 本机根本没有 systemd 单元；托管方式先确认
- ❌ "mysqld_safe 会无限重启" → 有节流（5 次快速重启后 sleep 1），且 `pid_file.shutdown` 标记可阻止重启

---

## 10. 心智模型总结

```text
mysqld_safe（常驻 shell 监护）          mysqld（服务本体）
  ├─ 拉起（nohup）                        ├─ 连接线程 + Server 层
  ├─ 崩溃自动重启（主循环）                 └─ InnoDB（BP/Redo/Undo/数据）
  ├─ 退出码 16 → RESTART 支持
  ├─ 双实例防护（pid 文件）
  └─ 快速重启节流

生命周期: 启动(ready for connections) → 运行 → 崩溃/RESTART/正常停机
正常停机 = mysqladmin shutdown（双方都退出）；想停库永远用 shutdown，不要 kill -9
```

一句话：**mysqld_safe 是"监护人"，mysqld 是"被监护对象"；排障看 error.log 找 mysqld 的死因，看 mysqld_safe.log 找监护人的动作。**

---

## 11. Evidence 与参考

- 本机 `ps -ef | grep mysqld`（进程树）→ `study_record/env/ENV-005_mysql_instance_lifecycle/evidence/env-probe.txt`
- 受控重启实验（shutdown → 双方退出 → 拉起 → ready for connections）→ `evidence/env-probe2.txt` / `mysql-config.txt`
- mysqld_safe 脚本源码：`/usr/local/mysql/mysql-8.4.10/bin/mysqld_safe`（第 5、15、88、884-1015 行为主循环）
- 后续：崩溃恢复机制（redo/undo 重放）见 REDO-001 专题
