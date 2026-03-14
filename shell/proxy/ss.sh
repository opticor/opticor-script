#!/bin/bash

# Shadowsocks 安装脚本 (Debian/Ubuntu)

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "错误：此脚本必须以 root 权限运行。" 1>&2
   exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 函数：打印信息
echo_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

echo_error() {
    echo -e "${RED}[错误]${NC} $1"
}

is_valid_ipv4() {
    local ip=$1
    local IFS='.'
    local -a octets

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1

    for octet in "${octets[@]}"; do
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

urlencode() {
    jq -nr --arg v "$1" '$v|@uri'
}

is_private_ipv4() {
    local ip=$1
    is_valid_ipv4 "$ip" || return 1
    [[ "$ip" =~ ^10\. ]] \
        || [[ "$ip" =~ ^127\. ]] \
        || [[ "$ip" =~ ^192\.168\. ]] \
        || [[ "$ip" =~ ^169\.254\. ]] \
        || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] \
        || [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

detect_public_ip() {
    local detected_ip=""
    if command -v curl &> /dev/null; then
        detected_ip=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
    fi
    if [ -z "$detected_ip" ] && command -v wget &> /dev/null; then
        detected_ip=$(wget -qO- --timeout=4 https://api.ipify.org 2>/dev/null || true)
    fi
    echo "$detected_ip"
}

ensure_apt_updated() {
    if [ "$apt_updated" = true ]; then
        return 0
    fi

    echo_info "更新软件包列表..."
    if ! apt update -y; then
        echo_error "apt update 失败，请检查网络连接和 APT 源配置。"
        return 1
    fi

    apt_updated=true
    return 0
}

install_missing_packages() {
    local packages=()
    local pkg

    for pkg in "$@"; do
        if ! command -v "$pkg" &> /dev/null; then
            packages+=("$pkg")
        fi
    done

    if [ "${#packages[@]}" -eq 0 ]; then
        return 0
    fi

    ensure_apt_updated || return 1
    echo_info "正在安装依赖: ${packages[*]} ..."
    if ! apt install -y "${packages[@]}"; then
        echo_error "安装依赖失败: ${packages[*]}"
        return 1
    fi

    return 0
}

ensure_download_tool() {
    if command -v curl &> /dev/null || command -v wget &> /dev/null; then
        return 0
    fi

    install_missing_packages curl || return 1
    return 0
}

download_cn_ipv4_list() {
    local output_file=$1

    ensure_download_tool || return 1

    if command -v curl &> /dev/null; then
        curl -fsSL "https://www.ipdeny.com/ipblocks/data/countries/cn.zone" -o "$output_file" || return 1
    else
        wget -qO "$output_file" "https://www.ipdeny.com/ipblocks/data/countries/cn.zone" || return 1
    fi

    if [ ! -s "$output_file" ]; then
        return 1
    fi

    return 0
}

ensure_firewalld_port() {
    local zone_name=$1
    local port_proto=$2
    if firewall-cmd --permanent --zone="$zone_name" --query-port="$port_proto" --quiet; then
        return 0
    fi
    firewall-cmd --permanent --zone="$zone_name" --add-port="$port_proto" --quiet
}

ensure_firewalld_rich_rule() {
    local zone_name=$1
    local rule=$2
    if firewall-cmd --permanent --zone="$zone_name" --query-rich-rule="$rule" --quiet; then
        return 0
    fi
    firewall-cmd --permanent --zone="$zone_name" --add-rich-rule="$rule" --quiet
}

sync_firewalld_ipset_from_file() {
    local ipset_name=$1
    local file_path=$2

    if firewall-cmd --permanent --ipset="$ipset_name" --add-entries-from-file="$file_path" >/dev/null 2>&1; then
        return 0
    fi

    while read -r cidr; do
        [ -z "$cidr" ] && continue
        firewall-cmd --permanent --ipset="$ipset_name" --add-entry="$cidr" --quiet || return 1
    done < "$file_path"

    return 0
}

ufw_add_rule_front() {
    if ufw prepend "$@" >/dev/null 2>&1; then
        return 0
    fi

    if ufw insert 1 "$@" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

apply_ufw_policy() {
    case "$firewall_policy" in
        all)
            echo_info "正在配置 ufw：端口 $server_port 对所有 IP 开放 (TCP/UDP)..."
            ufw allow "$server_port/tcp" >/dev/null || return 1
            ufw allow "$server_port/udp" >/dev/null || return 1
            ufw reload >/dev/null || return 1
            firewall_action_taken=true
            firewall_status_summary="ufw: 端口 ${server_port} 已对所有 IP 开放"
            ;;
        ip)
            echo_info "正在配置 ufw：端口 $server_port 仅允许 $restricted_ip 访问 (TCP/UDP)..."

            # 先前插 deny，再前插 allow，确保 allow 在 deny 之前命中
            ufw_add_rule_front deny to any port "$server_port" proto tcp || {
                echo_error "当前 ufw 不支持前插规则（prepend/insert），无法安全应用“仅特定 IP 开放”策略。"
                return 1
            }
            ufw_add_rule_front deny to any port "$server_port" proto udp || {
                echo_error "当前 ufw 不支持前插规则（prepend/insert），无法安全应用“仅特定 IP 开放”策略。"
                return 1
            }
            ufw_add_rule_front allow from "$restricted_ip" to any port "$server_port" proto tcp || {
                echo_error "当前 ufw 不支持前插规则（prepend/insert），无法安全应用“仅特定 IP 开放”策略。"
                return 1
            }
            ufw_add_rule_front allow from "$restricted_ip" to any port "$server_port" proto udp || {
                echo_error "当前 ufw 不支持前插规则（prepend/insert），无法安全应用“仅特定 IP 开放”策略。"
                return 1
            }

            ufw reload >/dev/null || return 1
            firewall_action_taken=true
            firewall_status_summary="ufw: 端口 ${server_port} 仅允许 ${restricted_ip}"
            ;;
        block_cn)
            local cn_file
            cn_file=$(mktemp)

            if ! download_cn_ipv4_list "$cn_file"; then
                rm -f "$cn_file"
                echo_error "下载大陆 IP 网段列表失败，无法应用屏蔽大陆策略。"
                return 1
            fi

            echo_info "正在配置 ufw：屏蔽大陆访问端口 $server_port (TCP/UDP)，该步骤可能耗时较长..."

            # 先追加 allow，再把大陆 deny 前插到最前，确保 deny 优先
            ufw allow "$server_port/tcp" >/dev/null || {
                rm -f "$cn_file"
                return 1
            }
            ufw allow "$server_port/udp" >/dev/null || {
                rm -f "$cn_file"
                return 1
            }

            while read -r cidr; do
                [ -z "$cidr" ] && continue
                ufw_add_rule_front deny from "$cidr" to any port "$server_port" proto tcp || {
                    rm -f "$cn_file"
                    echo_error "当前 ufw 不支持前插规则（prepend/insert），无法安全应用“屏蔽大陆”策略。"
                    return 1
                }
                ufw_add_rule_front deny from "$cidr" to any port "$server_port" proto udp || {
                    rm -f "$cn_file"
                    echo_error "当前 ufw 不支持前插规则（prepend/insert），无法安全应用“屏蔽大陆”策略。"
                    return 1
                }
            done < "$cn_file"

            rm -f "$cn_file"
            ufw reload >/dev/null || return 1
            firewall_action_taken=true
            firewall_status_summary="ufw: 端口 ${server_port} 已配置为屏蔽大陆"
            ;;
        *)
            echo_error "未知的 ufw 策略：$firewall_policy"
            return 1
            ;;
    esac

    return 0
}
apply_firewalld_policy() {
    local default_zone
    default_zone=$(firewall-cmd --get-default-zone 2>/dev/null)
    if [ -z "$default_zone" ]; then
        echo_error "无法获取 firewalld 默认 zone。"
        return 1
    fi

    case "$firewall_policy" in
        all)
            echo_info "正在配置 firewalld：端口 $server_port 对所有 IP 开放 (TCP/UDP)..."
            ensure_firewalld_port "$default_zone" "$server_port/tcp" || return 1
            ensure_firewalld_port "$default_zone" "$server_port/udp" || return 1
            firewall-cmd --reload >/dev/null || return 1
            firewall_action_taken=true
            firewall_status_summary="firewalld: 端口 ${server_port} 已对所有 IP 开放"
            ;;
        ip)
            local allow_tcp_rule
            local allow_udp_rule
            local deny_tcp_rule
            local deny_udp_rule

            allow_tcp_rule="rule family=\"ipv4\" priority=\"-100\" source address=\"${restricted_ip}\" port port=\"${server_port}\" protocol=\"tcp\" accept"
            allow_udp_rule="rule family=\"ipv4\" priority=\"-100\" source address=\"${restricted_ip}\" port port=\"${server_port}\" protocol=\"udp\" accept"
            deny_tcp_rule="rule family=\"ipv4\" priority=\"100\" port port=\"${server_port}\" protocol=\"tcp\" drop"
            deny_udp_rule="rule family=\"ipv4\" priority=\"100\" port port=\"${server_port}\" protocol=\"udp\" drop"

            echo_info "正在配置 firewalld：端口 $server_port 仅允许 $restricted_ip 访问 (TCP/UDP)..."
            ensure_firewalld_rich_rule "$default_zone" "$allow_tcp_rule" || return 1
            ensure_firewalld_rich_rule "$default_zone" "$allow_udp_rule" || return 1
            ensure_firewalld_rich_rule "$default_zone" "$deny_tcp_rule" || return 1
            ensure_firewalld_rich_rule "$default_zone" "$deny_udp_rule" || return 1
            firewall-cmd --reload >/dev/null || return 1
            firewall_action_taken=true
            firewall_status_summary="firewalld: 端口 ${server_port} 仅允许 ${restricted_ip}"
            ;;
        block_cn)
            local ipset_name="ss_cn_block_${server_port}"
            local cn_file
            local block_tcp_rule
            local block_udp_rule

            cn_file=$(mktemp)
            if ! download_cn_ipv4_list "$cn_file"; then
                rm -f "$cn_file"
                echo_error "下载大陆 IP 网段列表失败，无法应用屏蔽大陆策略。"
                return 1
            fi

            echo_info "正在配置 firewalld：屏蔽大陆访问端口 $server_port (TCP/UDP)..."
            if firewall-cmd --permanent --get-ipsets | tr ' ' '\n' | grep -qx "$ipset_name"; then
                firewall-cmd --permanent --delete-ipset="$ipset_name" >/dev/null || {
                    rm -f "$cn_file"
                    return 1
                }
            fi

            firewall-cmd --permanent --new-ipset="$ipset_name" --type=hash:net >/dev/null || {
                rm -f "$cn_file"
                return 1
            }

            sync_firewalld_ipset_from_file "$ipset_name" "$cn_file" || {
                rm -f "$cn_file"
                return 1
            }
            rm -f "$cn_file"

            ensure_firewalld_port "$default_zone" "$server_port/tcp" || return 1
            ensure_firewalld_port "$default_zone" "$server_port/udp" || return 1

            block_tcp_rule="rule family=\"ipv4\" priority=\"-50\" source ipset=\"${ipset_name}\" port port=\"${server_port}\" protocol=\"tcp\" drop"
            block_udp_rule="rule family=\"ipv4\" priority=\"-50\" source ipset=\"${ipset_name}\" port port=\"${server_port}\" protocol=\"udp\" drop"
            ensure_firewalld_rich_rule "$default_zone" "$block_tcp_rule" || return 1
            ensure_firewalld_rich_rule "$default_zone" "$block_udp_rule" || return 1

            firewall-cmd --reload >/dev/null || return 1
            firewall_action_taken=true
            firewall_status_summary="firewalld: 端口 ${server_port} 已配置为屏蔽大陆"
            ;;
        *)
            echo_error "未知的 firewalld 策略：$firewall_policy"
            return 1
            ;;
    esac

    return 0
}

