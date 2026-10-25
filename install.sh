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

# BEGIN TELEGRAM_SETUP
# Telegram 请求只保留错误摘要；原始更新和 Token 不输出到终端。
tg_read() {
    printf '%s' "$1" >&2
    if [[ "${3:-}" == hidden ]]; then
        if IFS= read -rs "$2"; then
            printf '\n' >&2
            return 0
        fi
    elif IFS= read -r "$2"; then
        return 0
    fi
    printf '\n输入结束，安装已取消，原配置未变。\n' >&2
    return 1
}

tg_valid_token() {
    [[ "$1" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]
}

tg_valid_chat_id() {
    # 不对 ID 做整数运算；同时兼容原配置中的公开频道 @username。
    [[ "$1" =~ ^-?[0-9]+$ || "$1" =~ ^@[A-Za-z][A-Za-z0-9_]*$ ]]
}

tg_api_request() {
    local method="$1" payload="${2:-}" deadline="${3:-$((SECONDS + 30))}"
    payload=${payload:-'{}'}
    local attempt http_status remaining request_time pause error_code
    local response_file="${SECURE_TMP}/telegram-response.json"
    TG_RESPONSE='' TG_ERROR='' TG_ERROR_KIND=temporary
    for attempt in 1 2 3; do
        remaining=$((deadline - SECONDS))
        if ((remaining <= 0)); then break; fi
        request_time=10
        if ((remaining < request_time)); then request_time=$remaining; fi
        # 不使用 -f，保留 Telegram 4xx 的 JSON 错误摘要；不输出 curl 错误中的 URL。
        if http_status=$(curl -s --connect-timeout 5 --max-time "$request_time" \
            -X POST -H 'Content-Type: application/json' -d "$payload" \
            -o "$response_file" -w '%{http_code}' \
            "https://api.telegram.org/bot${TG_TOKEN}/${method}" 2>/dev/null); then
            TG_RESPONSE=$(cat "$response_file")
            error_code=''
            if jq -e 'type == "object" and (.ok | type == "boolean")' \
                >/dev/null 2>&1 <<< "$TG_RESPONSE"; then
                if [[ "$http_status" == 2?? ]] && jq -e '.ok == true' \
                    >/dev/null 2>&1 <<< "$TG_RESPONSE"; then
                    TG_ERROR_KIND=''
                    return 0
                fi
                error_code=$(jq -r '.error_code // empty' <<< "$TG_RESPONSE")
                TG_ERROR=$(jq -r --arg token "$TG_TOKEN" '(.description // "Telegram 请求失败") | tostring |
                    split($token) | join("[REDACTED]") |
                    gsub("[\u0000-\u001f\u007f-\u009f]"; " ") | .[0:240]' <<< "$TG_RESPONSE")
            else
                TG_ERROR='Telegram 返回了无法解析的响应'
            fi
            case "${error_code:-$http_status}" in
                401|404) TG_ERROR_KIND=credentials; return 1 ;;
                409) TG_ERROR_KIND=conflict; return 1 ;;
                429|5??) TG_ERROR_KIND=temporary ;;
                *)
                    if [[ -n "$error_code" || "$http_status" == 4?? ]]; then
                        TG_ERROR_KIND=target
                        return 1
                    fi
                    TG_ERROR_KIND=temporary
                    ;;
            esac
        else
            TG_RESPONSE=''
            TG_ERROR='Telegram 网络请求失败或超时'
            TG_ERROR_KIND=temporary
        fi
        if ((attempt == 3)); then break; fi
        pause=2
        if [[ -n "$TG_RESPONSE" ]]; then
            pause=$(jq -r '(.parameters.retry_after // 2) |
                if type == "number" and . >= 0 then ceil else 2 end' \
                <<< "$TG_RESPONSE" 2>/dev/null) || pause=2
        fi
        remaining=$((deadline - SECONDS))
        # 不为限流无限等待，也不突破调用方的总时间预算。
        if ((pause > 30 || pause >= remaining)); then break; fi
        sleep "$pause"
    done
    TG_ERROR=${TG_ERROR:-Telegram 请求等待超时}
    return 1
}

