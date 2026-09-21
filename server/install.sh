#!/usr/bin/env bash
# install.sh — 在服务器上一键安装 zcode-relay
# 用法: bash install.sh git@github.com:44356831/zcode-jobs.git [安装目录]
#
# 它做四件事：克隆仓库 -> 建任务目录 -> 注册 cron -> 自检
# 前提：服务器上的 git 已能用 SSH 访问该仓库（Deploy Key 见 README）

set -euo pipefail

REPO_URL="${1:?用法: bash install.sh <git仓库地址> [安装目录]}"
RELAY_DIR="${2:-/opt/zcode-relay}"

echo "==> 安装目录: $RELAY_DIR"
mkdir -p "$RELAY_DIR"

# 1. 克隆任务仓库（脚本本身就在仓库的 server/ 目录里）
if [[ -d "$RELAY_DIR/repo/.git" ]]; then
  echo "==> 仓库已存在，跳过克隆"
else
  echo "==> 克隆任务仓库: $REPO_URL"
  git clone "$REPO_URL" "$RELAY_DIR/repo"
fi
cd "$RELAY_DIR/repo"
mkdir -p jobs results
touch jobs/.gitkeep results/.gitkeep
git add -A
git commit -m "chore: init relay dirs" >/dev/null 2>&1 || true
git push >/dev/null 2>&1 || true

# 2. 注册 cron（每分钟运行一次）
CRON_LINE="* * * * * $RELAY_DIR/repo/server/zcode-relay.sh >> $RELAY_DIR/relay.log 2>&1"
( crontab -l 2>/dev/null | grep -v "zcode-relay.sh" || true; echo "$CRON_LINE" ) | crontab -
echo "==> cron 已安装: $CRON_LINE"

# 3. 自检
echo "==> 自检：手动运行一次 relay"
chmod +x "$RELAY_DIR/repo/server/zcode-relay.sh"
if "$RELAY_DIR/repo/server/zcode-relay.sh"; then
  echo "==> 自检通过"
else
  echo "!! 自检未通过，请查看 $RELAY_DIR/relay.log"
  exit 1
fi

echo
echo "安装完成。后续："
echo "  - 自定义 zcode 命令: 编辑 cron 行，前面加 ZCODE_CMD='zcode exec -f %s'（%s 为文件路径占位符）"
echo "  - 日志: tail -f $RELAY_DIR/relay.log"
