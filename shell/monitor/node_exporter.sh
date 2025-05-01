#!/bin/bash

# Node Exporter

# --- 配置变量 (默认值) ---
DEFAULT_NODE_EXPORTER_VERSION="" # 将尝试从 GitHub 获取最新版本
NODE_EXPORTER_USER="node_exporter"
NODE_EXPORTER_GROUP="node_exporter"
DEFAULT_NODE_EXPORTER_PORT="9100" # Node Exporter 默认监听端口
BIN_DIR="/usr/local/bin"
INTERACTIVE=true # 默认为交互模式

# --- 帮助信息 ---
usage() {
  echo "用法: $0 [选项]"
  echo ""
  echo "安装 Node Exporter 并配置 systemd 服务."
  echo ""
  echo "选项:"
  echo "  -v, --version VERSION    指定要安装的 Node Exporter 版本 (默认: 最新稳定版)"
  echo "  -u, --user USER          指定 Node Exporter 运行用户 (默认: ${NODE_EXPORTER_USER})"
  echo "  -g, --group GROUP        指定 Node Exporter 运行用户组 (默认: ${NODE_EXPORTER_GROUP})"
  echo "  -p, --port PORT          指定 Node Exporter 监听端口 (默认: ${DEFAULT_NODE_EXPORTER_PORT})"
  echo "  -b, --bin-dir DIR        指定二进制文件安装目录 (默认: ${BIN_DIR})"
  echo "  -n, --no-interaction     使用默认值或命令行参数值，不进行交互式提问"
  echo "  -h, --help               显示此帮助信息"
  echo ""
  echo "示例:"
  echo "  # 交互式安装"
  echo "  sudo bash $0"
  echo ""
  echo "  # 使用命令行参数指定版本、端口并跳过交互"
  echo "  sudo bash $0 -v 1.7.0 -p 9101 -n"
  echo ""
  echo "  # 指定自定义用户和二进制目录"
  echo "  sudo bash $0 --user node-exp --group node-exp --bin-dir /opt/bin -n"
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

# --- 获取最新 Node Exporter 版本 ---
get_latest_version() {
    log_info "正在尝试从 GitHub 获取最新的 Node Exporter 版本..."
    local latest_version
    # 注意：Node Exporter 的 API URL 不同
    latest_version=$(curl -s "https://api.github.com/repos/prometheus/node_exporter/releases/latest" | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        log_warn "无法自动获取最新版本。您可以手动指定版本或稍后重试。"
        # 设置一个已知的较新版本作为备用
        DEFAULT_NODE_EXPORTER_VERSION="1.8.1" # <--- 在无法获取时使用的硬编码版本
        log_warn "将使用备用默认版本: ${DEFAULT_NODE_EXPORTER_VERSION}"
    else
        DEFAULT_NODE_EXPORTER_VERSION="$latest_version"
        log_info "获取到最新版本: ${DEFAULT_NODE_EXPORTER_VERSION}"
    fi
}

# --- 解析命令行参数 ---
TEMP=$(getopt -o v:u:g:p:b:nh --long version:,user:,group:,port:,bin-dir:,no-interaction,help -n "$0" -- "$@")
if [ $? != 0 ]; then usage; exit 1; fi

eval set -- "$TEMP"
unset TEMP

ARG_NODE_EXPORTER_VERSION=""
ARG_NODE_EXPORTER_USER=""
ARG_NODE_EXPORTER_GROUP=""
ARG_NODE_EXPORTER_PORT=""
ARG_BIN_DIR=""

while true; do
  case "$1" in
    -v | --version) ARG_NODE_EXPORTER_VERSION="$2"; shift 2 ;;
    -u | --user) ARG_NODE_EXPORTER_USER="$2"; shift 2 ;;
    -g | --group) ARG_NODE_EXPORTER_GROUP="$2"; shift 2 ;;
    -p | --port) ARG_NODE_EXPORTER_PORT="$2"; shift 2 ;;
    -b | --bin-dir) ARG_BIN_DIR="$2"; shift 2 ;;
    -n | --no-interaction) INTERACTIVE=false; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "内部错误！"; exit 1 ;;
  esac
done

# 自动禁用交互模式逻辑
if [[ -n "$ARG_NODE_EXPORTER_VERSION" || -n "$ARG_NODE_EXPORTER_USER" || -n "$ARG_NODE_EXPORTER_GROUP" || \
      -n "$ARG_NODE_EXPORTER_PORT" || -n "$ARG_BIN_DIR" ]]; then
    explicit_no_interaction=false
    # 检查原始参数中是否包含 -n 或 --no-interaction
    original_args=$(echo "$@" | sed "s/--//") # 去掉 getopt 添加的 --
    for arg in $original_args; do
        if [[ "$arg" == "-n" || "$arg" == "--no-interaction" ]]; then
            explicit_no_interaction=true
            break
        fi
    done

    if $INTERACTIVE && ! $explicit_no_interaction; then
       log_info "检测到命令行配置参数，自动禁用交互模式。"
       INTERACTIVE=false
    elif $explicit_no_interaction; then
        # Ensure INTERACTIVE is false if -n was explicitly passed
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
check_command jq # 用于获取最新版本
check_command curl # 用于获取最新版本