tg_manual_chat_id() {
    local input
    printf '改为手动输入 Chat ID（支持负数群组/频道 ID，也支持 @channel）。\n'
    while :; do
        tg_read '请输入 Chat ID（q 取消安装）: ' input || return 1
        if [[ "$input" == q ]]; then return 1; fi
        if tg_valid_chat_id "$input"; then
            CHAT_ID=$input
            return 0
        fi
        printf 'Chat ID 不能为空，且必须是正负数字 ID 或 @channel 用户名。\n'
    done
}

tg_select_candidate() {
    local automatic="${1:-false}" count choice index
    count=$(jq 'length' <<< "$TG_CANDIDATES") || return 1
    if ((count == 0)); then
        tg_manual_chat_id
        return $?
    fi
    # 只渲染会话元数据；过滤名称中的终端控制字符。
    jq -r 'to_entries[] | "  \(.key + 1)) ID=\(.value.id) 类型=\(.value.type) 名称=\(.value.name)"' \
        <<< "$TG_CANDIDATES"
    if [[ "$automatic" == true && "$count" == 1 ]]; then
        CHAT_ID=$(jq -r '.[0].id' <<< "$TG_CANDIDATES")
        printf '已自动选择本轮识别到的唯一会话。\n'
        return 0
    fi
    while :; do
        tg_read "请选择会话 [1-${count}]，m 手动输入，q 取消: " choice || return 1
        case "$choice" in
            m) tg_manual_chat_id; return $? ;;
            q) return 1 ;;
        esac
        if [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && ((10#$choice <= count)); then
            index=$((10#$choice - 1))
            CHAT_ID=$(jq -r --argjson index "$index" '.[$index].id' <<< "$TG_CANDIDATES")
            return 0
        fi
        printf '请选择列表中的有效序号，不会自动猜测接收目标。\n'
    done
}

tg_nonce() {
    od -An -N12 -tx1 /dev/urandom | tr -d ' \n'
}

tg_discover_chat() {
    local nonce action round deadline offset=0 batch_count matches
    TG_CANDIDATES='[]'
    if ! tg_api_request getWebhookInfo; then
        printf '无法检查 Telegram 接收状态：%s。\n' "$TG_ERROR"
        if [[ "$TG_ERROR_KIND" == credentials ]]; then return 1; fi
        tg_manual_chat_id
        return $?
    fi
    if jq -e '(.result.url // "") != ""' >/dev/null <<< "$TG_RESPONSE"; then
        printf '机器人已启用 Webhook，无法使用 getUpdates；安装器不会删除或修改 Webhook。\n'
        tg_manual_chat_id
        return $?
    fi
    nonce=$(tg_nonce) || return 1
    printf '机器人：@%s\n链接：https://t.me/%s\n' "$BOT_USERNAME" "$BOT_USERNAME"
    printf '私聊：打开以下本轮启动链接，点击 Start：\nhttps://t.me/%s?start=%s\n' "$BOT_USERNAME" "$nonce"
    printf '也可以在私聊中发送 /start %s\n' "$nonce"
    printf '群组：先添加机器人，再发送 /start@%s %s\n' "$BOT_USERNAME" "$nonce"
    printf '频道：将机器人设为管理员并授予发帖权限，再发布 /start@%s %s\n' "$BOT_USERNAME" "$nonce"
    printf '识别码只用于本轮绑定，历史消息不会被自动选中。\n'
    printf '请使用专用机器人。自动检测会读取并确认待处理更新；共用机器人请选择 m 手动配置。\n'
    tg_read '完成后按 Enter 开始检测（每轮最多 90 秒），m 手动输入，q 取消: ' action || return 1
    case "$action" in
        m) tg_manual_chat_id; return $? ;;
        q) return 1 ;;
    esac
    for round in 1 2; do
        deadline=$((SECONDS + 90))
        while ((SECONDS < deadline)); do
            if ! tg_api_request getUpdates "{\"offset\":${offset},\"limit\":100,\"timeout\":0}" "$deadline"; then
                printf '自动检测失败：%s。\n' "$TG_ERROR"
                if [[ "$TG_ERROR_KIND" == credentials ]]; then return 1; fi
                if [[ "$TG_ERROR_KIND" == conflict ]]; then
                    printf 'Webhook 或其他轮询程序可能正在接收更新；请使用手动配置。\n'
                fi
                tg_manual_chat_id
                return $?
            fi
            if ! jq -e '.result | type == "array"' >/dev/null <<< "$TG_RESPONSE"; then
                printf '自动检测响应格式不正确。\n'
                tg_manual_chat_id
                return $?
            fi
            # 不设置 allowed_updates，保留机器人的原订阅设置。
            # 只接受携带本轮随机码的 /start，消息正文不进入候选列表。
            matches=$(jq -c --arg nonce "$nonce" --arg bot "$BOT_USERNAME" '
                [.result[] | (.message // .channel_post // empty) |
                 select(.text == ("/start " + $nonce) or .text == ("/start@" + $bot + " " + $nonce)) |
                 .chat | select(.type == "private" or .type == "group" or .type == "supergroup" or .type == "channel") |
                 {id: (.id | tostring), type,
                  name: ((.title // .username // .first_name // "未命名") | tostring |
                         gsub("[\u0000-\u001f\u007f-\u009f]"; " ") | .[0:120])}]' <<< "$TG_RESPONSE") || return 1
            TG_CANDIDATES=$(jq -cn --argjson old "$TG_CANDIDATES" --argjson new "$matches" \
                '$old + $new | unique_by(.id)') || return 1
            batch_count=$(jq '.result | length' <<< "$TG_RESPONSE")
            if ((batch_count > 0)); then
                # 算术只用于 update_id 游标，绝不用于 Chat ID。
                offset=$(jq '[.result[].update_id] | max + 1' <<< "$TG_RESPONSE")
            fi
            # 先读完满页，避免第二页的会话被遗漏。
            if ((batch_count == 100)); then continue; fi
            if [[ "$TG_CANDIDATES" != '[]' ]]; then
                tg_select_candidate true
                return $?
            fi
            if ((deadline - SECONDS > 3)); then sleep 3; else break; fi
        done
        if ((round == 1)); then
            printf '本轮未发现携带识别码的会话，请检查 Start 命令、群组权限或机器人的更新订阅设置。\n'
            tg_read '按 Enter 重试一次（最多 90 秒），m 手动输入，q 取消: ' action || return 1
            case "$action" in
                m) break ;;
                q) return 1 ;;
            esac
        fi
    done
    tg_manual_chat_id
}

tg_test_target() {
    local payload action
    while :; do
        payload=$(jq -cn --arg cid "$CHAT_ID" \
            --arg text 'IP-Sentinel 安装测试：Telegram 日报接收目标已确认。' \
            '{chat_id: $cid, text: $text}') || return 1
        if tg_api_request sendMessage "$payload"; then
            printf '✅ Telegram 安装测试消息发送成功。\n'
            TG_SETUP_VERIFIED=true
            return 0
        fi
        printf '测试消息失败：%s。\n' "$TG_ERROR"
        if [[ "$TG_ERROR_KIND" == credentials ]]; then
            printf 'Token 已失效，请重新运行安装器输入有效 Token；原配置未变。\n'
            return 1
        fi
        if [[ "$TG_ERROR_KIND" == temporary ]]; then
            printf 'Telegram 暂时不可达或服务暂不可用。选择 k 保存并继续后，日报可能发送失败。\n'
        fi
        while :; do
            tg_read 'r 重试发送，s 重新选择，a 重新检测，m 手动输入，q 取消（临时故障可选 k 保存并继续）: ' action || return 1
            case "$action" in
                r) break ;;
                s) tg_select_candidate false || return 1; break ;;
                a) tg_discover_chat || return 1; break ;;
                m) tg_manual_chat_id || return 1; break ;;
                q) return 1 ;;
                k)
                    if [[ "$TG_ERROR_KIND" == temporary ]]; then
                        printf '⚠️ 将保存尚未通过发送测试的配置；日报可能发送失败。\n'
                        TG_SETUP_VERIFIED=false
                        return 0
                    fi
                    printf '当前是明确的 API/接收目标错误，请修正后再保存。\n'
                    ;;
                *) printf '请输入有效选项。\n' ;;
            esac
        done
    done
}

