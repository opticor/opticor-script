#!/bin/bash

# ==================== Colors ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== Defaults ====================
DEFAULT_PORT=443
DEFAULT_DEST="github.com:443"
DEFAULT_SERVER_NAMES="github.com,www.github.com"
DEFAULT_LOG_LEVEL="warning"
INSTALL_DIR="/usr/local/bin"

SERVICE_NAME="vapp"
BINARY_NAME="vapp"
CONFIG_DIR="/etc/vapp"
LOG_DIR="/var/log/vapp"

# ==================== Variables ====================
PORT=""
LOG_LEVEL=$DEFAULT_LOG_LEVEL
DOMAIN=""
UUID=""
DEST=""
SERVER_NAMES=""
SHORT_ID=""
PRIVATE_KEY=""
PUBLIC_KEY=""

# ==================== Helpers ====================
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step()  { echo -e "\n${BLUE}[STEP]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║      VApp (VLESS + Reality) Installer v1.0      ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    [[ $EUID -ne 0 ]] && log_error "Must be run as root"
    log_info "Root check passed."
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        log_info "OS: ${NAME:-Unknown} ${VERSION_ID:-}"
    fi
}

# ==================== Args ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -port|--port)
                PORT="$2"; shift 2 ;;
            -uuid|--uuid)
                UUID="$2"; shift 2 ;;
            -dest|--dest)
                DEST="$2"; shift 2 ;;
            -server-names|--server-names)
                SERVER_NAMES="$2"; shift 2 ;;
            -short-id|--short-id)
                SHORT_ID="$2"; shift 2 ;;
            -log|--log)
                LOG_LEVEL="$2"; shift 2 ;;
            -h|--help)  print_help; exit 0 ;;
            uninstall)  do_uninstall; exit 0 ;;
            *)          log_warn "Unknown argument: $1"; shift ;;
        esac
    done
}

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -port          <port>          External port (default: $DEFAULT_PORT)
  -uuid          <uuid>          VLESS UUID (default: random)
  -dest          <host:port>     Reality dest (default: $DEFAULT_DEST)
  -server-names  <names>         Reality serverNames, comma-separated
                                 (default: $DEFAULT_SERVER_NAMES)
  -short-id      <hex>           Reality shortId (default: random 8 bytes hex)
  -log           <level>         Log level: debug|info|warning|error (default: $DEFAULT_LOG_LEVEL)
  uninstall                      Uninstall VApp
EOF
}

