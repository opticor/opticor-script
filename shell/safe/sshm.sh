#!/usr/bin/env bash
#===============================================================================
# SSH Manager - SSH 配置管理工具
# 兼容: Debian / Ubuntu
# 功能: 端口修改(含连通性检测)、推荐安全配置、命令行/交互式双模式
# 版本: 1.0.0
#===============================================================================

set -euo pipefail

#---------- 全局变量 ----------
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
BACKUP_DIR="/etc/ssh/backups"
SCRIPT_NAME="$(basename "$0")"
VERSION="1.0.0"

# 颜色
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
CYAN=$'\e[0;36m'
MAGENTA=$'\e[0;35m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
NC=$'\e[0m'

#===============================================================================
# 工具函数
#===============================================================================

log_info()  { echo -e "${GREEN}[✓]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*" >&2; }
log_error() { echo -e "${RED}[✗]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[→]${NC} $*" >&2; }

die() { log_error "$*"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "此脚本需要 root 权限，请使用 sudo"
}

check_os() {
    [[ -f /etc/os-release ]] || die "无法检测操作系统"
    source /etc/os-release
    case "$ID" in
        debian|ubuntu) ;;
        *) die "仅支持 Debian/Ubuntu，当前: $ID" ;;
    esac
}

ensure_deps() {
    local need_install=()
    command -v ss    &>/dev/null || need_install+=(iproute2)
    command -v curl  &>/dev/null || need_install+=(curl)
    command -v nc    &>/dev/null || command -v ncat &>/dev/null || need_install+=(netcat-openbsd)
    if (( ${#need_install[@]} > 0 )); then
        log_step "安装依赖: ${need_install[*]}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${need_install[@]}" >/dev/null 2>&1
    fi
}

hr() {
    printf '%0.s─' $(seq 1 64)
    echo
}

#===============================================================================
# SSH 配置读写
#===============================================================================

# 获取生效值（config.d 优先）
get_effective_value() {
    local key="$1" default="${2:-}" value=""
    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        for f in "$SSHD_CONFIG_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            value=$(grep -Pi "^\s*${key}\s" "$f" 2>/dev/null | head -1 | awk '{print $2}')
            [[ -n "$value" ]] && { echo "$value"; return; }
        done
    fi
    value=$(grep -Pi "^\s*${key}\s" "$SSHD_CONFIG" 2>/dev/null | head -1 | awk '{print $2}')
    echo "${value:-$default}"
}

# 获取当前配置端口列表
get_current_ports() {
    local ports=()
    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        for f in "$SSHD_CONFIG_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            while read -r p; do
                [[ -n "$p" ]] && ports+=("$p")
            done < <(grep -Pi "^\s*Port\s" "$f" 2>/dev/null | awk '{print $2}')
        done
    fi
    while read -r p; do
        [[ -n "$p" ]] && ports+=("$p")
    done < <(grep -Pi "^\s*Port\s" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    if (( ${#ports[@]} > 0 )); then
        printf '%s\n' "${ports[@]}" | sort -un
    else
        echo "22"
    fi
}

# 实际监听端口
get_listening_ports() {
    ss -tlnp 2>/dev/null | grep -E 'sshd|"ssh"' | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    cp "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config.${ts}"
    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        for f in "$SSHD_CONFIG_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            cp "$f" "${BACKUP_DIR}/$(basename "$f").${ts}"
        done
    fi
    log_info "配置已备份 (${ts})"
    echo "$ts"
}

restore_backup() {
    local ts="${1:-}"
    if [[ -z "$ts" ]]; then
        local latest; latest=$(ls -t "${BACKUP_DIR}"/sshd_config.* 2>/dev/null | head -1)
        [[ -n "$latest" ]] || { log_error "无可用备份"; return 1; }
        ts=$(basename "$latest" | sed 's/sshd_config\.//')
    fi
    [[ -f "${BACKUP_DIR}/sshd_config.${ts}" ]] || { log_error "备份 ${ts} 不存在"; return 1; }
    cp "${BACKUP_DIR}/sshd_config.${ts}" "$SSHD_CONFIG"
    for bak in "${BACKUP_DIR}"/*.conf."${ts}"; do
        [[ -f "$bak" ]] || continue
        local name; name=$(basename "$bak" | sed "s/\.${ts}$//")
        cp "$bak" "${SSHD_CONFIG_DIR}/${name}"
    done
    log_info "已恢复备份 ${ts}"
}

# 清除 sshd_config.d 中指定 key（避免覆盖主配置）
clear_key_from_confd() {
    local key="$1"
    [[ -d "$SSHD_CONFIG_DIR" ]] || return
    for f in "$SSHD_CONFIG_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -Piq "^\s*${key}\s" "$f" 2>/dev/null; then
            log_warn "移除 $(basename "$f") 中的 ${key}"
            sed -i "/^\s*${key}\s/Id" "$f"
        fi
    done
}

set_config_value() {
    local key="$1" value="$2"
    clear_key_from_confd "$key"
    if grep -Piq "^\s*${key}\s" "$SSHD_CONFIG"; then
        sed -i "s/^\s*${key}\s.*/${key} ${value}/Ii" "$SSHD_CONFIG"
    elif grep -Piq "^\s*#\s*${key}\s" "$SSHD_CONFIG"; then
        sed -i "s/^\s*#\s*${key}\s.*/${key} ${value}/Ii" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

set_port_value() {
    local new_port="$1"
    clear_key_from_confd "Port"
    sed -i "/^\s*Port\s/Id"   "$SSHD_CONFIG"
    sed -i "/^\s*#\s*Port\s/Id" "$SSHD_CONFIG"
    sed -i "1a Port ${new_port}" "$SSHD_CONFIG"
}

validate_config() {
    local out
    if out=$(sshd -t 2>&1); then
        log_info "配置语法检查通过"
        return 0
    else
        log_error "配置语法错误:"; echo "$out"
        return 1
    fi
}

sshd_service_name() {
    if systemctl is-active --quiet sshd 2>/dev/null; then
        echo "sshd"
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        echo "ssh"
    elif systemctl list-unit-files sshd.service &>/dev/null; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

reload_sshd()  { systemctl reload  "$(sshd_service_name)"; log_info "sshd 已 reload"; }
restart_sshd() { systemctl restart "$(sshd_service_name)"; log_info "sshd 已 restart"; }

#===============================================================================
# 防火墙管理
#===============================================================================

detect_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null && iptables -L INPUT -n 2>/dev/null | grep -qE "REJECT|DROP"; then
        echo "iptables"
    elif command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -qiE "drop|reject"; then
        echo "nftables"
    else
        echo "none"
    fi
}

fw_allow() {
    local port="$1" fw; fw=$(detect_firewall)
    case "$fw" in
        ufw)
            ufw allow "${port}/tcp" comment "SSH" >/dev/null 2>&1
            log_info "UFW 已放行 ${port}/tcp"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            log_info "Firewalld 已放行 ${port}/tcp"
            ;;
        iptables)
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null || true
            log_info "iptables 已放行 ${port}/tcp"
            ;;
        nftables)
            nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
            log_info "nftables 已放行 ${port}/tcp"
            ;;
        none)
            log_info "无活动防火墙，跳过"
            ;;
    esac
}

fw_remove() {
    local port="$1" fw; fw=$(detect_firewall)
    [[ "$port" == "22" ]] && return 0
    case "$fw" in
        ufw)       ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true ;;
        firewalld) firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1 ;;
        iptables)  iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true ;;
        *)         ;;
    esac
}