apply_firewall_plan() {
    if [ "$configure_firewall" != true ]; then
        firewall_action_taken=false
        firewall_status_summary="未自动配置"
        return 0
    fi

    ensure_apt_updated || return 1

    case "$firewall_backend" in
        ufw)
            if [ "$install_firewall_package" = true ]; then
                echo_info "正在安装 ufw ..."
                apt install -y ufw || return 1
            fi

            if ! command -v ufw &> /dev/null; then
                echo_error "未找到 ufw，无法应用防火墙策略。"
                return 1
            fi

            if [ "$install_firewall_package" = true ] && [ "$firewall_is_existing" = false ]; then
                echo_info "新安装 ufw：保持其他端口开放，仅处理端口 $server_port。"
                ufw default allow incoming >/dev/null || return 1
                ufw default allow outgoing >/dev/null || return 1
            fi

            if ! ufw status 2>/dev/null | grep -q "Status: active"; then
                echo_info "启用 ufw ..."
                ufw --force enable >/dev/null || return 1
            fi

            apply_ufw_policy || return 1
            ;;
        firewalld)
            if [ "$install_firewall_package" = true ]; then
                echo_info "正在安装 firewalld ..."
                apt install -y firewalld || return 1
            fi

            if ! command -v firewall-cmd &> /dev/null; then
                echo_error "未找到 firewalld，无法应用防火墙策略。"
                return 1
            fi

            if ! systemctl is-active --quiet firewalld; then
                echo_info "启动 firewalld ..."
                systemctl enable --now firewalld || return 1
            fi

            if [ "$install_firewall_package" = true ] && [ "$firewall_is_existing" = false ]; then
                local default_zone
                default_zone=$(firewall-cmd --get-default-zone 2>/dev/null)
                if [ -z "$default_zone" ]; then
                    echo_error "无法获取 firewalld 默认 zone。"
                    return 1
                fi

                echo_info "新安装 firewalld：保持其他端口开放，仅处理端口 $server_port。"
                firewall-cmd --permanent --zone="$default_zone" --set-target=ACCEPT >/dev/null || return 1
                firewall-cmd --zone="$default_zone" --set-target=ACCEPT >/dev/null || return 1
            fi

            apply_firewalld_policy || return 1
            ;;
        *)
            echo_error "未知的防火墙后端：$firewall_backend"
            return 1
            ;;
    esac

    return 0
}

