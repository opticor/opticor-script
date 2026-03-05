#!/usr/bin/env bash
#
# Fail2Ban 安装管理脚本
# 兼容: Debian 8+ / Ubuntu 16.04+
# 功能: 安装/卸载/状态查看/封禁管理/白名单/日志查看/配置管理
#
# 使用方法: bash fail2ban-manager.sh
#

set -euo pipefail

# ==================== 全局变量 ====================
readonly SCRIPT_VERSION="1.0.0"
readonly F2B_CONF="/etc/fail2ban"
readonly F2B_JAIL_LOCAL="${F2B_CONF}/jail.local"
readonly F2B_JAIL_D="${F2B_CONF}/jail.d"
readonly F2B_FILTER_D="${F2B_CONF}/filter.d"
readonly F2B_ACTION_D="${F2B_CONF}/action.d"
readonly F2B_LOG="/var/log/fail2ban.log"
readonly BACKUP_DIR="/etc/fail2ban/backup"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m' # No Color

# ==================== 工具函数 ====================

print_color() {
    local color="$1"
    shift
    echo -e "${color}$*${NC}"
}

print_info()    { print_color "$CYAN"    "[INFO] $*"; }
print_success() { print_color "$GREEN"   "[ OK ] $*"; }
print_warning() { print_color "$YELLOW"  "[WARN] $*"; }
print_error()   { print_color "$RED"     "[ERR ] $*"; }

print_header() {
    local title="$1"
    local width=60
    local pad_len=$(( (width - ${#title} - 2) / 2 ))
    local pad=$(printf '%*s' "$pad_len" '' | tr ' ' '-')
    echo ""
    print_color "$BLUE" "+$(printf '%*s' "$width" '' | tr ' ' '-')+"
    print_color "$BLUE" "|${pad} ${WHITE}${BOLD}${title}${NC}${BLUE} ${pad}|"
    print_color "$BLUE" "+$(printf '%*s' "$width" '' | tr ' ' '-')+"
    echo ""
}

print_separator() {
    print_color "$DIM" "$(printf '%60s' '' | tr ' ' '-')"
}

confirm() {
    local prompt="${1:-确认操作?}"
    local default="${2:-n}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" yn
        yn="${yn:-y}"
    else
        read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy]$ ]]
}

press_any_key() {
    echo ""
    read -rp "$(echo -e "${DIM}按回车键继续...${NC}")" _
}

detect_current_ssh_ips() {
    local ips=""

    # 优先从 who 输出提取，兼容 "(ip)" 和 "ip" 两种格式
    ips=$(who 2>/dev/null | awk '{print $NF}' | tr -d '()' | \
        awk '{host=$0; sub(/:[0-9]+$/, "", host); print host}' | \
        grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$|^[0-9A-Fa-f:]+$' | sort -u || true)

    if [[ -z "$ips" ]]; then
        # 备用方式：从本机 22 端口已建立连接里提取远端地址
        ips=$(ss -tn 2>/dev/null | awk 'NR>1 && $4 ~ /:22$/ {print $5}' | \
            awk '{
                host=$0
                if (host ~ /^\[/) {
                    sub(/^\[/, "", host)
                    sub(/\]:[0-9]+$/, "", host)
                } else {
                    sub(/:[0-9]+$/, "", host)
                }
                print host
            }' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$|^[0-9A-Fa-f:]+$' | sort -u || true)
    fi

    echo "$ips"
}

# ==================== 环境检查 ====================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "无法检测操作系统类型"
        exit 1
    fi
    source /etc/os-release
    case "$ID" in
        debian|ubuntu)
            print_info "检测到系统: ${ID} ${VERSION_ID}"
            ;;
        *)
            print_error "不支持的操作系统: ${ID}"
            print_info "本脚本仅支持 Debian / Ubuntu"
            exit 1
            ;;
    esac
}

is_installed() {
    dpkg -l fail2ban 2>/dev/null | grep -q "^ii"
}

is_running() {
    systemctl is-active --quiet fail2ban 2>/dev/null
}

get_f2b_version() {
    if is_installed; then
        fail2ban-client --version 2>/dev/null | head -1 | grep -oP '[\d.]+'
    else
        echo "未安装"
    fi
}

# ==================== 安装功能 ====================

install_fail2ban() {
    print_header "安装 Fail2Ban"

    if is_installed; then
        print_warning "Fail2Ban 已安装 (版本: $(get_f2b_version))"
        if ! confirm "是否重新安装?"; then
            return
        fi
    fi

    print_info "更新软件包列表..."
    apt-get update -qq

    print_info "安装 Fail2Ban 及依赖..."
    apt-get install -y -qq fail2ban whois iptables > /dev/null 2>&1

    if ! is_installed; then
        print_error "安装失败，请检查网络连接和软件源"
        return 1
    fi

    print_success "Fail2Ban 安装成功 (版本: $(get_f2b_version))"

    # 创建备份目录
    mkdir -p "$BACKUP_DIR"

    # 备份默认配置
    if [[ -f "${F2B_CONF}/jail.conf" ]] && [[ ! -f "${BACKUP_DIR}/jail.conf.orig" ]]; then
        cp "${F2B_CONF}/jail.conf" "${BACKUP_DIR}/jail.conf.orig"
        print_info "已备份默认配置到 ${BACKUP_DIR}/"
    fi

    # 生成基础 jail.local
    if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
        echo ""
        echo "  配置初始化方式:"
        echo "    1) 一键生成推荐配置 (免交互, 默认)"
        echo "    2) 自定义配置 (逐项输入)"
        echo "    0) 跳过配置生成"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-2]: ${NC}")" init_choice
        case "${init_choice:-1}" in
            1) generate_recommended_config ;;
            2) generate_default_config ;;
            0) print_warning "已跳过配置生成，请后续手动配置 ${F2B_JAIL_LOCAL}" ;;
            *) print_warning "无效选择，使用默认推荐配置"; generate_recommended_config ;;
        esac
    else
        print_warning "已存在 jail.local，跳过配置生成"
    fi

    # 启动服务
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
    sleep 2

    if is_running; then
        print_success "Fail2Ban 服务已启动并设置为开机自启"
    else
        print_error "Fail2Ban 服务启动失败，请检查配置"
        journalctl -u fail2ban --no-pager -n 20
    fi

    press_any_key
}

generate_default_config() {
    print_info "生成基础配置文件..."

    # 检测 SSH 端口
    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    ssh_port="${ssh_port:-22}"
    print_info "检测到 SSH 端口: ${ssh_port}"

    # 获取用户输入
    local ban_time max_retry find_time
    read -rp "$(echo -e "${CYAN}封禁时长(秒, 默认 3600 即1小时, -1为永久): ${NC}")" ban_time
    ban_time="${ban_time:-3600}"

    read -rp "$(echo -e "${CYAN}最大重试次数(默认 5): ${NC}")" max_retry
    max_retry="${max_retry:-5}"

    read -rp "$(echo -e "${CYAN}检测时间窗口(秒, 默认 600 即10分钟): ${NC}")" find_time
    find_time="${find_time:-600}"

    local ignore_ip
    read -rp "$(echo -e "${CYAN}白名单IP(空格分隔, 默认仅127.0.0.1): ${NC}")" ignore_ip
    ignore_ip="${ignore_ip:-127.0.0.1/8 ::1}"

    # 选择通知方式
    local action_type="action_"
    echo ""
    echo "  封禁动作:"
    echo "    1) 仅封禁IP (默认)"
    echo "    2) 封禁IP + 记录相关信息"
    echo "    3) 封禁IP + 记录信息 + 发送邮件通知"
    read -rp "$(echo -e "${CYAN}选择 [1-3]: ${NC}")" action_choice
    case "${action_choice:-1}" in
        1) action_type="action_" ;;
        2) action_type="action_mw" ;;
        3) action_type="action_mwl"
           read -rp "$(echo -e "${CYAN}通知邮箱: ${NC}")" dest_email
           dest_email="${dest_email:-root@localhost}"
           ;;
    esac

    # 检测后端
    local backend="auto"
    if command -v systemctl &>/dev/null; then
        backend="systemd"
    fi

    # 可选启用其他服务防护，默认仅启用 SSH
    local enable_nginx="false"
    local enable_apache="false"
    local enable_postfix="false"
    local enable_dovecot="false"

    if [[ -d /etc/nginx ]] && confirm "检测到 Nginx，是否启用 Nginx 防护?"; then
        enable_nginx="true"
    fi
    if [[ -d /etc/apache2 ]] && confirm "检测到 Apache，是否启用 Apache 防护?"; then
        enable_apache="true"
    fi
    if [[ -d /etc/postfix ]] && confirm "检测到 Postfix，是否启用 Postfix 防护?"; then
        enable_postfix="true"
    fi
    if [[ -d /etc/dovecot ]] && confirm "检测到 Dovecot，是否启用 Dovecot 防护?"; then
        enable_dovecot="true"
    fi

    # 写入 jail.local
    cat > "$F2B_JAIL_LOCAL" <<JAILEOF
# ============================================================
# Fail2Ban 配置文件 - 由 fail2ban-manager.sh v${SCRIPT_VERSION} 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

[DEFAULT]

# --- 白名单 ---
ignoreip = ${ignore_ip}

# --- 封禁策略 ---
bantime  = ${ban_time}
findtime = ${find_time}
maxretry = ${max_retry}

# --- 递增封禁(fail2ban >= 0.11) ---
bantime.increment = true
bantime.factor    = 2
bantime.formula   = ban.Time * (1 << (ban.Count if ban.Count < 20 else 20)) * banFactor
bantime.maxtime   = 4w

# --- 后端 ---
backend = ${backend}