#===============================================================================
# 端口连通性检测
#===============================================================================

check_port_conflict() {
    local port="$1"
    local line; line=$(ss -tlnp "sport = :${port}" 2>/dev/null | tail -n +2 | head -1)
    [[ -z "$line" ]] && return 1
    local proc; proc=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")
    [[ "$proc" == "sshd" || "$proc" == "ssh" ]] && return 1
    echo "$proc"
    return 0
}

get_public_ip() {
    curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
    curl -s --connect-timeout 5 icanhazip.com 2>/dev/null || \
    curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || echo ""
}

# 外部端口可达检测：通过 /dev/tcp 连自己公网IP
check_port_external() {
    local port="$1"
    local ip; ip=$(get_public_ip)
    if [[ -z "$ip" ]]; then
        log_warn "无法获取公网 IP，跳过外部检测"
        return 0
    fi
    log_step "公网 IP: ${ip} — 检测端口 ${port} 可达性..."

    # 方法1: bash /dev/tcp
    if (echo > /dev/tcp/"$ip"/"$port") 2>/dev/null; then
        return 0
    fi
    # 方法2: nc
    if command -v nc &>/dev/null; then
        if nc -z -w5 "$ip" "$port" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

#===============================================================================
# 端口修改核心流程
#===============================================================================

change_port() {
    local new_port="$1"
    local force="${2:-false}"
    local skip_check="${3:-false}"

    # --- 验证 ---
    [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )) || \
        die "无效端口号: ${new_port} (1-65535)"

    if (( new_port < 1024 && new_port != 22 )); then
        log_warn "端口 ${new_port} 是特权端口(<1024)"
        [[ "$force" == "true" ]] || { read -rp "继续？[y/N] " c; [[ "$c" =~ ^[yY] ]] || return 1; }
    fi

    local occupant
    if occupant=$(check_port_conflict "$new_port"); then
        die "端口 ${new_port} 被 '${occupant}' 占用"
    fi

    local current_ports; current_ports=$(get_current_ports)
    local old_port;      old_port=$(echo "$current_ports" | head -1)

    echo "$current_ports" | grep -qx "$new_port" && { log_info "已是端口 ${new_port}"; return 0; }

    echo ""
    log_info "当前端口: $(echo $current_ports | tr '\n' ' ')"
    log_step "目标端口: ${new_port}"
    echo ""

    # --- 阶段1: 防火墙 ---
    log_step "[1/4] 放行防火墙..."
    fw_allow "$new_port"

    # --- 阶段2: 备份 + 双端口 ---
    log_step "[2/4] 备份配置，启用双端口模式..."
    local backup_ts; backup_ts=$(backup_config)

    clear_key_from_confd "Port"
    sed -i "/^\s*Port\s/Id"    "$SSHD_CONFIG"
    sed -i "/^\s*#\s*Port\s/Id" "$SSHD_CONFIG"
    sed -i "1a Port ${old_port}"  "$SSHD_CONFIG"
    sed -i "1a Port ${new_port}" "$SSHD_CONFIG"

    if ! validate_config; then
        restore_backup "$backup_ts"; die "语法错误，已回滚"
    fi

    # --- 阶段3: 重启 + 检测 ---
    log_step "[3/4] 重启 sshd（双端口），检测连通性..."
    restart_sshd
    sleep 2

    if ! ss -tlnp "sport = :${new_port}" 2>/dev/null | grep -qE 'sshd|"ssh"'; then
        log_error "端口 ${new_port} 未监听"; restore_backup "$backup_ts"; restart_sshd
        die "已回滚"
    fi
    log_info "本地监听正常: ${new_port}"

    if [[ "$skip_check" != "true" ]]; then
        sleep 1
        if ! check_port_external "$new_port"; then
            echo ""
            echo -e "${RED}┌──────────────────────────────────────────────────────────────┐${NC}"
            echo -e "${RED}│  ${BOLD}⚠  端口 ${new_port} 外部不可达！禁止切换！${NC}${RED}                       │${NC}"
            echo -e "${RED}│                                                              │${NC}"
            echo -e "${RED}│  本地防火墙已放行，但外部仍无法访问。                        │${NC}"
            echo -e "${RED}│  极大可能原因：                                              │${NC}"
            echo -e "${RED}│                                                              │${NC}"
            echo -e "${RED}│  • 云服务商安全组未放行该端口                                │${NC}"
            echo -e "${RED}│    AWS → Security Group / NACL                               │${NC}"
            echo -e "${RED}│    阿里云 → 安全组规则                                       │${NC}"
            echo -e "${RED}│    腾讯云 → 安全组规则                                       │${NC}"
            echo -e "${RED}│    GCP → VPC Firewall Rules                                  │${NC}"
            echo -e "${RED}│                                                              │${NC}"
            echo -e "${RED}│  • 上游路由/NAT 未转发                                       │${NC}"
            echo -e "${RED}│  • ISP 封锁了该端口                                          │${NC}"
            echo -e "${RED}│                                                              │${NC}"
            echo -e "${RED}│  请先在云控制台/上游防火墙放行端口 ${new_port}，再重试。       │${NC}"
            echo -e "${RED}└──────────────────────────────────────────────────────────────┘${NC}"
            echo ""
            log_step "回滚中..."
            restore_backup "$backup_ts"
            restart_sshd
            fw_remove "$new_port"
            log_info "已恢复原端口 ${old_port}"
            return 1
        fi
        log_info "外部可达检测通过"
    else
        log_warn "跳过外部可达性检测 (--skip-check)"
    fi

    # --- 阶段4: 定型 ---
    log_step "[4/4] 移除旧端口，完成切换..."
    sed -i "/^\s*Port\s/Id" "$SSHD_CONFIG"
    sed -i "1a Port ${new_port}" "$SSHD_CONFIG"

    validate_config || { restore_backup "$backup_ts"; restart_sshd; die "最终验证失败，已回滚"; }
    restart_sshd
    sleep 1
    fw_remove "$old_port"

    local conn_str="ssh -p ${new_port} user@host"
    echo ""
    echo -e "${GREEN}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│  ${BOLD}✓  SSH 端口修改成功${NC}${GREEN}                                        │${NC}"
    echo -e "${GREEN}│                                                              │${NC}"
    printf  "${GREEN}│  旧端口: %-52s│${NC}\n" "$old_port"
    printf  "${GREEN}│  新端口: %-52s│${NC}\n" "$new_port"
    echo -e "${GREEN}│                                                              │${NC}"
    printf  "${GREEN}│  连接: %-56s│${NC}\n" "$conn_str"
    echo -e "${GREEN}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${YELLOW}[!] 请保持当前会话，新开终端测试连接！${NC}"
}

