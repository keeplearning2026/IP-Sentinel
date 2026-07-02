#!/bin/bash

# ==========================================================
# 脚本名称: tg_report.sh
# 核心功能: Lite 极简日报 — 节点状态、Google 纠偏、执行快照、版本
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# --- [基础自检] ---
if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
source "$CONFIG_FILE"

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 未配置 Telegram 机器人参数，取消播报。"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 缺少 jq，无法构造 Telegram JSON payload。" >&2
    exit 1
fi

# ==========================================================
# 60 秒防并发锁
# ==========================================================
LOCK_FILE="${INSTALL_DIR}/core/.report_lock"
if [ -f "$LOCK_FILE" ]; then
    LAST_RUN=$(cat "$LOCK_FILE" 2>/dev/null)
    NOW=$(date +%s)
    if [[ "$LAST_RUN" =~ ^[0-9]+$ ]]; then
        if [ $((NOW - LAST_RUN)) -lt 60 ]; then
            exit 0
        fi
    fi
fi
echo $(date +%s) > "$LOCK_FILE"

# ==========================================================
# 1. 节点元数据
# ==========================================================
if [ -z "$NODE_NAME" ]; then
    IP_HASH=$(echo "${PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | cut -c 1-10)-${IP_HASH}"
fi
NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"

# --- 出口 IP 探测 ---
CURL_BIND_OPT=""
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    if ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        CURL_BIND_OPT="--interface $BIND_IP"
        if [[ "$BIND_IP" == *":"* ]]; then
            DYNAMIC_IP_PREF="-6"
        elif [[ "$BIND_IP" == *"."* ]]; then
            DYNAMIC_IP_PREF="-4"
        fi
    fi
fi

CURRENT_IP=$( (curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/ip || curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
[ -z "$CURRENT_IP" ] && CURRENT_IP="${PUBLIC_IP:-$BIND_IP}"
[[ "$CURRENT_IP" == *":"* ]] && [[ "$CURRENT_IP" != *"["* ]] && CURRENT_IP="[${CURRENT_IP}]"

# --- ISP / IP 属性 ---
ISP_INFO=""
ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ipinfo.io/org 2>/dev/null)
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ip-api.com/line/?fields=isp 2>/dev/null)
fi
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    if command -v jq &> /dev/null; then
        ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/geoip | jq -r '.organization' 2>/dev/null)
    fi
fi

ISP_INFO=$(echo "$ISP_INFO" | sed -E 's/^AS[0-9]+ //')
[ -z "$ISP_INFO" ] || [ "$ISP_INFO" == "null" ] && ISP_INFO="未知 ISP"

if [[ "$ISP_INFO" == *"Cloudflare"* ]]; then
    IP_TYPE="Cloudflare Warp 🛰️"
else
    IP_TYPE="$ISP_INFO 🏠"
fi

# ==========================================================
# 2. 日志分析
# ==========================================================
LOG_CONTENT=$(tail -n 1000 "$LOG_FILE" 2>/dev/null)

if [ -z "$LOG_CONTENT" ]; then
    read -r -d '' MSG <<EOT
🛑 **IP-Sentinel 告警：节点异常**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
⚠️ **警告**: 过去 24 小时无运行日志！
🛠️ **建议**: 节点可能刚部署完毕，请稍后再试。
EOT
else
    LAST_LOG_LINE=$(echo "$LOG_CONTENT" | grep "\[SCORE\]" | tail -n 1)
    LAST_TIME=$(echo "$LAST_LOG_LINE" | awk '{print $1,$2}' | tr -d '[]')
    LAST_SCORE=$(echo "$LAST_LOG_LINE" | awk -F'自检结论: ' '{print $2}')

    MSG="📊 **IP-Sentinel 每日简报**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