select_firewall_plan() {
    local have_ufw=false
    local have_firewalld=false
    local default_backend_choice=1

    read -rp "$(echo -e "${YELLOW}是否在安装前配置防火墙？ (y/N): ${NC}")" firewall_setup_choice
    if [[ "$firewall_setup_choice" != "y" && "$firewall_setup_choice" != "Y" ]]; then
        configure_firewall=false
        firewall_backend="none"
        firewall_policy="none"
        firewall_plan_summary="不自动配置"
        return 0
    fi

    configure_firewall=true

    if command -v ufw &> /dev/null; then
        have_ufw=true
    fi
    if command -v firewall-cmd &> /dev/null; then
        have_firewalld=true
    fi

    if [ "$have_ufw" = true ] && [ "$have_firewalld" = true ]; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            default_backend_choice=1
        elif systemctl is-active --quiet firewalld; then
            default_backend_choice=2
        else
            default_backend_choice=1
        fi

        echo_info "检测到系统已安装多种防火墙，请选择使用:"
        echo -e "  1) ufw ${BLUE}$(if [ "$default_backend_choice" -eq 1 ]; then echo "(默认)"; fi)${NC}"
        echo -e "  2) firewalld ${BLUE}$(if [ "$default_backend_choice" -eq 2 ]; then echo "(默认)"; fi)${NC}"
        read -rp "$(echo -e "${YELLOW}请输入选项 (1/2，默认 ${default_backend_choice}): ${NC}")" backend_choice
        backend_choice=${backend_choice:-$default_backend_choice}

        case "$backend_choice" in
            1)
                firewall_backend="ufw"
                ;;
            2)
                firewall_backend="firewalld"
                ;;
            *)
                echo_warning "无效选择，使用默认防火墙后端。"
                if [ "$default_backend_choice" -eq 1 ]; then
                    firewall_backend="ufw"
                else
                    firewall_backend="firewalld"
                fi
                ;;
        esac

        firewall_is_existing=true
        install_firewall_package=false
    elif [ "$have_ufw" = true ]; then
        firewall_backend="ufw"
        firewall_is_existing=true
        install_firewall_package=false
        echo_info "检测到已安装 ufw，将在现有规则基础上修改。"
    elif [ "$have_firewalld" = true ]; then
        firewall_backend="firewalld"
        firewall_is_existing=true
        install_firewall_package=false
        echo_info "检测到已安装 firewalld，将在现有规则基础上修改。"
    else
        firewall_is_existing=false
        install_firewall_package=true

        echo_warning "未检测到 ufw 或 firewalld。"
        echo_info "请选择安装防火墙软件（默认 ufw）："
        echo -e "  1) ufw ${BLUE}(默认)${NC}"
        echo -e "  2) firewalld"
        echo -e "  3) 不配置防火墙"
        read -rp "$(echo -e "${YELLOW}请输入选项 (1/2/3，默认 1): ${NC}")" install_fw_choice
        install_fw_choice=${install_fw_choice:-1}

        case "$install_fw_choice" in
            1)
                firewall_backend="ufw"
                ;;
            2)
                firewall_backend="firewalld"
                ;;
            3)
                configure_firewall=false
                firewall_backend="none"
                firewall_policy="none"
                firewall_plan_summary="不自动配置"
                install_firewall_package=false
                return 0
                ;;
            *)
                echo_warning "无效选择，默认安装 ufw。"
                firewall_backend="ufw"
                ;;
        esac

        echo_info "将安装 ${firewall_backend} 并保持其他端口开放，仅处理端口 $server_port。"
    fi

    echo_info "请选择防火墙策略:"
    echo -e "  1) ${GREEN}对所有 IP 开放${NC}"
    echo -e "  2) ${YELLOW}仅对特定 IP 开放${NC}"
    echo -e "  3) ${RED}屏蔽大陆${NC}"
    read -rp "$(echo -e "${YELLOW}请输入选项 (1/2/3，默认 1): ${NC}")" policy_choice
    policy_choice=${policy_choice:-1}

    case "$policy_choice" in
        1)
            firewall_policy="all"
            firewall_plan_summary="对所有 IP 开放"
            ;;
        2)
            firewall_policy="ip"
            read -rp "$(echo -e "${YELLOW}请输入允许访问的特定 IPv4 地址: ${NC}")" restricted_ip
            if [ -z "$restricted_ip" ]; then
                echo_error "特定 IP 不能为空。"
                return 1
            fi
            if ! is_valid_ipv4 "$restricted_ip"; then
                echo_error "无效的 IPv4 地址：${restricted_ip}"
                return 1
            fi
            firewall_plan_summary="仅允许 ${restricted_ip}"
            ;;
        3)
            firewall_policy="block_cn"
            firewall_plan_summary="屏蔽大陆"
            ;;
        *)
            echo_warning "无效选择，将默认对所有 IP 开放。"
            firewall_policy="all"
            firewall_plan_summary="对所有 IP 开放"
            ;;
    esac

    return 0
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo_error "无法检测到操作系统发行版。"
        return 1
    fi

    if [ "$OS" != "debian" ] && [ "$OS" != "ubuntu" ]; then
        echo_error "不支持的操作系统: $OS。此脚本仅支持 Debian 和 Ubuntu。"
        return 1
    fi

    return 0
}