#===============================================================================
# 配置项修改
#===============================================================================

set_config_item() {
    local key="$1" value="$2" desc="${3:-}"
    backup_config >/dev/null
    set_config_value "$key" "$value"
    if validate_config; then
        reload_sshd
        log_info "${desc:-$key} → ${value}"
    else
        restore_backup
        restart_sshd
        log_error "设置 ${key} 失败，已回滚"
        return 1
    fi
}

#===============================================================================
# 推荐配置方案
#===============================================================================

apply_preset() {
    local preset="$1"
    local ts; ts=$(backup_config)

    case "$preset" in
        basic)
            set_config_value "PermitRootLogin"        "prohibit-password"
            set_config_value "PasswordAuthentication"  "yes"
            set_config_value "PubkeyAuthentication"    "yes"
            set_config_value "PermitEmptyPasswords"    "no"
            set_config_value "MaxAuthTries"            "6"
            set_config_value "MaxSessions"             "10"
            set_config_value "X11Forwarding"           "no"
            set_config_value "ClientAliveInterval"     "300"
            set_config_value "ClientAliveCountMax"     "3"
            set_config_value "LoginGraceTime"          "60"
            set_config_value "UseDNS"                  "no"
            ;;
        moderate)
            set_config_value "PermitRootLogin"         "prohibit-password"
            set_config_value "PasswordAuthentication"  "no"
            set_config_value "PubkeyAuthentication"    "yes"
            set_config_value "PermitEmptyPasswords"    "no"
            set_config_value "MaxAuthTries"            "3"
            set_config_value "MaxSessions"             "5"
            set_config_value "X11Forwarding"           "no"
            set_config_value "AllowTcpForwarding"      "no"
            set_config_value "ClientAliveInterval"     "180"
            set_config_value "ClientAliveCountMax"     "2"
            set_config_value "LoginGraceTime"          "30"
            set_config_value "UseDNS"                  "no"
            set_config_value "Banner"                  "/etc/ssh/banner"
            # 创建 banner
            cat > /etc/ssh/banner <<'EOF'
*********************************************************************
*  Authorized access only. All activity is logged and monitored.    *
*********************************************************************
EOF
            ;;
        hardened)
            set_config_value "PermitRootLogin"           "no"
            set_config_value "PasswordAuthentication"    "no"
            set_config_value "PubkeyAuthentication"      "yes"
            set_config_value "PermitEmptyPasswords"      "no"
            set_config_value "MaxAuthTries"              "2"
            set_config_value "MaxSessions"               "3"
            set_config_value "X11Forwarding"             "no"
            set_config_value "AllowTcpForwarding"        "no"
            set_config_value "AllowAgentForwarding"      "no"
            set_config_value "AllowStreamLocalForwarding" "no"
            set_config_value "ClientAliveInterval"       "120"
            set_config_value "ClientAliveCountMax"       "2"
            set_config_value "LoginGraceTime"            "20"
            set_config_value "UseDNS"                    "no"
            set_config_value "PermitUserEnvironment"     "no"
            set_config_value "DisableForwarding"         "yes"
            set_config_value "GatewayPorts"              "no"
            set_config_value "PermitTunnel"              "no"
            set_config_value "Banner"                    "/etc/ssh/banner"
            cat > /etc/ssh/banner <<'EOF'
