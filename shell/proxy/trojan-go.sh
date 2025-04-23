#!/bin/bash

# Trojan-Go 一键安装脚本 (CF DNS + ACME + Nginx )


# --- 脚本配置 (默认值) ---
TROJAN_GO_INSTALL_DIR="/usr/local/bin"
TROJAN_GO_CONFIG_DIR="/etc/trojan-go"
TROJAN_GO_CERT_DIR="${TROJAN_GO_CONFIG_DIR}/certs"
TROJAN_GO_SERVICE_FILE="/etc/systemd/system/trojan-go.service"
ACME_EMAIL="my@example.com"
DEFAULT_TROJAN_PORT="443"
CERT_RENEW_DAYS=30
NGINX_CONFIG_FILE="/etc/nginx/conf.d/trojan-go-fallback.conf"
DEFAULT_FALLBACK_URL="https://www.google.com"

# --- 变量初始化 ---
DOMAIN=""
TROJAN_PORT="" # 将在后面根据参数或默认值设置
TROJAN_PASSWORD="" # 将在后面根据参数或随机生成
CF_TOKEN="" # 从参数或按需提示获取
NON_INTERACTIVE=false # 非交互模式标志

# --- 颜色代码 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

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
    echo "  --domain <域名>         指定要使用的域名 (必需)"
    echo "  --port <端口号>         指定 Trojan 监听端口 (默认: ${DEFAULT_TROJAN_PORT})"
    echo "  --password <密码>       指定 Trojan 连接密码 (默认: 随机生成)"
    echo "  --cf-token <令牌>       指定 Cloudflare API Token (如果需要申请/续期证书)"
    echo "  --non-interactive      启用非交互模式，如果缺少必要参数则报错退出"
    echo "  --help                 显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0 --domain sub.example.com --cf-token YOUR_CF_TOKEN"
    echo "  $0 --domain sub.example.com --port 12345 --password mysecret --cf-token YOUR_CF_TOKEN --non-interactive"
    exit 0
}

# --- 参数解析 ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "错误: --domain 需要一个值"; exit 1; fi
            DOMAIN="$2"; shift 2 ;;
        --port)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "错误: --port 需要一个值"; exit 1; fi
            # 端口验证稍后进行
            TROJAN_PORT="$2"; shift 2 ;;
        --password)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "错误: --password 需要一个值"; exit 1; fi
            TROJAN_PASSWORD="$2"; shift 2 ;;
        --cf-token)
            if [[ -z "$2" ]] || [[ "$2" == -* ]]; then print_error "错误: --cf-token 需要一个值"; exit 1; fi
            CF_TOKEN="$2"; shift 2 ;;
        --non-interactive)
            NON_INTERACTIVE=true; shift 1 ;;
        --help)
            display_help ;;
        *)
            print_error "未知选项: $1"; display_help ;;
    esac
done

# --- 依赖安装 ---
function install_dependencies() {
    print_info "更新软件包列表并安装依赖项 (curl, wget, unzip, socat, jq, coreutils)..."
    local pkg_manager=""; local pkgs_core="curl wget unzip socat jq coreutils"; local pkgs_needed=()
    if command -v apt-get &>/dev/null; then pkg_manager="apt"; elif command -v yum &>/dev/null; then pkg_manager="yum"; elif command -v dnf &>/dev/null; then pkg_manager="dnf"; fi
    if [ -z "$pkg_manager" ]; then print_error "不支持的包管理器。请手动安装 ${pkgs_core} 和 nginx。"; exit 1; fi
    print_info "更新软件包列表..."; case "$pkg_manager" in apt) sudo apt-get update -y || print_warning "apt update 失败。" ;; yum) sudo yum update -y || print_warning "yum update 失败。" ;; dnf) sudo dnf update -y || print_warning "dnf update 失败。" ;; esac
    for pkg in $pkgs_core; do if ! command -v $pkg &> /dev/null; then pkgs_needed+=("$pkg"); fi; done
    if [ ${#pkgs_needed[@]} -gt 0 ]; then
        print_info "正在安装核心依赖: ${pkgs_needed[*]}..."; case "$pkg_manager" in apt) sudo apt-get install -y "${pkgs_needed[@]}" || { print_error "安装核心依赖失败 (apt)。"; exit 1; } ;; yum) sudo yum install -y epel-release || print_warning "安装 epel-release 可能失败。"; sudo yum install -y "${pkgs_needed[@]}" || { print_error "安装核心依赖失败 (yum)。"; exit 1; } ;; dnf) sudo dnf install -y "${pkgs_needed[@]}" || { print_error "安装核心依赖失败 (dnf)。"; exit 1; } ;; esac
        if ! command -v jq &> /dev/null; then print_error "核心依赖项 jq 未能成功安装。"; exit 1; fi
    else print_info "核心依赖已安装。"; fi; print_ok "核心依赖安装检查完成。"
}

