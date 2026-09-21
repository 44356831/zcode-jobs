# zcode-jobs · Git 异步中继仓库

让 Kimi（生成工作流文件）与服务器（跑 zcode）解耦：中间只隔这个 Git 仓库，
不需要实时连接、不暴露端口，任何设备上都能查看执行状态。

## 目录约定

```
jobs/                 待执行任务（Kimi 写入；服务器消费后保留存档）
results/<任务名>/
  status.txt          状态: success / failed:<退出码> / timeout，含起止时间与耗时
  stdout.log          zcode 的完整输出
  ...                 zcode 产出的文件原样留在该目录
server/               服务器端 relay 脚本与安装器
```

## 服务器安装（一次性）

1. 在服务器上生成专用密钥并加到本仓库的 Deploy Key（需要写权限）：
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/zcode_relay -N "" -C "zcode-relay-server"
   cat ~/.ssh/zcode_relay.pub   # 复制这行输出
   ```
   把输出的公钥贴到 GitHub 仓库 Settings → Deploy keys → Add deploy key，
   勾选 **Allow write access**。
2. 配置服务器用这把钥匙访问本仓库：
   ```bash
   cat >> ~/.ssh/config <<'EOF'
   Host github.com
     IdentityFile ~/.ssh/zcode_relay
   EOF
   ssh-keyscan -H github.com >> ~/.ssh/known_hosts
   ```
3. 一键安装 relay：
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/44356831/zcode-jobs/main/server/install.sh) git@github.com:44356831/zcode-jobs.git
   ```
   装完会自动自检。日志在 `/opt/zcode-relay/relay.log`。

> 如果服务器访问 raw.githubusercontent.com 不方便，直接 `git clone` 本仓库后
> 运行 `bash server/install.sh git@github.com:44356831/zcode-jobs.git` 效果相同。

## 日常使用

- 投递任务：把 zcode 工作流文件提交到 `jobs/` 目录（任务名建议带时间戳），推送即可
- 查看结果：任务执行完后 `results/<任务名>/` 下出现 `status.txt` 和 `stdout.log`
- 失败排查：`status.txt` 里有退出码、耗时、实际执行的命令

## 配置项（可选）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ZCODE_CMD` | `zcode run %s` | zcode 调用模板，`%s` 替换为工作流文件路径 |
| `JOB_TIMEOUT` | `1800` | 单任务最长执行秒数，防挂死 |

在 cron 行里前置赋值即可，如：
`ZCODE_CMD='zcode exec -f %s' JOB_TIMEOUT=3600 /opt/zcode-relay/repo/server/zcode-relay.sh >> ...`

## 已知边界

- 执行粒度为"每分钟一批"，非实时（异步中继的固有特性）
- 同名任务重复投递会覆盖，任务名请带时间戳
- results 目录适合放日志和小产物；大文件请走对象存储，不要进 Git