*********************************************************************
*  UNAUTHORIZED ACCESS IS PROHIBITED. YOU WILL BE PROSECUTED.       *
*  All connections are monitored and recorded.                      *
*********************************************************************
EOF
            ;;
        *)
            die "未知方案: $preset"
            ;;
    esac

    if validate_config; then
        restart_sshd
        log_info "方案 '${preset}' 已应用"
    else
        log_error "配置验证失败，回滚..."
        restore_backup "$ts"
        restart_sshd
        return 1
    fi
}

#===============================================================================
# 显示当前配置
#===============================================================================

show_status() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║               SSH 服务状态 & 配置摘要                       ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 服务状态
    local svc; svc=$(sshd_service_name)
    local status; status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    case "$status" in
        active)  echo -e "  服务状态:        ${GREEN}● 运行中${NC} (${svc})" ;;
        *)       echo -e "  服务状态:        ${RED}● ${status}${NC} (${svc})" ;;
    esac

    # 防火墙
    local fw; fw=$(detect_firewall)
    echo -e "  防火墙:          ${YELLOW}${fw}${NC}"

    # 监听端口
    local lports; lports=$(get_listening_ports | tr '\n' ' ')
    echo -e "  监听端口(实际):  ${BOLD}${lports:-无}${NC}"

    # 配置端口
    local cports; cports=$(get_current_ports | tr '\n' ' ')
    echo -e "  配置端口:        ${BOLD}${cports}${NC}"

    echo ""
    hr

    declare -A labels=(
        [PermitRootLogin]="Root登录"
        [PasswordAuthentication]="密码认证"
        [PubkeyAuthentication]="公钥认证"
        [PermitEmptyPasswords]="空密码"
        [MaxAuthTries]="最大尝试"
        [MaxSessions]="最大会话"
        [ClientAliveInterval]="心跳间隔(s)"
        [ClientAliveCountMax]="心跳次数"
        [X11Forwarding]="X11转发"
        [AllowTcpForwarding]="TCP转发"
        [LoginGraceTime]="登录宽限(s)"
        [UseDNS]="DNS反查"
        [AllowUsers]="允许用户"
        [AllowGroups]="允许组"
        [Banner]="登录横幅"
    )

    declare -A defaults=(
        [PermitRootLogin]="prohibit-password"
        [PasswordAuthentication]="yes"
        [PubkeyAuthentication]="yes"
        [PermitEmptyPasswords]="no"
        [MaxAuthTries]="6"
        [MaxSessions]="10"
        [ClientAliveInterval]="0"
        [ClientAliveCountMax]="3"
        [X11Forwarding]="no"
        [AllowTcpForwarding]="yes"
        [LoginGraceTime]="120"
        [UseDNS]="no"
        [AllowUsers]=""
        [AllowGroups]=""
        [Banner]="none"
    )

    local ordered_keys=(
        PermitRootLogin PasswordAuthentication PubkeyAuthentication
        PermitEmptyPasswords MaxAuthTries MaxSessions
        ClientAliveInterval ClientAliveCountMax X11Forwarding
        AllowTcpForwarding LoginGraceTime UseDNS
        AllowUsers AllowGroups Banner
    )

    printf "  %-22s %-20s %s\n" "配置项" "当前值" "默认值"
    hr

    for key in "${ordered_keys[@]}"; do
        local val; val=$(get_effective_value "$key" "${defaults[$key]:-}")
        local dfl="${defaults[$key]:-}"
        local label="${labels[$key]:-$key}"
        if [[ "$val" != "$dfl" && -n "$dfl" ]]; then
            printf "  %-20s ${YELLOW}%-20s${NC} %-20s\n" "$label" "${val:-(未设置)}" "(${dfl:-N/A})"
        else
            printf "  %-20s %-20s %-20s\n" "$label" "${val:-(未设置)}" "(${dfl:-N/A})"
        fi
    done

    echo ""
}

#===============================================================================
# 交互式菜单
#===============================================================================

interactive_menu() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}"
        echo "  ┌──────────────────────────────────────────────────────────┐"
        echo "  │              SSH Manager v${VERSION}                          │"
        echo "  │              SSH 配置管理工具                            │"
        echo "  └──────────────────────────────────────────────────────────┘"
        echo -e "${NC}"
        echo -e "  ${BOLD}1)${NC}  查看当前配置状态"
        echo -e "  ${BOLD}2)${NC}  修改 SSH 端口"
        echo -e "  ${BOLD}3)${NC}  修改单项配置"
        echo -e "  ${BOLD}4)${NC}  应用推荐方案"
        echo -e "  ${BOLD}5)${NC}  备份/恢复配置"
        echo -e "  ${BOLD}6)${NC}  查看备份列表"
        echo -e "  ${BOLD}7)${NC}  重启/重载 SSH 服务"
        echo -e "  ${BOLD}8)${NC}  防火墙状态"
        echo -e "  ${BOLD}0)${NC}  退出"
        echo ""
        hr
        read -rp "  请选择 [0-8]: " choice
        echo ""

        case "$choice" in
            1) menu_status ;;
            2) menu_change_port ;;
            3) menu_single_config ;;
            4) menu_preset ;;
            5) menu_backup_restore ;;
            6) menu_list_backups ;;
            7) menu_service ;;
            8) menu_firewall ;;
            0) echo -e "  ${GREEN}再见！${NC}"; exit 0 ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

#---------- 子菜单：查看状态 ----------
menu_status() {
    show_status
    echo ""
    read -rp "  按 Enter 返回..." _
}

