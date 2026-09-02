#!/usr/bin/env bash
set -euo pipefail

# Debian 11/12 或 Ubuntu 上的官方仓库安装流程。需要 sudo 和外网。
# 本脚本会修改系统 APT 仓库并安装软件；不要在未审批的生产主机直接执行。

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ca-certificates gnupg2 lsb-release

curl -fsSLo /tmp/percona-release_latest.generic_all.deb \
  https://repo.percona.com/apt/percona-release_latest.generic_all.deb
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  /tmp/percona-release_latest.generic_all.deb

sudo percona-release enable pxb-84-lts release
sudo apt-get update
apt-cache policy percona-xtrabackup-84

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  percona-xtrabackup-84 lz4 zstd

xtrabackup --version
command -v xtrabackup
command -v xbstream
command -v xbcloud
dpkg-query -W -f='${Package} ${Version} ${Status}\n' \
  percona-xtrabackup-84 lz4 zstd

# 预期：版本为 8.4.x，三个命令均存在，包状态为 "install ok installed"。