# ==================== Interactive Input ====================
generate_uuid() {
    if command -v python3 &>/dev/null; then
        python3 -c "import uuid; print(uuid.uuid4())"
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_short_id() {
    openssl rand -hex 8
}

interactive_input() {
    echo ""
    log_step "Interactive Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Port
    if [[ -z "$PORT" ]]; then
        read -rp "$(echo -e "${YELLOW}External port [Enter=${DEFAULT_PORT}]:${NC} ")" input_port
        if [[ -z "$input_port" ]]; then
            PORT=$DEFAULT_PORT
        elif [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            PORT=$input_port
        else
            log_warn "Invalid port, using $DEFAULT_PORT"
            PORT=$DEFAULT_PORT
        fi
    fi
    log_info "Port: $PORT"

    # UUID
    if [[ -z "$UUID" ]]; then
        local gen_uuid
        gen_uuid=$(generate_uuid)
        read -rp "$(echo -e "${YELLOW}UUID [Enter=random]:${NC} ")" input_uuid
        UUID="${input_uuid:-$gen_uuid}"
    fi
    log_info "UUID: $UUID"

    # Reality Dest
    if [[ -z "$DEST" ]]; then
        read -rp "$(echo -e "${YELLOW}Reality dest [Enter=${DEFAULT_DEST}]:${NC} ")" input_dest
        DEST="${input_dest:-$DEFAULT_DEST}"
    fi
    log_info "Reality dest: $DEST"

    # Server Names
    if [[ -z "$SERVER_NAMES" ]]; then
        read -rp "$(echo -e "${YELLOW}Reality serverNames (comma-separated) [Enter=${DEFAULT_SERVER_NAMES}]:${NC} ")" input_sn
        SERVER_NAMES="${input_sn:-$DEFAULT_SERVER_NAMES}"
    fi
    log_info "Server names: $SERVER_NAMES"

    # Short ID
    if [[ -z "$SHORT_ID" ]]; then
        local gen_sid
        gen_sid=$(generate_short_id)
        read -rp "$(echo -e "${YELLOW}Reality shortId (hex) [Enter=random]:${NC} ")" input_sid
        SHORT_ID="${input_sid:-$gen_sid}"
    fi
    log_info "Short ID: $SHORT_ID"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

confirm_config() {
    echo ""
    log_step "Configuration Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Mode            : ${GREEN}VApp (VLESS + Reality)${NC}"
    echo -e "  Port            : ${GREEN}$PORT${NC}"
    echo -e "  UUID            : ${GREEN}$UUID${NC}"
    echo -e "  Reality Dest    : ${GREEN}$DEST${NC}"
    echo -e "  Server Names    : ${GREEN}$SERVER_NAMES${NC}"
    echo -e "  Short ID        : ${GREEN}$SHORT_ID${NC}"
    echo -e "  Log Level       : ${GREEN}$LOG_LEVEL${NC}"
    echo -e "  Service Name    : ${GREEN}$SERVICE_NAME${NC}"
    echo -e "  Config Dir      : ${GREEN}$CONFIG_DIR${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -rp "$(echo -e "${YELLOW}Proceed? (Y/n):${NC} ")" confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "Cancelled."; exit 0; }
}

# ==================== Dependencies ====================
install_deps() {
    log_step "Installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl wget unzip openssl python3
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip openssl python3
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl wget unzip openssl python3
    else
        log_error "Unsupported package manager"
    fi
    log_info "Dependencies ready."
}

# ==================== Download ====================
download_xray() {
    log_step "Downloading xray binary..."

    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  ARCH_NAME="64" ;;
        aarch64) ARCH_NAME="arm64-v8a" ;;
        armv7l)  ARCH_NAME="arm32-v7a" ;;
        *)       log_error "Unsupported arch: $arch" ;;
    esac

    local latest
    latest=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
             | grep '"tag_name"' | cut -d'"' -f4)
    [[ -z "$latest" ]] && log_error "Failed to fetch latest version."
    log_info "Latest xray: $latest"

    local url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${ARCH_NAME}.zip"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Downloading: $url"
    curl -fL --progress-bar -o "$tmp_dir/xray.zip" "$url" \
        || log_error "Download failed."

    unzip -q "$tmp_dir/xray.zip" -d "$tmp_dir" \
        || log_error "Unzip failed."

    [[ ! -f "$tmp_dir/xray" ]] && log_error "Binary not found in zip."

    mv "$tmp_dir/xray" "$INSTALL_DIR/$BINARY_NAME"
    chmod +x "$INSTALL_DIR/$BINARY_NAME"
    rm -rf "$tmp_dir"
    log_info "Binary installed: $INSTALL_DIR/$BINARY_NAME"

    # 下载 geo 数据文件到 CONFIG_DIR
    mkdir -p "$CONFIG_DIR"
    log_info "Downloading geoip.dat / geosite.dat..."
    curl -fsSL --progress-bar \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
        -o "$CONFIG_DIR/geoip.dat" || log_warn "geoip.dat download failed."
    curl -fsSL --progress-bar \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
        -o "$CONFIG_DIR/geosite.dat" || log_warn "geosite.dat download failed."
    log_info "Geo files: $CONFIG_DIR/"
}

# ==================== Patch ====================
patch_binary() {
    log_step "Patching binary strings (VApp mode)..."
    local binary="$INSTALL_DIR/$BINARY_NAME"
    cp "$binary" "${binary}.orig"

    python3 - "$binary" <<'PYEOF'
import sys

filepath = sys.argv[1]

# 必须等长替换
replacements = [
    (b'Xray-core', b'VApp-core'),
    (b'xray-core', b'vapp-core'),
    (b'XTLS/Xray', b'VAPP/Vapp'),
    (b'xtls/xray', b'vapp/vapp'),
    (b'XTLS Labs', b'VAPP Labs'),
]

for old, new in replacements:
    assert len(old) == len(new), f"Length mismatch: {old!r} vs {new!r}"

try:
    with open(filepath, 'rb') as f:
        data = f.read()

    original_size = len(data)
    total = 0
    for old, new in replacements:
        count = data.count(old)
        data = data.replace(old, new)
        print(f"  [{count:>5}x] {old.decode(errors='replace')!r:20s} -> {new.decode(errors='replace')!r}")
        total += count

    assert len(data) == original_size, f"Size changed: {original_size} -> {len(data)}"

    with open(filepath, 'wb') as f:
        f.write(data)

    print(f"  Total: {total} replacements. Size unchanged: {original_size:,} bytes.")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_warn "Patch failed, restoring original."
        mv "${binary}.orig" "$binary"
    else
        rm -f "${binary}.orig"
        chmod +x "$binary"
        log_info "Binary patch complete."
    fi
}