#---------- 子菜单：修改端口 ----------
menu_change_port() {
    clear
    echo -e "${CYAN}${BOLD}  ── 修改 SSH 端口 ──${NC}"
    echo ""

    local cports; cports=$(get_current_ports | tr '\n' ' ')
    echo -e "  当前端口: ${BOLD}${cports}${NC}"
    echo ""
    echo -e "  ${DIM}推荐非标准端口范围: 10000-65535${NC}"
    echo -e "  ${DIM}例如: 22022 / 33022 / 54321${NC}"
    echo ""

    read -rp "  输入新端口号 (q 取消): " new_port
    [[ "$new_port" == "q" || -z "$new_port" ]] && return

    echo ""
    read -rp "  是否跳过外部可达性检测？[y/N] " skip_ext
    local skip_check="false"
    [[ "$skip_ext" =~ ^[yY] ]] && skip_check="true"

    echo ""
    change_port "$new_port" "false" "$skip_check"
    echo ""
    read -rp "  按 Enter 返回..." _
}

#---------- 子菜单：单项配置 ----------
menu_single_config() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}  ── 修改单项配置 ──${NC}"
        echo ""

        # 动态显示当前值
        local prl; prl=$(get_effective_value "PermitRootLogin"       "prohibit-password")
        local pa;  pa=$(get_effective_value  "PasswordAuthentication" "yes")
        local pub; pub=$(get_effective_value "PubkeyAuthentication"   "yes")
        local mat; mat=$(get_effective_value "MaxAuthTries"           "6")
        local mas; mas=$(get_effective_value "MaxSessions"            "10")
        local cai; cai=$(get_effective_value "ClientAliveInterval"    "0")
        local cac; cac=$(get_effective_value "ClientAliveCountMax"    "3")
        local x11; x11=$(get_effective_value "X11Forwarding"         "no")
        local tcp; tcp=$(get_effective_value "AllowTcpForwarding"    "yes")
        local lgt; lgt=$(get_effective_value "LoginGraceTime"        "120")
        local dns; dns=$(get_effective_value "UseDNS"                "no")

        printf "  %-4s %-28s %s\n" "编号" "配置项" "当前值"
        hr
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "1)"  "Root 登录方式"   "$prl"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "2)"  "密码认证"         "$pa"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "3)"  "公钥认证"         "$pub"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "4)"  "最大认证尝试次数" "$mat"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "5)"  "最大并发会话数"   "$mas"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "6)"  "心跳间隔(秒)"     "$cai"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "7)"  "心跳失败次数"     "$cac"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "8)"  "X11 转发"         "$x11"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "9)"  "TCP 转发"         "$tcp"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "10)" "登录宽限时间(秒)" "$lgt"
        printf "  ${BOLD}%-3s${NC} %-28s ${YELLOW}%s${NC}\n" "11)" "DNS 反向查询"     "$dns"
        printf "  ${BOLD}%-3s${NC} %-28s\n"                  "12)" "AllowUsers 白名单"
        printf "  ${BOLD}%-3s${NC} %-28s\n"                  "13)" "自定义键值对"
        echo ""
        echo -e "  ${BOLD}0)${NC}  返回"
        echo ""
        read -rp "  请选择 [0-13]: " opt
        echo ""

        case "$opt" in
            0) return ;;
            1)
                echo "  选项:"
                echo "    yes               — 允许 root 用密码登录（危险）"
                echo "    no                — 完全禁止 root 登录（最安全）"
                echo "    prohibit-password — root 只能用密钥登录（推荐）"
                echo "    forced-commands-only — 只允许 root 执行指定命令"
                echo ""
                read -rp "  新值: " val
                [[ -n "$val" ]] && set_config_item "PermitRootLogin" "$val" "Root 登录策略"
                ;;
            2)
                echo "  yes → 允许密码登录 | no → 仅密钥登录（推荐配合公钥使用）"
                echo ""
                read -rp "  新值 [yes/no]: " val
                [[ "$val" == "yes" || "$val" == "no" ]] && \
                    set_config_item "PasswordAuthentication" "$val" "密码认证" || \
                    log_warn "无效值，仅接受 yes/no"
                ;;
            3)
                echo "  yes → 允许公钥登录（强烈推荐） | no → 禁用"
                read -rp "  新值 [yes/no]: " val
                [[ "$val" == "yes" || "$val" == "no" ]] && \
                    set_config_item "PubkeyAuthentication" "$val" "公钥认证" || \
                    log_warn "无效值"
                ;;
            4)
                echo "  建议值 3~6，越小越安全（默认6）"
                read -rp "  新值 [1-10]: " val
                [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 10 )) && \
                    set_config_item "MaxAuthTries" "$val" "最大认证次数" || \
                    log_warn "无效值（1-10）"
                ;;
            5)
                echo "  每个连接最多并行的会话数（默认10）"
                read -rp "  新值 [1-50]: " val
                [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 50 )) && \
                    set_config_item "MaxSessions" "$val" "最大会话数" || \
                    log_warn "无效值（1-50）"
                ;;
            6)
                echo "  客户端无响应多少秒后发送心跳（0=不发送，建议120-300）"
                read -rp "  新值 (秒, 0-3600): " val
                [[ "$val" =~ ^[0-9]+$ ]] && (( val <= 3600 )) && \
                    set_config_item "ClientAliveInterval" "$val" "心跳间隔" || \
                    log_warn "无效值"
                ;;
            7)
                echo "  心跳无响应多少次后断开（默认3，建议2-3）"
                read -rp "  新值 [1-10]: " val
                [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 10 )) && \
                    set_config_item "ClientAliveCountMax" "$val" "心跳次数" || \
                    log_warn "无效值"
                ;;
            8)
                echo "  是否允许 X11 图形界面转发（一般关闭）"
                read -rp "  新值 [yes/no]: " val
                [[ "$val" == "yes" || "$val" == "no" ]] && \
                    set_config_item "X11Forwarding" "$val" "X11转发" || \
                    log_warn "无效值"
                ;;
            9)
                echo "  是否允许 TCP 隧道转发（安全加固时建议关闭）"
                read -rp "  新值 [yes/no/local/remote]: " val
                [[ -n "$val" ]] && set_config_item "AllowTcpForwarding" "$val" "TCP转发"
                ;;
            10)
                echo "  登录认证宽限时间，超时自动断开（默认120秒，建议30-60）"
                read -rp "  新值 (秒, 10-300): " val
                [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 10 && val <= 300 )) && \
                    set_config_item "LoginGraceTime" "$val" "登录宽限" || \
                    log_warn "无效值（10-300）"
                ;;
            11)
                echo "  DNS 反查会拖慢登录速度，建议关闭（no）"
                read -rp "  新值 [yes/no]: " val
                [[ "$val" == "yes" || "$val" == "no" ]] && \
                    set_config_item "UseDNS" "$val" "DNS反查" || \
                    log_warn "无效值"
                ;;
            12)
                local current_au; current_au=$(get_effective_value "AllowUsers" "")
                echo "  当前: ${current_au:-(未设置，即所有用户)}"
                echo "  输入允许登录的用户名（空格分隔），留空则删除限制"
                echo "  示例: ubuntu deploy admin"
                echo ""
                read -rp "  用户列表: " val
                if [[ -z "$val" ]]; then
                    clear_key_from_confd "AllowUsers"
                    sed -i "/^\s*AllowUsers\s/Id" "$SSHD_CONFIG"
                    validate_config && reload_sshd && log_info "已移除 AllowUsers 限制"
                else
                    set_config_item "AllowUsers" "$val" "允许用户"
                fi
                ;;
            13)
                echo "  自定义设置任意 sshd_config 键值对"
                read -rp "  键名 (如 Compression): " ckey
                read -rp "  值  (如 yes): " cval
                [[ -n "$ckey" && -n "$cval" ]] && \
                    set_config_item "$ckey" "$cval" "自定义 $ckey" || \
                    log_warn "键名和值不能为空"
                ;;
            *)
                log_warn "无效选项"
                ;;
        esac

        echo ""
        read -rp "  按 Enter 继续..." _
    done
}

