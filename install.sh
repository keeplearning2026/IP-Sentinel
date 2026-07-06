#!/bin/bash
# ==========================================================
# 脚本名称: install.sh
# 核心功能: Google Lite Standalone 极简安装器
# 模式: Google only + Telegram 日报
# 特点: 独立极简运行时，不依赖完整 Agent 安装管线
# ==========================================================

set -euo pipefail

# ----------------------------------------------------------
# [权限鉴权]
# ----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 部署 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

# ----------------------------------------------------------
# [常量定义]
# ----------------------------------------------------------
REPO_RAW_URL="https://raw.githubusercontent.com/keeplearning2026/IP-Sentinel/main"
INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"
SECURE_TMP=$(mktemp -d /tmp/ips_lite_install.XXXXXX)

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
NC='\033[0m'

# ----------------------------------------------------------
# [中断清理]
# ----------------------------------------------------------
cleanup_and_exit() {
    echo -e "\n\n${YELLOW}⚠️ 检测到中断信号 (Ctrl+C)，安装已中止。${NC}"
    rm -rf "$SECURE_TMP" 2>/dev/null
    exit 1
}
trap cleanup_and_exit INT QUIT TERM
trap 'rm -rf "$SECURE_TMP" 2>/dev/null' EXIT HUP

# ----------------------------------------------------------
# [辅助函数]
# ----------------------------------------------------------
is_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

download_file() {
    local url="$1"
    local output="$2"
    local desc="${3:-文件}"
    curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "$url" -o "$output" 2>/dev/null
    if [ ! -s "$output" ]; then
        echo -e "${RED}❌ ${desc} 下载失败！${NC}"
        return 1
    fi
    return 0
}

download_check() {
    local url="$1"
    local output="$2"
    local desc="${3:-文件}"

    mkdir -p "$(dirname "$output")"
    if ! download_file "$url" "$output" "$desc"; then
        echo -e "${RED}  请检查网络连接或 GitHub Raw 访问。${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ ${desc} 下载成功${NC}"
    return 0
}

# ----------------------------------------------------------
# [版本信息]
# ----------------------------------------------------------
TARGET_VERSION=$(curl -fsSL --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 2 "${REPO_RAW_URL}/version.txt?t=$(date +%s)" 2>/dev/null | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]' || true)
TARGET_VERSION=${TARGET_VERSION:-"4.3.1"}

# ==========================================================
# 主流程开始
# ==========================================================

echo ""
echo "========================================================"
echo -e " ${BOLD}🛡️  IP-Sentinel Google Lite Standalone${NC}"
echo "========================================================"
echo -e " 模式: ${CYAN}Google 区域纠偏 + Telegram 日报${NC}"
echo -e " 版本: v${TARGET_VERSION}"
echo -e " 特点:"
echo -e "  • 可选地区的 Google 模块"
echo -e "  • 自动关键词刷新 (每日从上游拉取)"
echo -e "  • 仅保留 3 个 systemd timer"
echo -e "  • 不安装旧版 OTA / Trust / Webhook / Master"
echo "========================================================"
echo ""

# ----------------------------------------------------------
# [前置依赖检查]
# ----------------------------------------------------------
echo -e "${CYAN}[1/9] 检查系统依赖...${NC}"

echo -n "  • root 权限: "
echo -e "${GREEN}✅${NC}"

echo -n "  • systemd: "
if is_systemd; then
    echo -e "${GREEN}✅${NC}"
else
    echo -e "${RED}❌${NC}"
    echo -e "${RED}错误: Google Lite 需要 systemd 环境。${NC}"
    exit 1
fi

echo -n "  • curl: "
if command -v curl >/dev/null 2>&1; then
    echo -e "${GREEN}✅${NC}"
else
    echo -e "${RED}❌${NC}"
    echo -e "${RED}错误: 请先安装 curl。${NC}"
    echo -e "  Debian/Ubuntu: apt-get install -y curl"
    echo -e "  CentOS/RHEL:   yum install -y curl"
    echo -e "  Alpine:        apk add curl"
    exit 1
