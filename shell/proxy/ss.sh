#!/bin/bash

# Shadowsocs 安装脚本 (Debian/Ubuntu)

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
# 验证端口号是否为数字且在有效范围内
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
    encrypt_method=${encrypt_methods[$(($encrypt_choice-1))]}
else
    echo_warning "无效的选择，将使用默认加密方法: ${default_encrypt_method}"
    encrypt_method=$default_encrypt_method
fi

echo ""
echo_info "配置确认:"
echo -e "  ${YELLOW}服务器 IP:${NC}   $server_ip"
echo -e "  ${YELLOW}服务器端口:${NC} $server_port"
echo -e "  ${YELLOW}密码:${NC}       $ss_password"
echo -e "  ${YELLOW}加密方法:${NC}   $encrypt_method"
echo ""

read -rp "$(echo -e "${YELLOW}确认以上配置并开始安装吗？ (y/N): ${NC}")" confirm_install
if [[ "$confirm_install" != "y" && "$confirm_install" != "Y" ]]; then
    echo_info "安装已取消。"
    exit 0
fi

echo_info "开始安装 Shadowsocks (libsodium)..."

# 更新软件包列表并安装依赖
if ! apt update -y; then
    echo_error "apt update 失败，请检查网络连接和 APT 源配置。"
    exit 1
fi
if ! command -v curl &> /dev/null || ! command -v sudo &> /dev/null || ! command -v jq &> /dev/null || ! command -v qrencode &> /dev/null; then
    echo_info "正在安装必要的工具: curl, sudo, jq, qrencode..."
    apt install -y curl sudo jq qrencode
    if [ $? -ne 0 ]; then
        echo_error "安装依赖失败，请检查网络连接或手动安装。"
        exit 1
    fi
fi

# 安装 shadowsocks-libev
# 检查发行版
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo_error "无法检测到操作系统发行版。"
    exit 1
fi

if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
    echo_info "正在从 APT 仓库安装 shadowsocks-libev..."
    apt install -y shadowsocks-libev
    if [ $? -ne 0 ]; then
        echo_error "安装 shadowsocks-libev 失败。请尝试手动安装或检查软件源。"
        exit 1
    fi
else
    echo_error "不支持的操作系统: $OS。此脚本仅支持 Debian 和 Ubuntu。"
    exit 1
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
    exit 1
fi

echo_info "启动并设置 Shadowsocks 服务开机自启..."
systemctl enable shadowsocks-libev
systemctl restart shadowsocks-libev

# 检查服务状态
sleep 2 # 等待服务启动
if systemctl is-active --quiet shadowsocks-libev; then
    echo_success "Shadowsocks 服务已成功启动！"
else
    echo_error "Shadowsocks 服务启动失败。请检查日志：journalctl -u shadowsocks-libev"
    echo_error "配置文件路径: /etc/shadowsocks-libev/config.json"
    exit 1
fi

# --- 防火墙设置修改开始 ---
firewall_action_taken=false
restricted_ip=""

ensure_firewalld_zone() {
    local zone_name=$1
    if firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx "$zone_name"; then
        return 0
    fi
    firewall-cmd --permanent --new-zone="$zone_name" --quiet
}

ensure_firewalld_source() {
    local zone_name=$1
    local source_ip=$2
    if firewall-cmd --permanent --zone="$zone_name" --query-source="$source_ip" --quiet; then
        return 0
    fi
    firewall-cmd --permanent --zone="$zone_name" --add-source="$source_ip" --quiet
}

ensure_firewalld_port() {
    local zone_name=$1
    local port_proto=$2
    if firewall-cmd --permanent --zone="$zone_name" --query-port="$port_proto" --quiet; then
        return 0
    fi
    firewall-cmd --permanent --zone="$zone_name" --add-port="$port_proto" --quiet
}

handle_ufw() {
    echo_info "检测到 ufw 防火墙。请选择如何开放端口 $server_port:"
    echo -e "  1) ${GREEN}为所有 IP 开放端口 (推荐，如果服务器公网访问)${NC}"
    echo -e "  2) ${YELLOW}仅为特定 IP 开放端口 (更安全)${NC}"
    echo -e "  3) ${RED}不自动开放端口 (您需要手动配置)${NC}"
    read -rp "$(echo -e "${YELLOW}请输入选项 (1/2/3，默认 1): ${NC}")" fw_choice
    fw_choice=${fw_choice:-1}

    case $fw_choice in
        1)
            echo_info "正在为所有 IP 开放端口 $server_port (TCP/UDP) ..."
            if ufw allow "$server_port/tcp" && ufw allow "$server_port/udp" && ufw reload; then
                echo_success "ufw: 端口 $server_port (TCP/UDP) 已为所有 IP 开放。"
                firewall_action_taken=true
            else
                echo_error "ufw 规则应用失败，请手动检查 ufw 状态和规则。"
            fi
            ;;
        2)
            read -rp "$(echo -e "${YELLOW}请输入允许访问的特定 IP 地址: ${NC}")" specific_ip
            if [ -z "$specific_ip" ]; then
                echo_warning "未输入 IP 地址，将不开放端口。"
                echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则。"
            elif ! is_valid_ipv4 "$specific_ip"; then
                echo_error "无效的 IPv4 地址：${specific_ip}。将不自动开放端口。"
            else
                echo_info "正在为 IP $specific_ip 开放端口 $server_port (TCP/UDP) ..."
                if ufw allow from "$specific_ip" to any port "$server_port" proto tcp \
                    && ufw allow from "$specific_ip" to any port "$server_port" proto udp \
                    && ufw reload; then
                    echo_success "ufw: 端口 $server_port (TCP/UDP) 已为 IP $specific_ip 开放。"
                    firewall_action_taken=true
                    restricted_ip=$specific_ip
                else
                    echo_error "ufw 规则应用失败，请手动检查 ufw 状态和规则。"
                fi
            fi
            ;;
        3)
            echo_warning "您选择了不自动开放端口。"
            echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则以允许连接。"
            ;;
        *)
            echo_warning "无效的选择。将不自动开放端口。"
            echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则以允许连接。"
            ;;
    esac
}