install_shadowsocks() {
    echo_info "开始安装 Shadowsocks (libsodium)..."

    install_missing_packages curl sudo jq qrencode || return 1

    echo_info "正在从 APT 仓库安装 shadowsocks-libev..."
    if ! apt install -y shadowsocks-libev; then
        echo_error "安装 shadowsocks-libev 失败。请尝试手动安装或检查软件源。"
        return 1
    fi

    echo_info "配置 Shadowsocks 服务..."

    # 使用 jq 生成配置文件，避免密码中的特殊字符破坏 JSON
    if ! jq -n \
        --arg server "0.0.0.0" \
        --argjson server_port "$server_port" \
        --arg password "$ss_password" \
        --arg method "$encrypt_method" \
        '{
            server: $server,
            server_port: $server_port,
            password: $password,
            timeout: 300,
            method: $method,
            fast_open: false,
            nameserver: "8.8.8.8",
            mode: "tcp_and_udp"
        }' > /etc/shadowsocks-libev/config.json; then
        echo_error "写入配置文件失败：/etc/shadowsocks-libev/config.json"
        return 1
    fi

    echo_info "启动并设置 Shadowsocks 服务开机自启..."
    systemctl enable shadowsocks-libev >/dev/null
    systemctl restart shadowsocks-libev

    sleep 2
    if systemctl is-active --quiet shadowsocks-libev; then
        echo_success "Shadowsocks 服务已成功启动！"
        return 0
    fi

    echo_error "Shadowsocks 服务启动失败。请检查日志：journalctl -u shadowsocks-libev"
    echo_error "配置文件路径: /etc/shadowsocks-libev/config.json"
    return 1
}

