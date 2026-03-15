#!/bin/bash

#===============================================================================
# SmartDNS 一键安装与配置脚本
# 支持系统: Ubuntu/Debian, CentOS/RHEL/Fedora, Arch Linux, Alpine Linux
# 功能: 安装、配置、卸载、更新 SmartDNS
#===============================================================================

set -euo pipefail

# ======================== 全局变量 ========================
SMARTDNS_VERSION="Release46"
SMARTDNS_CONF="/etc/smartdns/smartdns.conf"
SMARTDNS_CONF_DIR="/etc/smartdns"
SMARTDNS_INSTALL_DIR="/usr/sbin"
SMARTDNS_SERVICE="/etc/systemd/system/smartdns.service"
LOG_FILE="/var/log/smartdns-install.log"
BACKUP_DIR="/etc/smartdns/backup"
RELEASE_ASSET_URLS=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ======================== 工具函数 ========================

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$LOG_FILE" 2>/dev/null || true
}

print_msg() {
    echo -e "${GREEN}[✓]${NC} $*"
    log "INFO: $*"
}

print_warn() {
    echo -e "${YELLOW}[⚠]${NC} $*"
    log "WARN: $*"
}

print_error() {
    echo -e "${RED}[✗]${NC} $*"
    log "ERROR: $*"
}

print_info() {
    echo -e "${BLUE}[ℹ]${NC} $*"
    log "INFO: $*"
}

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'BANNER'
  ____                       _   ____  _   _ ____
 / ___| _ __ ___   __ _ _ __| |_|  _ \| \ | / ___|
 \___ \| '_ ` _ \ / _` | '__| __| | | |  \| \___ \
  ___) | | | | | | (_| | |  | |_| |_| | |\  |___) |
 |____/|_| |_| |_|\__,_|_|   \__|____/|_| \_|____/

        一键安装与配置脚本 v2.0
BANNER
    echo -e "${NC}"
    echo -e "${PURPLE}=================================================${NC}"
    echo ""
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        local action="${1:-此操作}"
        print_error "${action}需要 root 权限运行"
        print_info "请使用 sudo 重新运行脚本，或切换到 root 后重试"
        return 1
    fi

    return 0
}

# 检查 systemd 是否可用 (命令存在且当前系统由 systemd 管理)
has_systemd() {
    command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]
}

# 确保配置目录存在
ensure_config_dir() {
    mkdir -p "$SMARTDNS_CONF_DIR"
}

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

pause_screen() {
    if ! is_interactive; then
        return 0
    fi

    echo ""
    read -rp "按回车键继续..." _pause_input
}

prompt_confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local hint input normalized

    if [[ "${default^^}" == "Y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    while true; do
        if is_interactive; then
            read -rp "${prompt} ${hint}: " input
            input="${input:-$default}"
        else
            input="$default"
        fi

        normalized="${input,,}"
        case "$normalized" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                print_warn "请输入 y 或 n"
                ;;
        esac
    done
}

prompt_menu_choice() {
    local __resultvar="$1"
    local prompt="$2"
    local valid_regex="$3"
    local default="${4:-}"
    local input prompt_text="$prompt"

    if [[ -n "$default" ]]; then
        prompt_text="${prompt} [默认: ${default}]"
    fi

    while true; do
        if is_interactive; then
            read -rp "${prompt_text}: " input
            if [[ -n "$default" && -z "$input" ]]; then
                input="$default"
            fi
        elif [[ -n "$default" ]]; then
            input="$default"
        else
            print_error "当前为非交互环境，无法继续等待输入"
            return 1
        fi

        if [[ "$input" =~ $valid_regex ]]; then
            printf -v "$__resultvar" '%s' "$input"
            return 0
        fi

        print_warn "输入无效，请重新输入"
    done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

is_valid_ipv4() {
    local ip="$1"
    local IFS=.
    local octets

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "$ip"

    for octet in "${octets[@]}"; do
        [[ "$octet" -le 255 ]] || return 1
    done

    return 0
}

is_valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_valid_group_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

ensure_main_config_exists() {
    if [[ -f "$SMARTDNS_CONF" ]]; then
        return 0
    fi

    print_warn "未找到主配置文件: $SMARTDNS_CONF"
    print_info "请先执行快速安装，或在“高级配置 -> 重置为默认配置”中生成模板"
    return 1
}

open_text_editor() {
    local target_file="$1"
    local editor_cmd=""

    if [[ -n "${EDITOR:-}" ]]; then
        editor_cmd="${EDITOR%% *}"
        if command -v "$editor_cmd" &>/dev/null; then
            "$editor_cmd" "$target_file"
            return $?
        fi
    fi

    for editor_cmd in nano vim vi; do
        if command -v "$editor_cmd" &>/dev/null; then
            "$editor_cmd" "$target_file"
            return $?
        fi
    done

    print_error "没有找到可用的文本编辑器"
    print_info "请安装 nano/vim，或设置 EDITOR 环境变量"
    return 1
}

get_config_template_name() {
    case "$1" in
        basic)
            echo "基础配置"
            ;;
        china)
            echo "国内优化配置"
            ;;
        simple|default)
            echo "默认配置（无分组）"
            ;;
        *)
            echo "当前配置"
            ;;
    esac
}

show_config_summary() {
    local template_name="${1:-当前配置}"
    local listen_port upstream_count doh_count dot_count

    ensure_main_config_exists || return 1

    listen_port=$(grep -E '^bind' "$SMARTDNS_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)
    listen_port="${listen_port:-53}"
    upstream_count=$(grep -cE '^[[:space:]]*server([[:space:]]|-(https|tls)($|[[:space:]]))' "$SMARTDNS_CONF" 2>/dev/null || true)
    upstream_count="${upstream_count:-0}"
    doh_count=$(grep -cE '^[[:space:]]*server-https[[:space:]]+' "$SMARTDNS_CONF" 2>/dev/null || true)
    doh_count="${doh_count:-0}"
    dot_count=$(grep -cE '^[[:space:]]*server-tls[[:space:]]+' "$SMARTDNS_CONF" 2>/dev/null || true)
    dot_count="${dot_count:-0}"

    echo ""
    echo -e "${CYAN}=========== 配置摘要 ===========${NC}"
    echo "  模板: ${template_name}"
    echo "  配置文件: ${SMARTDNS_CONF}"
    echo "  监听端口: ${listen_port}"
    echo "  上游 DNS: ${upstream_count} 个"
    echo "  加密 DNS: DOH ${doh_count} 个 / DOT ${dot_count} 个"
    echo -e "${CYAN}================================${NC}"
}

select_config_template() {
    local __resultvar="$1"
    local prompt="${2:-请选择配置模板}"
    local default_choice="${3:-3}"
    local template_choice

    echo ""
    echo "  1) 基础配置         双组分流模板，适合需要手动分流"
    echo "  2) 国内优化配置     内置常见海外域名分流"
    echo "  3) 默认配置(无分组) 最简默认模板，适合快速安装"

    prompt_menu_choice template_choice "$prompt" '^[1-3]$' "$default_choice" || return 1

    case "$template_choice" in
        1)
            printf -v "$__resultvar" '%s' "basic"
            ;;
        2)
            printf -v "$__resultvar" '%s' "china"
            ;;
        3)
            printf -v "$__resultvar" '%s' "simple"
            ;;
    esac
}

apply_config_template() {
    local template_key="${1:-simple}"
    local template_name
    template_name=$(get_config_template_name "$template_key")

    case "$template_key" in
        basic)
            generate_basic_config
            ;;
        china)
            generate_china_optimized_config
            ;;
        simple|default)
            generate_simple_config
            ;;
        *)
            print_error "未知配置模板: ${template_key}"
            return 1
            ;;
    esac

    print_info "已应用模板: ${template_name}"
    show_config_summary "$template_name"
}

run_menu_action() {
    local action_name="$1"
    local permission="${2:-readonly}"
    shift 2

    echo ""
    echo -e "${CYAN}>>> ${action_name}${NC}"

    if [[ "$permission" == "root" ]] && ! check_root "$action_name"; then
        pause_screen
        return 1
    fi

    if ! "$@"; then
        print_warn "${action_name}未完全执行，请查看上方提示"
    fi

    pause_screen
}

# 安全更新 crontab：删除匹配项并可选追加一条任务
update_crontab_excluding() {
    local pattern="$1"
    local append_line="${2:-}"
    local current filtered final

    current=$(crontab -l 2>/dev/null || true)
    filtered=$(printf '%s\n' "$current" | grep -Ev "$pattern" || true)

    if [[ -n "$append_line" ]]; then
        final=$(printf '%s\n%s\n' "$filtered" "$append_line" | sed '/^[[:space:]]*$/d')
    else
        final=$(printf '%s\n' "$filtered" | sed '/^[[:space:]]*$/d')
    fi

    if [[ -n "$final" ]]; then
        printf '%s\n' "$final" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi
}

# 检测系统架构
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            ARCH="x86_64"
            PKG_ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="aarch64"
            PKG_ARCH="arm64"
            ;;
        armv7l|armhf)
            ARCH="armv7l"
            PKG_ARCH="armhf"
            ;;
        armv6l)
            ARCH="armv6l"
            PKG_ARCH="armel"
            ;;
        mips|mipsel|mips64|mips64el)
            ARCH="$arch"
            PKG_ARCH="$arch"
            ;;
        *)
            print_error "不支持的系统架构: $arch"
            exit 1
            ;;
    esac
    print_info "系统架构: $ARCH"
}

# 检测操作系统
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID,,}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-$ID}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="centos"
        OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        OS_NAME=$(cat /etc/redhat-release)
    else
        print_error "无法检测操作系统类型"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop|deepin|kali)
            OS_TYPE="debian"
            PKG_MGR="apt"
            ;;
        centos|rhel|rocky|almalinux|ol|fedora|amzn)
            OS_TYPE="redhat"
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        arch|manjaro|endeavouros)
            OS_TYPE="arch"
            PKG_MGR="pacman"
            ;;
        alpine)
            OS_TYPE="alpine"
            PKG_MGR="apk"
            ;;
        opensuse*|sles)
            OS_TYPE="suse"
            PKG_MGR="zypper"
            ;;
        *)
            print_warn "未知的操作系统: $OS_ID, 将尝试通用安装"
            OS_TYPE="unknown"
            ;;
    esac

    print_info "操作系统: $OS_NAME"
    print_info "包管理器: ${PKG_MGR:-unknown}"
}