fi

echo -n "  • jq: "
if command -v jq >/dev/null 2>&1; then
    echo -e "${GREEN}✅${NC}"
else
    echo -e "${RED}❌${NC}"
    echo -e "${RED}错误: 请先安装 jq。${NC}"
    echo -e "  Debian/Ubuntu: apt-get install -y jq"
    echo -e "  CentOS/RHEL:   yum install -y jq"
    echo -e "  Alpine:        apk add jq"
    exit 1
fi

echo ""

# ----------------------------------------------------------
# [主菜单]
# ----------------------------------------------------------
echo -e "${BOLD}请选择操作:${NC}"
echo "  1) 🚀 安装 / 更新 Google Lite"
echo "  2) 🗑️  卸载 IP-Sentinel"
read -rp "请输入选择 [1-2] (默认1): " LITE_ACTION
LITE_ACTION="${LITE_ACTION:-1}"
echo ""

# ----------------------------------------------------------
# [卸载分支]
# ----------------------------------------------------------
if [ "$LITE_ACTION" = "2" ]; then
    echo -e "${CYAN}正在拉取卸载程序...${NC}"
    UNINSTALL_SCRIPT="${SECURE_TMP}/ip_uninstall.sh"
    if ! download_file "${REPO_RAW_URL}/core/uninstall.sh?t=$(date +%s)" "$UNINSTALL_SCRIPT" "卸载程序"; then
        exit 1
    fi
    chmod +x "$UNINSTALL_SCRIPT"
    bash "$UNINSTALL_SCRIPT"
    exit 0
fi

# ==========================================================
# 安装 / 更新流程
# ==========================================================

# ----------------------------------------------------------
# [步骤 2] 拉取 map.json
# ----------------------------------------------------------
echo -e "${CYAN}[2/9] 拉取全球战区地图...${NC}"
MAP_FILE="${SECURE_TMP}/map.json"
if ! download_file "${REPO_RAW_URL}/data/map.json?t=$(date +%s)" "$MAP_FILE" "全球战区地图"; then
    exit 1
fi

MAP_VERSION=$(jq -r '.version // "未知"' "$MAP_FILE")
echo -e "  📍 地图版本: ${MAP_VERSION}"
echo ""

# ----------------------------------------------------------
# [步骤 3] 交互式地区选择
# ----------------------------------------------------------
echo -e "${CYAN}[3/9] 选择目标地区...${NC}"

# 3a. 选择大洲
CONTINENT_COUNT=$(jq '.continents | length' "$MAP_FILE")
echo -e "${BOLD}请选择大洲:${NC}"
for i in $(seq 0 $((CONTINENT_COUNT - 1))); do
    NAME=$(jq -r ".continents[$i].name" "$MAP_FILE")
    echo "  $((i + 1))) $NAME"
done
read -rp "请输入选择 [1-${CONTINENT_COUNT}]: " CONTINENT_CHOICE
CONTINENT_CHOICE="${CONTINENT_CHOICE:-1}"
CONTINENT_IDX=$((CONTINENT_CHOICE - 1))
if [ "$CONTINENT_IDX" -lt 0 ] || [ "$CONTINENT_IDX" -ge "$CONTINENT_COUNT" ]; then
    echo -e "${RED}无效选择，使用默认 (1)${NC}"
    CONTINENT_IDX=0
fi
echo ""

# 3b. 选择国家
echo -e "${BOLD}请选择国家/地区:${NC}"
COUNTRY_COUNT=$(jq ".continents[$CONTINENT_IDX].countries | length" "$MAP_FILE")
for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    NAME=$(jq -r ".continents[$CONTINENT_IDX].countries[$i].name" "$MAP_FILE")
    echo "  $((i + 1))) $NAME"
