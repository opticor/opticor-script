#!/bin/bash

# Grafana


# --- 配置变量 ---
DEFAULT_GRAFANA_VERSION="" # Auto-detect latest OSS
DEFAULT_GRAFANA_EDITION="oss" # oss or enterprise
DEFAULT_HTTP_PORT="3000"
INTERACTIVE=true

# --- 帮助信息 ---
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "使用官方仓库安装 Grafana 并配置 systemd 服务."
    echo ""
    echo "选项:"
    echo "  -v, --version VERSION    指定要安装的 Grafana 版本 (默认: 最新 OSS 稳定版)"
    echo "  -e, --edition EDITION    指定 Grafana 版本: 'oss' 或 'enterprise' (默认: ${DEFAULT_GRAFANA_EDITION})"
    echo "  -p, --port PORT          指定 Grafana 监听端口 (默认: ${DEFAULT_HTTP_PORT})"
    echo "  -n, --no-interaction     使用默认值或命令行参数值，不进行交互式提问"
    echo "  -h, --help               显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  # 交互式安装最新 OSS 版本"
    echo "  sudo bash $0"
    echo ""
    echo "  # 安装指定版本的 Enterprise 版，并修改端口，非交互"
    echo "  sudo bash $0 -v 10.4.1 -e enterprise -p 8080 -n"
}

# --- 日志函数 ---
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; exit 1; }

# --- 检查命令是否存在 ---
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "命令 '$1' 未找到。请先安装它。"
    fi
}

# --- 获取最新 Grafana OSS 版本 ---
get_latest_version() {
    log_info "正在尝试从 GitHub 获取最新的 Grafana OSS 版本..."
    local latest_version
    latest_version=$(curl -fsSL "https://api.github.com/repos/grafana/grafana/releases/latest" | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        log_warn "无法自动获取最新版本。您可以手动指定版本或稍后重试。"
        DEFAULT_GRAFANA_VERSION="11.0.0" # Fallback
        log_warn "将使用备用默认版本: ${DEFAULT_GRAFANA_VERSION}"
    else
        DEFAULT_GRAFANA_VERSION="$latest_version"
        log_info "获取到最新版本: ${DEFAULT_GRAFANA_VERSION}"
    fi
}

# --- 解析命令行参数 ---
TEMP=$(getopt -o v:e:p:nh --long version:,edition:,port:,no-interaction,help -n "$0" -- "$@")
if [ $? != 0 ]; then usage; exit 1; fi
eval set -- "$TEMP"
unset TEMP
ARG_GRAFANA_VERSION=""
ARG_GRAFANA_EDITION=""
ARG_HTTP_PORT=""
while true; do
    case "$1" in
        -v | --version) ARG_GRAFANA_VERSION="$2"; shift 2 ;;
        -e | --edition) ARG_GRAFANA_EDITION="$2"; shift 2 ;;
        -p | --port) ARG_HTTP_PORT="$2"; shift 2 ;;
        -n | --no-interaction) INTERACTIVE=false; shift ;;
        -h | --help) usage; exit 0 ;;
        --) shift; break ;;
        *) echo "内部错误！ Argument: $1"; exit 1 ;;
    esac
done

# --- 自动禁用交互模式逻辑 ---
if [[ -n "$ARG_GRAFANA_VERSION" || -n "$ARG_GRAFANA_EDITION" || -n "$ARG_HTTP_PORT" ]]; then
    if $INTERACTIVE; then
        log_info "检测到命令行配置参数，自动禁用交互模式。"
        INTERACTIVE=false
    fi
fi

# --- 检查 Root 权限 ---
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本需要 root 权限运行。请使用 sudo。"
fi

# --- 检查基本依赖 ---
log_info "检查基本依赖项..."
check_command wget
check_command curl
check_command jq
check_command systemctl
check_command sudo
check_command gpg