# 检查网络连接
check_network() {
    print_info "检查网络连接..."
    local test_urls=("github.com" "raw.githubusercontent.com" "google.com")
    local connected=false

    for url in "${test_urls[@]}"; do
        if ping -c 1 -W 3 "$url" &>/dev/null || curl -s --connect-timeout 5 "https://$url" &>/dev/null; then
            connected=true
            break
        fi
    done

    if ! $connected; then
        print_warn "网络连接可能存在问题，安装过程可能会失败"
        if ! prompt_confirm "是否继续安装流程?" "N"; then
            print_info "已取消当前流程"
            return 1
        fi
    else
        print_msg "网络连接正常"
    fi
}

# 安装依赖
install_dependencies() {
    print_info "安装依赖包..."

    case "$OS_TYPE" in
        debian)
            apt-get update -qq
            apt-get install -y -qq curl wget tar gzip openssl ca-certificates \
                libssl-dev dnsutils 2>/dev/null || true
            ;;
        redhat)
            $PKG_MGR install -y -q curl wget tar gzip openssl ca-certificates \
                bind-utils 2>/dev/null || true
            ;;
        arch)
            pacman -Sy --noconfirm --needed curl wget tar gzip openssl \
                ca-certificates bind-tools 2>/dev/null || true
            ;;
        alpine)
            apk update
            apk add --no-cache curl wget tar gzip openssl ca-certificates \
                bind-tools 2>/dev/null || true
            ;;
        suse)
            zypper --non-interactive install curl wget tar gzip openssl \
                ca-certificates bind-utils 2>/dev/null || true
            ;;
    esac

    print_msg "依赖安装完成"
}

# ======================== 安装函数 ========================