# ==================== Log Filter Wrapper ====================
create_log_filter_wrapper() {
    log_step "Creating log filter wrapper..."

    cat > "$INSTALL_DIR/vapp-run" <<'WRAPPER'
#!/usr/bin/env python3
"""VApp runtime wrapper - filters sensitive strings from log output"""
import sys
import subprocess
import re

FILTERS = [
    (re.compile(rb'[Xx]ray',      re.IGNORECASE), b'vapp'),
    (re.compile(rb'XTLS',         re.IGNORECASE), b'VAPP'),
    (re.compile(rb'xtls',                      0), b'vapp'),
    (re.compile(rb'vapp-cor',     re.IGNORECASE), b'vapp'),
]

def filter_line(line: bytes) -> bytes:
    for pattern, replacement in FILTERS:
        line = pattern.sub(replacement, line)
    return line

def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    proc = subprocess.Popen(
        sys.argv[1:],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        for raw in proc.stdout:
            sys.stdout.buffer.write(filter_line(raw))
            sys.stdout.buffer.flush()
    except KeyboardInterrupt:
        pass
    finally:
        proc.wait()
        sys.exit(proc.returncode)

if __name__ == '__main__':
    main()
WRAPPER

    chmod +x "$INSTALL_DIR/vapp-run"
    log_info "Wrapper: $INSTALL_DIR/vapp-run"
}

# ==================== Key Generation ====================
generate_reality_keys() {
    log_step "Generating Reality keypair..."
    local output
    output=$("$INSTALL_DIR/$BINARY_NAME" x25519 2>/dev/null) \
        || log_error "Failed to generate Reality keypair."
    # 兼容新旧两种格式：
    # 旧: "Private key: xxx" / "Public key: xxx"
    # 新: "PrivateKey: xxx"  / "PublicKey: xxx" / "Password: xxx"
    PRIVATE_KEY=$(echo "$output" | grep -i 'privatekey\|private key' | awk '{print $NF}')
    PUBLIC_KEY=$(echo  "$output" | grep -i 'publickey\|public key'   | awk '{print $NF}')
    # 新版把 PublicKey 叫做 Password（客户端使用的即为 public key）
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY=$(echo "$output" | grep -i 'password' | awk '{print $NF}')
    fi
    [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] \
        && log_error "Key parsing failed. Output was: $output"
    log_info "Private key: [set]"
    log_info "Public key : $PUBLIC_KEY"
}

# ==================== Config ====================
build_server_names_json() {
    # "github.com,www.github.com" -> "github.com", "www.github.com"
    echo "$SERVER_NAMES" \
        | tr ',' '\n' \
        | sed 's/^ *//;s/ *$//' \
        | python3 -c "
import sys, json
names = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps(names))
"
}

create_config() {
    log_step "Writing xray/vapp config..."
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    local sn_json
    sn_json=$(build_server_names_json)

    # dest: "github.com:443" -> address + port
    local dest_host dest_port
    dest_host="${DEST%:*}"
    dest_port="${DEST##*:}"

    cat > "$CONFIG_DIR/config.json" <<EOF
{
    "log": {
        "loglevel": "${LOG_LEVEL}",
        "access":   "${LOG_DIR}/access.log",
        "error":    "${LOG_DIR}/error.log"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port":   ${PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id":   "${UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network":  "tcp",
                "security": "reality",
                "realitySettings": {
                    "show":        false,
                    "dest":        "${dest_host}:${dest_port}",
                    "xver":        0,
                    "serverNames": ${sn_json},
                    "privateKey":  "${PRIVATE_KEY}",
                    "shortIds":    ["${SHORT_ID}"]
                }
            },
            "sniffing": {
                "enabled":      true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag":      "direct"
        },
        {
            "protocol": "blackhole",
            "tag":      "block"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type":        "field",
                "ip":          ["geoip:private"],
                "outboundTag": "block"
            }
        ]
    }
}
EOF

    log_info "Config: $CONFIG_DIR/config.json"
}

# ==================== Systemd ====================
create_service() {
    log_step "Creating systemd service: $SERVICE_NAME"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=VApp Network Service
After=network.target network-online.target

[Service]
Type=simple
User=root
Environment="XRAY_LOCATION_ASSET=${CONFIG_DIR}"
ExecStart=${INSTALL_DIR}/vapp-run ${INSTALL_DIR}/${BINARY_NAME} run -config ${CONFIG_DIR}/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" &>/dev/null
    systemctl restart "$SERVICE_NAME"
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "✅ Service '$SERVICE_NAME' is running."
    else
        log_warn "⚠️  Service may have failed."
        log_warn "    Run: journalctl -u $SERVICE_NAME -n 30 --no-pager"
    fi
}

