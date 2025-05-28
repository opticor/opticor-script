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

# 交互式获取配置信息
echo_info "开始配置 Shadowsocks 服务..."

# 获取服务器 IP 地址 (尝试自动获取，否则提示输入)
server_ip=$(hostname -I | awk '{print $1}')
if [ -z "$server_ip" ]; then
    read -rp "$(echo -e "${YELLOW}请输入您的服务器公网 IP 地址: ${NC}")" server_ip
    if [ -z "$server_ip" ]; then
        echo_error "服务器 IP 地址不能为空！"
        exit 1
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
apt update -y
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

# 创建配置文件
cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server":"0.0.0.0",
    "server_port":${server_port},
    "password":"${ss_password}",
    "timeout":300,
    "method":"${encrypt_method}",
    "fast_open":false,
    "nameserver":"8.8.8.8",
    "mode":"tcp_and_udp"
}
EOF

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
            ufw allow "$server_port/tcp"
            ufw allow "$server_port/udp"
            ufw reload
            echo_success "ufw: 端口 $server_port (TCP/UDP) 已为所有 IP 开放。"
            firewall_action_taken=true
            ;;
        2)
            read -rp "$(echo -e "${YELLOW}请输入允许访问的特定 IP 地址: ${NC}")" specific_ip
            if [ -z "$specific_ip" ]; then
                echo_warning "未输入 IP 地址，将不开放端口。"
                echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则。"
            else
                echo_info "正在为 IP $specific_ip 开放端口 $server_port (TCP/UDP) ..."
                ufw allow from "$specific_ip" to any port "$server_port" proto tcp
                ufw allow from "$specific_ip" to any port "$server_port" proto udp
                ufw reload
                echo_success "ufw: 端口 $server_port (TCP/UDP) 已为 IP $specific_ip 开放。"
                firewall_action_taken=true
                restricted_ip=$specific_ip
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
            firewall-cmd --permanent --add-port="$server_port/tcp"
            firewall-cmd --permanent --add-port="$server_port/udp"
            firewall-cmd --reload
            echo_success "firewalld: 端口 $server_port (TCP/UDP) 已为所有 IP 开放。"
            firewall_action_taken=true
            ;;
        2)
            read -rp "$(echo -e "${YELLOW}请输入允许访问的特定 IP 地址: ${NC}")" specific_ip
            if [ -z "$specific_ip" ]; then
                echo_warning "未输入 IP 地址，将不开放端口。"
                echo_warning "请确保手动为端口 $server_port (TCP/UDP) 配置防火墙规则。"
            else
                echo_info "正在为 IP $specific_ip 开放端口 $server_port (TCP/UDP) ..."
                firewall-cmd --permanent --new-zone=sslimit --quiet
                firewall-cmd --permanent --zone=sslimit --add-source="$specific_ip" --quiet
                firewall-cmd --permanent --zone=sslimit --add-port="$server_port/tcp" --quiet
                firewall-cmd --permanent --zone=sslimit --add-port="$server_port/udp" --quiet
                firewall-cmd --reload
                echo_success "firewalld: 端口 $server_port (TCP/UDP) 已通过新区域 'sslimit' 为 IP $specific_ip 开放。"
                echo_info "注意: firewalld 的 IP 限制是通过创建一个新的 zone (sslimit) 并将源 IP 和端口添加到该 zone 来实现的。"
                firewall_action_taken=true
                restricted_ip=$specific_ip
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
elif command -v firewalld &> /dev/null && systemctl is-active --quiet firewalld; then
    handle_firewalld
else
    echo_warning "未检测到 ufw 或 firewalld 防火墙，或者防火墙未激活。"
    echo_warning "如果您的服务器有其他防火墙，请确保手动开放端口 $server_port (TCP 和 UDP) 以允许外部连接。"
fi
# --- 防火墙设置修改结束 ---


# 生成 ss:// 链接
ss_link_plain="ss://${encrypt_method}:${ss_password}@${server_ip}:${server_port}"
ss_link_base64="ss://$(echo -n "${encrypt_method}:${ss_password}@${server_ip}:${server_port}" | base64 -w 0)"

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
echo "      password: \"${ss_password}\""
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