apt_updated=false
OS=""

# 防火墙计划变量
configure_firewall=false
firewall_backend="none"
firewall_policy="none"
firewall_plan_summary="不自动配置"
firewall_status_summary="未自动配置"
firewall_is_existing=false
install_firewall_package=false
firewall_action_taken=false
restricted_ip=""

# 交互式获取配置信息
echo_info "开始配置 Shadowsocks 服务..."

# 获取服务器 IP 地址 (优先公网 IP，失败则使用本机 IP 并提示确认)
server_ip=$(detect_public_ip)
if [ -n "$server_ip" ] && ! is_valid_ipv4 "$server_ip"; then
    echo_warning "自动检测到的 IP (${server_ip}) 不是有效 IPv4，已忽略。"
    server_ip=""
fi
if [ -z "$server_ip" ]; then
    server_ip=$(hostname -I | awk '{print $1}')
    if [ -n "$server_ip" ] && ! is_valid_ipv4 "$server_ip"; then
        echo_warning "本机地址 (${server_ip}) 不是有效 IPv4，请手动输入公网 IPv4。"
        server_ip=""
    fi
fi
if [ -z "$server_ip" ]; then
    read -rp "$(echo -e "${YELLOW}请输入您的服务器公网 IP 地址: ${NC}")" server_ip
    if [ -z "$server_ip" ]; then
        echo_error "服务器 IP 地址不能为空！"
        exit 1
    elif ! is_valid_ipv4 "$server_ip"; then
        echo_error "无效的 IPv4 地址：${server_ip}"
        exit 1
    fi
