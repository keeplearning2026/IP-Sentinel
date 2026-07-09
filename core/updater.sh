#!/bin/bash
# ==========================================================
# 脚本名称: updater.sh (Google Lite 数据刷新器)
# 核心功能:
#   1. 每次运行刷新当前地区关键词库
#   2. 每 30 天刷新一次 user_agents.txt
#   3. 输出今日数据刷新状态摘要
# 不更新: core 脚本、region json、ip_probe、程序本身
# ==========================================================

set -euo pipefail

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"
STATE_DIR="${INSTALL_DIR}/state"
DATA_UPDATE_STATE="${STATE_DIR}/data_update.env"
UA_TIME_FILE="${INSTALL_DIR}/core/.ua_last_update"
REPO_RAW_URL="https://raw.githubusercontent.com/keeplearning2026/IP-Sentinel/main"

KEYWORD_STATUS="skipped"
UA_STATUS="skipped"
LOG_STATUS="skipped"
DATA_UPDATE_STATUS="ok"

KEYWORD_SUMMARY="关键词库跳过"
UA_SUMMARY="UA 池跳过"
LOG_SUMMARY="日志清理跳过"
DATA_UPDATE_SUMMARY=""

# --- [日志函数] ---
log() {
    local level="$1"
    local msg="$2"
    local local_ver="${AGENT_VERSION:-未知}"
    local core_msg

    mkdir -p "${INSTALL_DIR}/logs"

    core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$level" "Updater" "${REGION_CODE:-未知}" "$msg")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    fi
}

count_nonempty_lines() {
    local file="$1"

    if [ ! -f "$file" ]; then
        printf '0\n'
        return 0
    fi

    awk 'NF { c++ } END { print c + 0 }' "$file" 2>/dev/null || printf '0\n'
}

file_has_valid_lines() {
    local file="$1"
    local line_count

    line_count="$(count_nonempty_lines "$file")"
    [[ "$line_count" =~ ^[0-9]+$ ]] && [ "$line_count" -gt 0 ]
}