# --- !! 检查 Sudo 主机名解析问题 !! ---
log_info "检查 sudo 配置..."
sudo_error=$(sudo -n true 2>&1 >/dev/null) # 尝试非交互式运行 sudo
if [[ $? -ne 0 && "$sudo_error" == *"unable to resolve host"* ]]; then
    log_error "检测到 sudo 错误: 'unable to resolve host'. 这是您的服务器环境问题。"
    log_error "请修复 /etc/hosts 文件或 DNS 配置，确保主机名可以正确解析，然后重试。"
    log_error "例如，在 /etc/hosts 中添加 '127.0.0.1 $(hostname)'。"
    exit 1 # 必须退出，因为后续步骤会失败
fi
log_info "Sudo 配置检查通过（或不需要密码）。"

# --- 检测发行版和包管理器 ---
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""
PRE_REQS=""
OS_ID=""
if [ -f /etc/os-release ]; then . /etc/os-release; OS_ID=$ID;
elif [ -f /etc/lsb-release ]; then . /etc/lsb-release; OS_ID=${DISTRIB_ID,,};
else log_error "无法检测操作系统发行版。"; fi

log_info "检测到操作系统: ${OS_ID}"

case "$OS_ID" in
    ubuntu|debian|raspbian)
        PKG_MANAGER="apt"
        UPDATE_CMD="sudo apt-get update"
        PRE_REQS="apt-transport-https software-properties-common wget gpg"
        INSTALL_CMD="sudo apt-get install -y --allow-change-held-packages"
        log_info "使用 apt 包管理器。"
        ;;
    centos|rhel|fedora|almalinux|rocky)
        if command -v dnf &> /dev/null; then PKG_MANAGER="dnf"; INSTALL_CMD="sudo dnf install -y";
        elif command -v yum &> /dev/null; then PKG_MANAGER="yum"; INSTALL_CMD="sudo yum install -y";
        else log_error "在此 RPM 系发行版上未找到 yum 或 dnf。"; fi
        UPDATE_CMD="sudo ${PKG_MANAGER} check-update"
        PRE_REQS="wget"
        log_info "使用 ${PKG_MANAGER} 包管理器。"
        ;;
    *) log_error "不支持的操作系统发行版: $OS_ID"; ;;
esac

# --- 获取最新版本 (如果需要) ---
if [[ -z "$ARG_GRAFANA_VERSION" ]] && $INTERACTIVE; then get_latest_version; fi
if [[ -z "$ARG_GRAFANA_VERSION" ]] && ! $INTERACTIVE; then
    get_latest_version
    if [[ -z "$DEFAULT_GRAFANA_VERSION" ]]; then log_error "无法自动获取最新版本，且未通过 -v 指定版本。"; fi
    ARG_GRAFANA_VERSION=${ARG_GRAFANA_VERSION:-$DEFAULT_GRAFANA_VERSION}
    log_info "将使用版本: ${ARG_GRAFANA_VERSION}"
fi

# --- 最终确定配置值 ---
GRAFANA_VERSION=""
GRAFANA_EDITION=""
HTTP_PORT=""
if $INTERACTIVE; then
    log_info "进入交互式配置..."
    if [[ -z "$DEFAULT_GRAFANA_VERSION" ]]; then get_latest_version; fi
    read -p "请输入要安装的 Grafana 版本 [${DEFAULT_GRAFANA_VERSION}]: " INPUT_VERSION; GRAFANA_VERSION=${INPUT_VERSION:-$DEFAULT_GRAFANA_VERSION}
    read -p "请输入 Grafana 版本 (oss/enterprise) [${DEFAULT_GRAFANA_EDITION}]: " INPUT_EDITION; GRAFANA_EDITION=${INPUT_EDITION:-$DEFAULT_GRAFANA_EDITION}
    read -p "请输入 Grafana 监听端口 [${DEFAULT_HTTP_PORT}]: " INPUT_PORT; HTTP_PORT=${INPUT_PORT:-$DEFAULT_HTTP_PORT}
else
    GRAFANA_VERSION=${ARG_GRAFANA_VERSION:-$DEFAULT_GRAFANA_VERSION}
    GRAFANA_EDITION=${ARG_GRAFANA_EDITION:-$DEFAULT_GRAFANA_EDITION}
    HTTP_PORT=${ARG_HTTP_PORT:-$DEFAULT_HTTP_PORT}
    log_info "使用非交互模式配置:"; log_info "  版本: ${GRAFANA_VERSION}"; log_info "  Edition: ${GRAFANA_EDITION}"; log_info "  端口: ${HTTP_PORT}"