# 获取最新版本号
get_latest_version() {
    print_info "获取 SmartDNS 最新版本..."
    local latest
    latest=$(curl -sL "https://api.github.com/repos/pymumu/smartdns/releases/latest" \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')

    if [[ -n "$latest" ]]; then
        SMARTDNS_VERSION="$latest"
        print_msg "最新版本: $SMARTDNS_VERSION"
    else
        print_warn "无法获取最新版本，使用默认版本: $SMARTDNS_VERSION"
    fi
}

# 获取发布资产下载链接列表
fetch_release_asset_urls() {
    if [[ -n "${RELEASE_ASSET_URLS:-}" ]]; then
        return 0
    fi

    local release_api release_json
    release_api="https://api.github.com/repos/pymumu/smartdns/releases/tags/${SMARTDNS_VERSION}"
    release_json=$(curl -fsSL "$release_api" 2>/dev/null || true)

    # 标签接口失败时，回退到 latest，尽量保证可用
    if [[ -z "$release_json" ]]; then
        release_api="https://api.github.com/repos/pymumu/smartdns/releases/latest"
        release_json=$(curl -fsSL "$release_api" 2>/dev/null || true)
    fi

    RELEASE_ASSET_URLS=$(printf '%s\n' "$release_json" \
        | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)".*/\1/' || true)

    [[ -n "${RELEASE_ASSET_URLS:-}" ]]
}

# 按关键字从发布资产中匹配下载链接
resolve_release_asset_url() {
    local asset_url keyword

    if ! fetch_release_asset_urls; then
        return 1
    fi

    for keyword in "$@"; do
        asset_url=$(printf '%s\n' "$RELEASE_ASSET_URLS" | grep -F "$keyword" | head -1 || true)
        if [[ -n "$asset_url" ]]; then
            echo "$asset_url"
            return 0
        fi
    done

    return 1
}

# 下载 SmartDNS
download_smartdns() {
    local download_url
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # 优先从 release assets 自动匹配，兼容新旧文件命名
    if ! download_url=$(resolve_release_asset_url "${ARCH}-linux-all.tar.gz"); then
        download_url="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_VERSION}/smartdns.${ARCH}-linux-all.tar.gz"
        print_warn "未匹配到发布资产，尝试兼容旧命名下载"
    fi

    print_info "下载 SmartDNS ${SMARTDNS_VERSION}..."
    print_info "下载地址: $download_url"

    # 尝试下载
    if ! wget -q --show-progress -O "${tmp_dir}/smartdns.tar.gz" "$download_url" 2>/dev/null; then
        # 尝试备用方式
        if ! curl -fSL --progress-bar -o "${tmp_dir}/smartdns.tar.gz" "$download_url"; then
            print_error "下载失败！"
            print_info "请检查网络连接或手动下载:"
            print_info "  $download_url"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    # 验证下载文件
    if [[ ! -f "${tmp_dir}/smartdns.tar.gz" ]] || [[ $(stat -c%s "${tmp_dir}/smartdns.tar.gz" 2>/dev/null || stat -f%z "${tmp_dir}/smartdns.tar.gz" 2>/dev/null) -lt 1000 ]]; then
        print_error "下载的文件无效"
        rm -rf "$tmp_dir"
        return 1
    fi

    DOWNLOAD_DIR="$tmp_dir"
    print_msg "下载完成"
}

# 安装 SmartDNS (通用方式)
install_smartdns_generic() {
    print_info "安装 SmartDNS..."

    cd "$DOWNLOAD_DIR"

    # 解压
    tar -xzf smartdns.tar.gz
    local extract_dir
    extract_dir=$(tar -tzf smartdns.tar.gz 2>/dev/null | cut -d/ -f1 | grep -vE '^\.$|^$' | head -1 || true)
    if [[ -n "$extract_dir" ]] && [[ -d "$extract_dir" ]]; then
        cd "$extract_dir"
    else
        # 兼容目录名变化
        extract_dir=$(find . -maxdepth 2 -type d -name "smartdns*" 2>/dev/null | head -1 || true)
        if [[ -n "$extract_dir" ]]; then
            cd "$extract_dir"
        else
            print_error "无法识别 SmartDNS 解压目录"
            return 1
        fi
    fi

    # 查找并执行安装脚本
    if [[ -f "install" ]]; then
        chmod +x install
        bash install -i
    else
        # 手动安装
        print_info "使用手动方式安装..."

        # 查找 smartdns 二进制文件
        local binary_file
        binary_file=$(find . -name "smartdns" -type f -executable 2>/dev/null | head -1)
        if [[ -z "$binary_file" ]]; then
            binary_file=$(find . -name "smartdns" -type f 2>/dev/null | head -1)
        fi

        if [[ -z "$binary_file" ]]; then
            print_error "找不到 SmartDNS 二进制文件"
            return 1
        fi

        # 安装二进制文件
        install -m 0755 "$binary_file" "${SMARTDNS_INSTALL_DIR}/smartdns"

        # 创建配置目录
        mkdir -p "$SMARTDNS_CONF_DIR"

        # 安装默认配置
        if [[ -f "etc/smartdns/smartdns.conf" ]] && [[ ! -f "$SMARTDNS_CONF" ]]; then
            cp "etc/smartdns/smartdns.conf" "$SMARTDNS_CONF"
        fi

        # 统一使用脚本维护的兼容 systemd 服务文件
        create_systemd_service
    fi

    # 清理
    cd /
    rm -rf "$DOWNLOAD_DIR"

    print_msg "SmartDNS 安装完成"
}

# 使用包管理器安装 (Debian/Ubuntu)
install_smartdns_deb() {
    local deb_url
    if ! deb_url=$(resolve_release_asset_url "${ARCH}-debian-all.deb" "${PKG_ARCH}-debian-all.deb"); then
        deb_url="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_VERSION}/smartdns.${ARCH}-debian-all.deb"
        print_warn "未匹配到 deb 资产，尝试兼容旧命名下载"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    print_info "下载 SmartDNS deb 包..."
    if wget -q --show-progress -O "${tmp_dir}/smartdns.deb" "$deb_url" 2>/dev/null || \
       curl -fSL --progress-bar -o "${tmp_dir}/smartdns.deb" "$deb_url"; then
        print_info "安装 deb 包..."
        dpkg -i "${tmp_dir}/smartdns.deb" || apt-get install -f -y

        # deb 包通常自带 systemd 单元；若存在，移除旧的自定义单元避免覆盖
        if has_systemd; then
            if [[ -f /lib/systemd/system/smartdns.service ]] || [[ -f /usr/lib/systemd/system/smartdns.service ]]; then
                if [[ -f "$SMARTDNS_SERVICE" ]]; then
                    rm -f "$SMARTDNS_SERVICE"
                    print_info "已移除旧版自定义服务文件，使用系统自带 smartdns.service"
                fi
            else
                create_systemd_service
            fi
            systemctl daemon-reload
        fi
        rm -rf "$tmp_dir"
        print_msg "SmartDNS deb 包安装完成"
    else
        print_warn "deb 包下载失败，使用通用方式安装"
        rm -rf "$tmp_dir"
        download_smartdns && install_smartdns_generic
    fi
}

# 创建 systemd 服务文件
create_systemd_service() {
    cat > "$SMARTDNS_SERVICE" << 'EOF'
[Unit]
Description=SmartDNS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/smartdns
ExecStartPre=/bin/rm -f /run/smartdns.pid
ExecStart=/usr/sbin/smartdns -f -c /etc/smartdns/smartdns.conf -p /run/smartdns.pid
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    if has_systemd; then
        systemctl daemon-reload
        print_msg "systemd 服务文件已创建"
    else
        print_warn "未检测到可用 systemd，已写入服务文件但未执行 daemon-reload"
    fi
}

# 修复旧版不兼容的 systemd 单元
repair_systemd_service_if_needed() {
    if [[ -f "$SMARTDNS_SERVICE" ]] && grep -q '^Type=forking' "$SMARTDNS_SERVICE"; then
        print_warn "检测到旧版 systemd 服务文件，正在自动修复..."
        create_systemd_service
    fi
}

# ======================== 配置函数 ========================

# 备份配置
backup_config() {
    if [[ -f "$SMARTDNS_CONF" ]]; then
        mkdir -p "$BACKUP_DIR"
        local backup_file="${BACKUP_DIR}/smartdns.conf.$(date +%Y%m%d_%H%M%S).bak"
        cp "$SMARTDNS_CONF" "$backup_file"
        print_msg "配置已备份至: $backup_file"
    fi
}

# 生成基础配置
generate_basic_config() {
    backup_config
    ensure_config_dir

    cat > "$SMARTDNS_CONF" << 'EOF'
# SmartDNS 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# ==================== 服务器基础设置 ====================

# 服务器名称
server-name smartdns

# DNS 监听端口 (默认53, 如果53被占用可以改为5353等)
bind [::]:53
# bind-tcp [::]:53

# 日志设置
# 日志级别: debug, info, notice, warn, error, fatal, off
log-level info
# log-file /var/log/smartdns/smartdns.log
# log-size 128k
# log-num 2

# 审计日志 (记录所有DNS查询)
# audit-enable yes
# audit-file /var/log/smartdns/smartdns-audit.log
# audit-size 128k
# audit-num 2

# ==================== 缓存设置 ====================

# 缓存大小 (条目数)
cache-size 4096

# 持久化缓存 (重启后保留缓存)
cache-persist yes
cache-file /etc/smartdns/smartdns.cache
cache-checkpoint-time 86400

# 预获取域名 (缓存即将过期时自动刷新)
prefetch-domain yes

# 过期缓存服务 (缓存过期后仍然返回旧结果，同时后台刷新)
serve-expired yes
serve-expired-ttl 259200
serve-expired-reply-ttl 3
# serve-expired-prefetch-time 21600

# ==================== 速度优化设置 ====================

# 测速模式 (ping, tcp:port, none)
speed-check-mode ping,tcp:80,tcp:443

# 双栈 IP 优选 (优先返回响应快的IP)
dualstack-ip-selection yes
dualstack-ip-selection-threshold 15

# 强制 AAAA 地址返回 SOA (如不需要IPv6解析可开启)
# force-AAAA-SOA yes

# ==================== 上游 DNS 服务器 ====================

# ---------- 国内 DNS 组 (china，1.1.1.1 优先) ----------

# Cloudflare DNS (按你的要求优先)
server 1.1.1.1 -group china -exclude-default-group
server 1.0.0.1 -group china -exclude-default-group

# 阿里 DNS
server 223.5.5.5 -group china -exclude-default-group
server 223.6.6.6 -group china -exclude-default-group

# 腾讯 DNS (DNSPod)
server 119.29.29.29 -group china -exclude-default-group
server 119.28.28.28 -group china -exclude-default-group

# Cloudflare DNS over HTTPS
server-https https://cloudflare-dns.com/dns-query -group china -exclude-default-group
# 阿里 DNS over HTTPS
server-https https://dns.alidns.com/dns-query -group china -exclude-default-group
# 腾讯 DNS over HTTPS
server-https https://doh.pub/dns-query -group china -exclude-default-group

# Cloudflare DNS over TLS
server-tls 1.1.1.1 -group china -exclude-default-group
# 阿里 DNS over TLS
server-tls dns.alidns.com -group china -exclude-default-group
# 腾讯 DNS over TLS
server-tls dot.pub -group china -exclude-default-group

# ---------- 国外 DNS 组 (overseas) ----------

# Cloudflare DNS
server 1.1.1.1 -group overseas -exclude-default-group
server 1.0.0.1 -group overseas -exclude-default-group

# Google DNS
server 8.8.8.8 -group overseas -exclude-default-group
server 8.8.4.4 -group overseas -exclude-default-group

# Cloudflare DNS over HTTPS
server-https https://cloudflare-dns.com/dns-query -group overseas -exclude-default-group
# Google DNS over HTTPS
server-https https://dns.google/dns-query -group overseas -exclude-default-group

# Cloudflare DNS over TLS
server-tls 1.1.1.1 -group overseas -exclude-default-group
# Google DNS over TLS
server-tls dns.google -group overseas -exclude-default-group

# ==================== 域名分流规则 ====================

# 国内域名使用国内 DNS
# nameserver /cn/china
# nameserver /baidu.com/china
# nameserver /taobao.com/china
# nameserver /jd.com/china
# nameserver /qq.com/china
# nameserver /weixin.com/china
# nameserver /alipay.com/china
# nameserver /bilibili.com/china
# nameserver /163.com/china
# nameserver /tmall.com/china

# 国外域名使用国外 DNS
# nameserver /google.com/overseas
# nameserver /youtube.com/overseas
# nameserver /facebook.com/overseas
# nameserver /twitter.com/overseas
# nameserver /github.com/overseas
# nameserver /amazonaws.com/overseas
# nameserver /cloudflare.com/overseas

# ==================== 域名规则文件 ====================

# 如需更精细的分流，可以使用域名列表文件
# conf-file /etc/smartdns/china-list.conf
# conf-file /etc/smartdns/gfw-list.conf
# conf-file /etc/smartdns/custom.conf

# ==================== 其他设置 ====================

# 最大回复 IP 数
max-reply-ip-num 3

# TTL 设置
rr-ttl-min 60
rr-ttl-max 86400
# rr-ttl-reply-max 60

# 设置 hosts 文件
# bogus-nxdomain 1.2.3.4
# blacklist-ip 1.2.3.4

# 自定义 hosts
# address /example.com/1.2.3.4
# address /ad.example.com/#  (屏蔽域名)
EOF

    # 替换日期
    sed -i "s|\$(date '+%Y-%m-%d %H:%M:%S')|$(date '+%Y-%m-%d %H:%M:%S')|g" "$SMARTDNS_CONF" 2>/dev/null || true

    print_msg "基础配置已生成: $SMARTDNS_CONF"
}

# 生成国内优化配置
generate_china_optimized_config() {
    backup_config
    ensure_config_dir

    cat > "$SMARTDNS_CONF" << 'EOF'
# SmartDNS 国内优化配置
# 适用于中国大陆用户，优化国内外DNS解析

server-name smartdns

# 监听设置
bind [::]:53
# bind-tcp [::]:53

# 日志
log-level warn

# 缓存
cache-size 8192
cache-persist yes
cache-file /etc/smartdns/smartdns.cache
cache-checkpoint-time 86400
prefetch-domain yes
serve-expired yes
serve-expired-ttl 259200
serve-expired-reply-ttl 3

# 测速
speed-check-mode ping,tcp:80,tcp:443
dualstack-ip-selection yes
dualstack-ip-selection-threshold 15

# TTL
rr-ttl-min 60
rr-ttl-max 86400

# Max reply IP
max-reply-ip-num 3

# ========== 默认 DNS (含 1.1.1.1 / 8.8.8.8 / 223.5.5.5) ==========
server 1.1.1.1
server 1.0.0.1
server 8.8.8.8
server 223.5.5.5
server 223.6.6.6
server 119.29.29.29
server 119.28.28.28
server 114.114.114.114
server 180.76.76.76
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
server-https https://dns.alidns.com/dns-query
server-https https://doh.pub/dns-query

# ========== 国外 DNS (overseas 组) ==========
server 1.1.1.1 -group overseas -exclude-default-group
server 8.8.8.8 -group overseas -exclude-default-group
server 208.67.222.222 -group overseas -exclude-default-group
server-https https://cloudflare-dns.com/dns-query -group overseas -exclude-default-group
server-https https://dns.google/dns-query -group overseas -exclude-default-group
server-tls 1.1.1.1 -group overseas -exclude-default-group

# ========== 国外域名走 overseas 组 ==========
nameserver /google.com/overseas
nameserver /google.com.hk/overseas
nameserver /google.co.jp/overseas
nameserver /googleapis.com/overseas
nameserver /googleusercontent.com/overseas
nameserver /gstatic.com/overseas
nameserver /youtube.com/overseas
nameserver /ytimg.com/overseas
nameserver /youtu.be/overseas
nameserver /facebook.com/overseas
nameserver /fbcdn.net/overseas
nameserver /twitter.com/overseas
nameserver /twimg.com/overseas
nameserver /t.co/overseas
nameserver /instagram.com/overseas
nameserver /whatsapp.com/overseas
nameserver /github.com/overseas
nameserver /githubusercontent.com/overseas
nameserver /github.io/overseas
nameserver /githubassets.com/overseas
nameserver /stackoverflow.com/overseas
nameserver /wikipedia.org/overseas
nameserver /wikimedia.org/overseas
nameserver /amazonaws.com/overseas
nameserver /cloudflare.com/overseas
nameserver /cloudfront.net/overseas
nameserver /docker.com/overseas
nameserver /docker.io/overseas
nameserver /netflix.com/overseas
nameserver /nflxvideo.net/overseas
nameserver /spotify.com/overseas
nameserver /telegram.org/overseas
nameserver /telegram.me/overseas
nameserver /t.me/overseas
nameserver /reddit.com/overseas
nameserver /redd.it/overseas
nameserver /medium.com/overseas
nameserver /linkedin.com/overseas
nameserver /apple.com/overseas
nameserver /icloud.com/overseas
nameserver /microsoft.com/overseas
nameserver /live.com/overseas
nameserver /office.com/overseas
nameserver /office365.com/overseas
nameserver /outlook.com/overseas
nameserver /openai.com/overseas
nameserver /chatgpt.com/overseas
nameserver /anthropic.com/overseas
nameserver /claude.ai/overseas
nameserver /npmjs.com/overseas
nameserver /pypi.org/overseas
EOF

    print_msg "国内优化配置已生成"
}

# 生成默认配置（无分组）
generate_simple_config() {
    backup_config
    ensure_config_dir

    cat > "$SMARTDNS_CONF" << 'EOF'
# SmartDNS 默认配置（无分组）

server-name smartdns
bind [::]:53
log-level warn

# 缓存
cache-size 4096
cache-persist yes
cache-file /etc/smartdns/smartdns.cache
prefetch-domain yes
serve-expired yes

# 测速
speed-check-mode ping,tcp:80,tcp:443
response-mode fastest-ip
max-reply-ip-num 1

# 上游 DNS（默认无分组）
# 明文 DNS
server 1.1.1.1
server 8.8.8.8
server 9.9.9.9
server 223.5.5.5

# DNS over HTTPS
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
server-https https://dns.alidns.com/dns-query

# DNS over TLS
server-tls 1.1.1.1
server-tls dns.google
server-tls dns.alidns.com

# TTL
rr-ttl-min 60
rr-ttl-max 86400
EOF

    print_msg "默认配置已生成"
}

# 生成广告过滤配置
generate_adblock_config() {
    print_info "生成广告过滤规则..."

    ensure_main_config_exists || return 1

    local adblock_conf="${SMARTDNS_CONF_DIR}/anti-ad.conf"
    ensure_config_dir

    # 下载 anti-ad 规则
    if curl -fSL -o "$adblock_conf" \
        "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-smartdns.conf" 2>/dev/null; then
        print_msg "anti-ad 规则下载成功"
    else
        print_warn "anti-ad 规则下载失败，创建基本规则..."
        cat > "$adblock_conf" << 'EOF'
# 基本广告域名屏蔽
address /ad.doubleclick.net/#
address /pagead2.googlesyndication.com/#
address /adservice.google.com/#
address /analytics.google.com/#
address /ads.facebook.com/#
address /pixel.facebook.com/#
address /ads.twitter.com/#
address /analytics.twitter.com/#
address /ads.yahoo.com/#
address /adlog.com.com/#
address /cpro.baidu.com/#
address /pos.baidu.com/#
address /cbjs.baidu.com/#
address /eclick.baidu.com/#
address /hmma.baidu.com/#
address /hm.baidu.com/#
address /cpro.baidustatic.com/#
address /images.sohu.com/#
address /atanx.alicdn.com/#
address /acs.m.taobao.com/#
address /gma.alicdn.com/#
address /ad.sina.com.cn/#
address /ads.sina.com/#
address /beacon.sina.com.cn/#
EOF
    fi

    # 添加引用到主配置
    if ! grep -q "anti-ad" "$SMARTDNS_CONF" 2>/dev/null; then
        echo "" >> "$SMARTDNS_CONF"
        echo "# 广告过滤规则" >> "$SMARTDNS_CONF"
        echo "conf-file /etc/smartdns/anti-ad.conf" >> "$SMARTDNS_CONF"
        print_msg "广告过滤规则已添加到配置"
    fi
}

# 生成自定义 hosts
create_custom_hosts() {
    ensure_main_config_exists || return 1

    local custom_conf="${SMARTDNS_CONF_DIR}/custom-hosts.conf"
    ensure_config_dir

    if [[ ! -f "$custom_conf" ]]; then
        cat > "$custom_conf" << 'EOF'
# 自定义 hosts 记录
# 格式: address /域名/IP地址
# 屏蔽域名: address /域名/#

# 示例:
# address /myserver.local/192.168.1.100
# address /nas.local/192.168.1.200
# address /blocked-site.com/#
EOF

        # 添加引用到主配置
        if ! grep -q "custom-hosts" "$SMARTDNS_CONF" 2>/dev/null; then
            echo "" >> "$SMARTDNS_CONF"
            echo "# 自定义 hosts" >> "$SMARTDNS_CONF"
            echo "conf-file /etc/smartdns/custom-hosts.conf" >> "$SMARTDNS_CONF"
        fi

        print_msg "自定义 hosts 文件已创建: $custom_conf"
    fi
}

# ======================== 端口与服务管理 ========================

# 检查端口占用
check_port_conflict() {
    local port="${1:-53}"

    print_info "检查端口 ${port} 占用情况..."

    local has_tool=false
    local conflict=false
    local service=""

    if command -v ss &>/dev/null; then
        has_tool=true
        if ss -tulnp 2>/dev/null | grep -q ":${port} "; then
            conflict=true
            service=$(ss -tulnp 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
        fi
    fi

    if ! $conflict && command -v netstat &>/dev/null; then
        has_tool=true
        if netstat -tulnp 2>/dev/null | grep -q ":${port} "; then
            conflict=true
            service=$(netstat -tulnp 2>/dev/null | grep ":${port} " | awk '{print $7}' | head -1 || true)
        fi
    fi

    if ! $conflict && command -v lsof &>/dev/null; then
        has_tool=true
        if lsof -i :"${port}" 2>/dev/null | awk 'NR>1{print; exit}' | grep -q .; then
            conflict=true
            service=$(lsof -i :"${port}" 2>/dev/null | tail -1 | awk '{print $1}' || true)
        fi
    fi

    if ! $has_tool; then
        print_warn "未找到端口检测工具 (ss/netstat/lsof)，跳过端口占用检查"
        return 0
    fi

    if $conflict; then
        [[ -z "$service" ]] && service="unknown"
        print_warn "端口 ${port} 已被 ${service} 占用"
        return 1
    fi

    print_msg "端口 ${port} 可用"
    return 0
}

# 处理端口冲突
resolve_port_conflict() {
    local port="${1:-53}"
    local choice custom_port

    if ! check_port_conflict "$port"; then
        echo ""
        echo -e "${YELLOW}检测到端口 ${port} 被占用，请选择处理方式:${NC}"
        echo "  1) 停用 systemd-resolved (推荐，适用于 Ubuntu/Debian)"
        echo "  2) 修改 SmartDNS 监听端口为 5353"
        echo "  3) 修改 SmartDNS 监听端口为 6053"
        echo "  4) 自定义端口"
        echo "  5) 跳过 (手动处理)"
        echo ""

        prompt_menu_choice choice "请选择处理方式 [1-5]" '^[1-5]$' "1" || return 1

        case "$choice" in
            1)
                disable_systemd_resolved
                ;;
            2)
                change_listen_port 5353
                ;;
            3)
                change_listen_port 6053
                ;;
            4)
                while true; do
                    if is_interactive; then
                        read -rp "请输入自定义端口号 (1024-65535): " custom_port
                    else
                        custom_port="5353"
                    fi

                    if [[ "$custom_port" =~ ^[0-9]+$ ]] && [[ "$custom_port" -ge 1024 ]] && [[ "$custom_port" -le 65535 ]]; then
                        change_listen_port "$custom_port"
                        break
                    fi

                    print_warn "端口号必须在 1024-65535 之间"
                done
                ;;
            5)
                print_warn "已跳过端口冲突处理，请稍后手动处理监听端口或系统 DNS"
                ;;
        esac
    fi
}

