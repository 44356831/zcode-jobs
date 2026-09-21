#!/usr/bin/env python3
# zcode-bridge.py — ZCode 常驻桥接服务
#
# 职责：
#   1. 周期性 git pull 任务仓库
#   2. 发现 jobs/ 新任务 -> 通知 ZCode（飞书群 webhook / HTTP 回调）
#   3. 轮询 results/<任务>/report.md 出现 -> commit + push 回仓库
#   4. 超时未出结果 -> 写 timeout 状态并回传
#
# 全部配置走环境变量（/etc/zcode-bridge.env 由 install.sh 生成）：

import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.request

REPO_DIR = os.environ.get("REPO_DIR", "/opt/zcode-relay/repo")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
RESULT_TIMEOUT = int(os.environ.get("RESULT_TIMEOUT", "3600"))
# 通知方式: feishu-webhook | http | none
NOTIFIER = os.environ.get("NOTIFIER", "none")
FEISHU_WEBHOOK = os.environ.get("FEISHU_WEBHOOK", "")
FEISHU_SECRET = os.environ.get("FEISHU_SECRET", "")
HTTP_NOTIFY_URL = os.environ.get("HTTP_NOTIFY_URL", "")
# 附加投递：同时把任务 md 拷到本机目录（可选，供小糯直接读取）
TASKS_DROP_DIR = os.environ.get("TASKS_DROP_DIR", "")

JOBS_DIR = os.path.join(REPO_DIR, "jobs")
RESULTS_DIR = os.path.join(REPO_DIR, "results")
DISPATCHED_DIR = os.path.join(REPO_DIR, ".dispatched")


def log(msg):
    print(f"[{time.strftime('%F %T')}] {msg}", flush=True)


def git(*args, check=False):
    return subprocess.run(["git", "-C", REPO_DIR, *args],
                          capture_output=True, text=True, check=check)


def git_pull():
    r = git("pull", "--rebase", "--autostash")
    if r.returncode != 0:
        log(f"git pull 失败: {r.stderr.strip()[:200]}")
        return False
    return True


def git_push(path, message):
    git("add", path)
    git("commit", "-m", message)
    r = git("push")
    if r.returncode != 0:
        log(f"推送失败，下轮重试: {r.stderr.strip()[:200]}")
        return False
    return True


def feishu_sign(secret):
    ts = str(int(time.time()))
    s = f"{ts}\n{secret}"
    digest = hmac.new(s.encode(), digestmod=hashlib.sha256).digest()
    return ts, base64.b64encode(digest).decode()


def notify_feishu(text):
    if not FEISHU_WEBHOOK:
        return False
    payload = {"msg_type": "text", "content": {"text": text}}
    if FEISHU_SECRET:
        ts, sign = feishu_sign(FEISHU_SECRET)
        payload["timestamp"] = ts
        payload["sign"] = sign
    req = urllib.request.Request(
        FEISHU_WEBHOOK,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode() or "{}")
            if body.get("code") not in (0, None):
                log(f"飞书返回异常: {body}")
                return False
        return True
    except Exception as e:
        log(f"飞书通知失败: {e}")
        return False