# --- 获取用户输入 (结合参数处理) ---
function get_user_input_values() {
    print_info "检查配置值..."

    # 1. 域名 (必需)
    if [[ -z "$DOMAIN" ]]; then
        if $NON_INTERACTIVE; then print_error "缺少必需参数 --domain"; exit 1; fi
        print_info "请输入必需信息:"
        while [[ -z "$DOMAIN" ]]; do
            read -rp "请输入你的域名 (例如: sub.yourdomain.com): " DOMAIN
            if [[ -z "$DOMAIN" ]]; then print_warning "域名不能为空。"; fi
        done
    else
        print_info "使用域名: ${DOMAIN}"
    fi

    # 2. 端口
    if [[ -z "$TROJAN_PORT" ]]; then
        if ! $NON_INTERACTIVE; then
            read -rp "请输入 Trojan 监听端口 (留空则使用默认端口 ${DEFAULT_TROJAN_PORT}): " user_port
            TROJAN_PORT=${user_port:-$DEFAULT_TROJAN_PORT}
        else
            TROJAN_PORT=$DEFAULT_TROJAN_PORT # 非交互模式下使用默认值
        fi
    fi
    # 验证端口号
    if [[ ! "$TROJAN_PORT" =~ ^[0-9]+$ ]] || [ "$TROJAN_PORT" -lt 1 ] || [ "$TROJAN_PORT" -gt 65535 ]; then
        print_error "无效的端口号: ${TROJAN_PORT}。请输入 1-65535 之间的数字。"
        exit 1
    fi
    print_info "将使用 Trojan 端口: ${TROJAN_PORT}"
    # 端口占用检查（可选，这里只警告）
    if ss -Hltn "sport = ${TROJAN_PORT}" | grep -q LISTEN; then
         print_warning "端口 ${TROJAN_PORT} 似乎已被监听。请确保没有冲突。"
    fi


    # 3. 密码
    if [[ -z "$TROJAN_PASSWORD" ]]; then
        DEFAULT_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        if ! $NON_INTERACTIVE; then
            read -rp "请输入 Trojan 连接密码 (留空则使用随机密码): " user_password
            TROJAN_PASSWORD=${user_password:-$DEFAULT_PASSWORD}
            if [[ "$TROJAN_PASSWORD" == "$DEFAULT_PASSWORD" ]]; then
                print_info "已生成随机密码: ${TROJAN_PASSWORD}"
            else
                print_info "使用输入的密码。"
            fi
        else
            TROJAN_PASSWORD=$DEFAULT_PASSWORD # 非交互模式下使用随机密码
            print_info "已生成随机密码: ${TROJAN_PASSWORD}"
        fi
    else
        print_info "使用提供的密码。"
    fi
}

