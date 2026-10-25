# 🛡️ IP-Sentinel Lite

> **极简 VPS 出口 IP / Google 区域纠偏监控 — 一键安装，自动运行，Telegram 日报。**

[![License](https://img.shields.io/github/license/keeplearning2026/IP-Sentinel)](https://github.com/keeplearning2026/IP-Sentinel)

📢 交流频道: [@IP_Sentinel_Matrix](https://t.me/IP_Sentinel_Matrix)

---

## 功能特性

- 📡 **出口 IP 检测** — 多级 ISP 探测，自动识别 IPv4/IPv6 和 Cloudflare Warp
- 🎯 **Google 区域纠偏** — 模拟真实用户行为，逐步修正 IP 地理归属，解决"送中"问题
- 📊 **Telegram 每日报告** — 每天自动推送节点状态、纠偏统计、执行快照
- ⏱️ **systemd timer 全自动运行** — 无需手动干预，安装即跑
- 🔄 **数据自动刷新** — 每日任务先刷新纠偏数据，再在 Telegram 日报显示一行摘要
- 🪶 **极简低占用** — 无外部依赖（仅需 curl/jq），shell 原生实现

## 快速安装

```bash
bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/keeplearning2026/IP-Sentinel/main/install.sh)"
```

安装过程交互式选择地区和配置 Telegram。

**依赖**: `systemd`、`curl`、`jq`（安装脚本会自动检查）。

## 配置 Telegram

新安装通常只需要输入 **Bot Token**，Chat ID 由安装器通过 Telegram 自动检测。

1. 在 Telegram 打开 [@BotFather](https://t.me/BotFather)，发送 `/newbot`。
2. 按提示设置机器人名称和以 `bot` 结尾的唯一用户名，复制 BotFather 返回的 Token。
3. 将 Token 粘贴到安装器。输入默认隐藏；安装器通过 `getMe` 验证后显示机器人用户名和链接。
4. 私聊接收日报时，打开安装器显示的本轮启动链接并点击 **Start**。也可以发送安装器给出的 `/start <识别码>` 命令。
5. 群组接收日报时，先添加机器人，再在目标群组发送安装器给出的 `/start@机器人用户名 <识别码>`。普通消息可能受隐私模式限制。
6. 频道接收日报时，将机器人设为管理员并授予发帖权限，再在目标频道发布上述带识别码的命令。
7. 返回安装器按 Enter。每轮检测最多等待 90 秒，约每 3 秒查询一次；没有发现会话时可重试一次。
8. 本轮只有一个会话时自动选择；多个会话时显示 ID、类型和名称，必须手动选择。安装器发送测试消息，成功后才保存配置。

识别码用于防止历史消息被误认为本次接收目标，消息正文不会输出到终端。建议使用专用机器人；自动检测会读取并确认待处理更新，如果机器人还有其他接收消息的程序，请在检测前选择 `m` 手动输入 Chat ID。安装器不更改机器人的更新订阅设置。

自动检测失败、没有收到带识别码的消息、Webhook 已启用或存在其他轮询程序时，安装器会提示“改为手动输入 Chat ID”。手动输入支持私聊 ID、负数群组/频道 ID 和公开频道的 `@channel` 用户名。手动填写不会绕过测试发送；错误目标或权限不足时，可以重新选择、重新检测或重新填写。安装器不会删除 Webhook。

无效 Token 最多允许输入三次。网络、限流或服务端临时故障会有上限地重试；未验证的新 Token 不会写入配置。如果测试发送仅遇到临时故障，可以明确选择 `k` 保存并继续，**此时日报可能发送失败**。

升级时，Token 和 Chat ID 均可回车沿用；即使再次粘贴相同 Token，也不会自动更换接收目标。输入不同 Token 后会重新检测 Chat ID。验证原 Token 时若 Telegram 暂时不可达，可选择 `k` 保留原 Telegram 配置并继续，同样会提示日报可能发送失败。

最终配置仍保存在 `/opt/ip_sentinel/config.conf`，字段与原版本兼容：

```bash
TG_TOKEN="123456:ABC..."
TG_API_URL="https://api.telegram.org/bot123456:ABC.../sendMessage"
CHAT_ID="987654321"
```

如需更换 Token 或接收目标，重新运行安装器并选择重新检测或手动输入即可。手动编辑配置时，更换 Token 应同步更新 `TG_API_URL`：

```bash
sudo nano /opt/ip_sentinel/config.conf
sudo systemctl restart ip-sentinel-report.timer
```

## 常用命令

```bash
# 查看 timer 状态
systemctl list-timers --all | grep ip-sentinel

# 查看 runner 日志
journalctl -u ip-sentinel-runner.service -n 100 --no-pager

# 查看日报发送日志
journalctl -u ip-sentinel-report.service -n 30 --no-pager

# 查看完整运行日志
tail -n 100 /opt/ip_sentinel/logs/sentinel.log

# 手动触发一次 Google 纠偏
sudo systemctl start ip-sentinel-runner.service

# 手动触发一次每日任务（先刷新数据，再发送日报）
sudo rm -f /opt/ip_sentinel/core/.report_lock
sudo systemctl start ip-sentinel-report.service
journalctl -u ip-sentinel-report.service -n 160 --no-pager
```

## Timer 说明

| Timer | 频率 | 作用 |
|-------|------|------|
| `ip-sentinel-runner.timer` | 每 1 小时（随机延迟 0-20 分钟） | 执行 Google 区域纠偏 |
| `ip-sentinel-report.timer` | 每天 04:30 UTC | 执行每日任务：刷新数据并发送 Telegram 日报 |

`ip-sentinel-report.timer` 触发 `core/daily.sh`；`daily.sh` 会先运行 `updater.sh`，再运行 `tg_report.sh`。

## Telegram 日报内容

```
📊 IP-Sentinel 每日简报
----------------------------
📍 节点名称: xxx
📡 出口 IP: xxx
🛡️ IP 属性: xxx ISP 🏠

🎯 Google 区域纠偏
执行次数: x | 完成会话: x
✅ 成功: x | ❌ 失败: x | ⚠️ 警告: x
胜率: x%

🕒 最近执行快照
时间: xxx
结论: xxx

----------------------------
🛡️ 系统状态
⏱️ 战报生成: xxx
🧩 数据刷新: ✅ 关键词库成功；UA 池跳过；日志清理成功
当前运行版本: vX.X.X
```

数据刷新摘要只显示关键词库、UA 池、日志清理的执行结果；不会展示文件名、数量或 timer 细节。

## 更新

```bash
bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/keeplearning2026/IP-Sentinel/main/install.sh)"
```

选择"安装/更新"即可，现有配置自动保留。

## 卸载

```bash
# 方式 1: 重新运行安装脚本，选择"卸载"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/keeplearning2026/IP-Sentinel/main/install.sh)"

# 方式 2: 直接执行卸载脚本
sudo bash /opt/ip_sentinel/core/uninstall.sh
```

## 故障排查

**收不到 Telegram 日报**

```bash
# 查看报告服务状态
systemctl status ip-sentinel-report.service --no-pager

# 手动触发看报错
sudo rm -f /opt/ip_sentinel/core/.report_lock
sudo systemctl start ip-sentinel-report.service
journalctl -u ip-sentinel-report.service -n 160 --no-pager
```

常见原因：Token/Chat ID 错误、Bot 未启动或被屏蔽、VPS 无法访问 api.telegram.org。

**`report.service` 显示 `inactive (dead)` 是正常的**

report 是一次性任务（Type=oneshot），执行完自动退出，不是常驻服务。只要 timer 存在且没有持续报错就没问题。

**Runner 看似卡住**

纠偏任务有时需要 10-20 分钟，期间日志不输出是正常的。runner 服务允许最长执行 30 分钟；如果日报中“执行次数”明显大于“完成会话”，请查看 `journalctl -u ip-sentinel-runner.service -n 100 --no-pager`。

**确认 runner 是否按小时触发**

```bash
systemctl cat ip-sentinel-runner.timer
systemctl list-timers --all | grep ip-sentinel-runner
grep "\[Google.*\[START\]" /opt/ip_sentinel/logs/sentinel.log | tail -n 30
```

**`jq` 缺失**

```bash
sudo apt install jq       # Debian/Ubuntu
sudo yum install jq       # CentOS/RHEL
sudo apk add jq           # Alpine
```

---

## ⛔ 已移除的组件

以下功能已从当前 Lite 主线移除，不再维护：

- Master-Agent 分布式架构
- Trust / IP 信用净化
- 关键词库 / UA 池 文件名、数量等详细状态日报
- OTA 热更新 / 中枢控制台
- Webhook / agent_daemon

---

## 免责声明

本项目仅供网络原理研究与 VPS 维护学习使用。请遵守当地法律法规及目标服务商的 TOS。使用者自行承担因不当使用造成的 IP 封禁或其他风险。

---

💡 如果本项目对你有帮助，欢迎点亮 🌟 Star！