env_quote() {
    local value="${1:-}"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

finalize_data_update_status() {
    DATA_UPDATE_SUMMARY="${KEYWORD_SUMMARY}；${UA_SUMMARY}；${LOG_SUMMARY}"

    if [ "$KEYWORD_STATUS" = "failed" ] || [ "$UA_STATUS" = "failed" ]; then
        DATA_UPDATE_STATUS="fail"
    elif [ "$KEYWORD_STATUS" = "degraded" ] || [ "$UA_STATUS" = "degraded" ] || [ "$LOG_STATUS" = "degraded" ]; then
        DATA_UPDATE_STATUS="degraded"
    else
        DATA_UPDATE_STATUS="ok"
    fi
}

write_data_update_state() {
    local now_utc
    local now_epoch
    local tmp_file

    mkdir -p "$STATE_DIR"

    now_utc="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    now_epoch="$(date +%s)"
    tmp_file="${DATA_UPDATE_STATE}.$$"

    if ! {
        printf 'DATA_UPDATE_STATUS="%s"\n' "$(env_quote "$DATA_UPDATE_STATUS")"
        printf 'DATA_UPDATE_TIME_UTC="%s"\n' "$(env_quote "$now_utc")"
        printf 'DATA_UPDATE_EPOCH="%s"\n' "$(env_quote "$now_epoch")"
        printf 'DATA_UPDATE_SUMMARY="%s"\n' "$(env_quote "$DATA_UPDATE_SUMMARY")"
        printf 'DATA_UPDATE_KEYWORD_STATUS="%s"\n' "$(env_quote "$KEYWORD_STATUS")"
        printf 'DATA_UPDATE_UA_STATUS="%s"\n' "$(env_quote "$UA_STATUS")"
        printf 'DATA_UPDATE_LOG_STATUS="%s"\n' "$(env_quote "$LOG_STATUS")"
    } > "$tmp_file"; then
        rm -f "$tmp_file"
        log "ERROR" "数据刷新状态文件写入失败: ${DATA_UPDATE_STATE}"
        return 1
    fi

    chmod 644 "$tmp_file" 2>/dev/null || true

    if ! mv "$tmp_file" "$DATA_UPDATE_STATE"; then
        rm -f "$tmp_file"
        log "ERROR" "数据刷新状态文件替换失败: ${DATA_UPDATE_STATE}"
        return 1
    fi

    return 0
}

mark_ua_failure() {
    local reason="$1"

    if file_has_valid_lines "${INSTALL_DIR}/data/user_agents.txt"; then
        UA_STATUS="degraded"
        UA_SUMMARY="UA 池失败，使用旧数据"
        log "WARN" "${reason}，使用旧 User-Agent 池"
    else
        UA_STATUS="failed"
        UA_SUMMARY="UA 池不可用"
        log "ERROR" "${reason}，且旧 User-Agent 池不可用"
    fi
}

refresh_user_agents() {
    local now
    local last_update
    local diff
    local days_left
    local tmp_ua
    local line_count

    now="$(date +%s)"
    last_update="0"

    if [ -f "$UA_TIME_FILE" ]; then
        last_update="$(tr -d '\r\n' < "$UA_TIME_FILE" 2>/dev/null || printf '0')"
    fi

    if ! [[ "$last_update" =~ ^[0-9]+$ ]]; then
        last_update="0"
    fi

    diff=$((now - last_update))

    if [ "$diff" -lt 2592000 ] && [ "$last_update" -ne 0 ]; then
        days_left=$(((2592000 - diff) / 86400))
        UA_STATUS="skipped"
        UA_SUMMARY="UA 池跳过"
        log "INFO" "User-Agent 池处于 30 天静默期 (剩余约 ${days_left} 天)，跳过"
        return 0
    fi

    tmp_ua="/tmp/ip_sentinel_user_agents.$$"
    log "INFO" "开始刷新 User-Agent 池 (距上次更新 ${diff} 秒)..."

    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "${REPO_RAW_URL}/data/user_agents.txt?t=$(date +%s)" -o "$tmp_ua" 2>/dev/null; then
        rm -f "$tmp_ua"
        mark_ua_failure "User-Agent 池下载失败"
        return 0
    fi

    line_count="$(count_nonempty_lines "$tmp_ua")"
    if ! [[ "$line_count" =~ ^[0-9]+$ ]] || [ "$line_count" -le 0 ]; then
        rm -f "$tmp_ua"
        mark_ua_failure "User-Agent 池有效行数为 0"
        return 0
    fi

    mkdir -p "${INSTALL_DIR}/data"
    if mv "$tmp_ua" "${INSTALL_DIR}/data/user_agents.txt" && chmod 644 "${INSTALL_DIR}/data/user_agents.txt" && echo "$now" > "$UA_TIME_FILE"; then
        UA_STATUS="success"
        UA_SUMMARY="UA 池成功"
        log "INFO" "User-Agent 池刷新成功: ${line_count} 条"
    else
        rm -f "$tmp_ua"
        mark_ua_failure "User-Agent 池落盘失败"
    fi
}

mark_keyword_failure() {
    local reason="$1"
    local keyword_path="${INSTALL_DIR}/data/keywords/${KEYWORD_FILE:-}"

    if [ -n "${KEYWORD_FILE:-}" ] && file_has_valid_lines "$keyword_path"; then
        KEYWORD_STATUS="degraded"
        KEYWORD_SUMMARY="关键词库失败，使用旧数据"
        log "WARN" "${reason}，使用旧关键词库: ${KEYWORD_FILE}"
    else
        KEYWORD_STATUS="failed"
        KEYWORD_SUMMARY="关键词库不可用"
        log "ERROR" "${reason}，且旧关键词库不可用"
    fi
}

refresh_keywords() {
    local tmp_kw
    local line_count
    local keyword_path

    if [ -z "${KEYWORD_FILE:-}" ]; then
        KEYWORD_STATUS="failed"
        KEYWORD_SUMMARY="关键词库未配置"
        log "ERROR" "KEYWORD_FILE 未配置，跳过关键词刷新"
        return 0
    fi

    keyword_path="${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
    tmp_kw="/tmp/ip_sentinel_${KEYWORD_FILE}.$$"

    log "INFO" "开始刷新关键词库: ${KEYWORD_FILE}"

    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}?t=$(date +%s)" -o "$tmp_kw" 2>/dev/null; then
        rm -f "$tmp_kw"
        mark_keyword_failure "关键词库下载失败"
        return 0
    fi

    line_count="$(count_nonempty_lines "$tmp_kw")"
    if ! [[ "$line_count" =~ ^[0-9]+$ ]] || [ "$line_count" -le 0 ]; then
        rm -f "$tmp_kw"
        mark_keyword_failure "关键词库有效行数为 0"
        return 0
    fi

    mkdir -p "$(dirname "$keyword_path")"
    if mv "$tmp_kw" "$keyword_path" && chmod 644 "$keyword_path"; then
        KEYWORD_STATUS="success"
        KEYWORD_SUMMARY="关键词库成功"
        log "INFO" "关键词库刷新成功: ${KEYWORD_FILE}, ${line_count} 条"
    else
        rm -f "$tmp_kw"
        mark_keyword_failure "关键词库落盘失败"
    fi
}