# --- 安装 acme.sh ---
function install_acme() {
    print_info "检查并安装/更新 acme.sh..."; ACME_CMD="$HOME/.acme.sh/acme.sh"
    if [ -f "$ACME_CMD" ]; then print_ok "acme.sh 已安装。"; print_info "尝试更新 acme.sh..."; "$ACME_CMD" --upgrade --log-level 1 || print_warning "更新 acme.sh 失败。";
    else print_info "正在安装 acme.sh..."; curl https://get.acme.sh | sh -s email="$ACME_EMAIL" || { print_error "安装 acme.sh 失败。"; exit 1; }; if [ ! -f "$ACME_CMD" ]; then print_error "安装后未找到 acme.sh。"; exit 1; fi; print_ok "acme.sh 安装成功。"; "$ACME_CMD" --upgrade --auto-upgrade || print_warning "启用自动更新失败。"; fi
    if ! grep -q "alias acme.sh=" ~/.bashrc; then echo "alias acme.sh='${ACME_CMD}'" >> ~/.bashrc; print_info "已添加 acme.sh alias 到 ~/.bashrc。"; fi
}

# --- 申请/验证证书 (结合参数处理) ---
function issue_certificate() {
    print_info "准备 SSL 证书 (域名: ${DOMAIN})..."
    local cert_needs_action=false; local cert_needs_install=false; local token_needed=false
    local effective_cf_token="$CF_TOKEN" # Use token from arg if provided

    print_info "检查域名 ${DOMAIN} 的证书记录..."; if "$ACME_CMD" --list | grep -qw "$DOMAIN"; then
        print_info "找到 ${DOMAIN} 的现有证书记录。"; cert_needs_install=true
        print_info "检查证书有效期 (阈值: ${CERT_RENEW_DAYS} 天)..."; local info_output; info_output=$("$ACME_CMD" --info -d "$DOMAIN" --log-level 1 2>&1); local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            local expiration_ts; expiration_ts=$(echo "$info_output" | grep 'Le_NextRenewTime=' | head -n 1 | cut -d= -f2 | tr -d "'")
            if [[ "$expiration_ts" =~ ^[0-9]+$ ]]; then
                local current_ts=$(date +%s); local renew_threshold_ts=$((current_ts + CERT_RENEW_DAYS * 24 * 60 * 60))
                if [[ "$expiration_ts" -lt "$renew_threshold_ts" ]]; then print_info "证书需要续期。"; cert_needs_action="renew"; token_needed=true;
                else local expire_date=$(date -d "@$expiration_ts" +"%Y-%m-%d %H:%M:%S"); print_ok "现有证书有效 (至: ${expire_date})。"; fi
            else print_warning "无法提取到期时间戳，尝试续期。"; cert_needs_action="renew"; token_needed=true; fi
        else print_warning "无法获取证书信息，尝试续期。"; print_warning "acme.sh 输出: $info_output"; cert_needs_action="renew"; token_needed=true; fi
    else print_info "未找到 ${DOMAIN} 证书记录，需申请新证书。"; cert_needs_action="issue"; token_needed=true; fi

    # 如果需要 Token 但未通过参数提供
    if [ "$token_needed" = true ] && [[ -z "$effective_cf_token" ]]; then
        if $NON_INTERACTIVE; then print_error "需要 Cloudflare API Token (--cf-token) 来 ${cert_needs_action} 证书，但未提供。"; exit 1; fi
        print_info "需要 Cloudflare API Token 来 ${cert_needs_action} 证书。"
        while [[ -z "$effective_cf_token" ]]; do
            read -sp "请输入 Cloudflare API Token (DNS 编辑权限): " effective_cf_token; echo
            if [[ -z "$effective_cf_token" ]]; then print_warning "Token 不能为空。"; fi
        done
    elif [ "$token_needed" = true ] && [[ -n "$effective_cf_token" ]]; then
         print_info "使用提供的 Cloudflare API Token。"
    else
         print_info "现有证书有效，无需 Cloudflare API Token。"
    fi

    # 如果需要操作，设置环境变量
    if [ "$token_needed" = true ]; then
        export CF_Token="$effective_cf_token"
    fi

    # 执行证书操作
    if [ "$cert_needs_action" = "renew" ]; then
        print_info "正在尝试续期证书..."; if "$ACME_CMD" --renew -d "$DOMAIN" --dns dns_cf --force --log; then print_ok "证书续期成功。"; cert_needs_install=true;
        else print_warning "证书续期失败。将尝试使用现有证书。"; fi
    elif [ "$cert_needs_action" = "issue" ]; then
        print_info "正在申请新证书..."; if "$ACME_CMD" --issue --dns dns_cf -d "$DOMAIN" --log; then print_ok "新证书签发成功。"; cert_needs_install=true;
        else print_error "签发新证书失败。检查 Token/DNS/日志。"; unset CF_Token; exit 1; fi
    fi

    # 安装证书
    if [ "$cert_needs_install" = true ]; then
        print_info "正在安装证书到 ${TROJAN_GO_CERT_DIR}..."; mkdir -p "$TROJAN_GO_CERT_DIR"
        if "$ACME_CMD" --install-cert -d "$DOMAIN" --key-file "${TROJAN_GO_CERT_DIR}/private.key" --fullchain-file "${TROJAN_GO_CERT_DIR}/fullchain.pem" --reloadcmd "echo 'Cert installed'"; then
            print_ok "证书已安装/验证到 ${TROJAN_GO_CERT_DIR}。"; chmod 600 "${TROJAN_GO_CERT_DIR}/private.key";
        else print_error "安装证书失败。"; unset CF_Token; exit 1; fi
    elif [ "$cert_needs_action" = false ]; then print_info "无需执行证书操作。";
    else print_error "证书处理流程异常。"; unset CF_Token; exit 1; fi
    unset CF_Token # 清理环境变量
}


