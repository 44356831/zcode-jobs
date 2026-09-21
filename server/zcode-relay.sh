#!/usr/bin/env bash
# zcode-relay.sh — Git 异步中继：服务器端执行器
# 由 cron 每分钟调用一次：拉取新任务 -> 执行 zcode -> 回传结果
#
# 环境变量（可在 cron 行或 /etc/zcode-relay.env 中覆盖）：
#   ZCODE_CMD   zcode 的调用命令模板，%s 会被替换为工作流文件路径
#               默认: zcode run %s
#   JOB_TIMEOUT 单个任务最长执行秒数，默认 1800（30 分钟）

set -u

REPO_DIR="${REPO_DIR:-/opt/zcode-relay/repo}"
RELAY_DIR="${RELAY_DIR:-/opt/zcode-relay}"
ZCODE_CMD="${ZCODE_CMD:-zcode run %s}"
JOB_TIMEOUT="${JOB_TIMEOUT:-1800}"
GIT_BIN="${GIT_BIN:-git}"

export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"

log() { echo "[$(date '+%F %T')] $*"; }

# 并发保护：同时只允许一个 relay 实例
exec 9>"$RELAY_DIR/.relay.lock"
if ! flock -n 9; then
  log "另一个 relay 实例正在运行，本次跳过"
  exit 0
fi

# 1. 拉取最新任务
cd "$REPO_DIR" || { log "仓库目录不存在: $REPO_DIR"; exit 1; }
if ! "$GIT_BIN" pull --rebase --autostash >>"$RELAY_DIR/git.log" 2>&1; then
  log "git pull 失败，详见 $RELAY_DIR/git.log"
  exit 1
fi

# 2. 找出未执行的任务：jobs/ 下存在、results/ 下还没有同名目录
shopt -s nullglob
pending=()
for f in jobs/*; do
  name="$(basename "$f")"
  [[ "$name" == .* ]] && continue
  [[ -e "results/$name/.running" ]] && continue
  [[ -d "results/$name" ]] && continue
  pending+=("$f")
done
shopt -u nullglob

if ((${#pending[@]} == 0)); then
  exit 0
fi

log "发现 ${#pending[@]} 个新任务: ${pending[*]##*/}"

# 3. 逐个执行
for job in "${pending[@]}"; do
  name="$(basename "$job")"
  outdir="results/$name"
  mkdir -p "$outdir"
  touch "$outdir/.running"

  log "开始执行: $name"
  start_ts=$(date +%s)

  cmd=$(printf "$ZCODE_CMD" "$REPO_DIR/$job")
  if (cd "$outdir" && timeout "$JOB_TIMEOUT" bash -c "$cmd" >stdout.log 2>&1); then
    status="success"
  else
    rc=$?
    if [[ $rc -eq 124 ]]; then
      status="timeout"
    else
      status="failed:$rc"
    fi
  fi

  end_ts=$(date +%s)
  rm -f "$outdir/.running"

  {
    echo "job: $name"
    echo "status: $status"
    echo "started: $(date -d "@$start_ts" '+%F %T' 2>/dev/null || date -r "$start_ts" '+%F %T')"
    echo "finished: $(date -d "@$end_ts" '+%F %T' 2>/dev/null || date -r "$end_ts" '+%F %T')"
    echo "duration_sec: $((end_ts - start_ts))"
    echo "command: $cmd"
  } >"$outdir/status.txt"

  log "任务结束: $name -> $status"

  # 4. 提交并回传结果（失败时保留现场，下轮重试推送）
  "$GIT_BIN" add "results/$name"
  "$GIT_BIN" commit -m "relay: $name -> $status" >>"$RELAY_DIR/git.log" 2>&1
  if ! "$GIT_BIN" push >>"$RELAY_DIR/git.log" 2>&1; then
    log "结果推送失败，下个周期会自动重试: $name"
  fi
done

log "本轮处理完成"
