#!/bin/bash

# Prometheus

# --- 配置变量 (默认值) ---
DEFAULT_PROM_VERSION="" # 将尝试从 GitHub 获取最新版本
PROM_USER="prometheus"
PROM_GROUP="prometheus"
CONFIG_DIR="/etc/prometheus"
DATA_DIR="/var/lib/prometheus"
BIN_DIR="/usr/local/bin"
DEFAULT_PROM_PORT="9090" # Prometheus 监听端口
INTERACTIVE=true # 默认为交互模式

# --- 帮助信息 ---
usage() {
  echo "用法: $0 [选项]"
  echo ""
  echo "安装 Prometheus 并配置 systemd 服务."
  echo ""
  echo "选项:"
  echo "  -v, --version VERSION    指定要安装的 Prometheus 版本 (默认: 最新稳定版)"
  echo "  -u, --user USER          指定 Prometheus 运行用户 (默认: ${PROM_USER})"
  echo "  -g, --group GROUP        指定 Prometheus 运行用户组 (默认: ${PROM_GROUP})"
  echo "  -c, --config-dir DIR     指定配置目录 (默认: ${CONFIG_DIR})"
  echo "  -d, --data-dir DIR       指定数据存储目录 (默认: ${DATA_DIR})"
  echo "  -b, --bin-dir DIR        指定二进制文件安装目录 (默认: ${BIN_DIR})"
  echo "  -p, --port PORT          指定 Prometheus 监听端口 (默认: ${DEFAULT_PROM_PORT})"
  echo "  -n, --no-interaction     使用默认值或命令行参数值，不进行交互式提问"
  echo "  -h, --help               显示此帮助信息"
  echo ""
  echo "示例:"
  echo "  # 交互式安装"
  echo "  sudo bash $0"
  echo ""
  echo "  # 使用命令行参数指定版本、端口并跳过交互"
  echo "  sudo bash $0 -v 2.45.0 -p 9091 -n"
  echo ""
  echo "  # 指定自定义用户和目录"
  echo "  sudo bash $0 --user prom --group prom --config-dir /opt/prometheus/etc --data-dir /opt/prometheus/data -n"
}

# --- 日志函数 ---
log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_error() {
  echo "[ERROR] $1"
  exit 1
}

# --- 检查命令是否存在 ---
check_command() {
  if ! command -v "$1" &> /dev/null; then
    log_error "命令 '$1' 未找到。请先安装它。 (例如: sudo apt update && sudo apt install $1 或 sudo yum install $1)"
  fi
}

# --- 获取最新 Prometheus 版本 ---
get_latest_version() {
    log_info "正在尝试从 GitHub 获取最新的 Prometheus 版本..."
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/prometheus/prometheus/releases/latest" | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        log_warn "无法自动获取最新版本。您可以手动指定版本或稍后重试。"
        DEFAULT_PROM_VERSION="2.51.2" # Fallback version
        log_warn "将使用备用默认版本: ${DEFAULT_PROM_VERSION}"
    else
        DEFAULT_PROM_VERSION="$latest_version"
        log_info "获取到最新版本: ${DEFAULT_PROM_VERSION}"
    fi
}

# --- 解析命令行参数 ---
TEMP=$(getopt -o v:u:g:c:d:b:p:nh --long version:,user:,group:,config-dir:,data-dir:,bin-dir:,port:,no-interaction,help -n "$0" -- "$@")
if [ $? != 0 ]; then usage; exit 1; fi

eval set -- "$TEMP"
unset TEMP

ARG_PROM_VERSION=""
ARG_PROM_USER=""
ARG_PROM_GROUP=""
ARG_CONFIG_DIR=""
ARG_DATA_DIR=""
ARG_BIN_DIR=""
ARG_PROM_PORT=""

while true; do
  case "$1" in
    -v | --version) ARG_PROM_VERSION="$2"; shift 2 ;;
    -u | --user) ARG_PROM_USER="$2"; shift 2 ;;
    -g | --group) ARG_PROM_GROUP="$2"; shift 2 ;;
    -c | --config-dir) ARG_CONFIG_DIR="$2"; shift 2 ;;
    -d | --data-dir) ARG_DATA_DIR="$2"; shift 2 ;;
    -b | --bin-dir) ARG_BIN_DIR="$2"; shift 2 ;;
    -p | --port) ARG_PROM_PORT="$2"; shift 2 ;;
    -n | --no-interaction) INTERACTIVE=false; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "内部错误！"; exit 1 ;;
  esac