# 停用 systemd-resolved
disable_systemd_resolved() {
    print_info "停用 systemd-resolved..."

    if has_systemd; then
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
            print_msg "systemd-resolved 已停用"
        fi
    else
        print_warn "当前系统未使用 systemd，跳过 systemd-resolved 停用"
    fi

    # 处理 /etc/resolv.conf
    if command -v chattr &>/dev/null; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi

    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi

    # 创建临时 resolv.conf
    cat > /etc/resolv.conf << 'EOF'
# Generated by SmartDNS install script
nameserver 127.0.0.1
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 9.9.9.9
nameserver 223.5.5.5
EOF
    print_msg "/etc/resolv.conf 已更新"
}


# 修改监听端口
change_listen_port() {
    local new_port="$1"

    if [[ -f "$SMARTDNS_CONF" ]]; then
        sed -i -E "s|^bind[[:space:]]+\\[::\\]:[0-9]+|bind [::]:${new_port}|" "$SMARTDNS_CONF"
        sed -i -E "s|^bind-tcp[[:space:]]+\\[::\\]:[0-9]+|bind-tcp [::]:${new_port}|" "$SMARTDNS_CONF"
        # 也处理 bind :53 这种格式
        sed -i -E "s|^bind[[:space:]]+:[0-9]+|bind :${new_port}|" "$SMARTDNS_CONF"
        print_msg "SmartDNS 监听端口已修改为: ${new_port}"
        print_warn "请注意：你需要在系统中配置 DNS 指向 127.0.0.1:${new_port}"
    fi
}

# 设置系统 DNS
set_system_dns() {
    print_info "设置系统 DNS 为 SmartDNS..."

    ensure_main_config_exists || return 1

    local dns_port
    dns_port=$(grep -E '^bind' "$SMARTDNS_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    dns_port="${dns_port:-53}"

    if [[ "$dns_port" == "53" ]]; then
        if [[ -f /etc/resolv.conf ]] && [[ ! -L /etc/resolv.conf ]]; then
            cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)
        fi

        if command -v chattr &>/dev/null; then
            chattr -i /etc/resolv.conf 2>/dev/null || true
        fi

        if [[ -L /etc/resolv.conf ]]; then
            rm -f /etc/resolv.conf
        fi

        cat > /etc/resolv.conf << EOF
# Generated by SmartDNS
nameserver 127.0.0.1
# Fallback DNS (1.1.1.1 优先)
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 9.9.9.9
nameserver 223.5.5.5
EOF

        if command -v chattr &>/dev/null; then
            chattr +i /etc/resolv.conf 2>/dev/null || true
        fi

        print_msg "系统 DNS 已设置为 127.0.0.1"
        print_info "如后续网络解析异常，可先恢复 /etc/resolv.conf 备份后再排查"
    else
        print_warn "SmartDNS 未监听 53 端口 (当前: ${dns_port})"
        print_info "请手动配置系统 DNS 或使用端口转发"
        print_info "  方法1: 在客户端设置 DNS 为 服务器IP:${dns_port}"
        print_info "  方法2: iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-port ${dns_port}"
        return 1
    fi
}

# ======================== 服务管理 ========================