#---------- 子菜单：推荐方案 ----------
menu_preset() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}  ── 推荐安全方案 ──${NC}"
        echo ""

        # ---- 方案1 ----
        echo -e "  ${BOLD}${GREEN}1) 基础方案 (basic)${NC}  ${DIM}— 适合开发/测试环境${NC}"
        echo -e "  ${DIM}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${DIM}│${NC}  • Root 登录: prohibit-password（仅密钥）              ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 密码认证: ${GREEN}开启${NC}（兼顾便利性）                     ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • MaxAuthTries: 6 | MaxSessions: 10                 ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 心跳: 300s × 3次 | X11转发: 关                    ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • DNS反查: 关                                        ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${YELLOW}适用: 内网/开发机器，需要密码登录的场景${NC}             ${DIM}│${NC}"
        echo -e "  ${DIM}└────────────────────────────────────────────────────────┘${NC}"
        echo ""

        # ---- 方案2 ----
        echo -e "  ${BOLD}${YELLOW}2) 均衡方案 (moderate)${NC}  ${DIM}— 适合生产环境（推荐）${NC}"
        echo -e "  ${DIM}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${DIM}│${NC}  • Root 登录: prohibit-password（仅密钥）              ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 密码认证: ${RED}关闭${NC}（仅公钥认证）                      ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • MaxAuthTries: 3 | MaxSessions: 5                  ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 心跳: 180s × 2次 | X11/TCP转发: 关                ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 登录宽限: 30s | 登录横幅: 启用                     ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${YELLOW}适用: 公网服务器、生产环境，已配置 SSH 密钥${NC}       ${DIM}│${NC}"
        echo -e "  ${DIM}└────────────────────────────────────────────────────────┘${NC}"
        echo ""

        # ---- 方案3 ----
        echo -e "  ${BOLD}${RED}3) 加固方案 (hardened)${NC}  ${DIM}— 适合高安全需求环境${NC}"
        echo -e "  ${DIM}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${DIM}│${NC}  • Root 登录: ${RED}完全禁止${NC}                               ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 密码/X11/TCP/Agent/Tunnel 转发: ${RED}全部关闭${NC}          ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • MaxAuthTries: 2 | MaxSessions: 3                  ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 心跳: 120s × 2次 | 登录宽限: 20s                  ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • DisableForwarding: yes（禁止所有转发）              ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  • 登录横幅: 启用警告信息                              ${DIM}│${NC}"
        echo -e "  ${DIM}│${NC}  ${RED}⚠ 要求: 必须已配置 SSH 公钥，否则将锁定！${NC}          ${DIM}│${NC}"
        echo -e "  ${DIM}└────────────────────────────────────────────────────────┘${NC}"
        echo ""

        echo -e "  ${BOLD}0)${NC}  返回"
        echo ""
        read -rp "  请选择方案 [0-3]: " choice
        echo ""

        case "$choice" in
            0) return ;;
            1|2|3)
                local preset_name
                case "$choice" in
                    1) preset_name="basic" ;;
                    2) preset_name="moderate" ;;
                    3) preset_name="hardened" ;;
                esac

                if [[ "$preset_name" == "hardened" ]]; then
                    echo -e "  ${RED}${BOLD}⚠ 警告：加固方案将禁止所有密码登录和 Root 登录！${NC}"
                    echo -e "  ${RED}请确保您已在 ~/.ssh/authorized_keys 中配置了公钥！${NC}"
                    echo ""
                    read -rp "  确认已配置 SSH 公钥，继续？[yes/N] " confirm
                    [[ "$confirm" == "yes" ]] || { log_info "已取消"; sleep 1; continue; }
                fi

                echo ""
                log_step "正在应用方案: ${preset_name}..."
                apply_preset "$preset_name"
                echo ""
                read -rp "  按 Enter 返回..." _
                ;;
            *)
                log_warn "无效选项"
                sleep 1
                ;;
        esac
    done
}

