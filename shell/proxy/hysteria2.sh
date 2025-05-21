#!/bin/bash

# Hysteria 2  (支持参数化与交互式)

# --- 默认配置 ---
DEFAULT_PORT="443"
DEFAULT_MASQUERADE_URL="https://bing.com" # 改为 bing.com 作为默认值
HYSTERIA_CONFIG_FILE="/etc/hysteria/config.yaml"
HYSTERIA_SERVICE_NAME="hysteria-server.service"
SERVICE_DIR="/etc/systemd/system/"

# --- 变量初始化 ---
PORT=""
DOMAIN=""
EMAIL=""
CF_TOKEN=""
PASSWORD=""
MASQUERADE_URL=""
NON_INTERACTIVE=false

# --- 颜色代码 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m' # No Color

# --- 辅助函数 ---
function print_info() { echo -e "${BLUE}[信息] ${1}${NC}"; }
function print_ok() { echo -e "${GREEN}[成功] ${1}${NC}"; }
function print_warning() { echo -e "${YELLOW}[警告] ${1}${NC}"; }
function print_error() { echo -e "${RED}[错误] ${1}${NC}"; }
function check_root() { if [[ "$(id -u)" -ne 0 ]]; then print_error "此脚本必须以 root 用户身份运行。"; exit 1; fi; }

# --- 帮助信息 ---
function display_help() {
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  --port <端口号>         指定 Hysteria 监听端口 (默认: ${DEFAULT_PORT})"
    echo "  --domain <域名>         指定用于申请证书的域名 (必需)"
    echo "  --email <邮箱>          指定 ACME 证书申请邮箱 (必需)"
    echo "  --cf-token <令牌>       指定 Cloudflare API Token (必需)"
    echo "  --password <密码>       指定连接密码 (默认: 随机生成)"
    echo "  --masquerade-url <URL>  指定伪装访问的目标 URL (默认: ${DEFAULT_MASQUERADE_URL})"
    echo "  --non-interactive      启用非交互模式，缺少必要参数则报错"
    echo "  --help                 显示此帮助信息"
    echo
    echo "示例:"
    echo "  sudo $0 --domain hy.example.com --email user@example.com --cf-token YOUR_TOKEN"
    echo "  sudo $0 --domain hy.example.com --email user@example.com --cf-token YOUR_TOKEN --port 12345 --password mypass --non-interactive"
    exit 0
}

# --- 参数解析 ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "--port 需要一个值"; exit 1; fi
            PORT="$2"; shift 2 ;;
        --domain)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "--domain 需要一个值"; exit 1; fi
            DOMAIN="$2"; shift 2 ;;
        --email)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "--email 需要一个值"; exit 1; fi
            EMAIL="$2"; shift 2 ;;
        --cf-token)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "--cf-token 需要一个值"; exit 1; fi
            CF_TOKEN="$2"; shift 2 ;;
        --password)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "--password 需要一个值"; exit 1; fi
            PASSWORD="$2"; shift 2 ;;
        --masquerade-url)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "--masquerade-url 需要一个值"; exit 1; fi
            MASQUERADE_URL="$2"; shift 2 ;;
        --non-interactive)
            NON_INTERACTIVE=true; shift 1 ;;
        --help)
            display_help ;;
        *)
            print_error "未知选项: $1"; display_help ;;
    esac
done

# --- 检查依赖 ---
function check_dependencies() {
    local missing_deps=()
    if ! command -v curl &> /dev/null; then missing_deps+=("curl"); fi
    if ! command -v openssl &> /dev/null; then missing_deps+=("openssl"); fi # Needed for password generation

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "缺少依赖项: ${missing_deps[*]}。请先安装它们。"
        # 可以尝试自动安装，但这里选择报错退出
        exit 1
    fi
    print_ok "依赖项检查通过。"
}