# 启动 SmartDNS
start_smartdns() {
    print_info "启动 SmartDNS..."

    # 创建日志目录
    mkdir -p /var/log/smartdns 2>/dev/null || true

    if has_systemd; then
        repair_systemd_service_if_needed

        # 清理未受 systemd 管理的残留进程，避免端口/PID 冲突
        if pgrep -x smartdns &>/dev/null && ! systemctl is-active --quiet smartdns 2>/dev/null; then
            print_warn "检测到残留 smartdns 进程，正在清理..."
            pkill -x smartdns 2>/dev/null || true
            rm -f /run/smartdns.pid 2>/dev/null || true
            sleep 1
        fi

        systemctl daemon-reload
        systemctl start smartdns

        if systemctl is-active --quiet smartdns; then
            print_msg "SmartDNS 启动成功"
        else
            print_error "SmartDNS 启动失败"
            print_info "查看错误信息:"
            systemctl status smartdns --no-pager -l 2>/dev/null || true
            journalctl -u smartdns --no-pager -n 20 2>/dev/null || true

            local bind_port
            bind_port=$(grep -E '^bind' "$SMARTDNS_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
            bind_port="${bind_port:-53}"
            check_port_conflict "$bind_port" || true
            return 1
        fi
    elif command -v rc-service &>/dev/null; then
        rc-service smartdns start
    elif command -v service &>/dev/null; then
        service smartdns start
    else
        # 直接启动
        /usr/sbin/smartdns -c "$SMARTDNS_CONF" -p /run/smartdns.pid
    fi
}

# 停止 SmartDNS
stop_smartdns() {
    print_info "停止 SmartDNS..."

    if has_systemd; then
        systemctl stop smartdns 2>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service smartdns stop 2>/dev/null || true
    else
        kill "$(cat /run/smartdns.pid 2>/dev/null)" 2>/dev/null || true
        killall smartdns 2>/dev/null || true
    fi

    print_msg "SmartDNS 已停止"
}

# 重启 SmartDNS
restart_smartdns() {
    stop_smartdns
    sleep 1
    start_smartdns
}

# 设置开机自启
enable_autostart() {
    print_info "设置开机自启..."

    if has_systemd; then
        systemctl enable smartdns
        print_msg "已设置开机自启 (systemd)"
    elif command -v rc-update &>/dev/null; then
        rc-update add smartdns default
        print_msg "已设置开机自启 (OpenRC)"
    elif command -v chkconfig &>/dev/null; then
        chkconfig smartdns on
        print_msg "已设置开机自启 (chkconfig)"
    else
        print_warn "无法自动设置开机自启，请手动配置"
    fi
}

# ======================== 验证与测试 ========================

# 验证配置文件
validate_config() {
    print_info "验证配置文件..."

    if [[ ! -f "$SMARTDNS_CONF" ]]; then
        print_error "配置文件不存在: $SMARTDNS_CONF"
        return 1
    fi

    # 检查配置文件语法 (使用 smartdns 自带检查)
    if command -v smartdns &>/dev/null; then
        if smartdns -c "$SMARTDNS_CONF" -x 2>/dev/null; then
            print_msg "配置文件语法正确"
        else
            print_warn "配置文件可能存在问题，但不一定是致命错误"
        fi
    fi

    # 基本检查
    local bind_count
    bind_count=$(grep -cE '^bind' "$SMARTDNS_CONF" 2>/dev/null || true)
    bind_count="${bind_count:-0}"
    local server_count
    server_count=$(grep -cE '^[[:space:]]*server([[:space:]]|-(https|tls)($|[[:space:]]))' "$SMARTDNS_CONF" 2>/dev/null || true)
    server_count="${server_count:-0}"

    if [[ "$bind_count" -eq 0 ]]; then
        print_error "配置文件中没有 bind 指令"
        return 1
    fi

    if [[ "$server_count" -eq 0 ]]; then
        print_error "配置文件中没有上游 DNS 服务器"
        return 1
    fi

    print_info "  监听配置: ${bind_count} 个"
    print_info "  上游 DNS: ${server_count} 个"

    return 0
}

# DNS 解析测试
test_dns() {
    local port
    port=$(grep -E '^bind' "$SMARTDNS_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    port="${port:-53}"

    echo ""
    echo -e "${CYAN}==================== DNS 解析测试 ====================${NC}"
    echo ""

    local test_domains=("www.baidu.com" "www.google.com" "github.com" "www.taobao.com")
    local success_count=0
    local total=${#test_domains[@]}

    for domain in "${test_domains[@]}"; do
        echo -e "${BLUE}[测试]${NC} $domain"

        local result=""
        local query_output=""
        if command -v dig &>/dev/null; then
            result=$(dig @127.0.0.1 -p "$port" "$domain" +short 2>/dev/null \
                | grep -E '^[0-9A-Fa-f:.]+$' | head -3 || true)
        elif command -v nslookup &>/dev/null; then
            if [[ "$port" == "53" ]]; then
                query_output=$(nslookup "$domain" 127.0.0.1 2>/dev/null || true)
            else
                query_output=$(nslookup -port="$port" "$domain" 127.0.0.1 2>/dev/null || true)
            fi

            result=$(printf '%s\n' "$query_output" | awk '
                BEGIN { IGNORECASE=1 }
                /^Address([0-9]+)?:[[:space:]]*/ {
                    sub(/^Address([0-9]+)?:[[:space:]]*/, "", $0)
                    sub(/#.*$/, "", $0)
                    if ($0 != "127.0.0.1" && $0 != "::1" && $0 != "") print
                }
                /^Addresses:[[:space:]]*/ {
                    sub(/^Addresses:[[:space:]]*/, "", $0)
                    gsub(/,/, "\n", $0)
                    print
                }
            ' | awk 'NF' | head -3 || true)
        elif command -v host &>/dev/null; then
            result=$(host "$domain" 127.0.0.1 2>/dev/null \
                | awk '/has address/ {print $NF} /has IPv6 address/ {print $NF}' | head -3 || true)
        fi

        if [[ -n "$result" ]]; then
            echo -e "  ${GREEN}✓${NC} $result"
            ((success_count+=1))
        else
            echo -e "  ${RED}✗${NC} 解析失败"
        fi
    done

    echo ""
    echo -e "${CYAN}====================================================${NC}"

    if [[ "$success_count" -eq "$total" ]]; then
        print_msg "所有测试通过 (${success_count}/${total})"
    elif [[ "$success_count" -gt 0 ]]; then
        print_warn "部分测试通过 (${success_count}/${total})"
    else
        print_error "所有测试失败 (${success_count}/${total})"
        print_info "请检查 SmartDNS 是否正常运行和配置是否正确"
    fi
}

# 性能测试
benchmark_dns() {
    local port
    port=$(grep -E '^bind' "$SMARTDNS_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    port="${port:-53}"

    echo ""
    echo -e "${CYAN}==================== DNS 性能测试 ====================${NC}"
    echo ""

    local domains=("www.baidu.com" "www.qq.com" "www.google.com" "github.com" "www.youtube.com")
    local total_time=0
    local count=0

    for domain in "${domains[@]}"; do
        if command -v dig &>/dev/null; then
            # 第一次查询 (未缓存)
            local time1
            time1=$(dig @127.0.0.1 -p "$port" "$domain" +stats 2>/dev/null | grep 'Query time' | awk '{print $4}' || true)

            # 第二次查询 (缓存命中)
            local time2
            time2=$(dig @127.0.0.1 -p "$port" "$domain" +stats 2>/dev/null | grep 'Query time' | awk '{print $4}' || true)

            if [[ -n "$time1" ]] && [[ -n "$time2" ]]; then
                printf "  %-25s  首次: %4s ms  缓存: %4s ms\n" "$domain" "$time1" "$time2"
                total_time=$((total_time + time1))
                ((count+=1))
            else
                printf "  %-25s  ${RED}测试失败${NC}\n" "$domain"
            fi
        else
            print_warn "需要 dig 命令进行性能测试"
            return
        fi
    done

    if [[ "$count" -gt 0 ]]; then
        local avg=$((total_time / count))
        echo ""
        echo -e "  ${GREEN}平均首次查询时间: ${avg} ms${NC}"
    fi

    echo ""
    echo -e "${CYAN}====================================================${NC}"
}

# ======================== 查看状态 ========================

show_status() {
    echo ""
    echo -e "${CYAN}==================== SmartDNS 状态 ====================${NC}"
    echo ""

    # 检查安装
    if command -v smartdns &>/dev/null; then
        local version
        version=$(smartdns --version 2>&1 | head -1 || echo "未知")
        echo -e "  安装状态:  ${GREEN}已安装${NC}"
        echo -e "  版本信息:  ${version}"
        echo -e "  程序路径:  $(which smartdns)"
    else
        echo -e "  安装状态:  ${RED}未安装${NC}"
        echo ""
        return
    fi

    # 检查运行状态
    if has_systemd; then
        if systemctl is-active --quiet smartdns 2>/dev/null; then
            echo -e "  运行状态:  ${GREEN}运行中${NC}"
            local pid
            pid=$(systemctl show smartdns --property=MainPID --value 2>/dev/null)
            [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && echo -e "  进程 PID:  ${pid}"

            # 内存使用
            if [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && [[ -f "/proc/$pid/status" ]]; then
                local mem
                mem=$(grep VmRSS "/proc/$pid/status" 2>/dev/null | awk '{print $2" "$3}')
                [[ -n "$mem" ]] && echo -e "  内存使用:  ${mem}"
            fi
        else
            echo -e "  运行状态:  ${RED}未运行${NC}"
        fi

        if systemctl is-enabled --quiet smartdns 2>/dev/null; then
            echo -e "  开机自启:  ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启:  ${YELLOW}未启用${NC}"
        fi
    else
        if pgrep -x smartdns &>/dev/null; then
            echo -e "  运行状态:  ${GREEN}运行中${NC}"
        else
            echo -e "  运行状态:  ${RED}未运行${NC}"
        fi
    fi

    # 配置信息
    if [[ -f "$SMARTDNS_CONF" ]]; then
        local listen_port
        listen_port=$(grep -E '^bind' "$SMARTDNS_CONF" | head -1 | grep -oE '[0-9]+$')
        local upstream_count
        upstream_count=$(grep -cE '^[[:space:]]*server([[:space:]]|-(https|tls)($|[[:space:]]))' "$SMARTDNS_CONF" 2>/dev/null || true)
        upstream_count="${upstream_count:-0}"
        local cache_size
        cache_size=$(grep -E '^cache-size' "$SMARTDNS_CONF" | awk '{print $2}')

        echo -e "  配置文件:  ${SMARTDNS_CONF}"
        echo -e "  监听端口:  ${listen_port:-53}"
        echo -e "  上游 DNS:  ${upstream_count} 个"
        [[ -n "$cache_size" ]] && echo -e "  缓存大小:  ${cache_size} 条"
    fi

    # DNS 设置
    if [[ -f /etc/resolv.conf ]]; then
        local current_dns
        current_dns=$(grep -E '^nameserver' /etc/resolv.conf | head -3 | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
        echo -e "  系统 DNS:  ${current_dns}"
    fi

    echo ""
    echo -e "${CYAN}======================================================${NC}"
    echo ""
}

# ======================== 更新功能 ========================

update_smartdns() {
    print_info "检查 SmartDNS 更新..."

    local current_version
    current_version=$(smartdns --version 2>&1 | grep -oE 'Release[0-9]+|[0-9]+\.[0-9]+' | head -1 || echo "unknown")

    get_latest_version

    if [[ "$current_version" == "$SMARTDNS_VERSION" ]] || [[ "$current_version" == *"${SMARTDNS_VERSION##Release}"* ]]; then
        print_msg "当前已是最新版本: $current_version"
        if ! prompt_confirm "是否强制重新安装?" "N"; then
            return 0
        fi
    else
        print_info "当前版本: $current_version"
        print_info "最新版本: $SMARTDNS_VERSION"
    fi

    # 备份配置
    backup_config

    # 停止服务
    stop_smartdns

    # 下载安装
    if [[ "$OS_TYPE" == "debian" ]]; then
        install_smartdns_deb
    else
        download_smartdns && install_smartdns_generic
    fi

    # 恢复服务
    start_smartdns

    print_msg "SmartDNS 更新完成"
}

# 更新广告过滤规则
update_adblock_rules() {
    print_info "更新广告过滤规则..."

    local adblock_conf="${SMARTDNS_CONF_DIR}/anti-ad.conf"

    if curl -fSL -o "${adblock_conf}.new" \
        "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-smartdns.conf" 2>/dev/null; then

        local new_count
        new_count=$(wc -l < "${adblock_conf}.new")

        if [[ "$new_count" -gt 100 ]]; then
            mv "${adblock_conf}.new" "$adblock_conf"
            print_msg "广告过滤规则已更新 (${new_count} 条规则)"

            # 重载配置
            if has_systemd && systemctl is-active --quiet smartdns 2>/dev/null; then
                systemctl reload smartdns 2>/dev/null || restart_smartdns
                print_msg "SmartDNS 已重载配置"
            fi
        else
            rm -f "${adblock_conf}.new"
            print_error "下载的规则文件异常，已放弃更新"
        fi
    else
        rm -f "${adblock_conf}.new"
        print_error "广告过滤规则下载失败"
    fi
}

# ======================== 卸载功能 ========================

uninstall_smartdns() {
    echo ""
    echo -e "${RED}${BOLD}警告: 即将卸载 SmartDNS${NC}"
    echo ""

    if ! prompt_confirm "确认卸载 SmartDNS?" "N"; then
        print_info "取消卸载"
        return 0
    fi

    print_info "开始卸载 SmartDNS..."

    # 停止服务
    stop_smartdns

    # 禁用自启
    if has_systemd; then
        systemctl disable smartdns 2>/dev/null || true
    fi

    # 根据安装方式卸载
    if [[ "$OS_TYPE" == "debian" ]] && dpkg -l smartdns &>/dev/null 2>&1; then
        apt-get remove --purge -y smartdns 2>/dev/null || true
    elif [[ "$OS_TYPE" == "redhat" ]] && rpm -q smartdns &>/dev/null 2>&1; then
        $PKG_MGR remove -y smartdns 2>/dev/null || true
    else
        # 手动清理
        rm -f "${SMARTDNS_INSTALL_DIR}/smartdns"
        rm -f "$SMARTDNS_SERVICE"
    fi

    # 询问是否删除配置
    if prompt_confirm "是否删除配置文件?" "N"; then
        rm -rf "$SMARTDNS_CONF_DIR"
        print_msg "配置文件已删除"
    else
        print_info "配置文件已保留: $SMARTDNS_CONF_DIR"
    fi

    # 清理服务文件
    rm -f "$SMARTDNS_SERVICE"
    if has_systemd; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 恢复 DNS 设置
    if command -v chattr &>/dev/null; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi

    # 恢复 systemd-resolved
    if prompt_confirm "是否恢复 systemd-resolved?" "N"; then
        if has_systemd && systemctl list-unit-files | grep -q systemd-resolved; then
            systemctl enable systemd-resolved
            systemctl start systemd-resolved
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
            print_msg "systemd-resolved 已恢复"
        else
            print_warn "当前系统未检测到 systemd-resolved 单元"
        fi
    fi

    print_msg "SmartDNS 已成功卸载"
}

edit_main_config() {
    if ! ensure_main_config_exists; then
        if ! prompt_confirm "配置文件不存在，是否现在生成配置模板?" "Y"; then
            return 0
        fi

        local template_key
        select_config_template template_key "请选择要生成的配置模板" "3" || return 1
        apply_config_template "$template_key" || return 1
    fi

    open_text_editor "$SMARTDNS_CONF"
}

manage_custom_hosts() {
    create_custom_hosts || return 1
    open_text_editor "${SMARTDNS_CONF_DIR}/custom-hosts.conf"
}

interactive_change_listen_port() {
    ensure_main_config_exists || return 1

    local new_port
    while true; do
        if is_interactive; then
            read -rp "请输入新的监听端口 (1-65535): " new_port
        else
            new_port="5353"
        fi

        if is_valid_port "$new_port"; then
            change_listen_port "$new_port"
            show_config_summary "当前配置"
            return 0
        fi

        print_warn "监听端口必须是 1-65535 之间的数字"
    done
}

reset_config_template() {
    local template_key
    select_config_template template_key "请选择要重置的配置模板" "3" || return 1
    apply_config_template "$template_key"
}

menu_update_smartdns() {
    detect_os
    detect_arch
    update_smartdns
}

menu_uninstall_smartdns() {
    detect_os
    uninstall_smartdns
}

# ======================== 高级配置菜单 ========================

advanced_config_menu() {
    local adv_choice

    while true; do
        echo ""
        echo -e "${CYAN}============ 高级配置 ============${NC}"
        if [[ $EUID -ne 0 ]]; then
            echo -e "  ${YELLOW}当前为只读模式，修改类操作需要 root 权限${NC}"
            echo ""
        fi
        echo "  1) 编辑主配置文件       创建模板后再进入编辑器"
        echo "  2) 添加上游 DNS         追加 server/server-https/server-tls"
        echo "  3) 添加域名分流规则     追加 nameserver 规则"
        echo "  4) 配置广告过滤         下载并引用 anti-ad 规则"
        echo "  5) 配置自定义 hosts     创建并编辑 custom-hosts.conf"
        echo "  6) 修改监听端口         校验后写入 bind 配置"
        echo "  7) 开启/关闭 DOH/DOT    批量切换加密 DNS"
        echo "  8) 配置日志             设置日志级别和审计日志"
        echo "  9) 重置为默认配置       重新选择配置模板"
        echo "  10) 查看上游 DNS 配置   只读查看当前 server 列表"
        echo "  0) 返回主菜单"
        echo -e "${CYAN}==================================${NC}"
        echo ""

        prompt_menu_choice adv_choice "请选择 [0-10]" '^(0|[1-9]|10)$' || return 1

        case "$adv_choice" in
            1)
                run_menu_action "编辑主配置文件" root edit_main_config
                ;;
            2)
                run_menu_action "添加上游 DNS 服务器" root add_upstream_dns
                ;;
            3)
                run_menu_action "添加域名分流规则" root add_domain_rules
                ;;
            4)
                run_menu_action "配置广告过滤" root generate_adblock_config
                ;;
            5)
                run_menu_action "配置自定义 hosts" root manage_custom_hosts
                ;;
            6)
                run_menu_action "修改监听端口" root interactive_change_listen_port
                ;;
            7)
                run_menu_action "切换加密 DNS" root toggle_encrypted_dns
                ;;
            8)
                run_menu_action "配置日志" root configure_logging
                ;;
            9)
                run_menu_action "重置配置模板" root reset_config_template
                ;;
            10)
                run_menu_action "查看上游 DNS 配置" readonly view_upstream_dns
                ;;
            0)
                return
                ;;
        esac
    done
}