done

# 自动禁用交互模式逻辑
if [[ -n "$ARG_PROM_VERSION" || -n "$ARG_PROM_USER" || -n "$ARG_PROM_GROUP" || \
      -n "$ARG_CONFIG_DIR" || -n "$ARG_DATA_DIR" || -n "$ARG_BIN_DIR" || \
      -n "$ARG_PROM_PORT" ]]; then
    # Check if -n or --no-interaction was explicitly passed
    explicit_no_interaction=false
    for arg in "$@"; do
        if [[ "$arg" == "-n" || "$arg" == "--no-interaction" ]]; then
            explicit_no_interaction=true
            break
        fi
    done

    if $INTERACTIVE && ! $explicit_no_interaction; then
       log_info "检测到命令行配置参数，自动禁用交互模式。"
       INTERACTIVE=false
    elif ! $INTERACTIVE && $explicit_no_interaction; then
        # User specified -n, ensure INTERACTIVE is false
        INTERACTIVE=false
    fi
fi


# --- 检查 root 权限 ---
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本需要 root 权限运行。请使用 sudo。"
fi

# --- 检查依赖 ---
log_info "检查依赖项..."
check_command wget
check_command tar
check_command useradd
check_command groupadd
check_command systemctl
check_command jq
check_command curl # Needed by get_latest_version

# --- 获取最新版本 (如果需要) ---
if [[ -z "$ARG_PROM_VERSION" ]] && $INTERACTIVE; then
    get_latest_version
elif [[ -z "$ARG_PROM_VERSION" ]] && ! $INTERACTIVE; then
    get_latest_version
    if [[ -z "$DEFAULT_PROM_VERSION" ]]; then
        log_error "无法自动获取最新版本，且未通过 -v 指定版本。请使用 -v 参数指定版本。"
    fi
    # 如果 ARG_PROM_VERSION 仍然为空（例如，只提供了其他参数但未提供-v），则使用默认值
    ARG_PROM_VERSION=${ARG_PROM_VERSION:-$DEFAULT_PROM_VERSION}
    # 仅在非交互模式下显式设置版本时记录日志
    if [[ -n "$ARG_PROM_VERSION" && "$ARG_PROM_VERSION" == "$DEFAULT_PROM_VERSION" ]]; then
         log_info "将使用版本: ${ARG_PROM_VERSION}"
    fi

fi


# --- 最终确定配置值 ---
if $INTERACTIVE; then
  log_info "进入交互式配置..."
  # 获取最新版本（如果在交互模式下未通过参数指定）
  if [[ -z "$DEFAULT_PROM_VERSION" ]]; then get_latest_version; fi

  read -p "请输入要安装的 Prometheus 版本 [${DEFAULT_PROM_VERSION}]: " PROM_VERSION
  PROM_VERSION=${PROM_VERSION:-$DEFAULT_PROM_VERSION}

  read -p "请输入 Prometheus 运行用户 [${PROM_USER}]: " INPUT_USER
  PROM_USER=${INPUT_USER:-$PROM_USER}

  read -p "请输入 Prometheus 运行用户组 [${PROM_GROUP}]: " INPUT_GROUP
  PROM_GROUP=${INPUT_GROUP:-$PROM_GROUP}

  read -p "请输入配置目录 [${CONFIG_DIR}]: " INPUT_CONFIG_DIR
  CONFIG_DIR=${INPUT_CONFIG_DIR:-$CONFIG_DIR}

  read -p "请输入数据存储目录 [${DATA_DIR}]: " INPUT_DATA_DIR
  DATA_DIR=${INPUT_DATA_DIR:-$DATA_DIR}

  read -p "请输入二进制文件安装目录 [${BIN_DIR}]: " INPUT_BIN_DIR
  BIN_DIR=${INPUT_BIN_DIR:-$BIN_DIR}

  read -p "请输入 Prometheus 监听端口 [${DEFAULT_PROM_PORT}]: " INPUT_PORT
  PROM_PORT=${INPUT_PORT:-$DEFAULT_PROM_PORT}