configure_telegram() {
    # 即使用 bash -x 启动安装器，也不将凭据写入执行跟踪。
    set +x
    local input action invalid_attempts=0 existing_valid=false
    EXISTING_TG_TOKEN='' EXISTING_CHAT_ID=''
    TG_CANDIDATES='[]' TG_SETUP_VERIFIED=false
    if [[ -f "$CONFIG_FILE" ]]; then
        # 仅读取字段，不 source 旧配置，避免执行配置中的 shell 内容。
        EXISTING_TG_TOKEN=$(awk -F '"' '$1 == "TG_TOKEN=" {print $2; exit}' "$CONFIG_FILE")
        EXISTING_CHAT_ID=$(awk -F '"' '$1 == "CHAT_ID=" {print $2; exit}' "$CONFIG_FILE")
    fi
    if tg_valid_token "$EXISTING_TG_TOKEN" && tg_valid_chat_id "$EXISTING_CHAT_ID"; then
        existing_valid=true
    fi
    printf '创建机器人：打开 @BotFather，发送 /newbot，按提示设置名称和以 bot 结尾的用户名，再复制 Bot Token。\n'
    printf 'Token 输入默认隐藏，不会显示现有 Token。\n'
    while ((invalid_attempts < 3)); do
        tg_read "请输入 Bot Token${EXISTING_TG_TOKEN:+（回车沿用现有）}: " input hidden || return 1
        TG_TOKEN=${input:-$EXISTING_TG_TOKEN}
        if ! tg_valid_token "$TG_TOKEN"; then
            invalid_attempts=$((invalid_attempts + 1))
            printf 'Token 为空或格式无效（%s/3），请重新输入。\n' "$invalid_attempts"
            continue
        fi
        while :; do
            if tg_api_request getMe; then
                BOT_USERNAME=$(jq -r '.result | select(.is_bot == true) | .username // empty' <<< "$TG_RESPONSE") || return 1
                if [[ ! "$BOT_USERNAME" =~ ^[A-Za-z0-9_]+$ ]]; then
                    printf 'Telegram 未返回有效机器人身份，原配置未变。\n'
                    return 1
                fi
                break 2
            fi
            printf 'Token 验证未通过：%s。\n' "$TG_ERROR"
            if [[ "$TG_ERROR_KIND" == credentials ]]; then
                invalid_attempts=$((invalid_attempts + 1))
                printf 'Token 无效（%s/3），请重新输入。\n' "$invalid_attempts"
                break
            fi
            printf '尚未验证的新 Token 不会写入配置。\n'
            if [[ "$existing_valid" == true && "$TG_TOKEN" == "$EXISTING_TG_TOKEN" && "$TG_ERROR_KIND" == temporary ]]; then
                printf '可输入 k 原样保留现有 Telegram 配置并继续；日报可能发送失败。\n'
            fi
            tg_read 'r 重试验证，e 重新输入 Token，q 取消: ' action || return 1
            case "$action" in
                r) continue ;;
                e) break ;;
                k)
                    if [[ "$existing_valid" == true && "$TG_TOKEN" == "$EXISTING_TG_TOKEN" && "$TG_ERROR_KIND" == temporary ]]; then
                        CHAT_ID=$EXISTING_CHAT_ID
                        TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
                        printf '⚠️ 已保留现有 Telegram 配置；日报可能发送失败。\n'
                        return 0
                    fi
                    ;;
                q) return 1 ;;
            esac
        done
    done
    if ((invalid_attempts >= 3)); then
        printf 'Token 连续三次无效，安装已取消，原配置未变。\n'
        return 1
    fi
    TG_API_URL="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    printf '✅ Token 有效：@%s（https://t.me/%s）\n' "$BOT_USERNAME" "$BOT_USERNAME"
    CHAT_ID=''
    if [[ "$existing_valid" == true && "$TG_TOKEN" == "$EXISTING_TG_TOKEN" ]]; then
        printf '现有接收目标：%s\n' "$EXISTING_CHAT_ID"
        while :; do
            tg_read '按 Enter 保留原 Chat ID，a 重新检测，m 手动输入，q 取消: ' action || return 1
            case "$action" in
                '') CHAT_ID=$EXISTING_CHAT_ID; break ;;
                a) tg_discover_chat || return 1; break ;;
                m) tg_manual_chat_id || return 1; break ;;
                q) return 1 ;;
                *) printf '请输入有效选项。\n' ;;
            esac
        done
    else
        # Token 实际改变或没有原 Chat ID 时，绝不默认沿用旧接收目标。
        tg_discover_chat || return 1
    fi
    tg_test_target
}

