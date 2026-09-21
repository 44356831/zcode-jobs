#!/usr/bin/env bash
# install.sh — 在服务器上一键安装 zcode-bridge（常驻桥接服务）
# 用法: bash install.sh git@github.com:44356831/zcode-jobs.git [安装目录]
#
# 前提：服务器 git 已能用 SSH 访问该仓库（Deploy Key，需写权限，见 README）

set -euo pipefail

REPO_URL="${1:?用法: bash install.sh <git仓库地址> [安装目录]}"
RELAY_DIR="${2:-/opt/zcode-relay}"

echo "==> 安装目录: $RELAY_DIR"
mkdir -p "$RELAY_DIR"

# 1. 克隆仓库
if [[ -d "$RELAY_DIR/repo/.git" ]]; then
  echo "==> 仓库已存在，跳过克隆"
else
  echo "==> 克隆任务仓库: $REPO_URL"
  git clone "$REPO_URL" "$RELAY_DIR/repo"
fi
cd "$RELAY_DIR/repo"
mkdir -p jobs results
touch jobs/.gitkeep results/.gitkeep
git config user.name "zcode-relay"
git config user.email "zcode-relay@local"
git add -A
git commit -m "chore: init relay dirs" >/dev/null 2>&1 || true
git push >/dev/null 2>&1 || true

# 2. 写默认配置（通知通道由主人后续填 webhook）
if [[ ! -f /etc/zcode-bridge.env ]]; then
  cat > /etc/zcode-bridge.env <<'EOF'
# zcode-bridge 配置（改完需 systemctl restart zcode-bridge）
REPO_DIR=/opt/zcode-relay/repo
POLL_INTERVAL=60
RESULT_TIMEOUT=3600
# 通知通道：feishu-webhook | http | none
NOTIFIER=none
FEISHU_WEBHOOK=
FEISHU_SECRET=
HTTP_NOTIFY_URL=
TASKS_DROP_DIR=
EOF
  echo "==> 配置已写入 /etc/zcode-bridge.env（当前 NOTIFIER=none）"
fi

# 3. 安装 systemd 服务
if command -v systemctl >/dev/null 2>&1; then
  cp "$RELAY_DIR/repo/server/zcode-bridge.service" /etc/systemd/system/zcode-bridge.service
  systemctl daemon-reload
  systemctl enable --now zcode-bridge
  echo "==> systemd 服务已启动: systemctl status zcode-bridge"
else
  echo "!! 无 systemd，请手动后台运行:"
  echo "   set -a; source /etc/zcode-bridge.env; set +a; python3 $RELAY_DIR/repo/server/zcode-bridge.py"
fi

echo
echo "安装完成。最后一步（启用自动通知）："
echo "  1. 飞书群 -> 群机器人 -> 添加「自定义机器人」-> 复制 Webhook 地址"
echo "  2. 编辑 /etc/zcode-bridge.env: NOTIFIER=feishu-webhook, FEISHU_WEBHOOK=<粘贴>"
echo "     （若机器人开了签名校验，把 SECRET 填 FEISHU_SECRET）"
echo "  3. systemctl restart zcode-bridge"
echo "  4. 把该机器人和小糯拉进同一个群（小糯就能看到任务通知）"