else
  # 使用命令行参数或默认值
  PROM_VERSION=${ARG_PROM_VERSION:-$DEFAULT_PROM_VERSION}
  PROM_USER=${ARG_PROM_USER:-$PROM_USER}
  PROM_GROUP=${ARG_PROM_GROUP:-$PROM_GROUP}
  CONFIG_DIR=${ARG_CONFIG_DIR:-$CONFIG_DIR}
  DATA_DIR=${ARG_DATA_DIR:-$DATA_DIR}
  BIN_DIR=${ARG_BIN_DIR:-$BIN_DIR}
  PROM_PORT=${ARG_PROM_PORT:-$DEFAULT_PROM_PORT}

  log_info "使用非交互模式配置:"
  log_info "  版本: ${PROM_VERSION}"
  log_info "  用户: ${PROM_USER}"
  log_info "  用户组: ${PROM_GROUP}"
  log_info "  配置目录: ${CONFIG_DIR}"
  log_info "  数据目录: ${DATA_DIR}"
  log_info "  二进制目录: ${BIN_DIR}"
  log_info "  监听端口: ${PROM_PORT}"
fi

# 再次检查版本是否已确定
if [[ -z "$PROM_VERSION" ]]; then
    log_error "最终未能确定 Prometheus 版本。请检查网络或使用 -v 参数指定。"
fi

# 验证端口号
if ! [[ "$PROM_PORT" =~ ^[0-9]+$ ]] || [ "$PROM_PORT" -lt 1 ] || [ "$PROM_PORT" -gt 65535 ]; then
    log_error "无效的端口号: ${PROM_PORT}。端口必须是 1 到 65535 之间的数字。"
fi

# 构造完整的监听地址
PROM_LISTEN_ADDRESS="0.0.0.0:${PROM_PORT}"
log_info "Prometheus 将监听在: ${PROM_LISTEN_ADDRESS}"

# --- 确定系统架构 ---
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  *) log_error "不支持的系统架构: $ARCH"; exit 1 ;;
esac
log_info "检测到系统架构: $ARCH"

# --- 安装步骤 ---
log_info "开始安装 Prometheus v${PROM_VERSION}..."

# 1. 创建用户和组
log_info "创建用户 '${PROM_USER}' 和组 '${PROM_GROUP}'..."
if ! getent group "$PROM_GROUP" > /dev/null; then
  groupadd --system "$PROM_GROUP"
  log_info "用户组 '${PROM_GROUP}' 已创建。"
else
  log_info "用户组 '${PROM_GROUP}' 已存在。"
fi

if ! id -u "$PROM_USER" > /dev/null 2>&1; then
  useradd --system --no-create-home --shell /bin/false -g "$PROM_GROUP" "$PROM_USER"
  log_info "用户 '${PROM_USER}' 已创建。"
else
  log_info "用户 '${PROM_USER}' 已存在。"
  usermod -g "$PROM_GROUP" "$PROM_USER" # Ensure user is in the correct group
fi

# 2. 创建目录
log_info "创建目录..."
mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}"
mkdir -p "${BIN_DIR}"

# 3. 下载并解压 Prometheus
PROM_FILENAME="prometheus-${PROM_VERSION}.linux-${ARCH}.tar.gz"
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_FILENAME}"
DOWNLOAD_DIR="/tmp"
DOWNLOAD_PATH="${DOWNLOAD_DIR}/${PROM_FILENAME}"
EXTRACT_DIR="/tmp/prometheus-${PROM_VERSION}.linux-${ARCH}"

log_info "正在下载 Prometheus 从 ${PROM_URL}..."
wget --quiet -O "$DOWNLOAD_PATH" "$PROM_URL"
if [ $? -ne 0 ]; then
  log_error "下载 Prometheus 失败。请检查版本号 '${PROM_VERSION}' 和网络连接。"
fi
log_info "下载完成。"

log_info "正在解压 ${PROM_FILENAME}..."
rm -rf "$EXTRACT_DIR" # Clean up previous extraction attempts
tar xzf "$DOWNLOAD_PATH" -C "$DOWNLOAD_DIR"
if [ $? -ne 0 ]; then
  log_error "解压 Prometheus 失败。"
fi
log_info "解压完成。"