📡 **出口 IP**: \`${CURRENT_IP}\`
🛡️ **IP 属性**: ${IP_TYPE}"

    # Google 区域纠偏
    if [ "$ENABLE_GOOGLE" == "true" ]; then
        GOOGLE_LOGS=$(echo "$LOG_CONTENT" | grep "\[Google")
        G_TOTAL=$(echo "$GOOGLE_LOGS" | grep "\[START\]" -c)
        G_SUCCESS=$(echo "$GOOGLE_LOGS" | grep "✅" -c)
        G_FAILED=$(echo "$GOOGLE_LOGS" | grep "❌" -c)
        G_WARN=$(echo "$GOOGLE_LOGS" | grep "⚠️" -c)

        G_RATE="0.0"
        [ "$G_TOTAL" -gt 0 ] && G_RATE=$(awk "BEGIN {printf \"%.1f\", ($G_SUCCESS/$G_TOTAL)*100}")

        MSG="$MSG

🎯 **Google 区域纠偏**
执行次数: ${G_TOTAL}
✅ 成功: ${G_SUCCESS} | ❌ 失败: ${G_FAILED} | ⚠️ 警告: ${G_WARN}
胜率: **${G_RATE}%**"
    fi

    MSG="$MSG

🕒 **最近执行快照**
时间: ${LAST_TIME:-"暂无数据"}
结论: ${LAST_SCORE:-"暂无数据"}"
fi

# ==========================================================
# 3. 版本信息
# ==========================================================
LOCAL_VER="${AGENT_VERSION:-未知}"
DISPLAY_LOCAL_VER="$LOCAL_VER"
[[ "$DISPLAY_LOCAL_VER" != v* && "$DISPLAY_LOCAL_VER" != "未知" ]] && DISPLAY_LOCAL_VER="v${DISPLAY_LOCAL_VER}"

REPORT_UTC_TIME=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

REPO_RAW_URL="https://raw.githubusercontent.com/keeplearning2026/IP-Sentinel/main"
REMOTE_VER=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt" | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
DISPLAY_REMOTE_VER="$REMOTE_VER"
[[ "$DISPLAY_REMOTE_VER" != v* && -n "$DISPLAY_REMOTE_VER" ]] && DISPLAY_REMOTE_VER="v${DISPLAY_REMOTE_VER}"

MSG="$MSG
----------------------------
🛡️ **系统状态**
⏱️ 战报生成: \`${REPORT_UTC_TIME}\`"

if [ -n "$REMOTE_VER" ]; then
    if [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
        MSG="$MSG
当前运行版本: \`${DISPLAY_LOCAL_VER}\`
✨ **发现新版本**: \`${DISPLAY_REMOTE_VER}\` (建议更新)
💡 *Google Lite 持续为您守护节点。*"
    else
        MSG="$MSG
当前运行版本: \`${DISPLAY_LOCAL_VER}\` (✅ 已是最新)
💡 *Google Lite 持续为您守护节点。*"
    fi
else
    MSG="$MSG
当前运行版本: \`${DISPLAY_LOCAL_VER}\`
💡 *Google Lite 持续为您守护节点。*"
fi

# ==========================================================
# 4. 发送 Telegram
# ==========================================================
TG_API="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

JSON_PAYLOAD=$(jq -n \
  --arg cid "$CHAT_ID" \
  --arg txt "$MSG" \
  '{
    chat_id: $cid,
    text: $txt,
    parse_mode: "Markdown",
    disable_web_page_preview: true
  }')

RESPONSE=$(curl -sS -X POST "$TG_API" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD")
CURL_STATUS=$?

if [[ $CURL_STATUS -ne 0 ]]; then
    echo "❌ Telegram API 请求失败，curl exit code: $CURL_STATUS" >&2
    echo "❌ Telegram API 请求失败，curl exit code: $CURL_STATUS" >> "${INSTALL_DIR}/logs/error.log"
    exit 1
fi

if ! printf '%s' "$RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "❌ 战报发送失败！API 响应: $RESPONSE" >&2
    echo "❌ 战报发送失败！API 响应: $RESPONSE" >> "${INSTALL_DIR}/logs/error.log"
    exit 1
fi

echo "✅ 战报推送成功！"