#---------- 子菜单：备份恢复 ----------
menu_backup_restore() {
    clear
    echo -e "${CYAN}${BOLD}  ── 备份 / 恢复 ──${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  立即备份当前配置"
    echo -e "  ${BOLD}2)${NC}  恢复最新备份"
    echo -e "  ${BOLD}3)${NC}  恢复指定备份"
    echo -e "  ${BOLD}0)${NC}  返回"
    echo ""
    read -rp "  请选择 [0-3]: " opt
    echo ""

    case "$opt" in
        1)
            backup_config
            ;;
        2)
            log_step "恢复最新备份..."
            restore_backup ""
            validate_config && restart_sshd || log_error "恢复后配置验证失败"
            ;;
        3)
            menu_list_backups
            echo ""
            read -rp "  输入时间戳 (如 20240101_120000): " ts
            [[ -n "$ts" ]] && restore_backup "$ts" && \
                validate_config && restart_sshd || log_error "恢复失败"
            ;;
        0) return ;;
        *) log_warn "无效选项" ;;
    esac

    echo ""
    read -rp "  按 Enter 返回..." _
}

#---------- 子菜单：备份列表 ----------
menu_list_backups() {
    echo ""
    echo -e "${CYAN}${BOLD}  ── 备份列表 ──${NC}"
    echo ""

    local count=0
    if [[ -d "$BACKUP_DIR" ]]; then
        while IFS= read -r f; do
            local ts; ts=$(basename "$f" | sed 's/sshd_config\.//')
            local sz; sz=$(du -h "$f" 2>/dev/null | cut -f1)
            local dt; dt=$(date -d "${ts:0:8} ${ts:9:2}:${ts:11:2}:${ts:13:2}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ts")
            printf "  ${BOLD}%-25s${NC} ${DIM}%s  %s${NC}\n" "$ts" "$dt" "$sz"
            (( count++ ))
        done < <(ls -t "${BACKUP_DIR}"/sshd_config.* 2>/dev/null)
    fi

    if (( count == 0 )); then
        echo -e "  ${DIM}暂无备份${NC}"
    fi
    echo ""
    [[ "${1:-}" == "pause" ]] && read -rp "  按 Enter 返回..." _
}

#---------- 子菜单：服务管理 ----------
menu_service() {
    clear
    echo -e "${CYAN}${BOLD}  ── SSH 服务管理 ──${NC}"
    echo ""
    local svc; svc=$(sshd_service_name)
    local status; status=$(systemctl is-active "$svc" 2>/dev/null)
    echo -e "  服务: ${BOLD}${svc}${NC}   状态: $(
        [[ "$status" == "active" ]] && echo "${GREEN}● 运行中${NC}" || echo "${RED}● ${status}${NC}"
    )"
    echo ""
    echo -e "  ${BOLD}1)${NC}  reload  (重新加载配置，不中断连接)"
    echo -e "  ${BOLD}2)${NC}  restart (完全重启，会短暂中断)"
    echo -e "  ${BOLD}3)${NC}  stop"
    echo -e "  ${BOLD}4)${NC}  start"
    echo -e "  ${BOLD}5)${NC}  查看最近日志"
    echo -e "  ${BOLD}0)${NC}  返回"
    echo ""
    read -rp "  请选择 [0-5]: " opt
    echo ""

    case "$opt" in
        1) reload_sshd ;;
        2) restart_sshd ;;
        3) systemctl stop  "$svc" && log_info "已停止 $svc" ;;
        4) systemctl start "$svc" && log_info "已启动 $svc" ;;
        5) journalctl -u "$svc" -n 30 --no-pager ;;
        0) return ;;
        *) log_warn "无效选项" ;;
    esac

    echo ""
    read -rp "  按 Enter 返回..." _
}

#---------- 子菜单：防火墙状态 ----------
menu_firewall() {
    clear
    echo -e "${CYAN}${BOLD}  ── 防火墙状态 ──${NC}"
    echo ""

    local fw; fw=$(detect_firewall)
    echo -e "  检测到防火墙: ${BOLD}${YELLOW}${fw}${NC}"
    echo ""

    case "$fw" in
        ufw)
            ufw status verbose 2>/dev/null || true
            ;;
        firewalld)
            firewall-cmd --list-all 2>/dev/null || true
            ;;
        iptables)
            echo -e "  ${DIM}INPUT 规则:${NC}"
            iptables -L INPUT -n --line-numbers 2>/dev/null | head -30 || true
            ;;
        nftables)
            nft list ruleset 2>/dev/null | head -40 || true
            ;;
        none)
            echo -e "  ${YELLOW}未检测到活动防火墙${NC}"
            echo ""
            echo -e "  ${DIM}说明：这不一定意味着没有防火墙保护。${NC}"
            echo -e "  ${DIM}云服务商（AWS/阿里云/腾讯云等）通常在${NC}"
            echo -e "  ${DIM}服务器外层提供安全组/防火墙，在系统内${NC}"
            echo -e "  ${DIM}无法直接查看和修改。${NC}"
            ;;
    esac

    echo ""

    echo -e "  ${BOLD}手动放行端口:${NC}"
    echo ""
    read -rp "  输入要放行的端口 (留空跳过): " fw_port
    if [[ -n "$fw_port" ]] && [[ "$fw_port" =~ ^[0-9]+$ ]]; then
        fw_allow "$fw_port"
    fi

    echo ""
    read -rp "  按 Enter 返回..." _
}

#===============================================================================
# 命令行模式
#===============================================================================