fi

if [[ -z "$GRAFANA_VERSION" ]]; then log_error "最终未能确定 Grafana 版本。"; fi
if [[ "$GRAFANA_EDITION" != "oss" && "$GRAFANA_EDITION" != "enterprise" ]]; then log_error "无效的 Edition: '${GRAFANA_EDITION}'。"; fi
if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1 ] || [ "$HTTP_PORT" -gt 65535 ]; then log_error "无效的端口号: ${HTTP_PORT}。"; fi

# --- 安装步骤 ---
log_info "开始安装 Grafana v${GRAFANA_VERSION} (${GRAFANA_EDITION})..."

# 1. 安装依赖
log_info "安装依赖项..."
if [[ -n "$PRE_REQS" ]]; then
    if ! $INSTALL_CMD $PRE_REQS; then log_error "安装依赖项失败。"; fi
fi

# 2. 添加 Grafana 仓库并安装
GRAFANA_PACKAGE_NAME="grafana"
if [[ "$GRAFANA_EDITION" == "enterprise" ]]; then GRAFANA_PACKAGE_NAME="grafana-enterprise"; fi

GRAFANA_INSTALL_TARGET=$GRAFANA_PACKAGE_NAME
if [[ "$GRAFANA_VERSION" != "latest" && -n "$GRAFANA_VERSION" ]]; then
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        log_warn "为 apt 指定版本 (${GRAFANA_VERSION}) 时，apt 会尝试查找匹配此版本号的最新修订版。"
        GRAFANA_INSTALL_TARGET="${GRAFANA_PACKAGE_NAME}=${GRAFANA_VERSION}"
    elif [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
        GRAFANA_INSTALL_TARGET="${GRAFANA_PACKAGE_NAME}-${GRAFANA_VERSION}"
    fi
    log_info "将尝试安装特定版本: ${GRAFANA_INSTALL_TARGET}"
else
    log_info "将安装最新的可用版本: ${GRAFANA_INSTALL_TARGET}"
fi

# 添加仓库逻辑
if [[ "$PKG_MANAGER" == "apt" ]]; then
    GRAFANA_LIST_FILE="/etc/apt/sources.list.d/grafana.list"
    GRAFANA_KEYRING_FILE="/usr/share/keyrings/grafana.key"
    log_info "配置 Grafana APT 仓库..."
    if [ ! -f "$GRAFANA_LIST_FILE" ]; then
        sudo mkdir -p "$(dirname "$GRAFANA_LIST_FILE")"
        sudo mkdir -p "$(dirname "$GRAFANA_KEYRING_FILE")"

        log_info "下载并添加 Grafana GPG 密钥到 ${GRAFANA_KEYRING_FILE}..."
        if ! curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee "$GRAFANA_KEYRING_FILE" > /dev/null; then
            log_error "下载或添加 Grafana GPG 密钥失败。"
        fi
        sudo chmod 644 "$GRAFANA_KEYRING_FILE"

        log_info "创建仓库配置文件 ${GRAFANA_LIST_FILE}..."
        if [[ "$GRAFANA_EDITION" == "oss" ]]; then REPO_LINE="deb [signed-by=${GRAFANA_KEYRING_FILE}] https://apt.grafana.com stable main";
        else REPO_LINE="deb [signed-by=${GRAFANA_KEYRING_FILE}] https://apt.grafana.com enterprise main"; fi
        if ! echo "$REPO_LINE" | sudo tee "$GRAFANA_LIST_FILE" > /dev/null; then
            log_error "创建仓库配置文件 ${GRAFANA_LIST_FILE} 失败。"
        fi
    else
        log_info "Grafana APT 仓库文件 ${GRAFANA_LIST_FILE} 已存在。跳过添加。"
    fi

    log_info "更新 APT 包列表..."
    if ! $UPDATE_CMD; then
        log_error "更新 APT 包列表失败。可能是网络或仓库镜像问题。"
    fi

elif [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
    REPO_FILE="/etc/yum.repos.d/grafana.repo"
    log_info "配置 Grafana YUM/DNF 仓库..."
    if [ ! -f "$REPO_FILE" ]; then
        log_info "创建仓库文件 ${REPO_FILE}..."
        if [[ "$GRAFANA_EDITION" == "oss" ]]; then BASE_URL="https://packages.grafana.com/oss/rpm";
        else BASE_URL="https://packages.grafana.com/enterprise/rpm"; fi
        sudo tee "$REPO_FILE" > /dev/null <<EOF
[grafana]
name=grafana
baseurl=${BASE_URL}
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
        if [ $? -ne 0 ]; then log_error "创建仓库文件 ${REPO_FILE} 失败。"; fi
    else
        log_info "Grafana YUM/DNF 仓库文件 ${REPO_FILE} 已存在。跳过添加。"
    fi
    log_info "清理 ${PKG_MANAGER} 缓存..."
    sudo ${PKG_MANAGER} clean all > /dev/null
fi

# 安装 Grafana
log_info "正在安装 ${GRAFANA_INSTALL_TARGET}..."
if ! $INSTALL_CMD "$GRAFANA_INSTALL_TARGET"; then
    log_error "安装 Grafana 失败。请检查错误信息或尝试手动安装。"
fi

# 3. 配置端口 (如果需要)
GRAFANA_INI_FILE="/etc/grafana/grafana.ini"
if [[ "$HTTP_PORT" != "3000" ]]; then
    log_info "配置 Grafana 监听端口为 ${HTTP_PORT}..."
    if sudo test -f "$GRAFANA_INI_FILE"; then
        if sudo awk -v port="$HTTP_PORT" '/^\[server\]/ {in_server=1} /^\[/{if(!match($0,/^\[server\]/)) in_server=0} in_server && /^[[:space:]]*;?[[:space:]]*http_port[[:space:]]*=/ {$0="http_port = " port} 1' "$GRAFANA_INI_FILE" | sudo tee "${GRAFANA_INI_FILE}.tmp" > /dev/null && sudo mv "${GRAFANA_INI_FILE}.tmp" "$GRAFANA_INI_FILE"; then
             log_info "成功更新 ${GRAFANA_INI_FILE} 中的 http_port。"
        else
             log_error "更新 ${GRAFANA_INI_FILE} 中的 http_port 失败。"
             if ! sudo grep -q 'http_port[[:space:]]*=' "$GRAFANA_INI_FILE"; then
                 log_warn "注意: ${GRAFANA_INI_FILE} 中似乎不存在 'http_port =' 行。请手动检查/添加。"
             fi
        fi
    else
        log_error "Grafana 配置文件 ${GRAFANA_INI_FILE} 未找到！无法配置端口。"
    fi
else
    log_info "使用默认端口 3000。"
fi

# 4. 启动服务
log_info "重新加载 systemd 配置并启动 Grafana 服务..."
if ! sudo systemctl daemon-reload; then log_warn "执行 systemctl daemon-reload 失败，可能没有影响。"; fi
if sudo systemctl enable --now grafana-server.service; then
    log_info "Grafana 服务已启用并启动。"
else
    log_error "启动或启用 Grafana 服务失败。请检查日志: sudo journalctl -u grafana-server.service"
fi

# 5. 显示状态
log_info "检查 Grafana 服务状态..."
sleep 3
if ! systemctl status grafana-server.service --no-pager; then
    log_warn "无法获取 Grafana 服务状态，请手动检查。"
fi

# --- 完成信息 ---
echo ""
log_info "Grafana 安装完成！"
log_info "配置文件位于: ${GRAFANA_INI_FILE}"
log_info "日志文件位于: /var/log/grafana/grafana.log"
log_info "数据目录位于: /var/lib/grafana"
log_info "Grafana 正在监听端口: ${HTTP_PORT}"
log_info "服务管理: sudo systemctl [start|stop|restart|status] grafana-server.service"
echo ""
log_info "您可以通过浏览器访问 http://<您的服务器IP>:${HTTP_PORT} 来访问 Grafana UI。"
# 添加初始账号密码提示
log_info "默认管理员用户: admin / admin (首次登录会提示修改密码)"
log_info "如果无法访问，请确保防火墙已允许 TCP 端口 ${HTTP_PORT} 的入站连接。"

exit 0