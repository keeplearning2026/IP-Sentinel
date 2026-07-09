#!/bin/bash

# ==========================================================
# 脚本名称: daily.sh
# 核心功能: Lite 每日任务编排器 - 数据刷新 + Telegram 日报
# ==========================================================

set -uo pipefail

INSTALL_DIR="/opt/ip_sentinel"
LOG_DIR="${INSTALL_DIR}/logs"
LOG_FILE="${LOG_DIR}/sentinel.log"

mkdir -p "$LOG_DIR"

log_daily() {
    local level="$1"
    local msg="$2"

    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [Daily] [$level] $msg" >> "$LOG_FILE"
}

log_daily "START" "Lite 每日任务启动"

DATA_RC=0
REPORT_RC=0

if [ -f "${INSTALL_DIR}/core/updater.sh" ]; then
    /bin/bash "${INSTALL_DIR}/core/updater.sh"
    DATA_RC=$?
else
    log_daily "ERROR" "updater.sh 不存在"
    DATA_RC=1
fi

# updater 失败也继续发送日报，让用户能看到数据刷新异常摘要。
if [ -f "${INSTALL_DIR}/core/tg_report.sh" ]; then
    /bin/bash "${INSTALL_DIR}/core/tg_report.sh"
    REPORT_RC=$?
else
    log_daily "ERROR" "tg_report.sh 不存在"
    REPORT_RC=1
fi

log_daily "DONE" "data_rc=${DATA_RC}, report_rc=${REPORT_RC}"

if [ "$REPORT_RC" -ne 0 ]; then
    exit "$REPORT_RC"
fi

if [ "$DATA_RC" -ne 0 ]; then
    exit "$DATA_RC"
fi

exit 0