# 添加上游 DNS
add_upstream_dns() {
    ensure_main_config_exists || return 1

    echo ""
    echo -e "${CYAN}添加上游 DNS 服务器${NC}"
    echo "  格式说明:"
    echo "  - 普通 DNS:  IP地址 (如: 1.1.1.1)"
    echo "  - DOH:       https://域名/dns-query"
    echo "  - DOT:       域名 (如: dns.google)"
    echo "  - 留空回车:  取消当前操作"
    echo ""

    local dns_addr group_name dns_line=""

    while true; do
        if is_interactive; then
            read -rp "DNS 服务器地址: " dns_addr
        else
            print_error "非交互模式下无法手动添加上游 DNS"
            return 1
        fi

        [[ -z "$dns_addr" ]] && return 0

        if [[ "$dns_addr" == https://* ]]; then
            if [[ "$dns_addr" =~ ^https://[^[:space:]]+/dns-query([?][^[:space:]]*)?$ ]]; then
                dns_line="server-https ${dns_addr}"
                break
            fi
            print_warn "DOH 地址格式应类似 https://dns.google/dns-query"
        elif is_valid_ipv4 "$dns_addr"; then
            dns_line="server ${dns_addr}"
            break
        elif is_valid_domain "$dns_addr"; then
            dns_line="server-tls ${dns_addr}"
            break
        else
            print_warn "仅支持 IPv4、DOH 地址或域名形式的 DOT 服务器"
        fi
    done

    while true; do
        read -rp "分组名 (留空为默认组): " group_name
        if [[ -z "$group_name" ]] || is_valid_group_name "$group_name"; then
            break
        fi
        print_warn "分组名仅允许字母、数字、点、下划线和连字符"
    done

    if [[ -n "$group_name" ]]; then
        dns_line="${dns_line} -group ${group_name}"
        if prompt_confirm "是否从默认组排除?" "N"; then
            dns_line="${dns_line} -exclude-default-group"
        fi
    fi

    echo "$dns_line" >> "$SMARTDNS_CONF"
    print_msg "已添加: $dns_line"
    show_config_summary "当前配置"
}

# 查看当前上游 DNS 配置
view_upstream_dns() {
    if [[ ! -f "$SMARTDNS_CONF" ]]; then
        print_error "配置文件不存在: $SMARTDNS_CONF"
        return 1
    fi

    echo ""
    echo -e "${CYAN}=========== 当前上游 DNS 配置 ===========${NC}"

    local plain_dns https_dns tls_dns total

    plain_dns=$(grep -E '^[[:space:]]*server[[:space:]]+' "$SMARTDNS_CONF" 2>/dev/null || true)
    https_dns=$(grep -E '^[[:space:]]*server-https[[:space:]]+' "$SMARTDNS_CONF" 2>/dev/null || true)
    tls_dns=$(grep -E '^[[:space:]]*server-tls[[:space:]]+' "$SMARTDNS_CONF" 2>/dev/null || true)
    total=$(grep -cE '^[[:space:]]*server([[:space:]]|-(https|tls)[[:space:]])' "$SMARTDNS_CONF" 2>/dev/null || true)
    total="${total:-0}"

    if [[ "$total" -eq 0 ]]; then
        print_warn "未找到有效的上游 DNS 配置"
        return 0
    fi

    echo ""
    echo "普通 DNS:"
    if [[ -n "$plain_dns" ]]; then
        printf '%s\n' "$plain_dns"
    else
        echo "  (无)"
    fi

    echo ""
    echo "DNS over HTTPS:"
    if [[ -n "$https_dns" ]]; then
        printf '%s\n' "$https_dns"
    else
        echo "  (无)"
    fi

    echo ""
    echo "DNS over TLS:"
    if [[ -n "$tls_dns" ]]; then
        printf '%s\n' "$tls_dns"
    else
        echo "  (无)"
    fi

    echo ""
    print_info "上游 DNS 总数: ${total}"
    echo -e "${CYAN}==========================================${NC}"
}

# 添加域名分流规则
add_domain_rules() {
    ensure_main_config_exists || return 1

    echo ""
    echo -e "${CYAN}添加域名分流规则${NC}"
    echo ""

    local domain group_name

    while true; do
        if is_interactive; then
            read -rp "域名 (如: google.com，留空取消): " domain
        else
            print_error "非交互模式下无法手动添加域名规则"
            return 1
        fi

        [[ -z "$domain" ]] && return 0

        if is_valid_domain "$domain"; then
            break
        fi

        print_warn "域名格式无效，请重新输入"
    done

    while true; do
        read -rp "DNS 分组名: " group_name
        if [[ -n "$group_name" ]] && is_valid_group_name "$group_name"; then
            break
        fi
        print_warn "分组名不能为空，且只能包含字母、数字、点、下划线和连字符"
    done

    echo "nameserver /${domain}/${group_name}" >> "$SMARTDNS_CONF"
    print_msg "已添加规则: ${domain} -> ${group_name}"
}

# 切换加密 DNS
toggle_encrypted_dns() {
    ensure_main_config_exists || return 1

    echo ""
    echo "当前加密 DNS 状态:"
    local doh_count dot_count enc_choice
    doh_count=$(grep -c '^server-https' "$SMARTDNS_CONF" 2>/dev/null || true)
    doh_count="${doh_count:-0}"
    dot_count=$(grep -c '^server-tls' "$SMARTDNS_CONF" 2>/dev/null || true)
    dot_count="${dot_count:-0}"
    echo "  DOH 服务器: ${doh_count} 个"
    echo "  DOT 服务器: ${dot_count} 个"
    echo ""
    echo "  1) 启用所有加密 DNS"
    echo "  2) 禁用所有加密 DNS"
    echo "  3) 返回"

    prompt_menu_choice enc_choice "选择 [1-3]" '^[1-3]$' "3" || return 1

    case "$enc_choice" in
        1)
            sed -i -E 's|^[[:space:]]*#?[[:space:]]*(server-https[[:space:]].*)$|\1|' "$SMARTDNS_CONF"
            sed -i -E 's|^[[:space:]]*#?[[:space:]]*(server-tls[[:space:]].*)$|\1|' "$SMARTDNS_CONF"
            print_msg "已启用所有加密 DNS"
            ;;
        2)
            sed -i -E 's|^[[:space:]]*#?[[:space:]]*(server-https[[:space:]].*)$|# \1|' "$SMARTDNS_CONF"
            sed -i -E 's|^[[:space:]]*#?[[:space:]]*(server-tls[[:space:]].*)$|# \1|' "$SMARTDNS_CONF"
            print_msg "已禁用所有加密 DNS"
            ;;
        3)
            return 0
            ;;
    esac
}

# 配置日志
configure_logging() {
    ensure_main_config_exists || return 1

    echo ""
    echo "日志级别选择:"
    echo "  1) debug  - 调试 (最详细)"
    echo "  2) info   - 信息"
    echo "  3) notice - 通知"
    echo "  4) warn   - 警告 (推荐)"
    echo "  5) error  - 错误"
    echo "  6) off    - 关闭"

    local log_choice log_level
    prompt_menu_choice log_choice "选择 [1-6]" '^[1-6]$' "4" || return 1

    case "$log_choice" in
        1) log_level="debug" ;;
        2) log_level="info" ;;
        3) log_level="notice" ;;
        4) log_level="warn" ;;
        5) log_level="error" ;;
        6) log_level="off" ;;
    esac

    sed -i "s/^log-level .*/log-level ${log_level}/" "$SMARTDNS_CONF"

    mkdir -p /var/log/smartdns 2>/dev/null || true

    if ! grep -q '^log-file' "$SMARTDNS_CONF"; then
        sed -i "/^log-level/a log-file /var/log/smartdns/smartdns.log" "$SMARTDNS_CONF"
        sed -i "/^log-file/a log-size 256k" "$SMARTDNS_CONF"
        sed -i "/^log-size/a log-num 5" "$SMARTDNS_CONF"
    fi

    if prompt_confirm "是否开启审计日志 (记录所有 DNS 查询)?" "N"; then
        if grep -q '^# *audit-enable' "$SMARTDNS_CONF"; then
            sed -i 's/^# *audit-enable.*/audit-enable yes/' "$SMARTDNS_CONF"
            sed -i 's/^# *audit-file.*/audit-file \/var\/log\/smartdns\/smartdns-audit.log/' "$SMARTDNS_CONF"
            sed -i 's/^# *audit-size.*/audit-size 256k/' "$SMARTDNS_CONF"
            sed -i 's/^# *audit-num.*/audit-num 5/' "$SMARTDNS_CONF"
        elif ! grep -q '^audit-enable' "$SMARTDNS_CONF"; then
            cat >> "$SMARTDNS_CONF" << 'EOF'