# --- 获取最新版本---
if [[ -z "$ARG_NODE_EXPORTER_VERSION" ]] && $INTERACTIVE; then
    get_latest_version
elif [[ -z "$ARG_NODE_EXPORTER_VERSION" ]] && ! $INTERACTIVE; then
    get_latest_version
    if [[ -z "$DEFAULT_NODE_EXPORTER_VERSION" ]]; then
        log_error "无法自动获取最新版本，且未通过 -v 指定版本。请使用 -v 参数指定版本。"
    fi
    ARG_NODE_EXPORTER_VERSION=${ARG_NODE_EXPORTER_VERSION:-$DEFAULT_NODE_EXPORTER_VERSION}
    if [[ -n "$ARG_NODE_EXPORTER_VERSION" && "$ARG_NODE_EXPORTER_VERSION" == "$DEFAULT_NODE_EXPORTER_VERSION" ]]; then
         log_info "将使用版本: ${ARG_NODE_EXPORTER_VERSION}"
    fi

fi

# --- 最终确定配置值 ---
if $INTERACTIVE; then
  log_info "进入交互式配置..."
  if [[ -z "$DEFAULT_NODE_EXPORTER_VERSION" ]]; then get_latest_version; fi # 确保有默认版本

  read -p "请输入要安装的 Node Exporter 版本 [${DEFAULT_NODE_EXPORTER_VERSION}]: " NODE_EXPORTER_VERSION
  NODE_EXPORTER_VERSION=${NODE_EXPORTER_VERSION:-$DEFAULT_NODE_EXPORTER_VERSION}

  read -p "请输入 Node Exporter 运行用户 [${NODE_EXPORTER_USER}]: " INPUT_USER
  NODE_EXPORTER_USER=${INPUT_USER:-$NODE_EXPORTER_USER}

  read -p "请输入 Node Exporter 运行用户组 [${NODE_EXPORTER_GROUP}]: " INPUT_GROUP
  NODE_EXPORTER_GROUP=${INPUT_GROUP:-$NODE_EXPORTER_GROUP}

  read -p "请输入 Node Exporter 监听端口 [${DEFAULT_NODE_EXPORTER_PORT}]: " INPUT_PORT
  NODE_EXPORTER_PORT=${INPUT_PORT:-$DEFAULT_NODE_EXPORTER_PORT}

  read -p "请输入二进制文件安装目录 [${BIN_DIR}]: " INPUT_BIN_DIR
  BIN_DIR=${INPUT_BIN_DIR:-$BIN_DIR}

else
  # 使用命令行参数或默认值
  NODE_EXPORTER_VERSION=${ARG_NODE_EXPORTER_VERSION:-$DEFAULT_NODE_EXPORTER_VERSION}
  NODE_EXPORTER_USER=${ARG_NODE_EXPORTER_USER:-$NODE_EXPORTER_USER}
  NODE_EXPORTER_GROUP=${ARG_NODE_EXPORTER_GROUP:-$NODE_EXPORTER_GROUP}
  NODE_EXPORTER_PORT=${ARG_NODE_EXPORTER_PORT:-$DEFAULT_NODE_EXPORTER_PORT}
  BIN_DIR=${ARG_BIN_DIR:-$BIN_DIR}

  log_info "使用非交互模式配置:"
  log_info "  版本: ${NODE_EXPORTER_VERSION}"
  log_info "  用户: ${NODE_EXPORTER_USER}"
  log_info "  用户组: ${NODE_EXPORTER_GROUP}"
  log_info "  监听端口: ${NODE_EXPORTER_PORT}"
  log_info "  二进制目录: ${BIN_DIR}"
fi

# 再次检查版本是否已确定
if [[ -z "$NODE_EXPORTER_VERSION" ]]; then
    log_error "最终未能确定 Node Exporter 版本。请检查网络或使用 -v 参数指定。"
fi

# 验证端口号
if ! [[ "$NODE_EXPORTER_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_EXPORTER_PORT" -lt 1 ] || [ "$NODE_EXPORTER_PORT" -gt 65535 ]; then
    log_error "无效的端口号: ${NODE_EXPORTER_PORT}。端口必须是 1 到 65535 之间的数字。"
fi

# 构造完整的监听地址
NODE_EXPORTER_LISTEN_ADDRESS="0.0.0.0:${NODE_EXPORTER_PORT}"
log_info "Node Exporter 将监听在: ${NODE_EXPORTER_LISTEN_ADDRESS}"

# --- 确定系统架构 ---
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  armv6l) ARCH="armv6" ;; # Node exporter might still support armv6
  *) log_error "不支持的系统架构: $ARCH"; exit 1 ;;