# --- 安装 Hysteria ---
function install_hysteria() {
    print_info "检查 Hysteria 安装状态..."
    # 注意: hysteria 2.x 的可执行文件名可能就是 `hysteria`
    if command -v hysteria &> /dev/null; then
        # 获取版本信息可能需要特定命令，例如 hysteria version
        local current_version
        current_version=$(hysteria version 2>/dev/null || echo "未知版本")
        print_ok "Hysteria 已安装 (${current_version})。跳过安装步骤。"
        # 可以选择在这里提供更新选项，但暂时跳过
        return 0
    fi

    print_info "正在使用官方脚本安装 Hysteria..."
    # 使用 /bin/bash 执行，增加兼容性
    if /bin/bash <(curl -fsSL https://get.hy2.sh/); then
        print_ok "Hysteria 安装完成！"
        # 验证安装是否成功
        if ! command -v hysteria &> /dev/null; then
             print_error "安装后未能找到 hysteria 命令，请检查安装日志。"
             exit 1
        fi
    else
        print_error "Hysteria 安装脚本执行失败。"
        exit 1
    fi
}

# --- 获取配置值 (结合参数和交互) ---
function get_config_values() {
    print_info "准备 Hysteria 配置..."

    # 端口
    if [[ -z "$PORT" ]]; then
        if ! $NON_INTERACTIVE; then read -rp "请输入端口号 (默认 ${DEFAULT_PORT}): " user_port; PORT=${user_port:-$DEFAULT_PORT};
        else PORT=$DEFAULT_PORT; fi
    fi
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then print_error "无效端口号: ${PORT}"; exit 1; fi
    print_info "使用端口: ${PORT}"

    # 域名 (必需)
    if [[ -z "$DOMAIN" ]]; then
        if $NON_INTERACTIVE; then print_error "缺少必需参数 --domain"; exit 1; fi
        until [[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do read -rp "请输入域名 (必需，如 hy.example.com): " DOMAIN; if [[ -z "$DOMAIN" ]]; then print_warning "域名不能为空。"; elif [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then print_warning "域名格式不正确。"; fi; done
    else
        if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then print_error "提供的域名 (--domain) 格式不正确: ${DOMAIN}"; exit 1; fi
        print_info "使用域名: ${DOMAIN}"
    fi

    # 邮箱 (必需)
    if [[ -z "$EMAIL" ]]; then
        if $NON_INTERACTIVE; then print_error "缺少必需参数 --email"; exit 1; fi
        until [[ -n "$EMAIL" ]]; do read -rp "请输入 ACME 邮箱 (必需): " EMAIL; if [[ -z "$EMAIL" ]]; then print_warning "邮箱不能为空。"; fi; done # 简单的非空检查
    else
        print_info "使用邮箱: ${EMAIL}"
    fi

    # Cloudflare Token (必需)
    if [[ -z "$CF_TOKEN" ]]; then
        if $NON_INTERACTIVE; then print_error "缺少必需参数 --cf-token"; exit 1; fi
        until [[ -n "$CF_TOKEN" ]]; do read -sp "请输入 Cloudflare API Token (必需): " CF_TOKEN; echo; if [[ -z "$CF_TOKEN" ]]; then print_warning "Token 不能为空。"; fi; done
    else
        print_info "使用提供的 Cloudflare API Token。"
    fi

    # 密码
    if [[ -z "$PASSWORD" ]]; then
        local random_pw
        random_pw=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16) # 更健壮的随机密码
        if ! $NON_INTERACTIVE; then
            read -rp "请输入连接密码 (留空则随机生成): " user_password
            PASSWORD=${user_password:-$random_pw}
            if [[ "$PASSWORD" == "$random_pw" ]]; then print_info "已生成随机密码: ${PASSWORD}"; else print_info "使用输入的密码。"; fi
        else
            PASSWORD=$random_pw; print_info "已生成随机密码: ${PASSWORD}";
        fi
    else
        print_info "使用提供的密码。"
    fi

    # 伪装 URL
    if [[ -z "$MASQUERADE_URL" ]]; then
        if ! $NON_INTERACTIVE; then read -rp "请输入伪装目标 URL (默认 ${DEFAULT_MASQUERADE_URL}): " user_masquerade; MASQUERADE_URL=${user_masquerade:-$DEFAULT_MASQUERADE_URL};
        else MASQUERADE_URL=$DEFAULT_MASQUERADE_URL; fi
    fi
    # 检查伪装 URL 格式 (必须包含协议)
    if [[ ! "$MASQUERADE_URL" =~ ^https?:// ]]; then
        print_warning "伪装 URL ('$MASQUERADE_URL') 缺少协议 (http:// 或 https://)。"
        local fix_url_confirm="y"
        if ! $NON_INTERACTIVE; then read -rp "是否自动添加 'https://' 前缀？[Y/n]: " user_confirm; fix_url_confirm=${user_confirm:-y}; fi
        if [[ "$fix_url_confirm" =~ ^[Nn]$ ]]; then print_error "伪装 URL 格式错误，无法继续。"; exit 1;
        else MASQUERADE_URL="https://${MASQUERADE_URL}"; print_info "已修正伪装 URL: ${MASQUERADE_URL}"; fi
    fi
    print_info "使用伪装 URL: ${MASQUERADE_URL}"

    print_ok "配置值准备完成。"
}

# --- 生成配置文件 ---
function generate_config_file() {
    print_info "正在生成 Hysteria 配置文件: ${HYSTERIA_CONFIG_FILE}..."
    local config_dir
    config_dir=$(dirname "$HYSTERIA_CONFIG_FILE") # 获取目录路径 /etc/hysteria

    # 创建目录（如果不存在）并设置目录权限
    sudo mkdir -p "$config_dir" || { print_error "创建配置目录失败: ${config_dir}"; exit 1; }
    # 确保 hysteria 组可以访问该目录 (r-x)
    sudo chown root:hysteria "$config_dir" # 假设 hysteria 组存在
    sudo chmod 750 "$config_dir"          # Owner: rwx, Group: r-x, Other: ---

    # 使用 sudo tee 写入文件，避免权限问题
    sudo tee "$HYSTERIA_CONFIG_FILE" > /dev/null <<EOF
# Hysteria 配置文件由脚本生成

listen: :${PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}
  # 使用 ZeroSSL 作为 CA，Let's Encrypt 也可以: ca: letsencrypt
  ca: zerossl
  # DNS 验证方式
  type: dns
  dns:
    name: cloudflare
    # provider 配置
    config:
      # Cloudflare API Token (Zone: Read, DNS: Edit permissions required)
      cloudflare_api_token: ${CF_TOKEN}

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    # 伪装流量的目标 URL
    url: ${MASQUERADE_URL}
    # 是否重写 Host 头为目标 URL 的 Host
    rewriteHost: true

# 其他可选配置（默认禁用或使用内置值）:
# transport:
#   type: udp # or wechat-video, ...
# bandwidth:
#   up: 100 mbps
#   down: 500 mbps
# ignoreClientBandwidth: false
# disableUDP: false
# ...
EOF

    # 检查文件是否成功创建
    if [ ! -f "$HYSTERIA_CONFIG_FILE" ]; then
        print_error "配置文件 ${HYSTERIA_CONFIG_FILE} 创建失败！"
        exit 1
    fi

    # --- 设置正确的所有权和权限 ---
    print_info "设置配置文件权限..."
    # 将文件所有者设为 root，组设为 hysteria
    if ! sudo chown root:hysteria "$HYSTERIA_CONFIG_FILE"; then
        print_warning "设置配置文件组所有权为 'hysteria' 失败。请确保 'hysteria' 组存在。"
        print_warning "将尝试使用 644 权限作为备选方案..."
        sudo chmod 644 "$HYSTERIA_CONFIG_FILE" # 允许所有人读取
    else
        # 设置权限为 640 (Owner: rw-, Group: r--, Other: ---)
        sudo chmod 640 "$HYSTERIA_CONFIG_FILE"
    fi


    print_ok "配置文件 ${HYSTERIA_CONFIG_FILE} 生成和权限设置成功！"
}

# --- 启动服务 ---
function start_hysteria_service() {
    print_info "正在启动 Hysteria 服务 (${HYSTERIA_SERVICE_NAME})..."

    # 重新加载 systemd 配置，以防安装脚本更改了 service 文件
    sudo systemctl daemon-reload || print_warning "systemctl daemon-reload 执行失败。"

    # 启动服务
    if ! sudo systemctl start "${HYSTERIA_SERVICE_NAME}"; then
        print_error "启动 Hysteria 服务失败！请检查配置文件和日志。"
        echo -e "尝试运行: ${YELLOW}journalctl --no-pager -u ${HYSTERIA_SERVICE_NAME}${NC}"
        exit 1
    fi

    # 设置开机自启
    if ! sudo systemctl enable "${HYSTERIA_SERVICE_NAME}"; then
        print_warning "设置 Hysteria 服务开机自启失败。"
    fi

    # 检查服务状态
    print_info "等待服务启动并检查状态..."
    sleep 3 # 等待几秒钟让服务启动
    if systemctl is-active --quiet "${HYSTERIA_SERVICE_NAME}"; then
        print_ok "Hysteria 服务已成功启动并设置为开机自启！"
    else
        print_error "Hysteria 服务启动后未能保持运行状态！"
        echo -e "请检查日志: ${YELLOW}journalctl --no-pager -u ${HYSTERIA_SERVICE_NAME}${NC}"
        exit 1
    fi
}

# --- 输出总结信息 ---
function output_summary() {
    local service_status_cmd="sudo systemctl status ${HYSTERIA_SERVICE_NAME}"
    local service_restart_cmd="sudo systemctl restart ${HYSTERIA_SERVICE_NAME}"
    local service_logs_cmd="sudo journalctl --no-pager -e -u ${HYSTERIA_SERVICE_NAME}"

    echo -e "\n================ Hysteria 2 安装完成 ==============="
    echo -e "监听端口:      ${YELLOW}${PORT}${NC}"
    echo -e "域名:          ${YELLOW}${DOMAIN}${NC}"
    echo -e "连接密码:      ${GREEN}${PASSWORD}${NC}"
    echo -e "伪装目标:      ${YELLOW}${MASQUERADE_URL}${NC}"
    echo -e "配置文件:      ${BLUE}${HYSTERIA_CONFIG_FILE}${NC}"
    echo -e "systemctl地址: ${BLUE}${SERVICE_DIR}${HYSTERIA_SERVICE_NAME}"
    echo -e " ↑部分虚拟机 service 文件 Working Dir需改为 /var/lib/hysteria↑ "
    echo -e "---------------------------------------------------"
    echo -e "常用命令:"
    echo -e "  查看状态:    ${BLUE}${service_status_cmd}${NC}"
    echo -e "  重启服务:    ${BLUE}${service_restart_cmd}${NC}"
    echo -e "  查看日志:    ${BLUE}${service_logs_cmd}${NC}"
    echo -e "==================================================="
    print_info "请根据以上信息配置你的 Hysteria 客户端。"
}

# --- 主程序 ---
main() {
    check_root
    check_dependencies
    # 参数解析已在脚本开头完成
    get_config_values    # 获取/验证所有配置值
    install_hysteria     # 检查并安装 Hysteria
    generate_config_file # 生成 YAML 配置文件
    start_hysteria_service # 启动并启用服务
    output_summary       # 显示总结信息
}

# --- 执行 ---
main

exit 0