done
read -rp "请输入选择 [1-${COUNTRY_COUNT}]: " COUNTRY_CHOICE
COUNTRY_CHOICE="${COUNTRY_CHOICE:-1}"
COUNTRY_IDX=$((COUNTRY_CHOICE - 1))
if [ "$COUNTRY_IDX" -lt 0 ] || [ "$COUNTRY_IDX" -ge "$COUNTRY_COUNT" ]; then
    echo -e "${RED}无效选择，使用默认 (1)${NC}"
    COUNTRY_IDX=0
fi

COUNTRY_ID=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].id" "$MAP_FILE")
COUNTRY_NAME=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].name" "$MAP_FILE")
KEYWORD_FILE=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].keyword_file" "$MAP_FILE")
REGION_CODE="$COUNTRY_ID"
echo -e "  ✅ 选择: ${GREEN}${COUNTRY_NAME}${NC} (${COUNTRY_ID})"
echo ""

# 3c. 选择州/省
STATE_COUNT=$(jq ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states | length" "$MAP_FILE")
if [ "$STATE_COUNT" -gt 1 ]; then
    echo -e "${BOLD}请选择州/省:${NC}"
    for i in $(seq 0 $((STATE_COUNT - 1))); do
        SNAME=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states[$i].name" "$MAP_FILE")
        echo "  $((i + 1))) $SNAME"
    done
    read -rp "请输入选择 [1-${STATE_COUNT}]: " STATE_CHOICE
    STATE_CHOICE="${STATE_CHOICE:-1}"
    STATE_IDX=$((STATE_CHOICE - 1))
    if [ "$STATE_IDX" -lt 0 ] || [ "$STATE_IDX" -ge "$STATE_COUNT" ]; then
        STATE_IDX=0
    fi
else
    STATE_IDX=0
fi

STATE_ID=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states[$STATE_IDX].id" "$MAP_FILE")
STATE_NAME=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states[$STATE_IDX].name" "$MAP_FILE")
echo -e "  ✅ 选择: ${GREEN}${STATE_NAME}${NC} (${STATE_ID})"
echo ""

# 3d. 选择城市
CITY_COUNT=$(jq ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states[$STATE_IDX].cities | length" "$MAP_FILE")
if [ "$CITY_COUNT" -gt 1 ]; then
    echo -e "${BOLD}请选择城市:${NC}"
    for i in $(seq 0 $((CITY_COUNT - 1))); do
        CNAME=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states[$STATE_IDX].cities[$i].name" "$MAP_FILE")
        echo "  $((i + 1))) $CNAME"
    done
    read -rp "请输入选择 [1-${CITY_COUNT}]: " CITY_CHOICE
    CITY_CHOICE="${CITY_CHOICE:-1}"
    CITY_IDX=$((CITY_CHOICE - 1))
    if [ "$CITY_IDX" -lt 0 ] || [ "$CITY_IDX" -ge "$CITY_COUNT" ]; then
        CITY_IDX=0
    fi
else
    CITY_IDX=0
fi

CITY_ID=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states[$STATE_IDX].cities[$CITY_IDX].id" "$MAP_FILE")
CITY_NAME=$(jq -r ".continents[$CONTINENT_IDX].countries[$COUNTRY_IDX].states[$STATE_IDX].cities[$CITY_IDX].name" "$MAP_FILE")
echo -e "  ✅ 选择: ${GREEN}${CITY_NAME}${NC} (${CITY_ID})"
echo ""

echo -e "  ${BOLD}最终选择:${NC} ${COUNTRY_NAME} / ${STATE_NAME} / ${CITY_NAME}"
echo -e "  ${BOLD}区域代码:${NC} ${REGION_CODE}"
echo -e "  ${BOLD}关键词文件:${NC} ${KEYWORD_FILE}"
echo ""

# ----------------------------------------------------------
# [步骤 4] 下载地区关键词库 (硬依赖，失败即中止)
# ----------------------------------------------------------
echo -e "${CYAN}[4/9] 下载地区关键词库...${NC}"

KW_FILE_DEST="${SECURE_TMP}/keywords/${KEYWORD_FILE}"
mkdir -p "$(dirname "$KW_FILE_DEST")"

if ! download_file "${REPO_RAW_URL}/data/keywords/${KEYWORD_FILE}?t=$(date +%s)" "$KW_FILE_DEST" "关键词库 ${KEYWORD_FILE}"; then
    echo -e ""
    echo -e "${RED}========================================================${NC}"
    echo -e "${RED}当前地区缺少关键词库 data/keywords/${KEYWORD_FILE}，暂不支持 Google Lite。${NC}"
    echo -e "${RED}请先补充该关键词文件后再安装。${NC}"
    echo -e "${RED}========================================================${NC}"
    exit 1
fi

KW_LINE_COUNT=$(wc -l < "$KW_FILE_DEST")
echo -e "  📊 关键词数量: ${KW_LINE_COUNT} 条"

if [ "$KW_LINE_COUNT" -eq 0 ]; then
    echo -e ""
    echo -e "${RED}========================================================${NC}"
    echo -e "${RED}关键词文件 ${KEYWORD_FILE} 为空，暂不支持 Google Lite。${NC}"
    echo -e "${RED}========================================================${NC}"
    exit 1
fi

# ----------------------------------------------------------
# [步骤 5] 下载选中地区 JSON
# ----------------------------------------------------------
echo -e "${CYAN}[5/9] 下载选中的区域规则...${NC}"

REGION_DIR="data/regions/${COUNTRY_ID}/${STATE_ID}"
REGION_JSON_PATH="${REGION_DIR}/${CITY_ID}.json"
REGION_JSON_FILE="${INSTALL_DIR}/${REGION_JSON_PATH}"
REGION_JSON_URL="${REPO_RAW_URL}/${REGION_JSON_PATH}"

mkdir -p "$(dirname "$REGION_JSON_FILE")"

if ! download_file "${REGION_JSON_URL}?t=$(date +%s)" "$REGION_JSON_FILE" "区域规则 ${CITY_ID}.json"; then
    echo -e "${RED}  区域规则下载失败: ${REGION_JSON_URL}${NC}"
    exit 1
fi

REGION_NAME=$(jq -r '.region_name // "未知"' "$REGION_JSON_FILE")
BASE_LAT=$(jq -r '.google_module.base_lat // ""' "$REGION_JSON_FILE")
BASE_LON=$(jq -r '.google_module.base_lon // ""' "$REGION_JSON_FILE")
LANG_PARAMS=$(jq -r '.google_module.lang_params // ""' "$REGION_JSON_FILE")
VALID_URL_SUFFIX=$(jq -r '.google_module.valid_url_suffix // ""' "$REGION_JSON_FILE")

echo -e "  📍 ${REGION_NAME}"
echo -e "  🗺️  坐标: ${BASE_LAT}, ${BASE_LON}"
echo -e "  🌐 语言参数: ${LANG_PARAMS}"
echo ""

# ----------------------------------------------------------
# [步骤 6] 下载 user_agents.txt
# ----------------------------------------------------------
echo -e "${CYAN}[6/9] 下载 User-Agent 池...${NC}"

UA_FILE_DEST="${SECURE_TMP}/user_agents.txt"
if ! download_file "${REPO_RAW_URL}/data/user_agents.txt?t=$(date +%s)" "$UA_FILE_DEST" "User-Agent 池"; then
    echo -e "${RED}  user_agents.txt 下载失败，这是必需文件。${NC}"
    exit 1
fi

UA_LINE_COUNT=$(wc -l < "$UA_FILE_DEST")
if [ "$UA_LINE_COUNT" -eq 0 ]; then
    echo -e "${RED}  user_agents.txt 为空文件，安装中止。${NC}"
    exit 1
fi
echo -e "  📊 UA 数量: ${UA_LINE_COUNT} 条"
echo ""

# ----------------------------------------------------------
# [步骤 7] Telegram 配置
# ----------------------------------------------------------
echo -e "${CYAN}[7/9] 配置 Telegram 日报...${NC}"

# 如果 config.conf 已存在，尝试读取现有配置作为默认值
EXISTING_TG_TOKEN=""
EXISTING_CHAT_ID=""
if [ -f "$CONFIG_FILE" ]; then
    EXISTING_TG_TOKEN=$(grep "^TG_TOKEN=" "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
    EXISTING_CHAT_ID=$(grep "^CHAT_ID=" "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
fi

read -rp "请输入 Telegram Bot Token${EXISTING_TG_TOKEN:+" (回车保持现有)"}: " TG_TOKEN_INPUT
TG_TOKEN="${TG_TOKEN_INPUT:-$EXISTING_TG_TOKEN}"

if [ -z "$TG_TOKEN" ]; then
    echo -e "${RED}❌ Telegram Bot Token 不能为空。${NC}"
    exit 1
fi

read -rp "请输入 Telegram Chat ID${EXISTING_CHAT_ID:+" (回车保持现有)"}: " CHAT_ID_INPUT
CHAT_ID="${CHAT_ID_INPUT:-$EXISTING_CHAT_ID}"

if [ -z "$CHAT_ID" ]; then
    echo -e "${RED}❌ Chat ID 不能为空。${NC}"
    exit 1
fi

# 验证 Telegram Bot Token
echo -n "  🕵️  正在验证 Telegram Bot Token..."
TG_VALID_URL="https://api.telegram.org/bot${TG_TOKEN}/getMe"
TG_TEST=$(curl -s -m 5 "$TG_VALID_URL" 2>/dev/null)
if echo "$TG_TEST" | grep -q '"ok":true'; then
    BOT_NAME=$(echo "$TG_TEST" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
    echo -e " ${GREEN}✅ (${BOT_NAME})${NC}"
else
    echo -e ""
    echo -e "${YELLOW}⚠️  Token 验证失败 (可能为网络问题或 Token 无效)。${NC}"
    echo -e "${YELLOW}   将继续安装，但请确认 Token 正确。${NC}"
fi

TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
echo ""

# ----------------------------------------------------------
# [步骤 8] 部署核心脚本和数据
# ----------------------------------------------------------
echo -e "${CYAN}[8/9] 部署核心引擎...${NC}"

# 创建目录结构
mkdir -p "${INSTALL_DIR}/core"
mkdir -p "${INSTALL_DIR}/data/keywords"
mkdir -p "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}"
mkdir -p "${INSTALL_DIR}/logs"

# 下载 5 个核心脚本
CORE_FILES=(
    "runner.sh"
    "mod_google.sh"
    "tg_report.sh"
    "uninstall.sh"
    "updater.sh"
)

echo -e "  ${BOLD}下载核心脚本 (5个):${NC}"
for script in "${CORE_FILES[@]}"; do
    echo -n "    • ${script}..."
    TMP_FILE="${SECURE_TMP}/${script}"
    if download_file "${REPO_RAW_URL}/core/${script}?t=$(date +%s)" "$TMP_FILE" "$script"; then
        cp "$TMP_FILE" "${INSTALL_DIR}/core/${script}"
        chmod +x "${INSTALL_DIR}/core/${script}"
        echo -e " ${GREEN}✅${NC}"
    else
        echo -e " ${RED}❌${NC}"
        echo -e "${RED}核心脚本 ${script} 下载失败，安装中止。${NC}"
        exit 1
    fi
done

# 复制关键词文件和 UA 文件到目标目录
cp "$KW_FILE_DEST" "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
cp "$UA_FILE_DEST" "${INSTALL_DIR}/data/user_agents.txt"
chmod 644 "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}"
chmod 644 "${INSTALL_DIR}/data/user_agents.txt"

echo ""

# ----------------------------------------------------------
# [步骤: 网络探测]
# ----------------------------------------------------------
echo -e "${CYAN}  探测网络出口...${NC}"

RAW_DETECT_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me) 2>/dev/null | tr -d '[:space:]' || true)
RAW_DETECT_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ifconfig.me) 2>/dev/null | tr -d '[:space:]' || true)

# 过滤 Warp/虚拟网卡
DETECT_V4=""
if [[ -n "$RAW_DETECT_V4" ]]; then
    V4_DEV=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || true)
    if [[ "$V4_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_DETECT_V4" =~ ^104\.28\. ]]; then
        echo -e "    ⚠️ 忽略虚拟网卡出口: $RAW_DETECT_V4"
    else
        DETECT_V4="$RAW_DETECT_V4"
    fi
