# XtraBackup 8.4 慢链路安装 Runbook

优先使用 `xtrabackup-install.sh` 的官方 APT 流程。只有官方仓库单连接过慢时，才使用这里的下载
加速；依赖仍由 APT 安装，最终软件包必须与 APT 索引公布的大小和校验值一致。

## 1. 取得 APT 选择的准确版本与官方 URI

```bash
apt-cache policy percona-xtrabackup-84
apt-get --print-uris --yes --reinstall install percona-xtrabackup-84
```

本次解析结果为 `8.4.0-6-1.bullseye`、大小 `56479962`、MD5
`c3155bfea7ea60fd5a43701e7decbab8`。升级版本后必须重新读取，不能沿用这些数字。

## 2. 使用断点续传

```bash
sudo apt-get install -y aria2
aria2c --continue=true \
  --max-connection-per-server=8 \
  --split=8 \
  --min-split-size=1M \
  --file-allocation=none \
  --dir=/tmp \
  --out=percona-xtrabackup-84_8.4.0-6-1.bullseye_amd64.deb \
  'APT 输出的包 URI'
```

若代理把多连接汇聚为单连接，可从 Percona 公共镜像按 byte range 分段下载。必须保证镜像路径、
版本、发行版和架构与 APT 解析结果完全一致。

## 3. 安装前校验

```bash
stat -c '%n %s bytes' \
  /tmp/percona-xtrabackup-84_8.4.0-6-1.bullseye_amd64.deb
printf '%s  %s\n' \
  c3155bfea7ea60fd5a43701e7decbab8 \
  /tmp/percona-xtrabackup-84_8.4.0-6-1.bullseye_amd64.deb | md5sum --check
```

只有大小和 MD5 都通过才能安装。更换版本时使用新 APT 索引给出的 hash。

## 4. 安装本地包

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libcurl4-openssl-dev libev4 rsync lz4 zstd
sudo dpkg -i \
  /tmp/percona-xtrabackup-84_8.4.0-6-1.bullseye_amd64.deb
xtrabackup --version
```

## 5. 卸载回滚

```bash
sudo apt-get remove -y percona-xtrabackup-84
sudo percona-release disable pxb-84-lts
sudo apt-get update
```

不要执行 `apt autoremove`，除非已经人工复核其候选列表；它可能删除与本专题无关的用户软件依赖。