# --- 动作 ---
action = %(${action_type})s
JAILEOF

    # 如果选了邮件通知
    if [[ "$action_type" == "action_mwl" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<MAILEOF

# --- 邮件通知 ---
destemail = ${dest_email}
sender    = fail2ban@$(hostname -f 2>/dev/null || hostname)
mta       = sendmail
MAILEOF
    fi

    # SSH jail
    cat >> "$F2B_JAIL_LOCAL" <<SSHEOF

# ============================================================
# SSH 防护
# ============================================================
[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
maxretry = ${max_retry}
findtime = ${find_time}
bantime  = ${ban_time}

# 激进模式 - 更严格的 SSH 检测
[sshd-aggressive]
enabled  = false
port     = ${ssh_port}
filter   = sshd[mode=aggressive]
maxretry = 3
findtime = 300
bantime  = 86400
SSHEOF

    # Nginx jail
    if [[ "$enable_nginx" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<NGINXEOF

# ============================================================
# Nginx 防护
# ============================================================
[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 5

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 2

[nginx-badbots]
enabled  = true
port     = http,https
filter   = nginx-badbots
logpath  = /var/log/nginx/access.log
maxretry = 2

[nginx-limit-req]
enabled  = false
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/error.log
maxretry = 10
NGINXEOF
        print_info "已添加 Nginx 防护规则"
    fi

    # Apache jail
    if [[ "$enable_apache" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<APACHEEOF

# ============================================================
# Apache 防护
# ============================================================
[apache-auth]
enabled  = true
port     = http,https
filter   = apache-auth
logpath  = /var/log/apache2/*error.log
maxretry = 5

[apache-badbots]
enabled  = true
port     = http,https
filter   = apache-badbots
logpath  = /var/log/apache2/*access.log
maxretry = 2

[apache-overflows]
enabled  = true
port     = http,https
filter   = apache-overflows
logpath  = /var/log/apache2/*error.log
maxretry = 2
APACHEEOF
        print_info "已添加 Apache 防护规则"
    fi

    # Postfix jail
    if [[ "$enable_postfix" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<POSTFIXEOF

# ============================================================
# Postfix 邮件防护
# ============================================================
[postfix]
enabled  = true
port     = smtp,465,submission
filter   = postfix
maxretry = 5

[postfix-sasl]
enabled  = true
port     = smtp,465,submission,imap,imaps,pop3,pop3s
filter   = postfix[mode=auth]
maxretry = 3
POSTFIXEOF
        print_info "已添加 Postfix 防护规则"
    fi

    # Dovecot jail
    if [[ "$enable_dovecot" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<DOVECOTEOF

# ============================================================
# Dovecot 邮件防护
# ============================================================
[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission,465,sieve
filter   = dovecot
maxretry = 3
DOVECOTEOF
        print_info "已添加 Dovecot 防护规则"
    fi

    print_success "配置文件已生成: ${F2B_JAIL_LOCAL}"
}

generate_recommended_config() {
    print_info "生成推荐配置文件 (免交互)..."

    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    ssh_port="${ssh_port:-22}"
    print_info "检测到 SSH 端口: ${ssh_port}"

    local ban_time="3600"
    local max_retry="5"
    local find_time="600"
    local ignore_ip="127.0.0.1/8 ::1"
    local action_type="action_"
    local backend="auto"
    local current_ips

    if command -v systemctl &>/dev/null; then
        backend="systemd"
    fi

    current_ips=$(detect_current_ssh_ips)
    if [[ -n "$current_ips" ]]; then
        for ip in $current_ips; do
            if ! echo "$ignore_ip" | grep -qw "$ip"; then
                ignore_ip="${ignore_ip} ${ip}"
            fi
        done
        print_info "已将当前 SSH 来源 IP 加入白名单"
    fi

    # 推荐配置默认只启用 SSH，其他服务防护按需后续手动开启
    local enable_nginx="false"
    local enable_apache="false"
    local enable_postfix="false"
    local enable_dovecot="false"

    cat > "$F2B_JAIL_LOCAL" <<JAILEOF
# ============================================================
# Fail2Ban 配置文件 - 由 fail2ban-manager.sh v${SCRIPT_VERSION} 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

[DEFAULT]

# --- 白名单 ---
ignoreip = ${ignore_ip}

# --- 封禁策略 ---
bantime  = ${ban_time}
findtime = ${find_time}
maxretry = ${max_retry}

# --- 递增封禁(fail2ban >= 0.11) ---
bantime.increment = true
bantime.factor    = 2
bantime.formula   = ban.Time * (1 << (ban.Count if ban.Count < 20 else 20)) * banFactor
bantime.maxtime   = 4w

# --- 后端 ---
backend = ${backend}

# --- 动作 ---
action = %(${action_type})s
JAILEOF

    cat >> "$F2B_JAIL_LOCAL" <<SSHEOF

# ============================================================
# SSH 防护
# ============================================================
[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
maxretry = ${max_retry}
findtime = ${find_time}
bantime  = ${ban_time}

# 激进模式 - 更严格的 SSH 检测
[sshd-aggressive]
enabled  = false
port     = ${ssh_port}
filter   = sshd[mode=aggressive]
maxretry = 3
findtime = 300
bantime  = 86400
SSHEOF

    if [[ "$enable_nginx" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<NGINXEOF

# ============================================================
# Nginx 防护
# ============================================================
[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 5

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 2

[nginx-badbots]
enabled  = true
port     = http,https
filter   = nginx-badbots
logpath  = /var/log/nginx/access.log
maxretry = 2

[nginx-limit-req]
enabled  = false
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/error.log
maxretry = 10
NGINXEOF
        print_info "已添加 Nginx 防护规则"
    fi

    if [[ "$enable_apache" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<APACHEEOF

# ============================================================
# Apache 防护
# ============================================================
[apache-auth]
enabled  = true
port     = http,https
filter   = apache-auth
logpath  = /var/log/apache2/*error.log
maxretry = 5

[apache-badbots]
enabled  = true
port     = http,https
filter   = apache-badbots
logpath  = /var/log/apache2/*access.log
maxretry = 2

[apache-overflows]
enabled  = true
port     = http,https
filter   = apache-overflows
logpath  = /var/log/apache2/*error.log
maxretry = 2
APACHEEOF
        print_info "已添加 Apache 防护规则"
    fi

    if [[ "$enable_postfix" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<POSTFIXEOF

# ============================================================
# Postfix 邮件防护
# ============================================================
[postfix]
enabled  = true
port     = smtp,465,submission
filter   = postfix
maxretry = 5

[postfix-sasl]
enabled  = true
port     = smtp,465,submission,imap,imaps,pop3,pop3s
filter   = postfix[mode=auth]
maxretry = 3
POSTFIXEOF
        print_info "已添加 Postfix 防护规则"
    fi

    if [[ "$enable_dovecot" == "true" ]]; then
        cat >> "$F2B_JAIL_LOCAL" <<DOVECOTEOF

# ============================================================
# Dovecot 邮件防护
# ============================================================
[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission,465,sieve
filter   = dovecot
maxretry = 3
DOVECOTEOF
        print_info "已添加 Dovecot 防护规则"
    fi

    print_success "推荐配置已生成: ${F2B_JAIL_LOCAL}"
}

# ==================== 卸载功能 ====================

uninstall_fail2ban() {
    print_header "卸载 Fail2Ban"

    if ! is_installed; then
        print_warning "Fail2Ban 未安装"
        press_any_key
        return
    fi

    print_warning "即将卸载 Fail2Ban"
    echo ""
    echo "  1) 仅卸载程序 (保留配置文件)"
    echo "  2) 完全卸载 (删除配置文件)"
    echo "  0) 取消"
    echo ""
    read -rp "$(echo -e "${CYAN}选择 [0-2]: ${NC}")" uninstall_choice

    case "${uninstall_choice}" in
        1)
            if confirm "确认卸载 Fail2Ban (保留配置)?"; then
                systemctl stop fail2ban 2>/dev/null || true
                systemctl disable fail2ban 2>/dev/null || true
                apt-get remove -y fail2ban > /dev/null 2>&1
                print_success "Fail2Ban 已卸载 (配置文件保留在 ${F2B_CONF}/)"
            fi
            ;;
        2)
            if confirm "确认完全卸载 Fail2Ban (包括所有配置)?"; then
                # 先解封所有 IP
                if is_running; then
                    print_info "解封所有已封禁的 IP..."
                    fail2ban-client unban --all 2>/dev/null || true
                fi
                systemctl stop fail2ban 2>/dev/null || true
                systemctl disable fail2ban 2>/dev/null || true
                apt-get purge -y fail2ban > /dev/null 2>&1
                apt-get autoremove -y > /dev/null 2>&1
                rm -rf "$F2B_CONF"
                print_success "Fail2Ban 已完全卸载"
            fi
            ;;
        *)
            print_info "已取消"
            ;;
    esac

    press_any_key
}

# ==================== 服务管理 ====================

service_management() {
    while true; do
        print_header "服务管理"

        local status_text status_color
        if is_running; then
            status_text="[RUNNING]"
            status_color="$GREEN"
        else
            status_text="[STOPPED]"
            status_color="$RED"
        fi

        local enabled_text
        if systemctl is-enabled fail2ban &>/dev/null; then
            enabled_text="是"
        else
            enabled_text="否"
        fi

        echo -e "  当前状态: ${status_color}${status_text}${NC}"
        echo -e "  开机自启: ${CYAN}${enabled_text}${NC}"
        echo -e "  软件版本: ${CYAN}$(get_f2b_version)${NC}"
        echo ""
        print_separator
        echo ""
        echo "  1) 启动服务"
        echo "  2) 停止服务"
        echo "  3) 重启服务"
        echo "  4) 重载配置 (不中断服务)"
        echo "  5) 开启开机自启"
        echo "  6) 关闭开机自启"
        echo "  7) 查看服务详细状态"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-7]: ${NC}")" svc_choice

        case "$svc_choice" in
            1)
                systemctl start fail2ban && print_success "服务已启动" || print_error "启动失败"
                press_any_key
                ;;
            2)
                systemctl stop fail2ban && print_success "服务已停止" || print_error "停止失败"
                press_any_key
                ;;
            3)
                systemctl restart fail2ban && print_success "服务已重启" || print_error "重启失败"
                press_any_key
                ;;
            4)
                fail2ban-client reload && print_success "配置已重载" || print_error "重载失败"
                press_any_key
                ;;
            5)
                systemctl enable fail2ban && print_success "已开启开机自启" || print_error "操作失败"
                press_any_key
                ;;
            6)
                systemctl disable fail2ban && print_success "已关闭开机自启" || print_error "操作失败"
                press_any_key
                ;;
            7)
                echo ""
                systemctl status fail2ban --no-pager -l
                press_any_key
                ;;
            0) return ;;
            *) print_error "无效选择" ;;
        esac
    done
}

# ==================== 状态查看 ====================

show_status() {
    print_header "Fail2Ban 运行状态"

    if ! is_running; then
        print_error "Fail2Ban 未运行"
        press_any_key
        return
    fi

    # 总体状态
    echo -e "  ${BOLD}${WHITE}> 总体状态${NC}"
    echo ""
    fail2ban-client status 2>/dev/null | sed 's/^/    /'
    echo ""

    # 获取所有 jail
    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')

    if [[ -z "$jails" ]]; then
        print_warning "没有活动的 Jail"
        press_any_key
        return
    fi

    print_separator
    echo ""
    echo -e "  ${BOLD}${WHITE}> 各 Jail 详细状态${NC}"
    echo ""

    printf "  ${BOLD}%-22s %-12s %-12s %-12s${NC}\n" "JAIL" "当前封禁" "总封禁数" "总失败数"
    print_separator

    while IFS= read -r jail; do
        [[ -z "$jail" ]] && continue
        local jail_status
        jail_status=$(fail2ban-client status "$jail" 2>/dev/null)
        local currently_banned total_banned total_failed
        currently_banned=$(echo "$jail_status" | grep "Currently banned:" | awk '{print $NF}')
        total_banned=$(echo "$jail_status" | grep "Total banned:" | awk '{print $NF}')
        total_failed=$(echo "$jail_status" | grep "Total failed:" | awk '{print $NF}')

        local color="$NC"
        [[ "${currently_banned:-0}" -gt 0 ]] && color="$RED"

        printf "  ${color}%-22s %-12s %-12s %-12s${NC}\n" \
            "$jail" "${currently_banned:-0}" "${total_banned:-0}" "${total_failed:-0}"
    done <<< "$jails"

    echo ""

    # 显示当前被封禁的 IP
    echo -e "  ${BOLD}${WHITE}> 当前封禁 IP 列表${NC}"
    echo ""

    local has_banned=false
    while IFS= read -r jail; do
        [[ -z "$jail" ]] && continue
        local banned_ips
        banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/.*Banned IP list:\s*//')
        if [[ -n "$banned_ips" ]]; then
            has_banned=true
            echo -e "  ${YELLOW}[${jail}]${NC}"
            for ip in $banned_ips; do
                echo -e "    ${RED}[BANNED] ${ip}${NC}"
            done
        fi
    done <<< "$jails"

    if [[ "$has_banned" == "false" ]]; then
        print_success "当前没有被封禁的 IP"
    fi

    press_any_key
}

# ==================== 封禁管理 ====================

ban_management() {
    while true; do
        print_header "封禁管理"

        if ! is_running; then
            print_error "Fail2Ban 未运行，请先启动服务"
            press_any_key
            return
        fi

        echo "  1) 手动封禁 IP"
        echo "  2) 手动解封 IP"
        echo "  3) 解封所有 IP"
        echo "  4) 查看封禁列表"
        echo "  5) 检查 IP 是否被封禁"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-5]: ${NC}")" ban_choice

        case "$ban_choice" in
            1) manual_ban ;;
            2) manual_unban ;;
            3) unban_all ;;
            4) list_banned ;;
            5) check_ip_banned ;;
            0) return ;;
            *) print_error "无效选择" ;;
        esac
    done
}