# --- 安装 Trojan-Go ---
function install_trojan_go() {
    print_info "正在安装 Trojan-Go..."; ARCH=$(uname -m); TROJAN_GO_ARCH=""; case $ARCH in x86_64) TROJAN_GO_ARCH="amd64" ;; aarch64) TROJAN_GO_ARCH="arm64" ;; armv7l) TROJAN_GO_ARCH="armv7" ;; *) print_error "不支持架构: ${ARCH}"; exit 1 ;; esac; print_info "检测到架构: ${TROJAN_GO_ARCH}"
    print_info "获取 Trojan-Go 版本..."; LATEST_TAG=$(curl -sI "https://github.com/p4gefau1t/trojan-go/releases/latest" | grep -i "location:" | awk -F'/' '{print $NF}' | tr -d '\r'); if [[ -z "$LATEST_TAG" ]] || [[ ! "$LATEST_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*$ ]]; then print_warning "无法获取或格式错误 ('${LATEST_TAG}')。使用 v0.10.6。"; LATEST_TAG="v0.10.6"; else print_info "最新版本: ${LATEST_TAG}"; fi
    DOWNLOAD_URL="https://github.com/p4gefau1t/trojan-go/releases/download/${LATEST_TAG}/trojan-go-linux-${TROJAN_GO_ARCH}.zip"; DOWNLOAD_FILE="/tmp/trojan-go.zip"
    print_info "下载 Trojan-Go..."; wget -q --show-progress -O "$DOWNLOAD_FILE" "$DOWNLOAD_URL" || { print_error "下载失败 (URL: ${DOWNLOAD_URL})"; exit 1; }
    print_info "解压 Trojan-Go..."; mkdir -p "$TROJAN_GO_CONFIG_DIR"; local extract_dir="/tmp/trojan-go-extracted"; rm -rf "$extract_dir"; mkdir -p "$extract_dir"; unzip -o "$DOWNLOAD_FILE" -d "$extract_dir" 'trojan-go' 'geoip.dat' 'geosite.dat' || { print_error "解压失败。"; rm -f "$DOWNLOAD_FILE"; exit 1; }
    print_info "安装主程序..."; install -m 755 "${extract_dir}/trojan-go" "${TROJAN_GO_INSTALL_DIR}/trojan-go" || { print_error "安装主程序失败。"; rm -f "$DOWNLOAD_FILE"; rm -rf "$extract_dir"; exit 1; }
    print_info "安装 geoip/geosite..."; install -m 644 "${extract_dir}/geoip.dat" "${TROJAN_GO_CONFIG_DIR}/geoip.dat" || print_warning "安装 geoip.dat 失败。"; install -m 644 "${extract_dir}/geosite.dat" "${TROJAN_GO_CONFIG_DIR}/geosite.dat" || print_warning "安装 geosite.dat 失败。"; rm -f "$DOWNLOAD_FILE"; rm -rf "$extract_dir"
    if [[ -x "${TROJAN_GO_INSTALL_DIR}/trojan-go" ]]; then print_ok "Trojan-Go 安装完成。"; else print_error "安装验证失败。"; exit 1; fi
}

# --- 配置 Trojan-Go ---
function configure_trojan_go() {
    print_info "生成 Trojan-Go 配置文件..."; CONFIG_FILE="${TROJAN_GO_CONFIG_DIR}/config.json"
    jq -n --arg run_type "server" --arg local_addr "0.0.0.0" --argjson local_port "${TROJAN_PORT}" \
      --arg remote_addr "127.0.0.1" --argjson remote_port 80 --arg password "${TROJAN_PASSWORD}" \
      --argjson log_level 1 --arg log_file "/var/log/trojan-go.log" \
      --arg cert_path "${TROJAN_GO_CERT_DIR}/fullchain.pem" --arg key_path "${TROJAN_GO_CERT_DIR}/private.key" \
      --arg sni "${DOMAIN}" --arg fallback_addr "127.0.0.1" --argjson fallback_port 80 \
      --arg geoip_path "${TROJAN_GO_CONFIG_DIR}/geoip.dat" --arg geosite_path "${TROJAN_GO_CONFIG_DIR}/geosite.dat" \
    '{ "run_type": $run_type, "local_addr": $local_addr, "local_port": $local_port, "remote_addr": $remote_addr, "remote_port": $remote_port, "password": [ $password ], "log_level": $log_level, "log_file": $log_file, "ssl": { "cert": $cert_path, "key": $key_path, "sni": $sni, "alpn": [ "http/1.1" ], "fallback_addr": $fallback_addr, "fallback_port": $fallback_port }, "router": { "enabled": true, "geoip": $geoip_path, "geosite": $geosite_path }, "websocket": { "enabled": false, "path": "/your-websocket-path", "host": $sni }, "transport_plugin": { "enabled": false } }' > "$CONFIG_FILE"
    if jq -e '.' "$CONFIG_FILE" > /dev/null; then print_ok "Trojan-Go 配置文件已生成: ${CONFIG_FILE}"; chmod 600 "$CONFIG_FILE"; else print_error "生成配置文件失败 (无效 JSON)。"; exit 1; fi
}

# --- 配置 Nginx 回落 ---
function setup_fallback_webserver() {
    print_info "检查并配置 HTTP (80端口) 回落服务 (使用 Nginx)..."; local nginx_installed=false; local port_80_listening=false; local nginx_listening_80=false
    if command -v nginx &>/dev/null; then nginx_installed=true; fi; if sudo ss -Hltn 'sport = 80' | grep -q 'LISTEN'; then port_80_listening=true; if sudo ss -Hltnp 'sport = 80' | grep -q 'nginx'; then nginx_listening_80=true; fi; fi
    if ! $port_80_listening; then
        print_info "端口 80 未被监听。"; if ! $nginx_installed; then print_info "Nginx 未安装，现在开始安装..."; local pkg_manager=""; if command -v apt-get &>/dev/null; then pkg_manager="apt"; elif command -v yum &>/dev/null; then pkg_manager="yum"; elif command -v dnf &>/dev/null; then pkg_manager="dnf"; fi; case "$pkg_manager" in apt) sudo apt-get update -y && sudo apt-get install -y nginx || { print_error "apt 安装 Nginx 失败。"; return 1; } ;; yum) sudo yum install -y epel-release || print_warning "安装 epel 可能失败。"; sudo yum install -y nginx || { print_error "yum 安装 Nginx 失败。"; return 1; } ;; dnf) sudo dnf install -y nginx || { print_error "dnf 安装 Nginx 失败。"; return 1; } ;; *) print_error "无法自动安装 Nginx。"; return 1 ;; esac; print_ok "Nginx 安装成功。"; nginx_installed=true; else print_info "Nginx 已安装但未运行，尝试启动..."; fi
        sudo systemctl enable nginx || print_warning "设置 Nginx 开机自启失败。"; sudo systemctl start nginx || { print_error "启动 Nginx 失败。"; return 1; }; sleep 2; if sudo ss -Hltn 'sport = 80' | grep -q 'LISTEN'; then print_ok "Nginx 启动成功。"; nginx_listening_80=true; else print_error "Nginx 启动后 80 端口仍未监听。"; return 1; fi
    elif $port_80_listening && $nginx_listening_80; then print_ok "Nginx 已在监听 80 端口。"
    elif $port_80_listening && ! $nginx_listening_80; then print_warning "端口 80 已被其他程序监听。跳过 Nginx 配置。"; return 0; fi
    if $nginx_listening_80; then
        if [ -f /etc/nginx/sites-enabled/default ]; then print_info "移除 Nginx 默认配置..."; sudo rm -f /etc/nginx/sites-enabled/default || print_warning "移除默认配置失败。"; fi; if [ -f "$NGINX_CONFIG_FILE" ]; then print_info "覆盖旧的回落配置文件..."; fi
        local choice=2 # 默认反代
        if ! $NON_INTERACTIVE; then print_info "配置 Nginx 回落规则..."; echo "选择方式： 1) 简单页面 2) 反代 (推荐)"; read -rp "输入选项 [1/2] (默认 2): " user_choice; choice=${user_choice:-2}; fi
        if [[ "$choice" == "1" ]]; then
             print_info "配置 Nginx (简单页面)..."; local fallback_html_dir="/var/www/html/trojan-fallback"; local fallback_html_file="${fallback_html_dir}/index.html"; sudo mkdir -p "$fallback_html_dir"; sudo tee "$fallback_html_file" > /dev/null <<EOF