esac
log_info "检测到系统架构: $ARCH"

# --- 安装步骤 ---
log_info "开始安装 Node Exporter v${NODE_EXPORTER_VERSION}..."

# 1. 创建用户和组
log_info "创建用户 '${NODE_EXPORTER_USER}' 和组 '${NODE_EXPORTER_GROUP}'..."
if ! getent group "$NODE_EXPORTER_GROUP" > /dev/null; then
  groupadd --system "$NODE_EXPORTER_GROUP"
  log_info "用户组 '${NODE_EXPORTER_GROUP}' 已创建。"
else
  log_info "用户组 '${NODE_EXPORTER_GROUP}' 已存在。"
fi

if ! id -u "$NODE_EXPORTER_USER" > /dev/null 2>&1; then
  # 使用 /sbin/nologin 或 /bin/false 作为 shell，并且不创建家目录
  useradd --system --no-create-home --shell /bin/false -g "$NODE_EXPORTER_GROUP" "$NODE_EXPORTER_USER"
  log_info "用户 '${NODE_EXPORTER_USER}' 已创建。"
else
  log_info "用户 '${NODE_EXPORTER_USER}' 已存在。"
  usermod -g "$NODE_EXPORTER_GROUP" "$NODE_EXPORTER_USER" # 确保用户属于正确的组
fi

# 2. 创建目录 (只需要确保二进制目录存在)
log_info "确保二进制目录存在: ${BIN_DIR}"
mkdir -p "${BIN_DIR}"

# 3. 下载并解压 Node Exporter
NODE_EXPORTER_FILENAME="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_FILENAME}"
DOWNLOAD_DIR="/tmp"
DOWNLOAD_PATH="${DOWNLOAD_DIR}/${NODE_EXPORTER_FILENAME}"
EXTRACT_DIR_BASE="/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}" # 解压后的目录名

log_info "正在下载 Node Exporter 从 ${NODE_EXPORTER_URL}..."
wget --quiet -O "$DOWNLOAD_PATH" "$NODE_EXPORTER_URL"
if [ $? -ne 0 ]; then
  log_error "下载 Node Exporter 失败。请检查版本号 '${NODE_EXPORTER_VERSION}' 和网络连接。"
fi
log_info "下载完成。"

log_info "正在解压 ${NODE_EXPORTER_FILENAME}..."
rm -rf "$EXTRACT_DIR_BASE" # 清理旧的解压目录
tar xzf "$DOWNLOAD_PATH" -C "$DOWNLOAD_DIR"
if [ $? -ne 0 ]; then
  log_error "解压 Node Exporter 失败。"
fi
log_info "解压完成。"

# 4. 安装文件
log_info "安装二进制文件..."
# 将解压目录中的 node_exporter 文件移动到目标 BIN_DIR
mv -f "${EXTRACT_DIR_BASE}/node_exporter" "${BIN_DIR}/"
if [ $? -ne 0 ]; then
    log_error "移动 node_exporter 二进制文件失败。"
fi

# 5. 设置权限
log_info "设置文件权限..."
chown root:root "${BIN_DIR}/node_exporter"
chmod 755 "${BIN_DIR}/node_exporter"

# 6. 创建 Systemd 服务文件
SERVICE_FILE="/etc/systemd/system/node_exporter.service"
log_info "创建 systemd 服务文件 ${SERVICE_FILE}..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_GROUP}
Type=simple
ExecStart=${BIN_DIR}/node_exporter \\
    --web.listen-address=${NODE_EXPORTER_LISTEN_ADDRESS}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
log_info "重新加载 systemd 配置并启动 Node Exporter 服务..."
systemctl daemon-reload
systemctl stop node_exporter >/dev/null 2>&1 # Stop existing service if running
systemctl enable node_exporter
systemctl start node_exporter

# 8. 清理
log_info "清理下载文件..."
rm -f "$DOWNLOAD_PATH"
rm -rf "$EXTRACT_DIR_BASE"

# 9. 显示状态
log_info "检查 Node Exporter 服务状态..."
sleep 3 # Give service time to start
systemctl status node_exporter --no-pager

echo ""
log_info "Node Exporter 安装完成！"
log_info "Node Exporter 正在监听地址: ${NODE_EXPORTER_LISTEN_ADDRESS}"
log_info "服务管理: sudo systemctl [start|stop|restart|status] node_exporter"
echo ""
log_info "您可以通过访问 http://<您的服务器IP>:${NODE_EXPORTER_PORT}/metrics 来获取指标。"
log_info "请确保 Prometheus 配置已添加此 Target 或通过服务发现找到它。"
log_info "如果无法访问，请确保防火墙已允许 TCP 端口 ${NODE_EXPORTER_PORT} 的入站连接。"

exit 0