# 4. 安装文件
log_info "安装二进制文件和配置文件..."
mv -f "${EXTRACT_DIR}/prometheus" "${BIN_DIR}/"
mv -f "${EXTRACT_DIR}/promtool" "${BIN_DIR}/"
# Ensure target directories for consoles are clean before moving
rm -rf "${CONFIG_DIR}/consoles" "${CONFIG_DIR}/console_libraries"
mv "${EXTRACT_DIR}/consoles" "${CONFIG_DIR}/"
mv "${EXTRACT_DIR}/console_libraries" "${CONFIG_DIR}/"

# 5. 创建基础配置文件 (如果不存在)
PROM_CONFIG_FILE="${CONFIG_DIR}/prometheus.yml"
if [ ! -f "$PROM_CONFIG_FILE" ]; then
  log_info "创建基础配置文件 ${PROM_CONFIG_FILE}..."
  # Removed comments from heredoc
  cat <<EOF > "$PROM_CONFIG_FILE"
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:${PROM_PORT}"]
EOF
else
  log_warn "配置文件 ${PROM_CONFIG_FILE} 已存在，跳过创建基础配置。"
  log_warn "请确保 ${PROM_CONFIG_FILE} 中的 scrape_configs -> prometheus -> static_configs -> targets 指向正确的本地端口 (localhost:${PROM_PORT})。"
fi

# 6. 设置权限
log_info "设置文件权限..."
chown "${PROM_USER}:${PROM_GROUP}" "${CONFIG_DIR}"
chown "${PROM_USER}:${PROM_GROUP}" "${DATA_DIR}"
chown root:root "${BIN_DIR}/prometheus"
chown root:root "${BIN_DIR}/promtool"
chmod 755 "${BIN_DIR}/prometheus"
chmod 755 "${BIN_DIR}/promtool"
chown -R "${PROM_USER}:${PROM_GROUP}" "${CONFIG_DIR}/consoles"
chown -R "${PROM_USER}:${PROM_GROUP}" "${CONFIG_DIR}/console_libraries"
# Ensure config file has correct ownership and restricted permissions
chown "${PROM_USER}:${PROM_GROUP}" "$PROM_CONFIG_FILE"
chmod 640 "$PROM_CONFIG_FILE" # Owner(rw) Group(r) Other(-)

# 7. 创建 Systemd 服务文件
SERVICE_FILE="/etc/systemd/system/prometheus.service"
log_info "创建 systemd 服务文件 ${SERVICE_FILE}..."
# Removed comments from heredoc
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Prometheus Time Series Collection and Processing Server
Wants=network-online.target
After=network-online.target

[Service]
User=${PROM_USER}
Group=${PROM_GROUP}
Type=simple
ExecStart=${BIN_DIR}/prometheus \\
    --config.file ${CONFIG_DIR}/prometheus.yml \\
    --storage.tsdb.path ${DATA_DIR}/ \\
    --web.console.templates=${CONFIG_DIR}/consoles \\
    --web.console.libraries=${CONFIG_DIR}/console_libraries \\
    --web.listen-address=${PROM_LISTEN_ADDRESS}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
log_info "重新加载 systemd 配置并启动 Prometheus 服务..."
systemctl daemon-reload
systemctl stop prometheus >/dev/null 2>&1 # Stop existing service if running
systemctl enable prometheus
systemctl start prometheus

# 9. 清理
log_info "清理下载文件..."
rm -f "$DOWNLOAD_PATH"
rm -rf "$EXTRACT_DIR"

# 10. 显示状态
log_info "检查 Prometheus 服务状态..."
sleep 5 # Give service time to start
systemctl status prometheus --no-pager

echo ""
log_info "Prometheus 安装完成！"
log_info "配置文件位于: ${PROM_CONFIG_FILE}"
log_info "数据存储于: ${DATA_DIR}"
log_info "Prometheus 正在监听地址: ${PROM_LISTEN_ADDRESS}"
log_info "服务管理: sudo systemctl [start|stop|restart|status] prometheus"
echo ""
log_info "您可以通过浏览器访问 http://<您的服务器IP>:${PROM_PORT} 来访问 Prometheus UI。"
log_info "如果无法访问，请确保防火墙已允许 TCP 端口 ${PROM_PORT} 的入站连接。"

exit 0