<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Site under construction.</h1></body></html>
EOF
             sudo chown -R www-data:www-data "$fallback_html_dir" 2>/dev/null || sudo chown -R nginx:nginx "$fallback_html_dir" 2>/dev/null || print_warning "设置 HTML 目录权限失败。"
             sudo tee "$NGINX_CONFIG_FILE" > /dev/null <<EOF
server { listen 80; listen [::]:80; server_name ${DOMAIN}; root ${fallback_html_dir}; index index.html; location / { try_files \$uri \$uri/ =404; } access_log /var/log/nginx/trojan_fallback.access.log; error_log /var/log/nginx/trojan_fallback.error.log; }
EOF
        elif [[ "$choice" == "2" ]]; then
             print_info "配置 Nginx (反向代理)..."; local target_url=$DEFAULT_FALLBACK_URL; if ! $NON_INTERACTIVE; then read -rp "输入目标网址 (默认 ${DEFAULT_FALLBACK_URL}): " user_target_url; target_url=${user_target_url:-$DEFAULT_FALLBACK_URL}; fi
             if [[ ! "$target_url" =~ ^https?:// ]]; then
                 print_warning "目标 URL ('$target_url') 缺少协议。"; local add_https_confirm="y"; if ! $NON_INTERACTIVE; then read -rp "是否自动添加 'https://' 前缀？[Y/n]: " user_confirm; add_https_confirm=${user_confirm:-y}; fi
                 if [[ "$add_https_confirm" =~ ^[Nn]$ ]]; then print_error "URL 格式错误，无法配置反代。"; sudo rm -f "$NGINX_CONFIG_FILE"; return 1; else target_url="https://${target_url}"; print_info "已修正目标 URL: ${target_url}"; fi
             fi
             sudo tee "$NGINX_CONFIG_FILE" > /dev/null <<EOF
server { listen 80; listen [::]:80; server_name ${DOMAIN}; location / { proxy_pass ${target_url}; proxy_redirect off; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; } access_log /var/log/nginx/trojan_fallback_proxy.access.log; error_log /var/log/nginx/trojan_fallback_proxy.error.log; }
EOF
        else print_warning "无效选项，跳过 Nginx 配置。"; return 0; fi
        if [[ "$choice" == "1" || "$choice" == "2" ]]; then print_info "测试 Nginx 配置..."; if sudo nginx -t -q; then print_info "重载 Nginx 配置..."; sudo systemctl reload nginx || { print_error "重载 Nginx 失败。"; return 1; }; print_ok "Nginx 配置生效。"; else print_error "Nginx 配置测试失败!"; sudo nginx -t; return 1; fi; fi
    fi; return 0
}

# --- 设置 Systemd 服务 ---
function setup_systemd_service() {
    print_info "设置 Trojan-Go systemd 服务..."; cat > "$TROJAN_GO_SERVICE_FILE" <<-EOF
[Unit]
Description=Trojan-Go Service (Port ${TROJAN_PORT})
Documentation=https://github.com/p4gefau1t/trojan-go
After=network.target nss-lookup.target network-online.target nginx.service
Wants=network-online.target
[Service]
Type=simple; User=root; WorkingDirectory=${TROJAN_GO_CONFIG_DIR}
ExecStart=${TROJAN_GO_INSTALL_DIR}/trojan-go -config ${TROJAN_GO_CONFIG_DIR}/config.json
Restart=on-failure; RestartSec=10; LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    print_info "重载 systemd..."; sudo systemctl daemon-reload || { print_error "daemon-reload 失败。"; exit 1; }
    print_info "设置开机自启..."; sudo systemctl enable trojan-go || { print_error "enable 失败。"; exit 1; }
    print_info "尝试停止旧服务..."; sudo systemctl stop trojan-go || true
    print_info "启动 Trojan-Go 服务..."; sudo systemctl start trojan-go || { print_error "start 失败，检查日志: journalctl -u trojan-go"; exit 1; }
    print_info "等待并检查状态..."; sleep 3
    if systemctl is-active --quiet trojan-go; then print_ok "Trojan-Go 服务启动成功。"; else print_error "服务未能启动。检查日志: journalctl -u trojan-go -n 50 --no-pager ; cat /var/log/trojan-go.log"; exit 1; fi
}

# --- 配置防火墙 ---
function configure_firewall() {
    print_info "配置防火墙允许端口 ${TROJAN_PORT}/tcp 和 80/tcp..."; local ports_to_open=("${TROJAN_PORT}/tcp" "80/tcp"); local fw_cmd=""; if command -v ufw &>/dev/null; then fw_cmd="ufw"; elif command -v firewall-cmd &>/dev/null; then fw_cmd="firewall-cmd"; fi
    if [ "$fw_cmd" = "ufw" ]; then print_info "检测到 UFW..."; local ufw_reload=false; for port_rule in "${ports_to_open[@]}"; do if ! sudo ufw status | grep -qw "$port_rule"; then print_info "允许 UFW: ${port_rule}..."; sudo ufw allow ${port_rule} || print_warning "添加 UFW (${port_rule}) 失败。"; ufw_reload=true; else print_info "UFW 规则 ${port_rule} 已存在。"; fi; done; if $ufw_reload; then sudo ufw reload || print_warning "重载 UFW 失败。"; fi
    elif [ "$fw_cmd" = "firewall-cmd" ]; then print_info "检测到 Firewalld..."; local fw_reload=false; for port_rule in "${ports_to_open[@]}"; do if ! sudo firewall-cmd --list-ports --permanent | grep -qw "$port_rule"; then print_info "允许 Firewalld: ${port_rule}..."; sudo firewall-cmd --permanent --add-port=${port_rule} || print_warning "添加 Firewalld (${port_rule}) 失败。"; fw_reload=true; else print_info "Firewalld 规则 ${port_rule} 已存在。"; fi; done; if $fw_reload; then sudo firewall-cmd --reload || print_warning "重载 Firewalld 失败。"; fi
    else print_warning "未检测到 UFW/Firewalld。请手动确保端口 ${TROJAN_PORT}/tcp 和 80/tcp 已开放。"; fi
}

# --- 显示总结信息 ---
function display_summary() {
    print_info "-------------------- 安装完成 --------------------"; print_ok "Trojan-Go 及 Nginx 回落配置已完成！"; print_info "--------------------------------------------------"
    print_info "Trojan-Go 服务器连接信息:"; echo -e "  ${YELLOW}地址:${NC} ${DOMAIN}"; echo -e "  ${YELLOW}端口:${NC} ${TROJAN_PORT}"; echo -e "  ${YELLOW}密码:${NC} ${TROJAN_PASSWORD}"; echo -e "  ${YELLOW}SNI:${NC}  ${DOMAIN}"
    print_info "--------------------------------------------------"; print_info "HTTP 回落 (端口 80):"; echo -e "  访问 http://${DOMAIN} 时将根据配置响应。"; echo -e "  Nginx 配置文件: ${NGINX_CONFIG_FILE}"
    print_info "--------------------------------------------------"; print_info "主要文件路径:"; echo -e "  Trojan-Go 配置: ${TROJAN_GO_CONFIG_DIR}/config.json"; echo -e "  证书文件: ${TROJAN_GO_CERT_DIR}"; echo -e "  日志文件: /var/log/trojan-go.log / journalctl -u trojan-go"
    print_info "--------------------------------------------------"; print_info "服务管理:"; echo -e "  Trojan-Go: ${GREEN}systemctl start/stop/restart/status trojan-go${NC}"; echo -e "  Nginx:     ${GREEN}systemctl start/stop/reload/status nginx${NC}"
    print_info "--------------------------------------------------"; print_info "证书管理 (acme.sh):"; echo -e "  ${GREEN}列出:${NC} acme.sh --list"; echo -e "  ${GREEN}信息:${NC} acme.sh --info -d ${DOMAIN}"; echo -e "  ${GREEN}续期:${NC} acme.sh --renew -d ${DOMAIN} --force"
    print_info "--------------------------------------------------"; print_warning "重要提示:"; print_warning " - 妥善保管 CF Token。"; print_warning " - 确保防火墙允许 TCP 端口 ${TROJAN_PORT} 和 80。"; print_warning " - 如遇问题，检查日志。"
    print_info "--------------------------------------------------"
}

# --- 主程序 ---
main() {
    check_root
    # 参数解析已在脚本开头完成
    install_dependencies
    get_user_input_values # 检查/获取/验证配置值
    install_acme
    issue_certificate     # 按需获取Token，处理证书
    install_trojan_go
    configure_trojan_go
    if ! setup_fallback_webserver; then # 设置 Nginx 回落
        print_error "设置 Nginx 回落失败。"; print_warning "继续尝试启动 Trojan-Go，但 HTTP 回落可能无效。"
        # exit 1 # 根据需要取消注释
    fi
    setup_systemd_service # 启动 trojan-go
    configure_firewall
    display_summary
}

# --- 执行主程序 ---
main

exit 0