manual_ban() {
    echo ""
    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')

    echo "  可用的 Jail:"
    local i=1
    local jail_arr=()
    while IFS= read -r jail; do
        [[ -z "$jail" ]] && continue
        echo "    ${i}) ${jail}"
        jail_arr+=("$jail")
        ((i++))
    done <<< "$jails"

    echo ""
    read -rp "$(echo -e "${CYAN}选择 Jail 编号: ${NC}")" jail_num
    if [[ -z "$jail_num" ]] || [[ "$jail_num" -lt 1 ]] || [[ "$jail_num" -gt "${#jail_arr[@]}" ]]; then
        print_error "无效选择"
        press_any_key
        return
    fi
    local selected_jail="${jail_arr[$((jail_num-1))]}"

    read -rp "$(echo -e "${CYAN}输入要封禁的 IP 地址: ${NC}")" ban_ip
    if [[ -z "$ban_ip" ]]; then
        print_error "IP 不能为空"
        press_any_key
        return
    fi

    # 简单的 IP 格式校验
    if ! [[ "$ban_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! [[ "$ban_ip" =~ : ]]; then
        print_error "IP 地址格式无效"
        press_any_key
        return
    fi

    if fail2ban-client set "$selected_jail" banip "$ban_ip" 2>/dev/null; then
        print_success "已在 [${selected_jail}] 中封禁 IP: ${ban_ip}"
    else
        print_error "封禁失败"
    fi
    press_any_key
}

manual_unban() {
    echo ""
    read -rp "$(echo -e "${CYAN}输入要解封的 IP 地址: ${NC}")" unban_ip
    if [[ -z "$unban_ip" ]]; then
        print_error "IP 不能为空"
        press_any_key
        return
    fi

    echo ""
    echo "  1) 从所有 Jail 解封"
    echo "  2) 从指定 Jail 解封"
    read -rp "$(echo -e "${CYAN}选择 [1-2]: ${NC}")" unban_scope

    case "$unban_scope" in
        1)
            if fail2ban-client unban "$unban_ip" 2>/dev/null; then
                print_success "已从所有 Jail 解封 IP: ${unban_ip}"
            else
                print_warning "该 IP 可能未被封禁或解封失败"
            fi
            ;;
        2)
            local jails
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')
            echo "  可用的 Jail:"
            local i=1
            local jail_arr=()
            while IFS= read -r jail; do
                [[ -z "$jail" ]] && continue
                echo "    ${i}) ${jail}"
                jail_arr+=("$jail")
                ((i++))
            done <<< "$jails"
            read -rp "$(echo -e "${CYAN}选择 Jail 编号: ${NC}")" jail_num
            if [[ -n "$jail_num" ]] && [[ "$jail_num" -ge 1 ]] && [[ "$jail_num" -le "${#jail_arr[@]}" ]]; then
                local selected_jail="${jail_arr[$((jail_num-1))]}"
                if fail2ban-client set "$selected_jail" unbanip "$unban_ip" 2>/dev/null; then
                    print_success "已从 [${selected_jail}] 解封 IP: ${unban_ip}"
                else
                    print_warning "解封失败，该 IP 可能不在此 Jail 中"
                fi
            else
                print_error "无效选择"
            fi
            ;;
        *)
            print_error "无效选择"
            ;;
    esac
    press_any_key
}

unban_all() {
    echo ""
    if confirm "确认解封所有被封禁的 IP?"; then
        if fail2ban-client unban --all 2>/dev/null; then
            print_success "已解封所有 IP"
        else
            print_error "操作失败"
        fi
    fi
    press_any_key
}

list_banned() {
    echo ""
    echo -e "  ${BOLD}${WHITE}> 当前封禁 IP 列表${NC}"
    echo ""

    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')
    local has_banned=false

    while IFS= read -r jail; do
        [[ -z "$jail" ]] && continue
        local jail_status
        jail_status=$(fail2ban-client status "$jail" 2>/dev/null)
        local banned_ips
        banned_ips=$(echo "$jail_status" | grep "Banned IP list:" | sed 's/.*Banned IP list:\s*//')
        local count
        count=$(echo "$jail_status" | grep "Currently banned:" | awk '{print $NF}')

        if [[ "${count:-0}" -gt 0 ]]; then
            has_banned=true
            echo -e "  ${YELLOW}[${jail}]${NC} (${count} 个)"
            for ip in $banned_ips; do
                # 尝试获取 IP 归属地
                local geo=""
                if command -v whois &>/dev/null; then
                    geo=$(whois "$ip" 2>/dev/null | grep -iE "^(country|Country):" | head -1 | awk '{print $NF}' 2>/dev/null)
                fi
                echo -e "    ${RED}[BANNED] ${ip}${NC} ${DIM}${geo}${NC}"
            done
            echo ""
        fi
    done <<< "$jails"

    if [[ "$has_banned" == "false" ]]; then
        print_success "当前没有被封禁的 IP"
    fi
    press_any_key
}

check_ip_banned() {
    echo ""
    read -rp "$(echo -e "${CYAN}输入要检查的 IP 地址: ${NC}")" check_ip
    if [[ -z "$check_ip" ]]; then
        print_error "IP 不能为空"
        press_any_key
        return
    fi

    echo ""
    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')
    local found=false

    while IFS= read -r jail; do
        [[ -z "$jail" ]] && continue
        local banned_ips
        banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/.*Banned IP list:\s*//')
        if echo "$banned_ips" | grep -qw "$check_ip"; then
            found=true
            print_warning "IP ${check_ip} 在 [${jail}] 中被封禁"
        fi
    done <<< "$jails"

    if [[ "$found" == "false" ]]; then
        print_success "IP ${check_ip} 未被封禁"
    fi

    # 同时检查 iptables
    echo ""
    echo -e "  ${BOLD}iptables 中的相关规则:${NC}"
    local ipt_result
    ipt_result=$(iptables -L -n 2>/dev/null | grep "$check_ip" || true)
    if [[ -n "$ipt_result" ]]; then
        echo "$ipt_result" | sed 's/^/    /'
    else
        echo "    (无相关 iptables 规则)"
    fi

    press_any_key
}

# ==================== 白名单管理 ====================

whitelist_management() {
    while true; do
        print_header "白名单管理"

        if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
            print_error "未找到 ${F2B_JAIL_LOCAL}，请先安装并生成配置"
            press_any_key
            return
        fi

        # 显示当前白名单
        echo -e "  ${BOLD}${WHITE}> 当前白名单${NC}"
        echo ""
        local current_whitelist
        current_whitelist=$(grep -E "^ignoreip\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/^ignoreip\s*=\s*//')
        if [[ -n "$current_whitelist" ]]; then
            for ip in $current_whitelist; do
                echo -e "    ${GREEN}[OK] ${ip}${NC}"
            done
        else
            echo "    (白名单为空)"
        fi

        echo ""
        print_separator
        echo ""
        echo "  1) 添加 IP 到白名单"
        echo "  2) 从白名单移除 IP"
        echo "  3) 添加当前连接 IP 到白名单"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-3]: ${NC}")" wl_choice

        case "$wl_choice" in
            1) whitelist_add ;;
            2) whitelist_remove ;;
            3) whitelist_add_current ;;
            0) return ;;
            *) print_error "无效选择" ;;
        esac
    done
}

whitelist_add() {
    echo ""
    read -rp "$(echo -e "${CYAN}输入要加入白名单的 IP 或 CIDR (如 192.168.1.0/24): ${NC}")" new_ip
    if [[ -z "$new_ip" ]]; then
        print_error "IP 不能为空"
        press_any_key
        return
    fi

    local current_whitelist
    current_whitelist=$(grep -E "^ignoreip\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/^ignoreip\s*=\s*//')

    # 检查是否已存在
    if echo "$current_whitelist" | grep -qw "$new_ip"; then
        print_warning "${new_ip} 已在白名单中"
        press_any_key
        return
    fi

    # 备份配置
    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    local new_whitelist="${current_whitelist} ${new_ip}"
    sed -i "s|^ignoreip\s*=.*|ignoreip = ${new_whitelist}|" "$F2B_JAIL_LOCAL"

    print_success "已添加 ${new_ip} 到白名单"

    if is_running; then
        if confirm "是否立即重载配置使其生效?"; then
            fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
            # 如果该 IP 当前被封禁，自动解封
            fail2ban-client unban "$new_ip" 2>/dev/null || true
        fi
    fi
    press_any_key
}

whitelist_remove() {
    echo ""
    local current_whitelist
    current_whitelist=$(grep -E "^ignoreip\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/^ignoreip\s*=\s*//')

    if [[ -z "$current_whitelist" ]]; then
        print_warning "白名单为空"
        press_any_key
        return
    fi

    echo "  当前白名单中的 IP:"
    local i=1
    local ip_arr=()
    for ip in $current_whitelist; do
        echo "    ${i}) ${ip}"
        ip_arr+=("$ip")
        ((i++))
    done

    echo ""
    read -rp "$(echo -e "${CYAN}选择要移除的编号: ${NC}")" rm_num
    if [[ -z "$rm_num" ]] || [[ "$rm_num" -lt 1 ]] || [[ "$rm_num" -gt "${#ip_arr[@]}" ]]; then
        print_error "无效选择"
        press_any_key
        return
    fi

    local rm_ip="${ip_arr[$((rm_num-1))]}"

    if [[ "$rm_ip" == "127.0.0.1/8" ]] || [[ "$rm_ip" == "::1" ]]; then
        if ! confirm "[WARN] 移除本地回环地址可能导致本机被封禁，确认?"; then
            press_any_key
            return
        fi
    fi

    # 备份配置
    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    # 转义特殊字符用于 sed
    local escaped_ip
    escaped_ip=$(echo "$rm_ip" | sed 's/[./]/\\&/g')
    local new_whitelist
    new_whitelist=$(echo "$current_whitelist" | sed "s/\b${escaped_ip}\b//g" | tr -s ' ' | sed 's/^ //;s/ $//')
    sed -i "s|^ignoreip\s*=.*|ignoreip = ${new_whitelist}|" "$F2B_JAIL_LOCAL"

    print_success "已从白名单移除 ${rm_ip}"

    if is_running && confirm "是否立即重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

whitelist_add_current() {
    echo ""
    echo -e "  ${BOLD}当前活动的 SSH 连接 IP:${NC}"
    echo ""

    local ssh_ips
    ssh_ips=$(detect_current_ssh_ips)

    if [[ -z "$ssh_ips" ]]; then
        print_warning "未检测到 SSH 连接 IP"
        press_any_key
        return
    fi

    local i=1
    local ip_arr=()
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        echo "    ${i}) ${ip}"
        ip_arr+=("$ip")
        ((i++))
    done <<< "$ssh_ips"

    echo ""
    read -rp "$(echo -e "${CYAN}选择要加入白名单的编号(0=全部): ${NC}")" sel

    local ips_to_add=()
    if [[ "$sel" == "0" ]]; then
        ips_to_add=("${ip_arr[@]}")
    elif [[ -n "$sel" ]] && [[ "$sel" -ge 1 ]] && [[ "$sel" -le "${#ip_arr[@]}" ]]; then
        ips_to_add=("${ip_arr[$((sel-1))]}")
    else
        print_error "无效选择"
        press_any_key
        return
    fi

    local current_whitelist
    current_whitelist=$(grep -E "^ignoreip\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/^ignoreip\s*=\s*//')

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    for ip in "${ips_to_add[@]}"; do
        if echo "$current_whitelist" | grep -qw "$ip"; then
            print_warning "${ip} 已在白名单中，跳过"
        else
            current_whitelist="${current_whitelist} ${ip}"
            print_success "已添加 ${ip}"
        fi
    done

    sed -i "s|^ignoreip\s*=.*|ignoreip = ${current_whitelist}|" "$F2B_JAIL_LOCAL"

    if is_running && confirm "是否立即重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

# ==================== Jail 管理 ====================

jail_management() {
    while true; do
        print_header "Jail 管理"

        if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
            print_error "未找到 ${F2B_JAIL_LOCAL}"
            press_any_key
            return
        fi

        echo "  1) 查看所有 Jail 状态"
        echo "  2) 启用/禁用 Jail"
        echo "  3) 修改 Jail 参数"
        echo "  4) 添加自定义 Jail"
        echo "  5) 查看 Jail 详细配置"
        echo "  6) 测试过滤器 (regex 测试)"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-6]: ${NC}")" jail_choice

        case "$jail_choice" in
            1) show_all_jails ;;
            2) toggle_jail ;;
            3) modify_jail ;;
            4) add_custom_jail ;;
            5) show_jail_detail ;;
            6) test_filter ;;
            0) return ;;
            *) print_error "无效选择" ;;
        esac
    done
}