# 审计日志
audit-enable yes
audit-file /var/log/smartdns/smartdns-audit.log
audit-size 256k
audit-num 5
EOF
        fi
        print_msg "审计日志已启用"
    fi

    print_msg "日志级别已设置为: ${log_level}"
}

# ======================== 定时任务 ========================

setup_cron_jobs() {
    if ! command -v crontab &>/dev/null; then
        print_error "未找到 crontab 命令"
        return 1
    fi

    local cron_choice

    echo ""
    echo -e "${CYAN}============ 定时任务设置 ============${NC}"
    echo "  1) 设置广告规则自动更新 (每天凌晨3点)"
    echo "  2) 设置 SmartDNS 自动重启 (每周一凌晨4点)"
    echo "  3) 设置日志自动清理 (每周日凌晨5点)"
    echo "  4) 查看当前定时任务"
    echo "  5) 清除所有 SmartDNS 定时任务"
    echo "  0) 返回"
    echo -e "${CYAN}======================================${NC}"
    echo ""

    prompt_menu_choice cron_choice "请选择 [0-5]" '^[0-5]$' "0" || return 1

    case "$cron_choice" in
        1)
            local cron_cmd="0 3 * * * curl -fSL -o /etc/smartdns/anti-ad.conf 'https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-smartdns.conf' && systemctl reload smartdns 2>/dev/null"
            update_crontab_excluding "anti-ad" "$cron_cmd"
            print_msg "广告规则自动更新任务已设置"
            ;;
        2)
            local cron_cmd="0 4 * * 1 systemctl restart smartdns 2>/dev/null"
            update_crontab_excluding "restart smartdns" "$cron_cmd"
            print_msg "自动重启任务已设置"
            ;;
        3)
            local cron_cmd="0 5 * * 0 find /var/log/smartdns/ -name '*.log' -mtime +30 -delete 2>/dev/null"
            update_crontab_excluding "smartdns.*log.*delete" "$cron_cmd"
            print_msg "日志自动清理任务已设置"
            ;;
        4)
            echo ""
            echo "当前 SmartDNS 相关定时任务:"
            crontab -l 2>/dev/null | grep -i smartdns || echo "  (无)"
            echo ""
            ;;
        5)
            update_crontab_excluding "smartdns"
            print_msg "已清除所有 SmartDNS 定时任务"
            ;;
        0)
            return
            ;;
    esac
}

# ======================== 查看日志 ========================