usage() {
    cat <<EOF

${BOLD}用法:${NC}
  $SCRIPT_NAME [命令] [选项]

${BOLD}命令:${NC}
  ${GREEN}port${NC} <端口>          修改 SSH 端口
  ${GREEN}status${NC}               显示当前配置状态
  ${GREEN}set${NC} <键> <值>         设置单项配置
  ${GREEN}preset${NC} <方案>         应用推荐方案 (basic/moderate/hardened)
  ${GREEN}backup${NC}               备份当前配置
  ${GREEN}restore${NC} [时间戳]      恢复配置备份
  ${GREEN}reload${NC}               重新加载 sshd
  ${GREEN}restart${NC}              重启 sshd
  ${GREEN}fw-allow${NC} <端口>       手动放行防火墙端口
  ${GREEN}fw-status${NC}            显示防火墙状态
  ${GREEN}interactive${NC}          启动交互式菜单（默认）
  ${GREEN}help${NC}                 显示此帮助

${BOLD}选项:${NC}
  ${CYAN}--force${NC}             跳过确认提示（批量执行用）
  ${CYAN}--skip-check${NC}        跳过外部端口可达检测
  ${CYAN}--no-reload${NC}         修改配置后不自动 reload/restart

${BOLD}示例:${NC}
  # 修改端口（自动检测可达性）
  $SCRIPT_NAME port 22022

  # 批量执行：强制修改端口，跳过外部检测
  $SCRIPT_NAME port 22022 --force --skip-check

  # 应用加固方案
  $SCRIPT_NAME preset hardened --force

  # 设置单项配置
  $SCRIPT_NAME set PasswordAuthentication no
  $SCRIPT_NAME set MaxAuthTries 3

  # 查看状态
  $SCRIPT_NAME status

  # 备份配置
  $SCRIPT_NAME backup

  # 恢复最新备份
  $SCRIPT_NAME restore

  # 放行防火墙端口
  $SCRIPT_NAME fw-allow 22022

${BOLD}批量执行示例 (通过 SSH 多台服务器):${NC}
  for host in server1 server2 server3; do
    ssh root@\$host "bash /path/to/$SCRIPT_NAME port 22022 --force --skip-check"
  done

  # 配合 pssh 并行执行
  pssh -h hosts.txt -l root "bash /path/to/$SCRIPT_NAME preset moderate --force"

EOF
}

#===============================================================================
# 主入口
#===============================================================================

main() {
    check_root
    check_os
    ensure_deps

    # 无参数时进入交互模式
    if [[ $# -eq 0 ]]; then
        interactive_menu
        exit 0
    fi

    local cmd="${1:-}"
    shift || true

    # 解析全局选项
    local opt_force="false"
    local opt_skip_check="false"
    local opt_no_reload="false"
    local positional=()

    for arg in "$@"; do
        case "$arg" in
            --force)       opt_force="true" ;;
            --skip-check)  opt_skip_check="true" ;;
            --no-reload)   opt_no_reload="true" ;;
            -*)            log_warn "未知选项: $arg" ;;
            *)             positional+=("$arg") ;;
        esac
    done

    case "$cmd" in
        port)
            [[ ${#positional[@]} -ge 1 ]] || die "用法: $SCRIPT_NAME port <端口号>"
            change_port "${positional[0]}" "$opt_force" "$opt_skip_check"
            ;;

        status)
            show_status
            ;;

        set)
            [[ ${#positional[@]} -ge 2 ]] || die "用法: $SCRIPT_NAME set <键> <值>"
            backup_config >/dev/null
            set_config_value "${positional[0]}" "${positional[1]}"
            if validate_config; then
                [[ "$opt_no_reload" == "true" ]] || reload_sshd
                log_info "${positional[0]} → ${positional[1]}"
            else
                restore_backup
                die "配置无效，已回滚"
            fi
            ;;

        preset)
            [[ ${#positional[@]} -ge 1 ]] || die "用法: $SCRIPT_NAME preset <basic|moderate|hardened>"
            local pname="${positional[0]}"
            [[ "$pname" == "basic" || "$pname" == "moderate" || "$pname" == "hardened" ]] || \
                die "未知方案: $pname，可选: basic / moderate / hardened"

            if [[ "$pname" == "hardened" && "$opt_force" != "true" ]]; then
                echo -e "${RED}${BOLD}⚠ 警告：加固方案将禁用密码登录和 Root 登录！${NC}"
                echo -e "${RED}请确保已配置 SSH 公钥，否则将无法登录！${NC}"
                read -rp "确认继续？[yes/N] " confirm
                [[ "$confirm" == "yes" ]] || { log_info "已取消"; exit 0; }
            fi

            apply_preset "$pname"
            ;;

        backup)
            backup_config
            ;;

        restore)
            local ts="${positional[0]:-}"
            restore_backup "$ts"
            if validate_config; then
                [[ "$opt_no_reload" == "true" ]] || restart_sshd
            else
                die "恢复后配置验证失败，请检查"
            fi
            ;;

        reload)
            reload_sshd
            ;;

        restart)
            restart_sshd
            ;;

        fw-allow)
            [[ ${#positional[@]} -ge 1 ]] || die "用法: $SCRIPT_NAME fw-allow <端口>"
            fw_allow "${positional[0]}"
            ;;

        fw-status)
            local fw; fw=$(detect_firewall)
            echo -e "防火墙类型: ${BOLD}${YELLOW}${fw}${NC}"
            echo ""
            case "$fw" in
                ufw)       ufw status verbose 2>/dev/null ;;
                firewalld) firewall-cmd --list-all 2>/dev/null ;;
                iptables)  iptables -L INPUT -n --line-numbers 2>/dev/null ;;
                nftables)  nft list ruleset 2>/dev/null ;;
                none)
                    echo -e "${YELLOW}未检测到活动防火墙${NC}"
                    echo -e "${DIM}注意：云服务商可能在外层提供安全组，系统内无法查看${NC}"
                    ;;
            esac
            ;;

        interactive)
            interactive_menu
            ;;

        help|--help|-h)
            usage
            ;;

        version|--version|-v)
            echo "SSH Manager v${VERSION}"
            ;;

        *)
            log_error "未知命令: ${cmd}"
            echo ""
            usage
            exit 1
            ;;
    esac
}

# ---- 入口 ----
main "$@"