# ==================== Firewall ====================
configure_firewall() {
    log_step "Configuring firewall..."
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$PORT/tcp" &>/dev/null
        log_info "UFW: opened $PORT/tcp"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_info "Firewalld: opened $PORT/tcp"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        log_info "iptables: opened $PORT/tcp"
    else
        log_warn "No firewall detected."
    fi
}

# ==================== Verify ====================
verify_install() {
    log_step "Verifying installation..."

    echo ""
    echo -e "${BLUE}── Service Status ──${NC}"
    systemctl is-active --quiet "$SERVICE_NAME" \
        && echo -e "  ${GREEN}✅ $SERVICE_NAME: running${NC}" \
        || echo -e "  ${RED}❌ $SERVICE_NAME: NOT running${NC}"

    echo ""
    echo -e "${BLUE}── Port Listening ──${NC}"
    if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
        echo -e "  ${GREEN}✅ :$PORT/tcp (vless+reality)${NC}"
    else
        echo -e "  ${RED}❌ :$PORT/tcp not listening${NC}"
    fi
}

verify_patch() {
    echo ""
    echo -e "${BLUE}── Binary Patch ──${NC}"
    python3 - "$INSTALL_DIR/$BINARY_NAME" <<'PYEOF'
import sys
filepath = sys.argv[1]
targets = [b'Xray-core', b'xray-core', b'XTLS/Xray', b'XTLS Labs']
try:
    with open(filepath, 'rb') as f:
        data = f.read()
    any_found = False
    for t in targets:
        count = data.count(t)
        if count > 0:
            print(f"  [REMAIN] {t.decode()!r:18s}: {count}x (may be in compressed section)")
            any_found = True
    if not any_found:
        print("  ✅ No sensitive strings in raw binary.")
except Exception as e:
    print(f"  ERROR: {e}", file=sys.stderr)
PYEOF
}

# ==================== Result ====================
print_result() {
    # 提取 dest 主机部分用于 SNI 显示
    local dest_host="${DEST%:*}"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      VApp (VLESS + Reality) Install Complete! ✅    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"

    echo ""
    echo -e "${BLUE}=== Client Config (Clash/Mihomo YAML) ===${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 取第一个 serverName 作为 client SNI
    local first_sn
    first_sn=$(echo "$SERVER_NAMES" | cut -d',' -f1 | tr -d ' ')

    cat <<EOF
proxies:
  - name: "vapp-reality"
    type: vless
    server: <YOUR_SERVER_IP>
    port: ${PORT}
    uuid: "${UUID}"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${first_sn}
    reality-opts:
      public-key: "${PUBLIC_KEY}"
      short-id: "${SHORT_ID}"
    client-fingerprint: chrome
    skip-cert-verify: false

EOF
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo ""
    echo -e "${BLUE}=== Key Info ===${NC}"
    echo "  Public Key  : $PUBLIC_KEY"
    echo "  Private Key : [stored in config, not displayed]"
    echo "  Short ID    : $SHORT_ID"
    echo "  UUID        : $UUID"
    echo "  Reality Dest: $DEST"
    echo ""
    echo -e "${BLUE}=== Management ===${NC}"
    echo "  systemctl {start|stop|restart|status} ${SERVICE_NAME}"
    echo "  journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo -e "${BLUE}=== Config Files ===${NC}"
    echo "  Config : $CONFIG_DIR/config.json"
    echo "  Logs   : $LOG_DIR/"
    echo ""
}

# ==================== Uninstall ====================
do_uninstall() {
    log_step "Uninstalling VApp..."
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "$INSTALL_DIR/$BINARY_NAME"
    rm -f "$INSTALL_DIR/${BINARY_NAME}.orig"
    rm -f "$INSTALL_DIR/vapp-run"
    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    systemctl daemon-reload
    log_info "VApp removed."
}

# ==================== Main ====================
main() {
    print_banner
    check_root
    check_os
    parse_args "$@"

    interactive_input
    confirm_config
    install_deps
    download_xray
    patch_binary
    create_log_filter_wrapper
    generate_reality_keys
    create_config
    create_service
    configure_firewall
    verify_install
    verify_patch
    print_result
}

main "$@"