elif is_private_ipv4 "$server_ip"; then
    echo_warning "自动检测到的 IP (${server_ip}) 可能是内网地址。"
    read -rp "$(echo -e "${YELLOW}请输入服务器公网 IP 地址 (回车保留当前值): ${NC}")" input_server_ip
    if [ -n "$input_server_ip" ]; then
        if is_valid_ipv4 "$input_server_ip"; then
            server_ip=$input_server_ip
        else
            echo_error "无效的 IPv4 地址：${input_server_ip}"
            exit 1
        fi
    fi
fi

# 获取端口号
default_port=8388
read -rp "$(echo -e "${YELLOW}请输入 Shadowsocks 服务端口号 (默认: ${default_port}): ${NC}")" server_port
server_port=${server_port:-$default_port}
if ! [[ "$server_port" =~ ^[0-9]+$ ]] || [ "$server_port" -lt 1 ] || [ "$server_port" -gt 65535 ]; then
    echo_error "无效的端口号：${server_port}。请输入 1-65535 之间的数字。"
    exit 1
fi

# 获取密码
default_password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
read -rp "$(echo -e "${YELLOW}请输入 Shadowsocks 密码 (默认: 自动生成随机密码): ${NC}")" ss_password
ss_password=${ss_password:-$default_password}
if [ -z "$ss_password" ]; then
    echo_error "密码不能为空！"
    exit 1
fi

# 获取加密方法
echo_info "请选择加密方法:"
encrypt_methods=(
    "aes-256-gcm"
    "aes-128-gcm"
    "chacha20-ietf-poly1305"
    "xchacha20-ietf-poly1305"
    "aes-256-cfb"
    "aes-128-cfb"
    "camellia-256-cfb"
    "camellia-128-cfb"
)
default_encrypt_method="aes-256-gcm"

for i in "${!encrypt_methods[@]}"; do
    echo -e "  $(($i+1))) ${encrypt_methods[$i]} ${BLUE}$(if [ "${encrypt_methods[$i]}" == "$default_encrypt_method" ]; then echo "(默认)"; fi)${NC}"
done

read -rp "$(echo -e "${YELLOW}请输入选项数字 (默认: 1 for ${default_encrypt_method}): ${NC}")" encrypt_choice
encrypt_choice=${encrypt_choice:-1}

if [[ "$encrypt_choice" =~ ^[0-9]+$ ]] && [ "$encrypt_choice" -ge 1 ] && [ "$encrypt_choice" -le "${#encrypt_methods[@]}" ]; then
    encrypt_method=${encrypt_methods[$((encrypt_choice-1))]}
else
    echo_warning "无效的选择，将使用默认加密方法: ${default_encrypt_method}"
    encrypt_method=$default_encrypt_method
fi

# 防火墙配置计划
if ! select_firewall_plan; then
    exit 1
fi