fi

DETECT_V6=""
if [[ -n "$RAW_DETECT_V6" ]]; then
    V6_DEV=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1 || true)
    if [[ "$V6_DEV" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$RAW_DETECT_V6" =~ ^fe80:|^::1 ]]; then
        echo -e "    ⚠️ 忽略虚拟网卡出口: $RAW_DETECT_V6"
    else
        DETECT_V6="$RAW_DETECT_V6"
    fi
fi

# 选择出口 IP
if [ -n "$DETECT_V4" ]; then
    PUBLIC_IP="$DETECT_V4"
    IP_PREF="4"
    echo -e "  ✅ 检测到 IPv4: ${GREEN}${PUBLIC_IP}${NC}"
elif [ -n "$DETECT_V6" ]; then
    PUBLIC_IP="$DETECT_V6"
    IP_PREF="6"
    echo -e "  ✅ 检测到 IPv6: ${GREEN}${PUBLIC_IP}${NC}"
else
    echo -e "  ${YELLOW}⚠️ 未检测到公网 IP，将在后续手动输入。${NC}"
    read -rp "  请输入本机公网 IP: " PUBLIC_IP
    IP_PREF="4"
    if [[ "$PUBLIC_IP" == *":"* ]]; then
        IP_PREF="6"
    fi
fi

if [[ "$PUBLIC_IP" == *":"* ]] && [[ "$PUBLIC_IP" != *"["* ]]; then
    SAFE_PUBLIC_IP="[${PUBLIC_IP}]"
else
    SAFE_PUBLIC_IP="$PUBLIC_IP"
fi

# 构建容灾通讯地址
COMM_IP="$SAFE_PUBLIC_IP"
if [[ -n "$DETECT_V4" ]] && [[ "$DETECT_V4" != "$PUBLIC_IP" ]]; then
    COMM_IP="${COMM_IP}_${DETECT_V4}"
fi
if [[ -n "$DETECT_V6" ]] && [[ "$DETECT_V6" != "$PUBLIC_IP" ]]; then
    [[ "$DETECT_V6" != *"["* ]] && SAFE_V6="[${DETECT_V6}]" || SAFE_V6="$DETECT_V6"
    COMM_IP="${COMM_IP}_${SAFE_V6}"
fi
SAFE_COMM_IP="$COMM_IP"

# 探测网卡绑定
BIND_IP=""
RAW_PUBLIC_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
if [[ "$RAW_PUBLIC_IP" == *":"* ]]; then
    TEST_TARGET="https://[2606:4700:4700::1111]"
else
    TEST_TARGET="https://1.1.1.1"
fi
if curl --interface "$RAW_PUBLIC_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
    BIND_IP="$SAFE_PUBLIC_IP"
    echo -e "  ✅ 原生直连，网卡锁定已激活"
else
    echo -e "  ⚠️ NAT 环境已自动卸除网卡枷锁"
    BIND_IP=""
fi

# ----------------------------------------------------------
# [写入 config.conf]
# ----------------------------------------------------------
echo -e "${CYAN}  生成配置文件...${NC}"

NODE_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z' 2>/dev/null || echo "0000")
NODE_NAME="lite-$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-6)-${NODE_HASH}"

cat > "$CONFIG_FILE" << EOF
# IP-Sentinel Lite 配置 (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
AGENT_VERSION="$TARGET_VERSION"

# 区域配置
COUNTRY_ID="${COUNTRY_ID}"
STATE_ID="${STATE_ID}"
CITY_ID="${CITY_ID}"
CITY_NAME="${CITY_NAME}"
REGION_CODE="${REGION_CODE}"
REGION_NAME="${REGION_NAME}"
KEYWORD_FILE="${KEYWORD_FILE}"
REGION_JSON_FILE="${REGION_JSON_FILE}"

# 地理坐标与语言参数
BASE_LAT="${BASE_LAT}"
BASE_LON="${BASE_LON}"
LANG_PARAMS="${LANG_PARAMS}"
VALID_URL_SUFFIX="${VALID_URL_SUFFIX}"

# Google 区域纠偏
ENABLE_GOOGLE="true"

# Telegram 配置
TG_TOKEN="${TG_TOKEN}"
TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
CHAT_ID="${CHAT_ID}"

# 网络配置
IP_PREF="${IP_PREF}"
PUBLIC_IP="${PUBLIC_IP}"
SAFE_PUBLIC_IP="${SAFE_PUBLIC_IP}"
SAFE_COMM_IP="${SAFE_COMM_IP}"
BIND_IP="${BIND_IP}"

# 节点标识
NODE_NAME="${NODE_NAME}"
NODE_ALIAS="${NODE_NAME}"

# 目录
INSTALL_DIR="${INSTALL_DIR}"
CONFIG_FILE="${CONFIG_FILE}"
LOG_FILE="${LOG_FILE}"
EOF

chmod 600 "$CONFIG_FILE"
echo -e "  ${GREEN}✅ 配置文件已生成: ${CONFIG_FILE}${NC}"
echo ""

# ----------------------------------------------------------
# [步骤 9] 注入 systemd 服务
# ----------------------------------------------------------
echo -e "${CYAN}[9/9] 注入 systemd 守护服务...${NC}"

# 停止并清理旧服务
systemctl stop ip-sentinel-runner.timer 2>/dev/null || true
systemctl stop ip-sentinel-report.timer 2>/dev/null || true
systemctl stop ip-sentinel-data.timer 2>/dev/null || true
systemctl stop ip-sentinel-keywords.timer 2>/dev/null || true
systemctl disable ip-sentinel-runner.timer 2>/dev/null || true
systemctl disable ip-sentinel-report.timer 2>/dev/null || true
systemctl disable ip-sentinel-data.timer 2>/dev/null || true
systemctl disable ip-sentinel-keywords.timer 2>/dev/null || true
rm -f /etc/systemd/system/ip-sentinel-runner.service
rm -f /etc/systemd/system/ip-sentinel-runner.timer
rm -f /etc/systemd/system/ip-sentinel-report.service
rm -f /etc/systemd/system/ip-sentinel-report.timer
rm -f /etc/systemd/system/ip-sentinel-data.service
rm -f /etc/systemd/system/ip-sentinel-data.timer
rm -f /etc/systemd/system/ip-sentinel-keywords.service
rm -f /etc/systemd/system/ip-sentinel-keywords.timer
rm -f /etc/systemd/system/ip-sentinel-updater.service
rm -f /etc/systemd/system/ip-sentinel-updater.timer
rm -f /etc/systemd/system/ip-sentinel-agent-daemon.service

# 创建 runner.service
cat > /etc/systemd/system/ip-sentinel-runner.service << EOF
[Unit]
Description=IP-Sentinel Runner Service (Lite)
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/runner.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
TimeoutStartSec=1800
KillMode=control-group
EOF

# 创建 runner.timer (每 1 小时一次)
cat > /etc/systemd/system/ip-sentinel-runner.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Runner (Lite)
[Timer]
OnCalendar=hourly
AccuracySec=1min
RandomizedDelaySec=1200
Persistent=true
Unit=ip-sentinel-runner.service
[Install]
WantedBy=timers.target
EOF

# 创建 report.service
cat > /etc/systemd/system/ip-sentinel-report.service << EOF
[Unit]
Description=IP-Sentinel Telegram Report Service (Lite)
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/tg_report.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
TimeoutStartSec=600
KillMode=control-group
EOF

# 创建 report.timer (每天 16:00 UTC)
cat > /etc/systemd/system/ip-sentinel-report.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Telegram Report (Lite)
[Timer]
OnCalendar=*-*-* 16:00:00 UTC
Unit=ip-sentinel-report.service
[Install]
WantedBy=timers.target
EOF

# 创建 data.service
cat > /etc/systemd/system/ip-sentinel-data.service << EOF
[Unit]
Description=IP-Sentinel Lite Data Refresh
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/updater.sh
User=root
TimeoutStartSec=300
KillMode=control-group
EOF

# 创建 data.timer (每天 03:30 UTC)
cat > /etc/systemd/system/ip-sentinel-data.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Lite Data Refresh
[Timer]
OnCalendar=*-*-* 03:30:00 UTC
RandomizedDelaySec=1800
Persistent=true
Unit=ip-sentinel-data.service
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ip-sentinel-runner.timer
systemctl enable --now ip-sentinel-report.timer
systemctl enable --now ip-sentinel-data.timer

echo -e "  ${GREEN}✅ runner.timer 已启动 (每 1 小时)${NC}"
echo -e "  ${GREEN}✅ report.timer 已启动 (每天 16:00 UTC)${NC}"
echo -e "  ${GREEN}✅ data.timer 已启动 (每天 03:30 UTC)${NC}"
echo ""

# ----------------------------------------------------------
# [安装完成]
# ----------------------------------------------------------
echo "========================================================"
echo -e " ${GREEN}${BOLD}✅ Google Lite Standalone 安装完成！${NC}"
echo "========================================================"
echo ""
echo -e " ${BOLD}验证命令:${NC}"
echo ""
echo -e " 1) 检查核心文件:"
echo -e "    ${CYAN}find /opt/ip_sentinel/core -maxdepth 1 -type f -printf '%f\\n' | sort${NC}"
echo ""
echo -e " 2) 检查 Timer 状态:"
echo -e "    ${CYAN}systemctl list-timers --all | grep ip-sentinel${NC}"
echo ""
echo -e " 3) 查看配置文件:"
echo -e "    ${CYAN}grep -E 'REGION_NAME|REGION_CODE|ENABLE_GOOGLE' /opt/ip_sentinel/config.conf${NC}"
echo ""
echo -e " 4) 立即触发一次巡检:"
echo -e "    ${CYAN}systemctl start ip-sentinel-runner.service${NC}"
echo ""
echo -e " 5) 手动触发数据刷新 (关键词 + UA):"
echo -e "    ${CYAN}systemctl start ip-sentinel-data.service${NC}"
echo -e "    ${CYAN}journalctl -u ip-sentinel-data.service -n 30 --no-pager${NC}"
echo ""
echo -e " 6) 查看运行日志:"
echo -e "    ${CYAN}tail -f /opt/ip_sentinel/logs/sentinel.log${NC}"
echo ""
echo -e " ${YELLOW}📌 说明:${NC}"
echo -e " • VPS 每日 03:30 UTC 自动刷新用户代理 (30天一次) 和关键词 (每日)"
echo -e " • Lite updater 不更新程序、region json、ip_probe、Trust、Quality"
echo -e " • 刷新失败保留旧文件，不 fallback 到其他国家关键词"
echo -e " • 如需更新区域 JSON，重新运行本脚本选择安装/更新"
echo -e " • 本模式不包含旧版 OTA / Trust / Webhook / Master"
echo ""
echo "========================================================"