handle_firewalld() {
    echo_info "检测到 firewalld 防火墙。请选择如何开放端口 $server_port:"
    echo -e "  1) ${GREEN}为所有 IP 开放端口 (推荐，如果服务器公网访问)${NC}"
    echo -e "  2) ${YELLOW}仅为特定 IP 开放端口 (更安全)${NC}"
    echo -e "  3) ${RED}不自动开放端口 (您需要手动配置)${NC}"
    read -rp "$(echo -e "${YELLOW}请输入选项 (1/2/3，默认 1): ${NC}")" fw_choice
    fw_choice=${fw_choice:-1}

    case $fw_choice in
        1)
            echo_info "正在为所有 IP 开放端口 $server_port (TCP/UDP) ..."
            local default_zone
            default_zone=$(firewall-cmd --get-default-zone 2>/dev/null)
            if [ -z "$default_zone" ]; then
                echo_error "无法获取 firewalld 默认 zone。"
                return 1
            fi
            if ensure_firewalld_port "$default_zone" "$server_port/tcp" \
                && ensure_firewalld_port "$default_zone" "$server_port/udp" \
                && firewall-cmd --reload; then
                echo_success "firewalld: 端口 $server_port (TCP/UDP) 已在默认 zone (${default_zone}) 开放。"
                firewall_action_taken=true
            else
                echo_error "firewalld 规则应用失败，请手动检查 firewalld 状态和规则。"
            fi
            ;;
        2)
            read -rp "$(echo -e "${YELLOW}请输入允许访问的特定 IP 地址: ${NC}")" specific_ip
            if [ -z "$specific_ip" ]; then
                echo_warning "未输入 IP 地址，将不开放端口。"
                echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则。"
            elif ! is_valid_ipv4 "$specific_ip"; then
                echo_error "无效的 IPv4 地址：${specific_ip}。将不自动开放端口。"
            else
                echo_info "正在为 IP $specific_ip 开放端口 $server_port (TCP/UDP) ..."
                if ensure_firewalld_zone sslimit \
                    && ensure_firewalld_source sslimit "$specific_ip" \
                    && ensure_firewalld_port sslimit "$server_port/tcp" \
                    && ensure_firewalld_port sslimit "$server_port/udp" \
                    && firewall-cmd --reload; then
                    echo_success "firewalld: 端口 $server_port (TCP/UDP) 已通过区域 'sslimit' 为 IP $specific_ip 开放。"
                    echo_info "注意: firewalld 的 IP 限制是通过创建/复用 zone (sslimit) 并将源 IP 和端口添加到该 zone 来实现的。"
                    firewall_action_taken=true
                    restricted_ip=$specific_ip
                else
                    echo_error "firewalld 规则应用失败，请手动检查 firewalld 状态和规则。"
                fi
            fi
            ;;
        3)
            echo_warning "您选择了不自动开放端口。"
            echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则以允许连接。"
            ;;
        *)
            echo_warning "无效的选择。将不自动开放端口。"
            echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则以允许连接。"
            ;;
    esac
}

if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    handle_ufw
elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
    handle_firewalld
else
    echo_warning "未检测到 ufw 或 firewalld 防火墙，或者防火墙未激活。"
    echo_warning "如果您的服务器有其他防火墙，请确保手动开放端口 $server_port (TCP 和 UDP) 以允许外部连接。"
fi
# --- 防火墙设置修改结束 ---


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
if [ "$firewall_action_taken" = true ] && [ -n "$restricted_ip" ]; then
    echo -e "  ${YELLOW}防火墙:${NC}         端口 ${server_port} 已为特定 IP ${GREEN}${restricted_ip}${NC} 开放"
elif [ "$firewall_action_taken" = true ]; then
    echo -e "  ${YELLOW}防火墙:${NC}         端口 ${server_port} 已为 ${GREEN}所有 IP${NC} 开放"
else
    echo -e "  ${YELLOW}防火墙:${NC}         ${RED}端口 ${server_port} 未自动配置，请手动检查或开放${NC}"
fi
echo "---------------------------------------------------"
echo -e "${GREEN}SS 链接 (明文):${NC}"
echo -e "  ${BLUE}${ss_link_plain}${NC}"
echo "---------------------------------------------------"
echo -e "${GREEN}SS 链接 (Base64):${NC}"
echo -e "  ${BLUE}${ss_link_base64}${NC}"
echo "---------------------------------------------------"
# 生成二维码 (如果 qrencode 已安装)
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
# 如果需要，可以添加更多 Clash 支持的 Shadowsocks 参数，例如：
# echo "      # plugin: obfs" # 如果你使用了 obfs 插件
# echo "      # plugin-opts:"
# echo "      #   mode: http"
# echo "      #   host: example.com"
echo "==================================================="
echo_info "请妥善保管您的配置信息。"
if ! $firewall_action_taken; then
    echo_warning "请再次注意：防火墙端口 ${server_port} 未自动配置，您可能需要手动开放才能连接。"
fi
echo_info "如果服务无法连接，请检查防火墙设置以及服务日志: journalctl -u shadowsocks-libev"

exit 0