view_logs() {
    local log_view_choice

    echo ""
    echo -e "${CYAN}============ 日志查看 ============${NC}"
    echo "  1) 查看 SmartDNS 运行日志 (最近50行)"
    echo "  2) 查看 SmartDNS 审计日志 (最近50行)"
    echo "  3) 查看 systemd 日志 (最近50行)"
    echo "  4) 实时跟踪运行日志"
    echo "  5) 实时跟踪审计日志"
    echo "  6) 实时跟踪 systemd 日志"
    echo "  0) 返回"
    echo -e "${CYAN}==================================${NC}"
    echo ""

    prompt_menu_choice log_view_choice "请选择 [0-6]" '^[0-6]$' "0" || return 1

    case "$log_view_choice" in
        1)
            if [[ -f /var/log/smartdns/smartdns.log ]]; then
                tail -50 /var/log/smartdns/smartdns.log
            else
                print_warn "运行日志文件不存在"
            fi
            ;;
        2)
            if [[ -f /var/log/smartdns/smartdns-audit.log ]]; then
                tail -50 /var/log/smartdns/smartdns-audit.log
            else
                print_warn "审计日志文件不存在 (可能未启用)"
            fi
            ;;
        3)
            if command -v journalctl &>/dev/null && has_systemd; then
                journalctl -u smartdns --no-pager -n 50 2>/dev/null || print_warn "无法查看 systemd 日志"
            else
                print_warn "当前系统未提供可用的 journalctl/systemd 日志"
            fi
            ;;
        4)
            if [[ -f /var/log/smartdns/smartdns.log ]]; then
                print_info "按 Ctrl+C 退出..."
                tail -f /var/log/smartdns/smartdns.log
            else
                print_warn "运行日志文件不存在"
            fi
            ;;
        5)
            if [[ -f /var/log/smartdns/smartdns-audit.log ]]; then
                print_info "按 Ctrl+C 退出..."
                tail -f /var/log/smartdns/smartdns-audit.log
            else
                print_warn "审计日志文件不存在"
            fi
            ;;
        6)
            if command -v journalctl &>/dev/null && has_systemd; then
                print_info "按 Ctrl+C 退出..."
                journalctl -u smartdns -f 2>/dev/null || print_warn "无法查看 systemd 日志"
            else
                print_warn "当前系统未提供可用的 journalctl/systemd 日志"
            fi
            ;;
        0)
            return
            ;;
    esac
}

# ======================== 快速安装流程 ========================

quick_install() {
    print_banner
    print_info "开始快速安装 SmartDNS..."
    echo ""
    echo -e "${CYAN}本向导将依次执行:${NC}"
    echo "  1) 检测系统、架构和网络"
    echo "  2) 安装依赖并下载 SmartDNS"
    echo "  3) 选择配置模板并写入配置"
    echo "  4) 处理端口冲突、验证配置、启动服务"
    echo "  5) 可选接管系统 DNS，并进行解析测试"
    echo ""

    if ! prompt_confirm "是否继续快速安装?" "Y"; then
        print_info "已取消快速安装"
        return 0
    fi

    detect_os
    detect_arch
    check_network || return 1

    install_dependencies
    get_latest_version

    case "$OS_TYPE" in
        debian)
            install_smartdns_deb
            ;;
        *)
            download_smartdns && install_smartdns_generic
            ;;
    esac

    if ! command -v smartdns &>/dev/null; then
        print_error "SmartDNS 安装失败，请检查下载或安装日志"
        return 1
    fi

    local template_key template_name
    select_config_template template_key "请选择安装后要应用的配置模板" "3" || return 1
    template_name=$(get_config_template_name "$template_key")
    apply_config_template "$template_key" || return 1

    resolve_port_conflict 53 || return 1
    validate_config || return 1
    enable_autostart
    start_smartdns || return 1

    if prompt_confirm "是否将系统 DNS 设置为 SmartDNS?" "Y"; then
        set_system_dns || print_warn "系统 DNS 未完成接管，请根据上方提示手动处理"
    fi

    if prompt_confirm "是否进行 DNS 解析测试?" "Y"; then
        sleep 2
        test_dns || true
    fi

    echo ""
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo -e "${GREEN}${BOLD}    SmartDNS 安装配置完成！${NC}"
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo ""
    print_info "最终配置模板: ${template_name}"
    show_status
}

# ======================== 主菜单 ========================

main_menu() {
    local main_choice

    while true; do
        print_banner

        if command -v smartdns &>/dev/null; then
            local status_color="${RED}"
            local status_text="未运行"
            if pgrep -x smartdns &>/dev/null; then
                status_color="${GREEN}"
                status_text="运行中"
            fi
            echo -e "  SmartDNS: ${status_color}${status_text}${NC}  |  版本: $(smartdns --version 2>&1 | head -1 | grep -oE '[0-9.]+|Release[0-9]+' | head -1 || echo '未知')"
        else
            echo -e "  SmartDNS: ${YELLOW}未安装${NC}"
        fi

        if [[ $EUID -ne 0 ]]; then
            echo -e "  ${YELLOW}当前为只读模式；安装、更新和写配置操作需要 root 权限${NC}"
        fi
        echo ""

        echo -e "${CYAN}==================== 主菜单 ====================${NC}"
        echo ""
        echo -e "  ${BOLD}安装与更新${NC}"
        echo "    1)  快速安装 SmartDNS   安装、配置并启动基础服务"
        echo "    2)  更新 SmartDNS       下载并重装最新版本"
        echo "    3)  卸载 SmartDNS       停止服务并清理安装"
        echo ""
        echo -e "  ${BOLD}服务管理${NC}"
        echo "    4)  启动 SmartDNS       启动或恢复服务"
        echo "    5)  停止 SmartDNS       停止当前服务"
        echo "    6)  重启 SmartDNS       重新加载进程"
        echo "    7)  查看运行状态        只读查看版本、端口和 DNS"
        echo ""
        echo -e "  ${BOLD}配置管理${NC}"
        echo "    8)  高级配置            编辑模板、规则和日志设置"
        echo "    9)  验证配置文件        检查 bind 和上游 DNS"
        echo "    10) 设置系统 DNS        接管 /etc/resolv.conf"
        echo ""
        echo -e "  ${BOLD}测试与诊断${NC}"
        echo "    11) DNS 解析测试        测试常见域名解析"
        echo "    12) DNS 性能测试        比较首次和缓存响应时间"
        echo "    13) 查看日志            查看运行、审计或 systemd 日志"
        echo ""
        echo -e "  ${BOLD}维护${NC}"
        echo "    14) 更新广告过滤规则    下载最新 anti-ad 规则"
        echo "    15) 定时任务设置        管理 SmartDNS 相关 crontab"
        echo "    16) 备份配置            备份当前 smartdns.conf"
        echo ""
        echo "    0)  退出"
        echo ""
        echo -e "${CYAN}=================================================${NC}"
        echo ""

        prompt_menu_choice main_choice "请选择 [0-16]" '^(0|[1-9]|1[0-6])$' || return 1

        case "$main_choice" in
            1)
                run_menu_action "快速安装 SmartDNS" root quick_install
                ;;
            2)
                run_menu_action "更新 SmartDNS" root menu_update_smartdns
                ;;
            3)
                run_menu_action "卸载 SmartDNS" root menu_uninstall_smartdns
                ;;
            4)
                run_menu_action "启动 SmartDNS" root start_smartdns
                ;;
            5)
                run_menu_action "停止 SmartDNS" root stop_smartdns
                ;;
            6)
                run_menu_action "重启 SmartDNS" root restart_smartdns
                ;;
            7)
                run_menu_action "查看运行状态" readonly show_status
                ;;
            8)
                advanced_config_menu
                ;;
            9)
                run_menu_action "验证配置文件" readonly validate_config
                ;;
            10)
                run_menu_action "设置系统 DNS" root set_system_dns
                ;;
            11)
                run_menu_action "DNS 解析测试" readonly test_dns
                ;;
            12)
                run_menu_action "DNS 性能测试" readonly benchmark_dns
                ;;
            13)
                run_menu_action "查看日志" readonly view_logs
                ;;
            14)
                run_menu_action "更新广告过滤规则" root update_adblock_rules
                ;;
            15)
                run_menu_action "定时任务设置" root setup_cron_jobs
                ;;
            16)
                run_menu_action "备份配置" root backup_config
                ;;
            0)
                echo ""
                print_msg "再见！"
                echo ""
                exit 0
                ;;
        esac
    done
}

# ======================== 命令行参数处理 ========================

show_help() {
    echo ""
    echo "SmartDNS 一键安装脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --install, -i       快速安装向导"
    echo "  --uninstall, -u     卸载 SmartDNS"
    echo "  --update            更新 SmartDNS"
    echo "  --start             启动服务"
    echo "  --stop              停止服务"
    echo "  --restart           重启服务"
    echo "  --status            查看状态 (非 root 可用)"
    echo "  --test              DNS 解析测试 (非 root 可用)"
    echo "  --benchmark         DNS 性能测试 (非 root 可用)"
    echo "  --config [type]     生成配置 (default/basic/china/simple)"
    echo "  --update-adblock    更新广告过滤规则"
    echo "  --menu              进入交互菜单 (默认，非 root 可只读浏览)"
    echo "  --help, -h          显示帮助"
    echo ""
    echo "说明:"
    echo "  - 只读操作可在非 root 模式下运行"
    echo "  - 安装、更新、写配置、改 DNS、改服务等操作需要 root 权限"
    echo ""
    echo "示例:"
    echo "  $0 --install        # 快速安装"
    echo "  $0 --config china   # 生成国内优化配置"
    echo "  $0 --status         # 查看当前状态"
    echo "  $0                  # 进入交互菜单"
    echo ""
}

# ======================== 入口 ========================

main() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

    case "${1:-}" in
        --install|-i)
            check_root "快速安装 SmartDNS" || exit 1
            detect_os
            detect_arch
            quick_install
            ;;
        --uninstall|-u)
            check_root "卸载 SmartDNS" || exit 1
            detect_os
            uninstall_smartdns
            ;;
        --update)
            check_root "更新 SmartDNS" || exit 1
            detect_os
            detect_arch
            update_smartdns
            ;;
        --start)
            check_root "启动 SmartDNS" || exit 1
            start_smartdns
            ;;
        --stop)
            check_root "停止 SmartDNS" || exit 1
            stop_smartdns
            ;;
        --restart)
            check_root "重启 SmartDNS" || exit 1
            restart_smartdns
            ;;
        --status)
            show_status
            ;;
        --test)
            test_dns
            ;;
        --benchmark)
            benchmark_dns
            ;;
        --config)
            check_root "生成 SmartDNS 配置" || exit 1
            case "${2:-default}" in
                default|simple)
                    apply_config_template simple
                    ;;
                china)
                    apply_config_template china
                    ;;
                basic)
                    apply_config_template basic
                    ;;
                *)
                    print_warn "未知配置模板: ${2:-default}，将使用默认配置（无分组）"
                    apply_config_template simple
                    ;;
            esac
            ;;
        --update-adblock)
            check_root "更新广告过滤规则" || exit 1
            update_adblock_rules
            ;;
        --help|-h)
            show_help
            ;;
        --menu|"")
            detect_os
            detect_arch
            main_menu
            ;;
        *)
            print_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

# 运行
main "$@"




