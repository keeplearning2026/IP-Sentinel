#!/bin/bash
# ==========================================================
# 脚本名称: updater.sh (Google Lite 数据刷新器)
# 核心功能:
#   1. 每次运行刷新当前地区关键词库
#   2. 每 30 天刷新一次 user_agents.txt
# 不更新: core 脚本、region json、ip_probe、程序本身
# ==========================================================

set -euo pipefail

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"
UA_TIME_FILE="${INSTALL_DIR}/core/.ua_last_update"
REPO_RAW_URL="https://raw.githubusercontent.com/keeplearning2026/IP-Sentinel/main"

# --- [日志函数] ---
log() {
    local level="$1"
    local msg="$2"
    local local_ver="${AGENT_VERSION:-未知}"

    mkdir -p "${INSTALL_DIR}/logs"

    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$level" "Updater" "${REGION_CODE:-未知}" "$msg")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    fi
}

# --- [基础检查] ---
if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "${INSTALL_DIR}/logs"
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [Updater] [ERROR] 配置文件不存在: $CONFIG_FILE" >> "${LOG_FILE}"
    exit 1
fi

source "$CONFIG_FILE"

log "INFO" "========== Lite 数据刷新器启动 =========="

# ==========================================================
# 1. User-Agent 池更新 (每 30 天一次)
# ==========================================================
NOW=$(date +%s)
LAST_UPDATE=0

if [ -f "$UA_TIME_FILE" ]; then
    LAST_UPDATE=$(cat "$UA_TIME_FILE" | tr -d '\r\n' 2>/dev/null || echo 0)
fi

if ! [[ "$LAST_UPDATE" =~ ^[0-9]+$ ]]; then
    LAST_UPDATE=0
fi

DIFF=$((NOW - LAST_UPDATE))

if [ "$DIFF" -ge 2592000 ] || [ "$LAST_UPDATE" -eq 0 ]; then
    TMP_UA="/tmp/ip_sentinel_user_agents.$$"
    log "INFO" "开始刷新 User-Agent 池 (距上次更新 ${DIFF} 秒)..."

    if curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "${REPO_RAW_URL}/data/user_agents.txt?t=$(date +%s)" -o "$TMP_UA" 2>/dev/null; then
        if [ -s "$TMP_UA" ]; then
            LINE_COUNT=$(grep -v '^[[:space:]]*$' "$TMP_UA" | wc -l | tr -d ' ')
            if [ "$LINE_COUNT" -gt 0 ]; then
                mv "$TMP_UA" "${INSTALL_DIR}/data/user_agents.txt"
                chmod 644 "${INSTALL_DIR}/data/user_agents.txt"
                echo "$NOW" > "$UA_TIME_FILE"
                log "INFO" "User-Agent 池刷新成功: ${LINE_COUNT} 条"
            else
                rm -f "$TMP_UA"
                log "WARN" "User-Agent 池有效行数为 0，保留旧文件"
            fi
        else
            rm -f "$TMP_UA"
            log "WARN" "User-Agent 池文件为空，保留旧文件"
        fi
    else
        rm -f "$TMP_UA"
        log "WARN" "User-Agent 池下载失败，保留旧文件"
    fi
else
    DAYS_LEFT=$(((2592000 - DIFF) / 86400))
    log "INFO" "User-Agent 池处于 30 天静默期 (剩余约 ${DAYS_LEFT} 天)，跳过"
fi

# ==========================================================
# 2. 关键词库更新 (每次运行)
# ==========================================================
if [ -z "${KEYWORD_FILE:-}" ]; then
    log "ERROR" "KEYWORD_FILE 未配置，跳过关键词刷新"
else
    log "INFO" "开始刷新关键词库: ${KEYWORD_FILE}"

    TMP_KW="/tmp/ip_sentinel_${KEYWORD_FILE}.$$"

    if curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}?t=$(date +%s)" -o "$TMP_KW" 2>/dev/null; then
        if [ -s "$TMP_KW" ]; then
            LINE_COUNT=$(grep -v '^[[:space:]]*$' "$TMP_KW" | wc -l | tr -d ' ')
            if [ "$LINE_COUNT" -gt 0 ]; then
                mv "$TMP_KW" "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
                chmod 644 "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
                log "INFO" "关键词库刷新成功: ${KEYWORD_FILE}, ${LINE_COUNT} 条"
            else
                rm -f "$TMP_KW"
                log "WARN" "关键词库有效行数为 0，保留旧文件: ${KEYWORD_FILE}"
            fi
        else
            rm -f "$TMP_KW"
            log "WARN" "关键词库文件为空，保留旧文件: ${KEYWORD_FILE}"
        fi
    else
        rm -f "$TMP_KW"
        log "WARN" "关键词库下载失败，保留旧文件: ${KEYWORD_FILE}"
    fi
fi

# ==========================================================
# 3. 日志瘦身 (保留最近 2000 行)
# ==========================================================
if [ -f "$LOG_FILE" ]; then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null || true
    mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
    log "INFO" "日志已定期清理 (保留最新 2000 行)"
fi

log "INFO" "========== Lite 数据刷新完成 =========="