save_config_atomic() {
    local temporary_config
    temporary_config=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
    if ! chmod 600 "$temporary_config" || ! cat > "$temporary_config" ||
        ! mv -f -- "$temporary_config" "$CONFIG_FILE"; then
        rm -f -- "$temporary_config"
        return 1
    fi
}
# END TELEGRAM_SETUP

# ----------------------------------------------------------
# [版本信息]
# ----------------------------------------------------------
TARGET_VERSION=$(curl -fsSL --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 2 "${REPO_RAW_URL}/version.txt?t=$(date +%s)" 2>/dev/null | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]' || true)
TARGET_VERSION=${TARGET_VERSION:-"4.3.2"}

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
echo -e "  • 自动数据刷新 (关键词 / UA / 日志瘦身)"
echo -e "  • 仅保留 2 个 systemd timer"
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

configure_telegram
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
mkdir -p "${INSTALL_DIR}/state"

# 下载 6 个核心脚本
CORE_FILES=(
    "runner.sh"
    "mod_google.sh"
    "tg_report.sh"
    "uninstall.sh"
    "updater.sh"
    "daily.sh"
)

echo -e "  ${BOLD}下载核心脚本 (6个):${NC}"
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

save_config_atomic << EOF
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
TG_API_URL="${TG_API_URL}"
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
for unit in \
    ip-sentinel-runner.timer \
    ip-sentinel-runner.service \
    ip-sentinel-report.timer \
    ip-sentinel-report.service \
    ip-sentinel-data.timer \
    ip-sentinel-data.service \
    ip-sentinel-updater.timer \
    ip-sentinel-updater.service \
    ip-sentinel-keywords.timer \
    ip-sentinel-keywords.service \
    ip-sentinel-agent-daemon.service