cleanup_logs() {
    local cutoff
    local tmp_log

    if [ ! -f "$LOG_FILE" ]; then
        LOG_STATUS="skipped"
        LOG_SUMMARY="日志清理跳过"
        return 0
    fi

    cutoff="$(date -u -d '48 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
    tmp_log="${LOG_FILE}.tmp.$$"

    if [ -n "$cutoff" ]; then
        if awk -v cutoff="$cutoff" '
            substr($0, 1, 1) == "[" && substr($0, 21, 5) == " UTC]" {
                ts = substr($0, 2, 19)
                if (ts >= cutoff) print
                next
            }
            { print }
        ' "$LOG_FILE" > "$tmp_log" 2>/dev/null && mv "$tmp_log" "$LOG_FILE"; then
            LOG_STATUS="success"
            LOG_SUMMARY="日志清理成功"
            log "INFO" "日志已定期清理 (保留最近 48 小时)"
        else
            rm -f "$tmp_log"
            LOG_STATUS="degraded"
            LOG_SUMMARY="日志清理失败"
            log "WARN" "日志清理失败"
        fi
    elif tail -n 10000 "$LOG_FILE" > "$tmp_log" 2>/dev/null && mv "$tmp_log" "$LOG_FILE"; then
        LOG_STATUS="success"
        LOG_SUMMARY="日志清理成功"
        log "INFO" "日志已定期清理 (date -d 不可用，保留最新 10000 行)"
    else
        rm -f "$tmp_log"
        LOG_STATUS="degraded"
        LOG_SUMMARY="日志清理失败"
        log "WARN" "日志清理失败"
    fi
}

finish_updater() {
    finalize_data_update_status

    if ! write_data_update_state; then
        exit 1
    fi

    log "INFO" "========== Lite 数据刷新完成: ${DATA_UPDATE_STATUS} (${DATA_UPDATE_SUMMARY}) =========="

    if [ "$DATA_UPDATE_STATUS" = "fail" ]; then
        exit 1
    fi

    exit 0
}

mkdir -p "$STATE_DIR"

# --- [基础检查] ---
if [ ! -f "$CONFIG_FILE" ]; then
    KEYWORD_STATUS="failed"
    KEYWORD_SUMMARY="关键词库未配置"
    log "ERROR" "配置文件不存在: $CONFIG_FILE"
    cleanup_logs
    finish_updater
fi

# shellcheck disable=SC1090
if ! source "$CONFIG_FILE"; then
    KEYWORD_STATUS="failed"
    KEYWORD_SUMMARY="关键词库未配置"
    log "ERROR" "配置文件加载失败: $CONFIG_FILE"
    cleanup_logs
    finish_updater
fi

log "INFO" "========== Lite 数据刷新器启动 =========="

refresh_user_agents
refresh_keywords
cleanup_logs
finish_updater