show_all_jails() {
    echo ""
    echo -e "  ${BOLD}${WHITE}> 配置文件中的 Jail${NC}"
    echo ""

    printf "  ${BOLD}%-24s %-10s %-10s %-10s %-10s${NC}\n" "JAIL" "状态" "bantime" "findtime" "maxretry"
    print_separator

    local in_jail=false
    local jail_name="" enabled="" bantime="" findtime="" maxretry=""

    while IFS= read -r line; do
        # 去除首尾空格
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # 跳过注释和空行
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            # 输出上一个 jail
            if [[ "$in_jail" == true ]] && [[ "$jail_name" != "DEFAULT" ]]; then
                local status_color
                if [[ "${enabled:-false}" == "true" ]]; then
                    status_color="$GREEN"
                    enabled="启用"
                else
                    status_color="$RED"
                    enabled="禁用"
                fi
                printf "  ${status_color}%-24s %-10s${NC} %-10s %-10s %-10s\n" \
                    "$jail_name" "$enabled" "${bantime:--}" "${findtime:--}" "${maxretry:--}"
            fi
            jail_name="${BASH_REMATCH[1]}"
            in_jail=true
            enabled="" bantime="" findtime="" maxretry=""
        fi

        if [[ "$in_jail" == true ]]; then
            case "$line" in
                enabled*=*true*)  enabled="true" ;;
                enabled*=*false*) enabled="false" ;;
                bantime*=*)  bantime=$(echo "$line" | sed 's/.*=\s*//') ;;
                findtime*=*) findtime=$(echo "$line" | sed 's/.*=\s*//') ;;
                maxretry*=*) maxretry=$(echo "$line" | sed 's/.*=\s*//') ;;
            esac
        fi
    done < "$F2B_JAIL_LOCAL"

    # 输出最后一个 jail
    if [[ "$in_jail" == true ]] && [[ "$jail_name" != "DEFAULT" ]]; then
        local status_color
        if [[ "${enabled:-false}" == "true" ]]; then
            status_color="$GREEN"
            enabled="启用"
        else
            status_color="$RED"
            enabled="禁用"
        fi
        printf "  ${status_color}%-24s %-10s${NC} %-10s %-10s %-10s\n" \
            "$jail_name" "$enabled" "${bantime:--}" "${findtime:--}" "${maxretry:--}"
    fi

    echo ""

    # 如果服务在运行，同时显示运行时信息
    if is_running; then
        echo -e "  ${BOLD}${WHITE}> 运行中的 Jail${NC}"
        echo ""
        fail2ban-client status 2>/dev/null | sed 's/^/    /'
    fi

    press_any_key
}

