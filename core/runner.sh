#!/bin/bash

# ==========================================================
# 脚本名称: runner.sh (Google Lite 版)
# 核心功能: Google 区域纠偏调度枢纽，防并发锁与随机休眠
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# --- [基础环境构建] ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件丢失，请重新运行 install_lite.sh"
    exit 1
fi
source "$CONFIG_FILE"

# ==========================================================
# [防线 1] 进程排他锁管控
# ==========================================================
exec 200>"/tmp/ip_sentinel_runner.lock"
if ! flock -n 200; then
    echo "[$(date)] ⚠️ 上一轮巡逻任务尚未结束，本次触发自动取消。" >> "$LOG_FILE"
    exit 0
fi

# --- [系统级日志通道] ---
log() {
    local module=$1
    local level=$2
    local msg=$3
    local local_ver="${AGENT_VERSION:-未知}"

    mkdir -p "${INSTALL_DIR}/logs"

    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$level" "$module" "$REGION_CODE" "$msg")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    else
        echo "$core_msg"
    fi
}
export -f log
export CONFIG_FILE INSTALL_DIR

# ==========================================================
# [防线 2] 行为学隐蔽 (Cron Jitter)
# ==========================================================
if [ -t 1 ]; then
    log "SYSTEM" "INFO " "💻 检测到人工终端干预，跳过静默休眠，立即执行任务！"
else
    JITTER_TIME=$((RANDOM % 180))
    log "SYSTEM" "INFO " "⏱️ 进入防并发随机休眠: ${JITTER_TIME} 秒..."
    sleep $JITTER_TIME
fi

# ==========================================================
# Google Lite: 只运行 Google 区域纠偏
# ==========================================================
log "SYSTEM" "INFO" "休眠结束，开始执行 Google 区域纠偏模块..."

if [ "${ENABLE_GOOGLE}" != "true" ]; then
    log "SYSTEM" "WARN" "Google 模块未开启 (ENABLE_GOOGLE != true)，跳过本轮执行。"
    exit 0
fi

if [ -x "${INSTALL_DIR}/core/mod_google.sh" ]; then
    log "SYSTEM" "INFO" "加载并执行: Google 区域纠偏"
    nice -n 19 bash "${INSTALL_DIR}/core/mod_google.sh" 200>&-
else
    log "SYSTEM" "ERROR" "未找到可执行脚本: mod_google.sh"
fi

log "SYSTEM" "INFO" "本轮任务执行完毕，哨兵继续隐蔽待命。"