echo ""
echo_info "配置确认:"
echo -e "  ${YELLOW}服务器 IP:${NC}   $server_ip"
echo -e "  ${YELLOW}服务器端口:${NC} $server_port"
echo -e "  ${YELLOW}密码:${NC}       $ss_password"
echo -e "  ${YELLOW}加密方法:${NC}   $encrypt_method"
if [ "$configure_firewall" = true ]; then
    echo -e "  ${YELLOW}防火墙后端:${NC} $firewall_backend $(if [ "$firewall_is_existing" = true ]; then echo "(已有)"; else echo "(新安装)"; fi)"
    echo -e "  ${YELLOW}防火墙策略:${NC} $firewall_plan_summary"
else
    echo -e "  ${YELLOW}防火墙策略:${NC} 不自动配置"
fi
echo ""

read -rp "$(echo -e "${YELLOW}确认以上配置并开始执行吗？ (y/N): ${NC}")" confirm_install
if [[ "$confirm_install" != "y" && "$confirm_install" != "Y" ]]; then
    echo_info "安装已取消。"
    exit 0
fi

detect_os || exit 1
ensure_apt_updated || exit 1

# 按要求：先执行防火墙策略，再安装 Shadowsocks
if [ "$configure_firewall" = true ]; then
    echo_info "先应用防火墙策略..."
    if ! apply_firewall_plan; then
        echo_error "防火墙策略执行失败，已停止安装 Shadowsocks。"
        exit 1
    fi
else
    firewall_status_summary="未自动配置"
fi

if ! install_shadowsocks; then
    exit 1
fi

# 生成 ss:// 链接
encoded_password=$(urlencode "$ss_password")
ss_link_plain="ss://${encrypt_method}:${encoded_password}@${server_ip}:${server_port}"
ss_link_base64="ss://$(echo -n "${encrypt_method}:${ss_password}@${server_ip}:${server_port}" | base64 -w 0 | tr '+/' '-_' | tr -d '=')"
clash_password_json=$(jq -Rn --arg v "$ss_password" '$v')

# 输出必要信息
echo ""
echo_success "🎉 Shadowsocks 安装完成！🎉"
echo "==================================================="
echo -e "${GREEN}您的 Shadowsocks 配置信息如下:${NC}"
echo "---------------------------------------------------"
echo -e "  ${YELLOW}服务器地址 (Server IP):${NC}  ${server_ip}"
echo -e "  ${YELLOW}服务器端口 (Server Port):${NC} ${server_port}"
echo -e "  ${YELLOW}密码 (Password):${NC}        ${ss_password}"
echo -e "  ${YELLOW}加密方法 (Encryption):${NC}  ${encrypt_method}"
if [ "$firewall_action_taken" = true ]; then
    echo -e "  ${YELLOW}防火墙:${NC}         ${GREEN}${firewall_status_summary}${NC}"
else
    echo -e "  ${YELLOW}防火墙:${NC}         ${RED}${firewall_status_summary}${NC}"
fi
echo "---------------------------------------------------"
echo -e "${GREEN}SS 链接 (明文):${NC}"
echo -e "  ${BLUE}${ss_link_plain}${NC}"
echo "---------------------------------------------------"
echo -e "${GREEN}SS 链接 (Base64):${NC}"
echo -e "  ${BLUE}${ss_link_base64}${NC}"
echo "---------------------------------------------------"

if command -v qrencode &> /dev/null; then
    echo -e "${GREEN}SS 链接二维码 (扫描导入):${NC}"
    qrencode -t ansiutf8 "${ss_link_base64}"
    echo "---------------------------------------------------"
fi

echo -e "${GREEN}Clash (YAML) 配置片段:${NC}"
echo "   proxies:"
echo "    - name: \"SS-$(hostname)-${server_port}\" # 您可以自定义名称"
echo "      type: ss"
echo "      server: ${server_ip}"
echo "      port: ${server_port}"
echo "      password: ${clash_password_json}"
echo "      cipher: ${encrypt_method}"
echo "      udp: true # 根据您的 Shadowsocks 服务端配置调整，这里默认开启 UDP"
echo "==================================================="

echo_info "请妥善保管您的配置信息。"
if [ "$firewall_action_taken" != true ]; then
    echo_warning "请再次注意：防火墙端口 ${server_port} 未自动配置，您可能需要手动开放才能连接。"
fi
echo_info "如果服务无法连接，请检查防火墙设置以及服务日志: journalctl -u shadowsocks-libev"

exit 0