def notify_http(text, job_name):
    if not HTTP_NOTIFY_URL:
        return False
    try:
        req = urllib.request.Request(
            HTTP_NOTIFY_URL,
            data=json.dumps({"text": text, "job": job_name}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return 200 <= resp.status < 300
    except Exception as e:
        log(f"HTTP 通知失败: {e}")
        return False


def notify(text, job_name):
    if NOTIFIER == "feishu-webhook":
        return notify_feishu(text)
    if NOTIFIER == "http":
        return notify_http(text, job_name)
    log("未配置通知通道（NOTIFIER=none），任务已就绪待手动触发")
    return False


def dispatch(job_name):
    """通知 ZCode 执行新任务，并记录派发信息"""
    job_path = os.path.join(JOBS_DIR, job_name)
    if TASKS_DROP_DIR:
        os.makedirs(TASKS_DROP_DIR, exist_ok=True)
        with open(job_path, encoding="utf-8") as f_src, \
             open(os.path.join(TASKS_DROP_DIR, job_name), "w", encoding="utf-8") as f_dst:
            f_dst.write(f_src.read())

    text = (
        f"【zcode-relay】发现新任务: {job_name}\n"
        f"请读取 {job_path} 并按其中规范执行，"
        f"完成后把报告写入 {os.path.join(RESULTS_DIR, job_name, 'report.md')}\n"
        f"(此消息由 relay 桥接服务自动发送)"
    )
    ok = notify(text, job_name)
    os.makedirs(DISPATCHED_DIR, exist_ok=True)
    with open(os.path.join(DISPATCHED_DIR, job_name + ".json"), "w", encoding="utf-8") as f:
        json.dump({"job": job_name, "dispatched_at": int(time.time()),
                   "notified": ok}, f)
    log(f"任务已派发: {job_name} (通知={'成功' if ok else '未送达/未配置'})")


def collect(job_name, meta):
    """结果已出现：标记完成并推送"""
    outdir = os.path.join(RESULTS_DIR, job_name)
    status_file = os.path.join(outdir, "status.txt")
    if not os.path.exists(status_file):
        dur = int(time.time()) - meta["dispatched_at"]
        with open(status_file, "w", encoding="utf-8") as f:
            f.write(f"job: {job_name}\nstatus: completed\n"
                    f"waited_sec: {dur}\n")
    git_push(f"results/{job_name}", f"relay: {job_name} 结果已回传")
    os.remove(os.path.join(DISPATCHED_DIR, job_name + ".json"))
    log(f"结果已回传: {job_name}")


def mark_timeout(job_name, meta):
    outdir = os.path.join(RESULTS_DIR, job_name)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "status.txt"), "w", encoding="utf-8") as f:
        f.write(f"job: {job_name}\nstatus: timeout\n"
                f"dispatched_at: {meta['dispatched_at']}\n"
                f"timeout_sec: {RESULT_TIMEOUT}\n")
    git_push(f"results/{job_name}", f"relay: {job_name} 执行超时")
    os.remove(os.path.join(DISPATCHED_DIR, job_name + ".json"))
    log(f"任务超时: {job_name}")


def main():
    os.makedirs(DISPATCHED_DIR, exist_ok=True)
    log(f"bridge 启动: repo={REPO_DIR} notifier={NOTIFIER} "
        f"interval={POLL_INTERVAL}s timeout={RESULT_TIMEOUT}s")
    while True:
        try:
            if git_pull():
                # 1. 发现新任务
                for name in sorted(os.listdir(JOBS_DIR)):
                    if name.startswith(".") or name == ".gitkeep":
                        continue
                    if not os.path.isdir(os.path.join(JOBS_DIR, name)) and \
                       not os.path.isfile(os.path.join(JOBS_DIR, name)):
                        continue
                    if os.path.exists(os.path.join(DISPATCHED_DIR, name + ".json")):
                        continue
                    if os.path.isdir(os.path.join(RESULTS_DIR, name)):
                        continue  # 已有结果（历史任务）
                    dispatch(name)

                # 2. 跟踪已派发任务
                for name in os.listdir(DISPATCHED_DIR):
                    if not name.endswith(".json"):
                        continue
                    job = name[:-5]
                    with open(os.path.join(DISPATCHED_DIR, name), encoding="utf-8") as f:
                        meta = json.load(f)
                    if os.path.exists(os.path.join(RESULTS_DIR, job, "report.md")):
                        collect(job, meta)
                    elif time.time() - meta["dispatched_at"] > RESULT_TIMEOUT:
                        mark_timeout(job, meta)
        except Exception as e:
            log(f"主循环异常（继续运行）: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
