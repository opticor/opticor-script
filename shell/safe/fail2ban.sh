#!/bin/bash

# Fail2ban 一键安装与 SSH 防护配置脚本

# --- 可配置参数 ---
SSH_MAXRETRY=5        # SSH 允许的最大失败尝试次数
SSH_FINDTIME="10m"    # 在此时间段内达到 maxretry 次数即触发封禁 (m=分钟, h=小时, d=天)
SSH_BANTIME="1h"      # 封禁时长 (m=分钟, h=小时, d=天), 设置为 -1 表示永久封禁 (不推荐)
# --- 可配置参数结束 ---

# --- 颜色定义 (可选) ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
# --- 颜色定义结束 ---

# 函数：打印信息
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 1. 检查 Root 权限
if [[ "$(id -u)" -ne 0 ]]; then
   log_error "此脚本必须以 root 用户或使用 sudo 运行。"
   exit 1
fi

# 2. 检测包管理器并设置命令
PACKAGE_MANAGER=""
UPDATE_CMD=""
INSTALL_CMD=""

if command -v apt >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt"
    UPDATE_CMD="apt update"
    INSTALL_CMD="apt install -y fail2ban"
    log_info "检测到包管理器: apt"
elif command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf"
    UPDATE_CMD="dnf check-update" # dnf 通常在安装时自动处理依赖更新
    INSTALL_CMD="dnf install -y fail2ban"
    log_info "检测到包管理器: dnf"
elif command -v yum >/dev/null 2>&1; then
    PACKAGE_MANAGER="yum"
    UPDATE_CMD="yum check-update" # yum 通常在安装时自动处理依赖更新
    INSTALL_CMD="yum install -y fail2ban epel-release" # CentOS 7可能需要epel
    log_info "检测到包管理器: yum"
else
    log_error "未找到支持的包管理器 (apt, dnf, yum)。请手动安装 Fail2ban。"
    exit 1
fi

# 3. 更新包列表 (根据需要)
log_info "正在更新包列表..."
if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
    if ! $UPDATE_CMD; then
        log_error "更新包列表失败。"
        exit 1
    fi
elif [[ "$PACKAGE_MANAGER" == "dnf" || "$PACKAGE_MANAGER" == "yum" ]]; then
     # dnf/yum 在 install 时通常会处理，check-update 主要用于显示信息
     $UPDATE_CMD > /dev/null 2>&1 # 抑制检查更新的输出
fi

# 4. 安装 Fail2ban
log_info "正在安装 Fail2ban..."
# 对于 RHEL/CentOS 7，fail2ban 通常在 EPEL 源中
if [[ "$PACKAGE_MANAGER" == "yum" ]] && ! rpm -q epel-release > /dev/null 2>&1; then
    log_info "检测到 CentOS/RHEL 系统且未安装 EPEL 源，尝试安装..."
    if ! yum install -y epel-release; then
        log_warn "安装 EPEL 源失败。如果 Fail2ban 安装失败，请先手动安装 EPEL 源。"
    fi
fi

if ! $INSTALL_CMD; then
    log_error "安装 Fail2ban 失败。"
    exit 1
fi
log_info "Fail2ban 安装成功。"

# 5. 启用并启动 Fail2ban 服务
log_info "正在启用并启动 Fail2ban 服务..."
if ! systemctl enable fail2ban; then
    log_warn "设置 Fail2ban 开机自启失败。"
else
    log_info "Fail2ban 已设置为开机自启。"
fi

if ! systemctl start fail2ban; then
    log_error "启动 Fail2ban 服务失败。请检查日志: journalctl -u fail2ban"
    exit 1
fi
log_info "Fail2ban 服务已启动。"

# 6. 创建基础 SSH 防护配置 (jail.local)
JAIL_LOCAL_FILE="/etc/fail2ban/jail.local"
log_info "正在创建 Fail2ban SSH 防护配置文件: $JAIL_LOCAL_FILE"

# 使用 cat 和 heredoc 创建文件，如果文件已存在则覆盖（或可以先备份）
# 注意：这里直接覆盖了 jail.local。如果用户已有此文件，其内容会丢失。
# 可以添加备份逻辑：
# if [ -f "$JAIL_LOCAL_FILE" ]; then
#     cp "$JAIL_LOCAL_FILE" "${JAIL_LOCAL_FILE}.bak_$(date +%Y%m%d%H%M%S)"
#     log_warn "已备份现有的 $JAIL_LOCAL_FILE 文件。"
# fi

cat << EOF > "$JAIL_LOCAL_FILE"
# Fail2ban local configuration file for SSH protection
# Created by install_fail2ban.sh script

[DEFAULT]
# 默认忽略的 IP 地址列表，可以添加你信任的 IP
# 例如: ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 your.trusted.ip
ignoreip = 127.0.0.1/8 ::1

# [sshd] jail configuration (for OpenSSH server)
[sshd]
enabled = true
port = ssh          # 监控 SSH 端口 (默认 22)
# 如果你的 SSH 端口不是 22, 请修改这里, 例如: port = 2222
filter = sshd       # 使用 /etc/fail2ban/filter.d/sshd.conf 过滤器
logpath = %(sshd_log)s # 自动检测 SSH 日志路径 (通常是 /var/log/auth.log 或 /var/log/secure)
backend = %(sshd_backend)s # 自动检测日志后端
maxretry = ${SSH_MAXRETRY}        # 最大尝试次数
findtime = ${SSH_FINDTIME}      # 查找时间窗口
bantime = ${SSH_BANTIME}       # 封禁时长

# 你可以根据需要添加或启用其他 jail, 例如:
# [nginx-http-auth]
# enabled = true
# ...

EOF

if [ $? -ne 0 ]; then
    log_error "创建 $JAIL_LOCAL_FILE 文件失败。"
    exit 1
fi

log_info "$JAIL_LOCAL_FILE 创建成功，SSH 防护已配置。"
log_info "配置详情: maxretry=${SSH_MAXRETRY}, findtime=${SSH_FINDTIME}, bantime=${SSH_BANTIME}"

# 7. 重启 Fail2ban 服务以应用配置
log_info "正在重启 Fail2ban 服务以应用新配置..."
if ! systemctl restart fail2ban; then
    log_error "重启 Fail2ban 服务失败。请检查配置: fail2ban-client -t"
    log_error "并检查日志: journalctl -u fail2ban"
    exit 1
fi
log_info "Fail2ban 服务已重启。"

# 8. 显示状态信息
log_info "Fail2ban 安装和基础配置完成！"
echo -e "${YELLOW}-----------------------------------------------------${NC}"
echo -e "你可以使用以下命令查看 Fail2ban 状态:"
echo -e "  ${GREEN}sudo systemctl status fail2ban${NC}  (查看服务状态)"
echo -e "  ${GREEN}sudo fail2ban-client status${NC}     (查看当前启用的 Jails)"
echo -e "  ${GREEN}sudo fail2ban-client status sshd${NC} (查看 sshd jail 的详细状态，包括被封禁的 IP)"
echo -e "${YELLOW}-----------------------------------------------------${NC}"
echo -e "配置文件位于: ${GREEN}/etc/fail2ban/jail.local${NC}"

exit 0