do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done

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
rm -rf /etc/systemd/system/ip-sentinel-data.timer.d
rm -rf /etc/systemd/system/ip-sentinel-data.service.d
rm -rf /etc/systemd/system/ip-sentinel-updater.timer.d
rm -rf /etc/systemd/system/ip-sentinel-updater.service.d
rm -f /etc/systemd/system/timers.target.wants/ip-sentinel-data.timer
rm -f /etc/systemd/system/timers.target.wants/ip-sentinel-updater.timer

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
Description=IP-Sentinel Daily Service (Lite)
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/daily.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
TimeoutStartSec=900
KillMode=control-group
EOF

# 创建 report.timer (每天 04:30 UTC)
cat > /etc/systemd/system/ip-sentinel-report.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Daily Task (Lite)
[Timer]
OnCalendar=*-*-* 04:30:00 UTC
Persistent=true
Unit=ip-sentinel-report.service
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ip-sentinel-runner.timer
systemctl enable --now ip-sentinel-report.timer
systemctl reset-failed

echo -e "  ${GREEN}✅ runner.timer 已启动 (每 1 小时)${NC}"
echo -e "  ${GREEN}✅ report.timer 已启动 (每天 04:30 UTC，数据刷新 + 日报)${NC}"
echo ""

# ----------------------------------------------------------
# [安装完成]
# ----------------------------------------------------------
echo "========================================================"
echo -e " ${GREEN}${BOLD}✅ Google Lite Standalone 安装完成！${NC}"
echo "========================================================"
if [[ "$TG_SETUP_VERIFIED" != true ]]; then
    printf '⚠️ Telegram 配置已保留/保存，但未通过本次发送测试，日报可能发送失败。\n'
fi
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
echo -e " 5) 手动触发每日任务 (数据刷新 + 日报):"
echo -e "    ${CYAN}rm -f /opt/ip_sentinel/core/.report_lock${NC}"
echo -e "    ${CYAN}systemctl start ip-sentinel-report.service${NC}"
echo -e "    ${CYAN}journalctl -u ip-sentinel-report.service -n 160 --no-pager${NC}"
echo ""
echo -e " 6) 查看运行日志:"
echo -e "    ${CYAN}tail -f /opt/ip_sentinel/logs/sentinel.log${NC}"
echo ""
echo -e " ${YELLOW}📌 说明:${NC}"
echo -e " • VPS 每日 04:30 UTC 自动刷新数据并发送 Telegram 日报"
echo -e " • Lite updater 不更新程序、region json、ip_probe、Trust、Quality"
echo -e " • 刷新失败保留旧文件，不 fallback 到其他国家关键词"
echo -e " • 如需更新区域 JSON，重新运行本脚本选择安装/更新"
echo -e " • 本模式不包含旧版 OTA / Trust / Webhook / Master"
echo ""
echo "========================================================"