toggle_jail() {
    echo ""
    # 列出所有 jail (排除 DEFAULT)
    local jails=()
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            local name="${BASH_REMATCH[1]}"
            [[ "$name" != "DEFAULT" ]] && jails+=("$name")
        fi
    done < "$F2B_JAIL_LOCAL"

    if [[ ${#jails[@]} -eq 0 ]]; then
        print_warning "没有找到任何 Jail"
        press_any_key
        return
    fi

    echo "  可用的 Jail:"
    for i in "${!jails[@]}"; do
        local j="${jails[$i]}"
        local status
        status=$(awk "/^\\[${j}\\]$/,/^\[/" "$F2B_JAIL_LOCAL" | grep -E "^enabled\s*=" | head -1 | sed 's/.*=\s*//')
        local indicator
        if [[ "$status" == "true" ]]; then
            indicator="${GREEN}[ON] 启用${NC}"
        else
            indicator="${RED}[OFF] 禁用${NC}"
        fi
        echo -e "    $((i+1))) ${j}  ${indicator}"
    done

    echo ""
    read -rp "$(echo -e "${CYAN}选择要切换的 Jail 编号: ${NC}")" toggle_num
    if [[ -z "$toggle_num" ]] || [[ "$toggle_num" -lt 1 ]] || [[ "$toggle_num" -gt "${#jails[@]}" ]]; then
        print_error "无效选择"
        press_any_key
        return
    fi

    local selected="${jails[$((toggle_num-1))]}"
    local current_status
    current_status=$(awk "/^\\[${selected}\\]$/,/^\[/" "$F2B_JAIL_LOCAL" | grep -E "^enabled\s*=" | head -1 | sed 's/.*=\s*//')

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    if [[ "$current_status" == "true" ]]; then
        # 使用 awk 精确修改对应 jail 块中的 enabled
        awk -v jail="$selected" '
            BEGIN { in_jail=0 }
            /^\[/ { in_jail=($0 == "[" jail "]") ? 1 : 0 }
            in_jail && /^enabled\s*=/ { $0 = "enabled  = false"; in_jail=0 }
            { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
        print_success "[${selected}] 已禁用"
    else
        awk -v jail="$selected" '
            BEGIN { in_jail=0 }
            /^\[/ { in_jail=($0 == "[" jail "]") ? 1 : 0 }
            in_jail && /^enabled\s*=/ { $0 = "enabled  = true"; in_jail=0 }
            { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
        print_success "[${selected}] 已启用"
    fi

    if is_running && confirm "是否立即重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

modify_jail() {
    echo ""
    local jails=()
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            local name="${BASH_REMATCH[1]}"
            [[ "$name" != "DEFAULT" ]] && jails+=("$name")
        fi
    done < "$F2B_JAIL_LOCAL"

    echo "  可用的 Jail:"
    for i in "${!jails[@]}"; do
        echo "    $((i+1))) ${jails[$i]}"
    done

    echo ""
    read -rp "$(echo -e "${CYAN}选择要修改的 Jail 编号: ${NC}")" mod_num
    if [[ -z "$mod_num" ]] || [[ "$mod_num" -lt 1 ]] || [[ "$mod_num" -gt "${#jails[@]}" ]]; then
        print_error "无效选择"
        press_any_key
        return
    fi

    local selected="${jails[$((mod_num-1))]}"

    echo ""
    echo -e "  ${BOLD}修改 [${selected}] 的参数 (留空则不修改):${NC}"
    echo ""

    local new_maxretry new_findtime new_bantime

    local cur_maxretry cur_findtime cur_bantime
    cur_maxretry=$(awk "/^\\[${selected}\\]$/,/^\[/" "$F2B_JAIL_LOCAL" | grep -E "^maxretry\s*=" | head -1 | sed 's/.*=\s*//')
    cur_findtime=$(awk "/^\\[${selected}\\]$/,/^\[/" "$F2B_JAIL_LOCAL" | grep -E "^findtime\s*=" | head -1 | sed 's/.*=\s*//')
    cur_bantime=$(awk "/^\\[${selected}\\]$/,/^\[/" "$F2B_JAIL_LOCAL" | grep -E "^bantime\s*=" | head -1 | sed 's/.*=\s*//')

    read -rp "$(echo -e "${CYAN}  maxretry (当前: ${cur_maxretry:-继承默认}): ${NC}")" new_maxretry
    read -rp "$(echo -e "${CYAN}  findtime (当前: ${cur_findtime:-继承默认}): ${NC}")" new_findtime
    read -rp "$(echo -e "${CYAN}  bantime  (当前: ${cur_bantime:-继承默认}): ${NC}")" new_bantime

    if [[ -z "$new_maxretry" && -z "$new_findtime" && -z "$new_bantime" ]]; then
        print_info "未做任何修改"
        press_any_key
        return
    fi

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    if [[ -n "$new_maxretry" ]]; then
        awk -v jail="$selected" -v val="$new_maxretry" '
            BEGIN { in_jail=0 }
            /^\[/ { in_jail=($0 == "[" jail "]") ? 1 : 0 }
            in_jail && /^maxretry\s*=/ { $0 = "maxretry = " val; in_jail=0 }
            { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
    fi

    if [[ -n "$new_findtime" ]]; then
        awk -v jail="$selected" -v val="$new_findtime" '
            BEGIN { in_jail=0 }
            /^\[/ { in_jail=($0 == "[" jail "]") ? 1 : 0 }
            in_jail && /^findtime\s*=/ { $0 = "findtime = " val; in_jail=0 }
            { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
    fi

    if [[ -n "$new_bantime" ]]; then
        awk -v jail="$selected" -v val="$new_bantime" '
            BEGIN { in_jail=0 }
            /^\[/ { in_jail=($0 == "[" jail "]") ? 1 : 0 }
            in_jail && /^bantime\s*=/ { $0 = "bantime  = " val; in_jail=0 }
            { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
    fi

    print_success "[${selected}] 参数已更新"

    if is_running && confirm "是否立即重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

add_custom_jail() {
    echo ""
    echo -e "  ${BOLD}添加自定义 Jail${NC}"
    echo ""

    read -rp "$(echo -e "${CYAN}Jail 名称: ${NC}")" jail_name
    if [[ -z "$jail_name" ]]; then
        print_error "名称不能为空"
        press_any_key
        return
    fi

    # 检查是否已存在
    if grep -q "^\\[${jail_name}\\]$" "$F2B_JAIL_LOCAL" 2>/dev/null; then
        print_error "Jail [${jail_name}] 已存在"
        press_any_key
        return
    fi

    read -rp "$(echo -e "${CYAN}端口 (如 80,443 或 http,https): ${NC}")" jail_port
    jail_port="${jail_port:-http,https}"

    read -rp "$(echo -e "${CYAN}日志路径: ${NC}")" jail_logpath
    if [[ -z "$jail_logpath" ]]; then
        print_error "日志路径不能为空"
        press_any_key
        return
    fi

    # 检查日志文件是否存在
    if [[ ! -f "$jail_logpath" ]] && ! ls $jail_logpath &>/dev/null; then
        print_warning "日志文件 ${jail_logpath} 不存在，Jail 可能无法正常工作"
        if ! confirm "是否继续?"; then
            press_any_key
            return
        fi
    fi

    echo ""
    echo "  选择过滤器:"
    echo "    1) 使用现有 filter"
    echo "    2) 创建自定义 filter"
    read -rp "$(echo -e "${CYAN}选择 [1-2]: ${NC}")" filter_choice

    local jail_filter
    case "$filter_choice" in
        1)
            echo ""
            echo "  可用的 filter:"
            ls "$F2B_FILTER_D"/*.conf 2>/dev/null | xargs -I{} basename {} .conf | pr -3 -t | sed 's/^/    /'
            echo ""
            read -rp "$(echo -e "${CYAN}filter 名称: ${NC}")" jail_filter
            if [[ ! -f "${F2B_FILTER_D}/${jail_filter}.conf" ]]; then
                print_error "filter ${jail_filter} 不存在"
                press_any_key
                return
            fi
            ;;
        2)
            jail_filter="$jail_name"
            echo ""
            read -rp "$(echo -e "${CYAN}failregex 正则表达式: ${NC}")" fail_regex
            if [[ -z "$fail_regex" ]]; then
                print_error "正则表达式不能为空"
                press_any_key
                return
            fi

            cat > "${F2B_FILTER_D}/${jail_filter}.conf" <<FILTEREOF
# Fail2Ban 自定义 filter: ${jail_filter}
# 创建时间: $(date '+%Y-%m-%d %H:%M:%S')

[Definition]
failregex = ${fail_regex}
ignoreregex =
FILTEREOF
            print_success "已创建 filter: ${F2B_FILTER_D}/${jail_filter}.conf"
            ;;
        *)
            print_error "无效选择"
            press_any_key
            return
            ;;
    esac

    read -rp "$(echo -e "${CYAN}maxretry (默认 5): ${NC}")" jail_maxretry
    jail_maxretry="${jail_maxretry:-5}"

    read -rp "$(echo -e "${CYAN}findtime (默认 600): ${NC}")" jail_findtime
    jail_findtime="${jail_findtime:-600}"

    read -rp "$(echo -e "${CYAN}bantime (默认 3600): ${NC}")" jail_bantime
    jail_bantime="${jail_bantime:-3600}"

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    cat >> "$F2B_JAIL_LOCAL" <<JAILEOF

# ============================================================
# 自定义 Jail: ${jail_name}
# 创建时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================
[${jail_name}]
enabled  = true
port     = ${jail_port}
filter   = ${jail_filter}
logpath  = ${jail_logpath}
maxretry = ${jail_maxretry}
findtime = ${jail_findtime}
bantime  = ${jail_bantime}
JAILEOF

    print_success "已添加自定义 Jail [${jail_name}]"

    if is_running && confirm "是否立即重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

show_jail_detail() {
    echo ""
    if ! is_running; then
        print_warning "Fail2Ban 未运行，仅显示配置文件内容"
        echo ""
                if [[ -f "$F2B_JAIL_LOCAL" ]]; then
            cat "$F2B_JAIL_LOCAL" | sed 's/^/    /'
        fi
        press_any_key
        return
    fi

    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')

    echo "  运行中的 Jail:"
    local i=1
    local jail_arr=()
    while IFS= read -r jail; do
        [[ -z "$jail" ]] && continue
        echo "    ${i}) ${jail}"
        jail_arr+=("$jail")
        ((i++))
    done <<< "$jails"

    echo ""
    read -rp "$(echo -e "${CYAN}选择要查看的 Jail 编号: ${NC}")" det_num
    if [[ -z "$det_num" ]] || [[ "$det_num" -lt 1 ]] || [[ "$det_num" -gt "${#jail_arr[@]}" ]]; then
        print_error "无效选择"
        press_any_key
        return
    fi

    local selected="${jail_arr[$((det_num-1))]}"
    echo ""
    echo -e "  ${BOLD}${WHITE}> [${selected}] 运行时详情${NC}"
    echo ""
    fail2ban-client status "$selected" 2>/dev/null | sed 's/^/    /'

    echo ""
    echo -e "  ${BOLD}${WHITE}> [${selected}] 配置文件内容${NC}"
    echo ""
    awk "/^\\[${selected}\\]$/,/^\[/" "$F2B_JAIL_LOCAL" 2>/dev/null | head -n -1 | sed 's/^/    /'

    # 显示对应的 filter 内容
    local filter_name
    filter_name=$(awk "/^\\[${selected}\\]$/,/^\[/" "$F2B_JAIL_LOCAL" | grep -E "^filter\s*=" | head -1 | sed 's/.*=\s*//' | sed 's/\[.*//')
    filter_name="${filter_name:-$selected}"

    if [[ -f "${F2B_FILTER_D}/${filter_name}.conf" ]]; then
        echo ""
        echo -e "  ${BOLD}${WHITE}> Filter: ${filter_name}.conf${NC}"
        echo ""
        grep -E "^(failregex|ignoreregex)" "${F2B_FILTER_D}/${filter_name}.conf" 2>/dev/null | sed 's/^/    /'
    fi

    press_any_key
}

test_filter() {
    echo ""
    echo -e "  ${BOLD}过滤器正则测试${NC}"
    echo ""

    echo "  可用的 filter:"
    ls "$F2B_FILTER_D"/*.conf 2>/dev/null | xargs -I{} basename {} .conf | pr -3 -t | sed 's/^/    /'
    echo ""

    read -rp "$(echo -e "${CYAN}filter 名称: ${NC}")" filter_name
    if [[ -z "$filter_name" ]] || [[ ! -f "${F2B_FILTER_D}/${filter_name}.conf" ]]; then
        print_error "filter 不存在"
        press_any_key
        return
    fi

    read -rp "$(echo -e "${CYAN}日志文件路径: ${NC}")" log_path
    if [[ -z "$log_path" ]] || [[ ! -f "$log_path" ]]; then
        print_error "日志文件不存在"
        press_any_key
        return
    fi

    echo ""
    echo -e "  ${BOLD}测试结果:${NC}"
    echo ""
    fail2ban-regex "$log_path" "${F2B_FILTER_D}/${filter_name}.conf" 2>&1 | sed 's/^/    /'

    press_any_key
}

# ==================== 日志查看 ====================

log_viewer() {
    while true; do
        print_header "日志查看"

        echo "  1) 查看最近封禁日志 (最近 50 条)"
        echo "  2) 查看最近解封日志 (最近 50 条)"
        echo "  3) 查看完整日志 (最近 100 行)"
        echo "  4) 实时监控日志 (tail -f)"
        echo "  5) 按 IP 搜索日志"
        echo "  6) 按 Jail 搜索日志"
        echo "  7) 封禁统计分析"
        echo "  8) 查看系统日志中的 fail2ban"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-8]: ${NC}")" log_choice

        case "$log_choice" in
            1)
                echo ""
                echo -e "  ${BOLD}最近封禁记录:${NC}"
                echo ""
                if [[ -f "$F2B_LOG" ]]; then
                    grep -i "ban " "$F2B_LOG" 2>/dev/null | grep -iv "unban" | tail -50 | sed 's/^/    /'
                else
                    print_warning "日志文件不存在: ${F2B_LOG}"
                    print_info "尝试从 journalctl 获取..."
                    journalctl -u fail2ban --no-pager -n 200 2>/dev/null | grep -i "ban " | grep -iv "unban" | tail -50 | sed 's/^/    /'
                fi
                press_any_key
                ;;
            2)
                echo ""
                echo -e "  ${BOLD}最近解封记录:${NC}"
                echo ""
                if [[ -f "$F2B_LOG" ]]; then
                    grep -i "unban" "$F2B_LOG" 2>/dev/null | tail -50 | sed 's/^/    /'
                else
                    journalctl -u fail2ban --no-pager -n 200 2>/dev/null | grep -i "unban" | tail -50 | sed 's/^/    /'
                fi
                press_any_key
                ;;
            3)
                echo ""
                if [[ -f "$F2B_LOG" ]]; then
                    tail -100 "$F2B_LOG" | sed 's/^/    /'
                else
                    journalctl -u fail2ban --no-pager -n 100 | sed 's/^/    /'
                fi
                press_any_key
                ;;
            4)
                echo ""
                print_info "按 Ctrl+C 退出实时监控"
                echo ""
                if [[ -f "$F2B_LOG" ]]; then
                    tail -f "$F2B_LOG" | sed 's/^/    /'
                else
                    journalctl -u fail2ban -f --no-pager | sed 's/^/    /'
                fi
                ;;
            5)
                echo ""
                read -rp "$(echo -e "${CYAN}输入要搜索的 IP: ${NC}")" search_ip
                if [[ -n "$search_ip" ]]; then
                    echo ""
                    echo -e "  ${BOLD}IP: ${search_ip} 的相关日志:${NC}"
                    echo ""
                    if [[ -f "$F2B_LOG" ]]; then
                        grep "$search_ip" "$F2B_LOG" 2>/dev/null | tail -50 | sed 's/^/    /'
                    else
                        journalctl -u fail2ban --no-pager 2>/dev/null | grep "$search_ip" | tail -50 | sed 's/^/    /'
                    fi
                fi
                press_any_key
                ;;
            6)
                echo ""
                read -rp "$(echo -e "${CYAN}输入 Jail 名称: ${NC}")" search_jail
                if [[ -n "$search_jail" ]]; then
                    echo ""
                    echo -e "  ${BOLD}Jail [${search_jail}] 的相关日志:${NC}"
                    echo ""
                    if [[ -f "$F2B_LOG" ]]; then
                        grep "\[${search_jail}\]" "$F2B_LOG" 2>/dev/null | tail -50 | sed 's/^/    /'
                    else
                        journalctl -u fail2ban --no-pager 2>/dev/null | grep "\[${search_jail}\]" | tail -50 | sed 's/^/    /'
                    fi
                fi
                press_any_key
                ;;
            7) ban_statistics ;;
            8)
                echo ""
                echo -e "  ${BOLD}systemd 日志:${NC}"
                echo ""
                journalctl -u fail2ban --no-pager -n 50 2>/dev/null | sed 's/^/    /'
                press_any_key
                ;;
            0) return ;;
            *) print_error "无效选择" ;;
        esac
    done
}

ban_statistics() {
    echo ""
    echo -e "  ${BOLD}${WHITE}> 封禁统计分析${NC}"
    echo ""

    local log_source=""
    if [[ -f "$F2B_LOG" ]]; then
        log_source="$F2B_LOG"
    else
        # 导出 journalctl 到临时文件
        log_source=$(mktemp)
        journalctl -u fail2ban --no-pager 2>/dev/null > "$log_source"
        trap "rm -f '$log_source'" RETURN
    fi

    if [[ ! -s "$log_source" ]]; then
        print_warning "没有日志数据可供分析"
        press_any_key
        return
    fi

    # 总封禁次数
    local total_bans
    total_bans=$(grep -ci " ban " "$log_source" 2>/dev/null | head -1)
    total_bans=$((total_bans - $(grep -ci "unban" "$log_source" 2>/dev/null | head -1) ))
    local total_ban_actions
    total_ban_actions=$(grep -i " ban " "$log_source" 2>/dev/null | grep -iv "unban" | wc -l)
    local total_unban_actions
    total_unban_actions=$(grep -ci "unban" "$log_source" 2>/dev/null | head -1)

    echo -e "  总封禁次数: ${RED}${total_ban_actions}${NC}"
    echo -e "  总解封次数: ${GREEN}${total_unban_actions}${NC}"
    echo ""

    # 被封禁最多的 IP (Top 20)
    echo -e "  ${BOLD}被封禁最多的 IP (Top 20):${NC}"
    echo ""
    printf "    ${BOLD}%-6s %-20s${NC}\n" "次数" "IP 地址"
    echo "    $(printf '%40s' '' | tr ' ' '-')"
    grep -i " ban " "$log_source" 2>/dev/null | grep -iv "unban" | \
        grep -oP '\d+\.\d+\.\d+\.\d+' | sort | uniq -c | sort -rn | head -20 | \
        while read -r count ip; do
            printf "    ${RED}%-6s${NC} %-20s\n" "$count" "$ip"
        done

    echo ""

    # 各 Jail 封禁次数
    echo -e "  ${BOLD}各 Jail 封禁次数:${NC}"
    echo ""
    printf "    ${BOLD}%-6s %-20s${NC}\n" "次数" "Jail"
    echo "    $(printf '%40s' '' | tr ' ' '-')"
    grep -i " ban " "$log_source" 2>/dev/null | grep -iv "unban" | \
        grep -oP '\[\K[\w-]+(?=\])' | sort | uniq -c | sort -rn | \
        while read -r count jail; do
            printf "    ${YELLOW}%-6s${NC} %-20s\n" "$count" "$jail"
        done

    echo ""

    # 按日期统计 (最近 7 天)
    echo -e "  ${BOLD}最近 7 天每日封禁次数:${NC}"
    echo ""
    for i in $(seq 6 -1 0); do
        local day
        day=$(date -d "${i} days ago" '+%Y-%m-%d' 2>/dev/null || date -v-${i}d '+%Y-%m-%d' 2>/dev/null)
        if [[ -n "$day" ]]; then
            local day_count
            day_count=$(grep "$day" "$log_source" 2>/dev/null | grep -i " ban " | grep -iv "unban" | wc -l)
            local bar=""
            local bar_len=$((day_count / 2))
            [[ $bar_len -gt 40 ]] && bar_len=40
            bar=$(printf '%*s' "$bar_len" '' | tr ' ' '#')
            printf "    %-12s %4s %s\n" "$day" "$day_count" "$bar"
        fi
    done

    press_any_key
}

# ==================== 配置管理 ====================

config_management() {
    while true; do
        print_header "配置管理"

        echo "  1) 编辑 jail.local"
        echo "  2) 查看当前配置"
        echo "  3) 备份配置"
        echo "  4) 恢复配置"
        echo "  5) 重新生成默认配置"
        echo "  6) 检查配置语法"
        echo "  7) 修改默认封禁参数"
        echo "  8) 查看 jail.d 目录下的配置"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-8]: ${NC}")" conf_choice

        case "$conf_choice" in
            1)
                local editor="${EDITOR:-nano}"
                if ! command -v "$editor" &>/dev/null; then
                    editor="vi"
                fi
                "$editor" "$F2B_JAIL_LOCAL"
                if is_running && confirm "是否重载配置?"; then
                    fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
                fi
                ;;
            2)
                echo ""
                if [[ -f "$F2B_JAIL_LOCAL" ]]; then
                    echo -e "  ${BOLD}${F2B_JAIL_LOCAL}:${NC}"
                    echo ""
                    cat "$F2B_JAIL_LOCAL" | sed 's/^/    /'
                else
                    print_warning "文件不存在: ${F2B_JAIL_LOCAL}"
                fi
                press_any_key
                ;;
            3)
                echo ""
                mkdir -p "$BACKUP_DIR"
                local backup_file="${BACKUP_DIR}/jail.local.$(date +%Y%m%d_%H%M%S)"
                if [[ -f "$F2B_JAIL_LOCAL" ]]; then
                    cp "$F2B_JAIL_LOCAL" "$backup_file"
                    print_success "配置已备份到: ${backup_file}"
                else
                    print_error "没有配置文件可备份"
                fi
                # 同时备份 jail.d 下的文件
                if [[ -d "$F2B_JAIL_D" ]] && ls "$F2B_JAIL_D"/*.conf &>/dev/null; then
                    local jail_d_backup="${BACKUP_DIR}/jail.d.$(date +%Y%m%d_%H%M%S)"
                    mkdir -p "$jail_d_backup"
                    cp "$F2B_JAIL_D"/*.conf "$jail_d_backup/" 2>/dev/null
                    print_success "jail.d 配置已备份到: ${jail_d_backup}/"
                fi
                press_any_key
                ;;
            4)
                echo ""
                echo -e "  ${BOLD}可用的备份:${NC}"
                echo ""
                if [[ -d "$BACKUP_DIR" ]]; then
                    local backups=()
                    local i=1
                    while IFS= read -r f; do
                        [[ -z "$f" ]] && continue
                        echo "    ${i}) $(basename "$f")  ($(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1))"
                        backups+=("$f")
                        ((i++))
                    done < <(ls -1t "${BACKUP_DIR}"/jail.local.* 2>/dev/null)

                    if [[ ${#backups[@]} -eq 0 ]]; then
                        print_warning "没有可用的备份"
                        press_any_key
                        continue
                    fi

                    echo ""
                    read -rp "$(echo -e "${CYAN}选择要恢复的备份编号: ${NC}")" restore_num
                    if [[ -n "$restore_num" ]] && [[ "$restore_num" -ge 1 ]] && [[ "$restore_num" -le "${#backups[@]}" ]]; then
                        local selected_backup="${backups[$((restore_num-1))]}"
                        if confirm "确认恢复备份 $(basename "$selected_backup")?"; then
                            # 先备份当前配置
                            cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.before_restore.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
                            cp "$selected_backup" "$F2B_JAIL_LOCAL"
                            print_success "配置已恢复"
                            if is_running && confirm "是否重载配置?"; then
                                fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
                            fi
                        fi
                    else
                        print_error "无效选择"
                    fi
                else
                    print_warning "备份目录不存在"
                fi
                press_any_key
                ;;
            5)
                echo ""
                if [[ -f "$F2B_JAIL_LOCAL" ]]; then
                    if confirm "当前配置将被覆盖，是否先备份?"; then
                        mkdir -p "$BACKUP_DIR"
                        cp "$F2B_JAIL_LOCAL" "${BACKUP_DIR}/jail.local.$(date +%Y%m%d_%H%M%S)"
                        print_success "已备份当前配置"
                    fi
                fi
                generate_default_config
                if is_running && confirm "是否重载配置?"; then
                    fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
                fi
                press_any_key
                ;;
            6)
                echo ""
                echo -e "  ${BOLD}配置语法检查:${NC}"
                echo ""
                # 使用 fail2ban-client 检测
                local test_result
                test_result=$(fail2ban-client -t 2>&1)
                local test_exit=$?
                if [[ $test_exit -eq 0 ]]; then
                    print_success "配置语法正确"
                else
                    print_error "配置存在错误:"
                    echo "$test_result" | sed 's/^/    /'
                fi
                # 额外检查 jail.local 的格式
                if [[ -f "$F2B_JAIL_LOCAL" ]]; then
                    local syntax_errors
                    syntax_errors=$(python3 -c "
import configparser
c = configparser.ConfigParser()
try:
    c.read('${F2B_JAIL_LOCAL}')
    print('OK')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)
                    if [[ "$syntax_errors" == "OK" ]]; then
                        print_success "jail.local INI 格式正确"
                    else
                        print_error "jail.local 格式错误: ${syntax_errors}"
                    fi
                fi
                press_any_key
                ;;
            7)
                echo ""
                echo -e "  ${BOLD}修改 [DEFAULT] 参数:${NC}"
                echo ""

                local cur_bantime cur_findtime cur_maxretry
                cur_bantime=$(grep -E "^bantime\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/.*=\s*//')
                cur_findtime=$(grep -E "^findtime\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/.*=\s*//')
                cur_maxretry=$(grep -E "^maxretry\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/.*=\s*//')

                echo "  当前值:"
                echo "    bantime  = ${cur_bantime:-未设置}"
                echo "    findtime = ${cur_findtime:-未设置}"
                echo "    maxretry = ${cur_maxretry:-未设置}"
                echo ""
                echo "  输入新值 (留空不修改):"

                local new_bantime new_findtime new_maxretry
                read -rp "$(echo -e "${CYAN}  bantime  (秒, -1=永久): ${NC}")" new_bantime
                read -rp "$(echo -e "${CYAN}  findtime (秒): ${NC}")" new_findtime
                read -rp "$(echo -e "${CYAN}  maxretry: ${NC}")" new_maxretry

                if [[ -z "$new_bantime" && -z "$new_findtime" && -z "$new_maxretry" ]]; then
                    print_info "未做任何修改"
                    press_any_key
                    continue
                fi

                cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

                # 修改 DEFAULT 段
                if [[ -n "$new_bantime" ]]; then
                    awk '
                        BEGIN { in_default=0; done_bt=0 }
                        /^\[/ { in_default=($0 == "[DEFAULT]") ? 1 : 0 }
                        in_default && !done_bt && /^bantime\s*=/ { $0 = "bantime  = " "'"$new_bantime"'"; done_bt=1 }
                        { print }
                    ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
                fi
                if [[ -n "$new_findtime" ]]; then
                    awk '
                        BEGIN { in_default=0; done_ft=0 }
                        /^\[/ { in_default=($0 == "[DEFAULT]") ? 1 : 0 }
                        in_default && !done_ft && /^findtime\s*=/ { $0 = "findtime = " "'"$new_findtime"'"; done_ft=1 }
                        { print }
                    ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
                fi
                if [[ -n "$new_maxretry" ]]; then
                    awk '
                        BEGIN { in_default=0; done_mr=0 }
                        /^\[/ { in_default=($0 == "[DEFAULT]") ? 1 : 0 }
                        in_default && !done_mr && /^maxretry\s*=/ { $0 = "maxretry = " "'"$new_maxretry"'"; done_mr=1 }
                        { print }
                    ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
                fi

                print_success "默认参数已更新"
                if is_running && confirm "是否重载配置?"; then
                    fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
                fi
                press_any_key
                ;;
            8)
                echo ""
                echo -e "  ${BOLD}jail.d 目录内容:${NC}"
                echo ""
                if [[ -d "$F2B_JAIL_D" ]]; then
                    local conf_files
                    conf_files=$(ls "$F2B_JAIL_D"/*.conf 2>/dev/null)
                    if [[ -n "$conf_files" ]]; then
                        for f in $conf_files; do
                            echo -e "  ${YELLOW}-- $(basename "$f") --${NC}"
                            cat "$f" | sed 's/^/    /'
                            echo ""
                        done
                    else
                        print_info "jail.d 目录为空"
                    fi

                    local local_files
                    local_files=$(ls "$F2B_JAIL_D"/*.local 2>/dev/null)
                    if [[ -n "$local_files" ]]; then
                        for f in $local_files; do
                            echo -e "  ${YELLOW}-- $(basename "$f") --${NC}"
                            cat "$f" | sed 's/^/    /'
                            echo ""
                        done
                    fi
                else
                    print_warning "目录不存在: ${F2B_JAIL_D}"
                fi
                press_any_key
                ;;
            0) return ;;
            *) print_error "无效选择" ;;
        esac
    done
}

# ==================== 安全加固 ====================

security_hardening() {
    while true; do
        print_header "安全加固"

        echo "  1) 启用激进 SSH 防护"
        echo "  2) 添加暴力破解防护 (DDoS 缓解)"
        echo "  3) 添加恶意扫描器防护"
        echo "  4) 配置递增封禁"
        echo "  5) 配置永久封禁 (recidive)"
        echo "  6) 一键应用推荐安全策略"
        echo "  0) 返回主菜单"
        echo ""
        read -rp "$(echo -e "${CYAN}选择 [0-6]: ${NC}")" sec_choice

        case "$sec_choice" in
            1) enable_aggressive_ssh ;;
            2) add_ddos_protection ;;
            3) add_scanner_protection ;;
            4) configure_incremental_ban ;;
            5) configure_recidive ;;
            6) apply_recommended_policy ;;
            0) return ;;
            *) print_error "无效选择" ;;
        esac
    done
}

enable_aggressive_ssh() {
    echo ""
    if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
        print_error "配置文件不存在"
        press_any_key
        return
    fi

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    if grep -q "^\[sshd-aggressive\]$" "$F2B_JAIL_LOCAL"; then
        # 启用已有的
        awk '
            BEGIN { in_jail=0 }
            /^\[/ { in_jail=($0 == "[sshd-aggressive]") ? 1 : 0 }
            in_jail && /^enabled\s*=/ { $0 = "enabled  = true"; in_jail=0 }
            { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
    else
        local ssh_port
        ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
        ssh_port="${ssh_port:-22}"

        cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# SSH 激进防护模式
# ============================================================
[sshd-aggressive]
enabled  = true
port     = ${ssh_port}
filter   = sshd[mode=aggressive]
maxretry = 3
findtime = 300
bantime  = 86400
EOF
    fi

    print_success "SSH 激进防护已启用 (3次失败即封禁24小时)"
    if is_running && confirm "是否重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

add_ddos_protection() {
    echo ""
    if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
        print_error "配置文件不存在"
        press_any_key
        return
    fi

    if grep -q "^\[http-get-dos\]$" "$F2B_JAIL_LOCAL"; then
        print_warning "DDoS 防护规则已存在"
        press_any_key
        return
    fi

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    # 创建 filter
    cat > "${F2B_FILTER_D}/http-get-dos.conf" <<'FILTEREOF'
# Fail2Ban filter - HTTP GET DDoS
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*
ignoreregex =
FILTEREOF

    # 检测 web 日志路径
    local web_log="/var/log/nginx/access.log"
    [[ ! -f "$web_log" ]] && web_log="/var/log/apache2/access.log"
    [[ ! -f "$web_log" ]] && web_log="/var/log/nginx/access.log"

    read -rp "$(echo -e "${CYAN}Web 访问日志路径 (默认: ${web_log}): ${NC}")" custom_log
    web_log="${custom_log:-$web_log}"

    read -rp "$(echo -e "${CYAN}时间窗口内最大请求数 (默认: 300): ${NC}")" max_req
    max_req="${max_req:-300}"

    read -rp "$(echo -e "${CYAN}检测时间窗口/秒 (默认: 60): ${NC}")" dos_findtime
    dos_findtime="${dos_findtime:-60}"

    read -rp "$(echo -e "${CYAN}封禁时长/秒 (默认: 600): ${NC}")" dos_bantime
    dos_bantime="${dos_bantime:-600}"

    cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# HTTP DDoS 缓解
# ============================================================
[http-get-dos]
enabled  = true
port     = http,https
filter   = http-get-dos
logpath  = ${web_log}
maxretry = ${max_req}
findtime = ${dos_findtime}
bantime  = ${dos_bantime}
EOF

    print_success "HTTP DDoS 防护已添加"
    if is_running && confirm "是否重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

add_scanner_protection() {
    echo ""
    if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
        print_error "配置文件不存在"
        press_any_key
        return
    fi

    if grep -q "^\[port-scanner\]$" "$F2B_JAIL_LOCAL"; then
        print_warning "扫描器防护规则已存在"
        press_any_key
        return
    fi

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    # 创建 iptables 端口扫描检测 filter
    cat > "${F2B_FILTER_D}/port-scanner.conf" <<'FILTEREOF'
# Fail2Ban filter - Port Scanner Detection
# 需要 iptables 记录日志配合使用
[Definition]
failregex = ^.*IN=.* SRC=<HOST> DST=.* DPT=.*$
ignoreregex =
FILTEREOF

    cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# 端口扫描防护
# 注意: 需要配合 iptables 日志规则使用
# iptables -A INPUT -j LOG --log-prefix "PortScan: " --log-level 4
# ============================================================
[port-scanner]
enabled  = false
port     = all
filter   = port-scanner
logpath  = /var/log/syslog
maxretry = 10
findtime = 60
bantime  = 86400
EOF

    # 添加恶意路径扫描 (针对 web)
    if [[ -d /etc/nginx ]] || [[ -d /etc/apache2 ]]; then
        cat > "${F2B_FILTER_D}/web-scanner.conf" <<'FILTEREOF'
# Fail2Ban filter - Web Vulnerability Scanner Detection
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*(wp-login|xmlrpc|phpmyadmin|admin|\.env|\.git|shell|eval|passwd|etc/shadow|cgi-bin|\.asp|\.aspx).*" (400|403|404|444)
ignoreregex =
FILTEREOF

        local web_access_log="/var/log/nginx/access.log"
        [[ ! -f "$web_access_log" ]] && web_access_log="/var/log/apache2/access.log"

        if ! grep -q "^\[web-scanner\]$" "$F2B_JAIL_LOCAL"; then
            cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# Web 漏洞扫描防护
# ============================================================
[web-scanner]
enabled  = true
port     = http,https
filter   = web-scanner
logpath  = ${web_access_log}
maxretry = 3
findtime = 300
bantime  = 86400
EOF
        fi

        print_success "Web 扫描器防护已添加"
    fi

    print_success "扫描器防护已添加 (端口扫描默认禁用，需手动配置 iptables 日志)"
    if is_running && confirm "是否重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

configure_incremental_ban() {
    echo ""
    echo -e "  ${BOLD}递增封禁配置${NC}"
    echo -e "  ${DIM}每次封禁后，下次封禁时间翻倍，用于打击惯犯${NC}"
    echo ""

    if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
        print_error "配置文件不存在"
        press_any_key
        return
    fi

    local current
    current=$(grep -c "bantime.increment" "$F2B_JAIL_LOCAL" 2>/dev/null || echo 0)
    if [[ "$current" -gt 0 ]]; then
        print_info "当前配置已包含递增封禁设置"
        grep "bantime\." "$F2B_JAIL_LOCAL" | head -5 | sed 's/^/    /'
        echo ""
        if ! confirm "是否重新配置?"; then
            press_any_key
            return
        fi
    fi

    read -rp "$(echo -e "${CYAN}封禁倍率因子 (默认 2): ${NC}")" ban_factor
    ban_factor="${ban_factor:-2}"

    read -rp "$(echo -e "${CYAN}最大封禁时长 (默认 4w 即4周): ${NC}")" ban_maxtime
    ban_maxtime="${ban_maxtime:-4w}"

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    # 删除旧的递增配置
    sed -i '/^bantime\.increment/d; /^bantime\.factor/d; /^bantime\.formula/d; /^bantime\.maxtime/d' "$F2B_JAIL_LOCAL"

    # 在 [DEFAULT] 段的 bantime 后插入递增配置
    sed -i "/^\[DEFAULT\]$/,/^\[/{
        /^bantime\s*=/{
            a\\
\\
# --- 递增封禁 ---\\
bantime.increment = true\\
bantime.factor    = ${ban_factor}\\
bantime.formula   = ban.Time * (1 << (ban.Count if ban.Count < 20 else 20)) * banFactor\\
bantime.maxtime   = ${ban_maxtime}
        }
    }" "$F2B_JAIL_LOCAL"

    print_success "递增封禁已配置 (倍率: ${ban_factor}, 最大时长: ${ban_maxtime})"
    if is_running && confirm "是否重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

configure_recidive() {
    echo ""
    echo -e "  ${BOLD}Recidive 惯犯永久封禁${NC}"
    echo -e "  ${DIM}对于反复被封禁的 IP，实施长期/永久封禁${NC}"
    echo ""

    if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
        print_error "配置文件不存在"
        press_any_key
        return
    fi

    if grep -q "^\[recidive\]$" "$F2B_JAIL_LOCAL"; then
        print_warning "Recidive 规则已存在"
        awk '/^\[recidive\]$/,/^\[/' "$F2B_JAIL_LOCAL" | head -n -1 | sed 's/^/    /'
        echo ""
        if ! confirm "是否重新配置?"; then
            press_any_key
            return
        fi
        # 删除旧配置
        cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
        awk '
            /^\[recidive\]$/ { skip=1; next }
            /^\[/ && skip { skip=0 }
            !skip { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
    else
        cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    read -rp "$(echo -e "${CYAN}多少次被封禁后触发 recidive (默认 5): ${NC}")" rec_maxretry
    rec_maxretry="${rec_maxretry:-5}"

    read -rp "$(echo -e "${CYAN}检测周期/秒 (默认 86400 即1天): ${NC}")" rec_findtime
    rec_findtime="${rec_findtime:-86400}"

    read -rp "$(echo -e "${CYAN}惯犯封禁时长/秒 (默认 604800 即1周, -1=永久): ${NC}")" rec_bantime
    rec_bantime="${rec_bantime:-604800}"

    cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# Recidive - 惯犯长期封禁
# 被封禁 ${rec_maxretry} 次以上的 IP 将被封禁 ${rec_bantime} 秒
# ============================================================
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
action   = %(action_)s
banaction = iptables-allports
maxretry = ${rec_maxretry}
findtime = ${rec_findtime}
bantime  = ${rec_bantime}
EOF

    print_success "Recidive 惯犯封禁已配置"
    if is_running && confirm "是否重载配置?"; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    fi
    press_any_key
}

apply_recommended_policy() {
    echo ""
    echo -e "  ${BOLD}推荐安全策略将包含:${NC}"
    echo ""
    echo "    * SSH 激进防护 (3次失败封禁24小时)"
    echo "    * 递增封禁 (重复犯封禁时间翻倍)"
    echo "    * 惯犯永久封禁 (recidive)"
    echo "    * Web 扫描器防护 (如检测到 Nginx/Apache)"
    echo "    * 当前 SSH 连接 IP 自动加入白名单"
    echo ""

    if ! confirm "是否应用推荐安全策略?"; then
        press_any_key
        return
    fi

    if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
        print_warning "配置文件不存在，将先生成基础配置"
        generate_default_config
    fi

    cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"

    # 1. 添加当前 SSH IP 到白名单
    local current_ips
    current_ips=$(detect_current_ssh_ips)
    if [[ -n "$current_ips" ]]; then
        local current_whitelist
        current_whitelist=$(grep -E "^ignoreip\s*=" "$F2B_JAIL_LOCAL" 2>/dev/null | head -1 | sed 's/^ignoreip\s*=\s*//')
        for ip in $current_ips; do
            if ! echo "$current_whitelist" | grep -qw "$ip"; then
                current_whitelist="${current_whitelist} ${ip}"
                print_success "已将当前 SSH IP ${ip} 加入白名单"
            fi
        done
        sed -i "s|^ignoreip\s*=.*|ignoreip = ${current_whitelist}|" "$F2B_JAIL_LOCAL"
    fi

    # 2. 启用 SSH 激进防护
    if ! grep -q "^\[sshd-aggressive\]$" "$F2B_JAIL_LOCAL"; then
        local ssh_port
        ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
        ssh_port="${ssh_port:-22}"
        cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# SSH 激进防护模式 (推荐策略)
# ============================================================
[sshd-aggressive]
enabled  = true
port     = ${ssh_port}
filter   = sshd[mode=aggressive]
maxretry = 3
findtime = 300
bantime  = 86400
EOF
    else
        awk '
            BEGIN { in_jail=0 }
            /^\[/ { in_jail=($0 == "[sshd-aggressive]") ? 1 : 0 }
            in_jail && /^enabled\s*=/ { $0 = "enabled  = true"; in_jail=0 }
            { print }
        ' "$F2B_JAIL_LOCAL" > "${F2B_JAIL_LOCAL}.tmp" && mv "${F2B_JAIL_LOCAL}.tmp" "$F2B_JAIL_LOCAL"
    fi
    print_success "SSH 激进防护已启用"

    # 3. 递增封禁
    if ! grep -q "bantime.increment" "$F2B_JAIL_LOCAL"; then
        sed -i "/^\[DEFAULT\]$/,/^\[/{
            /^bantime\s*=/{
                a\\
\\
# --- 递增封禁(推荐策略) ---\\
bantime.increment = true\\
bantime.factor    = 2\\
bantime.formula   = ban.Time * (1 << (ban.Count if ban.Count < 20 else 20)) * banFactor\\
bantime.maxtime   = 4w
            }
        }" "$F2B_JAIL_LOCAL"
    fi
    print_success "递增封禁已配置"

    # 4. Recidive
    if ! grep -q "^\[recidive\]$" "$F2B_JAIL_LOCAL"; then
        cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# Recidive - 惯犯长期封禁 (推荐策略)
# ============================================================
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
action   = %(action_)s
banaction = iptables-allports
maxretry = 5
findtime = 86400
bantime  = 604800
EOF
    fi
    print_success "Recidive 惯犯封禁已配置"

    # 5. Web 扫描器防护
    if [[ -d /etc/nginx ]] || [[ -d /etc/apache2 ]]; then
        if ! grep -q "^\[web-scanner\]$" "$F2B_JAIL_LOCAL"; then
            cat > "${F2B_FILTER_D}/web-scanner.conf" <<'FILTEREOF'
# Fail2Ban filter - Web Vulnerability Scanner Detection
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*(wp-login|xmlrpc|phpmyadmin|admin|\.env|\.git|shell|eval|passwd|etc/shadow|cgi-bin|\.asp|\.aspx).*" (400|403|404|444)
ignoreregex =
FILTEREOF

            local web_access_log="/var/log/nginx/access.log"
            [[ ! -f "$web_access_log" ]] && web_access_log="/var/log/apache2/access.log"

            cat >> "$F2B_JAIL_LOCAL" <<EOF

# ============================================================
# Web 漏洞扫描防护 (推荐策略)
# ============================================================
[web-scanner]
enabled  = true
port     = http,https
filter   = web-scanner
logpath  = ${web_access_log}
maxretry = 3
findtime = 300
bantime  = 86400
EOF
        fi
        print_success "Web 扫描器防护已添加"
    fi

    echo ""
    print_success "推荐安全策略已全部应用"

    if is_running; then
        fail2ban-client reload 2>/dev/null && print_success "配置已重载" || print_error "重载失败"
    else
        systemctl restart fail2ban 2>/dev/null
        sleep 2
        if is_running; then
            print_success "Fail2Ban 已启动"
        else
            print_error "启动失败，请检查配置"
        fi
    fi

    press_any_key
}

# ==================== 系统信息 ====================

show_system_info() {
    print_header "系统信息"

    source /etc/os-release 2>/dev/null

    echo -e "  ${BOLD}${WHITE}> 系统信息${NC}"
    echo ""
    echo -e "  操作系统:     ${CYAN}${PRETTY_NAME:-Unknown}${NC}"
    echo -e "  内核版本:     ${CYAN}$(uname -r)${NC}"
    echo -e "  主机名:       ${CYAN}$(hostname)${NC}"
    echo -e "  当前时间:     ${CYAN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"

    echo ""
    echo -e "  ${BOLD}${WHITE}> Fail2Ban 信息${NC}"
    echo ""
    echo -e "  安装状态:     $(is_installed && echo -e "${GREEN}已安装${NC}" || echo -e "${RED}未安装${NC}")"
    echo -e "  软件版本:     ${CYAN}$(get_f2b_version)${NC}"
    echo -e "  运行状态:     $(is_running && echo -e "${GREEN}[RUNNING]${NC}" || echo -e "${RED}[STOPPED]${NC}")"
    echo -e "  开机自启:     $(systemctl is-enabled fail2ban 2>/dev/null && echo -e "${GREEN}是${NC}" || echo -e "${RED}否${NC}")"
    echo -e "  配置文件:     ${CYAN}${F2B_JAIL_LOCAL}${NC} $([ -f "$F2B_JAIL_LOCAL" ] && echo -e "${GREEN}(存在)${NC}" || echo -e "${RED}(不存在)${NC}")"
    echo -e "  日志文件:     ${CYAN}${F2B_LOG}${NC} $([ -f "$F2B_LOG" ] && echo -e "${GREEN}(存在, $(du -h "$F2B_LOG" 2>/dev/null | awk '{print $1}'))${NC}" || echo -e "${RED}(不存在)${NC}")"

    if is_running; then
        echo ""
        echo -e "  ${BOLD}${WHITE}> 运行统计${NC}"
        echo ""
        local jails
        jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')
        local jail_count=0
        local total_banned=0
        local total_current=0

        while IFS= read -r jail; do
            [[ -z "$jail" ]] && continue
            ((jail_count++))
            local status
            status=$(fail2ban-client status "$jail" 2>/dev/null)
            local cur
            cur=$(echo "$status" | grep "Currently banned:" | awk '{print $NF}')
            local tot
            tot=$(echo "$status" | grep "Total banned:" | awk '{print $NF}')
            total_current=$((total_current + ${cur:-0}))
            total_banned=$((total_banned + ${tot:-0}))
        done <<< "$jails"

        echo -e "  活动 Jail 数: ${CYAN}${jail_count}${NC}"
        echo -e "  当前封禁数:   ${RED}${total_current}${NC}"
        echo -e "  历史封禁总数: ${YELLOW}${total_banned}${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}${WHITE}> 防火墙状态${NC}"
    echo ""
    local ipt_rules
    ipt_rules=$(iptables -L -n 2>/dev/null | grep -c "f2b-" || echo 0)
    echo -e "  iptables f2b 规则链数: ${CYAN}${ipt_rules}${NC}"

    # 检测 nftables
    if command -v nft &>/dev/null; then
        local nft_rules
        nft_rules=$(nft list ruleset 2>/dev/null | grep -c "f2b" || echo 0)
        echo -e "  nftables f2b 规则数:   ${CYAN}${nft_rules}${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}${WHITE}> 脚本信息${NC}"
    echo ""
    echo -e "  脚本版本:     ${CYAN}v${SCRIPT_VERSION}${NC}"
    echo -e "  备份目录:     ${CYAN}${BACKUP_DIR}${NC}"
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_count
        backup_count=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
        echo -e "  备份文件数:   ${CYAN}${backup_count}${NC}"
    fi

    press_any_key
}

# ==================== 主菜单 ====================

show_banner() {
    clear
    echo ""
    print_color "$CYAN" "  +-----------------------------------------------------------+"
    print_color "$CYAN" "  |                                                           |"
    print_color "$CYAN" "  |      ${WHITE}${BOLD}Fail2Ban 安装管理脚本${NC}${CYAN}                              |"
    print_color "$CYAN" "  |      ${DIM}兼容 Debian / Ubuntu${NC}${CYAN}                                |"
    print_color "$CYAN" "  |      ${DIM}版本: v${SCRIPT_VERSION}${NC}${CYAN}                                       |"
    print_color "$CYAN" "  |                                                           |"
    print_color "$CYAN" "  +-----------------------------------------------------------+"
    echo ""
}

main_menu() {
    while true; do
        show_banner

        # 快速状态栏
        local install_status run_status
        if is_installed; then
            install_status="${GREEN}已安装 ($(get_f2b_version))${NC}"
        else
            install_status="${RED}未安装${NC}"
        fi

        if is_running; then
            local current_banned=0
            local jails
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')
            while IFS= read -r jail; do
                [[ -z "$jail" ]] && continue
                local cur
                cur=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $NF}')
                current_banned=$((current_banned + ${cur:-0}))
            done <<< "$jails"
            run_status="${GREEN}[RUNNING]${NC} ${DIM}(封禁: ${current_banned})${NC}"
        else
            run_status="${RED}[STOPPED]${NC}"
        fi

        echo -e "  状态: ${install_status}  |  ${run_status}"
        echo ""
        print_separator
        echo ""
        echo -e "  ${BOLD}${WHITE}基础操作${NC}"
        echo "    1) 安装 Fail2Ban"
        echo "    2) 卸载 Fail2Ban"
        echo "    3) 服务管理 (启动/停止/重启)"
        echo ""
        echo -e "  ${BOLD}${WHITE}监控管理${NC}"
        echo "    4) 查看运行状态"
        echo "    5) 封禁管理 (封禁/解封 IP)"
        echo "    6) 白名单管理"
        echo ""
        echo -e "  ${BOLD}${WHITE}配置管理${NC}"
        echo "    7) Jail 管理"
        echo "    8) 配置文件管理"
        echo ""
        echo -e "  ${BOLD}${WHITE}高级功能${NC}"
        echo "    9) 安全加固"
        echo "   10) 日志查看与分析"
        echo "   11) 系统信息"
        echo ""
        echo "    0) 退出"
        echo ""
        read -rp "$(echo -e "${CYAN}  请选择 [0-11]: ${NC}")" main_choice

        case "$main_choice" in
            1)  install_fail2ban ;;
            2)  uninstall_fail2ban ;;
            3)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    service_management
                fi
                ;;
            4)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    show_status
                fi
                ;;
            5)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    ban_management
                fi
                ;;
            6)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    whitelist_management
                fi
                ;;
            7)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    jail_management
                fi
                ;;
            8)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    config_management
                fi
                ;;
            9)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    security_hardening
                fi
                ;;
            10)
                if ! is_installed; then
                    print_error "请先安装 Fail2Ban"
                    press_any_key
                else
                    log_viewer
                fi
                ;;
            11) show_system_info ;;
            0)
                echo ""
                print_info "再见！"
                echo ""
                exit 0
                ;;
            *)
                print_error "无效选择，请输入 0-11"
                sleep 1
                ;;
        esac
    done
}

# ==================== 命令行参数支持 ====================

show_cli_help() {
    cat <<HELPEOF

  Fail2Ban 管理脚本 v${SCRIPT_VERSION}

  用法: $(basename "$0") [命令] [参数]

  命令:
    install           安装 Fail2Ban
    uninstall         卸载 Fail2Ban
    status            查看运行状态
    start             启动服务
    stop              停止服务
    restart           重启服务
    reload            重载配置
    ban <jail> <ip>   封禁 IP
    unban <ip>        解封 IP (从所有 Jail)
    unban-all         解封所有 IP
    banned            列出所有被封禁的 IP
    whitelist-add <ip>    添加白名单
    whitelist-show        显示白名单
    log [lines]       查看日志 (默认50行)
    test <filter> <log>   测试过滤器
    help              显示帮助

  不带参数运行将进入交互式菜单。

HELPEOF
}

handle_cli() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        install)
            install_fail2ban
            ;;
        uninstall)
            uninstall_fail2ban
            ;;
        status)
            if ! is_running; then
                print_error "Fail2Ban 未运行"
                exit 1
            fi
            fail2ban-client status
            echo ""
            local jails
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')
            while IFS= read -r jail; do
                [[ -z "$jail" ]] && continue
                echo "=== [$jail] ==="
                fail2ban-client status "$jail"
                echo ""
            done <<< "$jails"
            ;;
        start)
            systemctl start fail2ban && print_success "已启动" || print_error "启动失败"
            ;;
        stop)
            systemctl stop fail2ban && print_success "已停止" || print_error "停止失败"
            ;;
        restart)
            systemctl restart fail2ban && print_success "已重启" || print_error "重启失败"
            ;;
        reload)
            fail2ban-client reload && print_success "已重载" || print_error "重载失败"
            ;;
        ban)
            local jail_name="${1:-}"
            local ban_ip="${2:-}"
            if [[ -z "$jail_name" || -z "$ban_ip" ]]; then
                print_error "用法: $(basename "$0") ban <jail> <ip>"
                exit 1
            fi
            if fail2ban-client set "$jail_name" banip "$ban_ip" 2>/dev/null; then
                print_success "已在 [${jail_name}] 中封禁 ${ban_ip}"
            else
                print_error "封禁失败，请检查 Jail 名称和 IP"
                exit 1
            fi
            ;;
        unban)
            local unban_ip="${1:-}"
            if [[ -z "$unban_ip" ]]; then
                print_error "用法: $(basename "$0") unban <ip>"
                exit 1
            fi
            if fail2ban-client unban "$unban_ip" 2>/dev/null; then
                print_success "已解封 ${unban_ip}"
            else
                print_warning "该 IP 可能未被封禁"
            fi
            ;;
        unban-all)
            if fail2ban-client unban --all 2>/dev/null; then
                print_success "已解封所有 IP"
            else
                print_error "操作失败"
                exit 1
            fi
            ;;
        banned)
            if ! is_running; then
                print_error "Fail2Ban 未运行"
                exit 1
            fi
            local jails
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | sed 's/^\s*//')
            local found=false
            while IFS= read -r jail; do
                [[ -z "$jail" ]] && continue
                local banned_ips
                banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/.*Banned IP list:\s*//')
                if [[ -n "$banned_ips" && "$banned_ips" != " " ]]; then
                    found=true
                    echo -e "${YELLOW}[${jail}]${NC}"
                    for ip in $banned_ips; do
                        echo -e "  ${RED}[BANNED] ${ip}${NC}"
                    done
                fi
            done <<< "$jails"
            if [[ "$found" == "false" ]]; then
                print_success "当前没有被封禁的 IP"
            fi
            ;;
        whitelist-add)
            local wl_ip="${1:-}"
            if [[ -z "$wl_ip" ]]; then
                print_error "用法: $(basename "$0") whitelist-add <ip>"
                exit 1
            fi
            if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
                print_error "配置文件不存在: ${F2B_JAIL_LOCAL}"
                exit 1
            fi
            local current_wl
            current_wl=$(grep -E "^ignoreip\s*=" "$F2B_JAIL_LOCAL" | head -1 | sed 's/^ignoreip\s*=\s*//')
            if echo "$current_wl" | grep -qw "$wl_ip"; then
                print_warning "${wl_ip} 已在白名单中"
                exit 0
            fi
            cp "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
            sed -i "s|^ignoreip\s*=.*|ignoreip = ${current_wl} ${wl_ip}|" "$F2B_JAIL_LOCAL"
            print_success "已添加 ${wl_ip} 到白名单"
            if is_running; then
                fail2ban-client reload 2>/dev/null && print_success "配置已重载"
                fail2ban-client unban "$wl_ip" 2>/dev/null || true
            fi
            ;;
        whitelist-show)
            if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
                print_error "配置文件不存在: ${F2B_JAIL_LOCAL}"
                exit 1
            fi
            local wl
            wl=$(grep -E "^ignoreip\s*=" "$F2B_JAIL_LOCAL" | head -1 | sed 's/^ignoreip\s*=\s*//')
            echo -e "${BOLD}白名单:${NC}"
            for ip in $wl; do
                echo -e "  ${GREEN}[OK] ${ip}${NC}"
            done
            ;;
        log)
            local lines="${1:-50}"
            if [[ -f "$F2B_LOG" ]]; then
                tail -"$lines" "$F2B_LOG"
            else
                journalctl -u fail2ban --no-pager -n "$lines"
            fi
            ;;
        test)
            local filter="${1:-}"
            local logfile="${2:-}"
            if [[ -z "$filter" || -z "$logfile" ]]; then
                print_error "用法: $(basename "$0") test <filter> <logfile>"
                exit 1
            fi
            if [[ ! -f "${F2B_FILTER_D}/${filter}.conf" ]]; then
                print_error "Filter 不存在: ${filter}"
                exit 1
            fi
            if [[ ! -f "$logfile" ]]; then
                print_error "日志文件不存在: ${logfile}"
                exit 1
            fi
            fail2ban-regex "$logfile" "${F2B_FILTER_D}/${filter}.conf"
            ;;
        help|--help|-h)
            show_cli_help
            ;;
        *)
            print_error "未知命令: ${cmd}"
            show_cli_help
            exit 1
            ;;
    esac
}

# ==================== 入口 ====================

main() {
    check_root
    check_os

    if [[ $# -gt 0 ]]; then
        handle_cli "$@"
    else
        main_menu
    fi
}

main "$@"
