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
DEFAULT_LOG_LEVEL="warning"
DEFAULT_CA="letsencrypt"
DEFAULT_MASQUERADE_URL="https://leetcode.cn"
INSTALL_DIR="/usr/local/bin"
ACME_DIR="/root/.acme.sh"

SERVICE_NAME="happ"
BINARY_NAME="happ"
CONFIG_DIR="/etc/happ"
LOG_DIR="/var/log/happ"
CERT_DIR="/etc/happ/ssl"

# ==================== Variables ====================
PORT=""
LOG_LEVEL=$DEFAULT_LOG_LEVEL
CA=$DEFAULT_CA
DOMAIN=""
PASSWORD=""
MASQUERADE_URL=""
CF_TOKEN=""
CF_EMAIL=""
ACME_EMAIL=""
USE_CF=false

# ==================== Helpers ====================
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step()  { echo -e "\n${BLUE}[STEP]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║        HApp (Hysteria2) Installer v1.0          ║"
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
            -domain|--domain)
                DOMAIN="$2"; shift 2 ;;
            -password|--password)
                PASSWORD="$2"; shift 2 ;;
            -log|--log)
                LOG_LEVEL="$2"; shift 2 ;;
            -ca|--ca)
                CA="$2"; shift 2 ;;
            -masquerade|--masquerade)
                MASQUERADE_URL="$2"; shift 2 ;;
            -cf-token|--cf-token)
                CF_TOKEN="$2"; USE_CF=true; shift 2 ;;
            -cf-email|--cf-email)
                CF_EMAIL="$2"; shift 2 ;;
            -email|--email)
                ACME_EMAIL="$2"; shift 2 ;;
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
  -port          <port>      External port (default: $DEFAULT_PORT)
  -domain        <domain>    Domain name
  -password      <pass>      Hysteria2 password (default: random)
  -masquerade    <url>       Masquerade proxy URL (default: $DEFAULT_MASQUERADE_URL)
  -email         <email>     Email for Let's Encrypt
  -cf-token      <token>     Cloudflare API Token (DNS-01)
  -cf-email      <email>     Cloudflare account email
  uninstall                  Uninstall HApp
EOF
}

# ==================== Interactive Input ====================
generate_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
    fi
}

interactive_input() {
    echo ""
    log_step "Interactive Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Domain
    if [[ -z "$DOMAIN" ]]; then
        while true; do
            read -rp "$(echo -e "${YELLOW}Domain name (required):${NC} ")" DOMAIN
            [[ -n "$DOMAIN" ]] && break
            echo -e "${RED}  Domain cannot be empty.${NC}"
        done
    else
        log_info "Domain: $DOMAIN (from arg)"
    fi

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

    # Password
    if [[ -z "$PASSWORD" ]]; then
        local gen_pwd
        gen_pwd=$(generate_password)
        read -rsp "$(echo -e "${YELLOW}Password [Enter=random]:${NC} ")" input_pwd
        echo ""
        PASSWORD="${input_pwd:-$gen_pwd}"
    fi
    log_info "Password: [set]"

    # Masquerade URL
    if [[ -z "$MASQUERADE_URL" ]]; then
        read -rp "$(echo -e "${YELLOW}Masquerade proxy URL [Enter=${DEFAULT_MASQUERADE_URL}]:${NC} ")" input_url
        MASQUERADE_URL="${input_url:-$DEFAULT_MASQUERADE_URL}"
    fi
    log_info "Masquerade URL: $MASQUERADE_URL"

    # ACME Email
    if [[ -z "$ACME_EMAIL" ]]; then
        echo ""
        while true; do
            read -rp "$(echo -e "${YELLOW}Email for Let's Encrypt (required):${NC} ")" ACME_EMAIL
            if [[ "$ACME_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
                break
            else
                echo -e "${RED}  Invalid email format.${NC}"
            fi
        done
    else
        if ! [[ "$ACME_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
            log_error "Invalid ACME email format: $ACME_EMAIL"
        fi
    fi
    log_info "ACME Email: $ACME_EMAIL"

    # Cloudflare
    if [[ "$USE_CF" == false ]]; then
        echo ""
        read -rp "$(echo -e "${YELLOW}Use Cloudflare DNS-01 challenge? (y/N):${NC} ")" use_cf_input
        if [[ "$use_cf_input" =~ ^[Yy]$ ]]; then
            USE_CF=true
            if [[ -z "$CF_TOKEN" ]]; then
                while true; do
                    read -rsp "$(echo -e "${YELLOW}Cloudflare API Token:${NC} ")" CF_TOKEN
                    echo ""
                    [[ -n "$CF_TOKEN" ]] && break
                    echo -e "${RED}  Token cannot be empty.${NC}"
                done
            fi
            if [[ -z "$CF_EMAIL" ]]; then
                read -rp "$(echo -e "${YELLOW}Cloudflare account email (optional):${NC} ")" CF_EMAIL
            fi
        fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

confirm_config() {
    echo ""
    log_step "Configuration Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Mode            : ${GREEN}HApp (Hysteria2 stealth)${NC}"
    echo -e "  Domain          : ${GREEN}$DOMAIN${NC}"
    echo -e "  Port            : ${GREEN}$PORT${NC}"
    echo -e "  Password        : ${GREEN}$PASSWORD${NC}"
    echo -e "  Masquerade URL  : ${GREEN}$MASQUERADE_URL${NC}"
    echo -e "  ACME Email      : ${GREEN}$ACME_EMAIL${NC}"
    echo -e "  Cloudflare DNS  : ${GREEN}$USE_CF${NC}"
    if [[ "$USE_CF" == true ]]; then
        echo -e "  CF Token        : ${GREEN}[set]${NC}"
        [[ -n "$CF_EMAIL" ]] && echo -e "  CF Email        : ${GREEN}$CF_EMAIL${NC}"
    fi
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
        apt-get install -y -qq curl wget unzip socat cron openssl python3
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip socat cronie openssl python3
        systemctl enable --now crond &>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl wget unzip socat cronie openssl python3
        systemctl enable --now crond &>/dev/null || true
    else
        log_error "Unsupported package manager"
    fi
    log_info "Dependencies ready."
}

# ==================== Download ====================
download_hysteria2() {
    log_step "Downloading hysteria2 binary..."

    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  ARCH_NAME="amd64" ;;
        aarch64) ARCH_NAME="arm64" ;;
        armv7l)  ARCH_NAME="arm" ;;
        *)       log_error "Unsupported arch: $arch" ;;
    esac

    local latest
    latest=$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest \
             | grep '"tag_name"' | cut -d'"' -f4)
    [[ -z "$latest" ]] && log_error "Failed to fetch latest version."
    log_info "Latest: $latest"

    local url="https://github.com/apernet/hysteria/releases/download/${latest}/hysteria-linux-${ARCH_NAME}"
    log_info "Downloading: $url"

    curl -fL --progress-bar -o "$INSTALL_DIR/$BINARY_NAME" "$url" \
        || log_error "Download failed."

    chmod +x "$INSTALL_DIR/$BINARY_NAME"
    log_info "Binary installed: $INSTALL_DIR/$BINARY_NAME"
}

# ==================== Patch ====================
patch_binary() {
    log_step "Patching binary strings (HApp mode)..."
    local binary="$INSTALL_DIR/$BINARY_NAME"
    cp "$binary" "${binary}.orig"

    python3 - "$binary" <<'PYEOF'
import sys

filepath = sys.argv[1]

replacements = [
    (b'hysteria',   b'happ-svc'),
    (b'Hysteria',   b'Happ-Svc'),
    (b'HYSTERIA',   b'HAPP-SVC'),
    (b'apernet',    b'happ-net'),
    (b'hysteria2',  b'happ-sv2'),
    (b'Hysteria2',  b'Happ-Sv2'),
]

# 确保等长
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
        print(f"  [{count:>5}x] {old.decode(errors='replace')!r:18s} -> {new.decode(errors='replace')!r}")
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

    cat > "$INSTALL_DIR/happ-run" <<'WRAPPER'
#!/usr/bin/env python3
"""HApp runtime wrapper - filters sensitive strings from log output"""
import sys
import subprocess
import re

FILTERS = [
    (re.compile(rb'hysteria2?', re.IGNORECASE), b'happ'),
    (re.compile(rb'apernet',    re.IGNORECASE), b'happ'),
    (re.compile(rb'happ-svc',   re.IGNORECASE), b'happ'),
    (re.compile(rb'happ-net',   re.IGNORECASE), b'happ'),
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

    chmod +x "$INSTALL_DIR/happ-run"
    log_info "Wrapper: $INSTALL_DIR/happ-run"
}

# ==================== acme.sh ====================
fix_acme_account_email() {
    local correct_email="$1"
    log_info "Checking acme.sh stored email..."

    local account_conf="$ACME_DIR/account.conf"
    if [[ -f "$account_conf" ]]; then
        local stored
        stored=$(grep '^ACCOUNT_EMAIL=' "$account_conf" \
                 | cut -d'=' -f2 | tr -d "'" | tr -d '"')
        if [[ "$stored" != "$correct_email" ]]; then
            log_info "  account.conf: '$stored' -> '$correct_email'"
            sed -i "/^ACCOUNT_EMAIL=/d" "$account_conf"
            echo "ACCOUNT_EMAIL='${correct_email}'" >> "$account_conf"
        else
            log_info "  account.conf: already correct"
        fi
    fi

    local le_dir="$ACME_DIR/ca/acme-v02.api.letsencrypt.org"
    if [[ -d "$le_dir" ]]; then
        local bad_email
        bad_email=$(grep -r '"contact"' "$le_dir" 2>/dev/null \
                    | grep -o '"mailto:[^"]*"' \
                    | grep -v "$correct_email" | head -1 || true)
        if [[ -n "$bad_email" ]]; then
            log_info "  Clearing stale LE account cache (was: $bad_email)"
            rm -rf "$le_dir"
        fi
    fi
}

install_acme() {
    log_step "Installing acme.sh..."
    if [[ ! -f "$ACME_DIR/acme.sh" ]]; then
        curl -fsSL https://get.acme.sh | bash -s "email=${ACME_EMAIL}" \
            || log_error "acme.sh install failed."
        log_info "acme.sh installed: $ACME_EMAIL"
    else
        log_info "acme.sh exists, fixing account email..."
        fix_acme_account_email "$ACME_EMAIL"
    fi
    "$ACME_DIR/acme.sh" --set-default-ca --server "$CA" 2>/dev/null || true
    log_info "Default CA: $CA"
}

issue_cert() {
    log_step "Issuing SSL certificate for: $DOMAIN"
    mkdir -p "$CERT_DIR"

    local issue_args=(--issue -d "$DOMAIN" --server "$CA" --accountemail "$ACME_EMAIL")

    if [[ "$USE_CF" == true ]]; then
        log_info "Method: Cloudflare DNS-01"
        export CF_Token="$CF_TOKEN"
        [[ -n "$CF_EMAIL" ]] && export CF_Email="$CF_EMAIL"
        issue_args+=(--dns dns_cf)
    else
        log_info "Method: HTTP standalone"
        issue_args+=(--standalone --httpport 80)
    fi

    "$ACME_DIR/acme.sh" "${issue_args[@]}" 2>&1 | tail -20
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 && $rc -ne 2 ]]; then
        log_warn "Issue rc=$rc, retrying with --force..."
        "$ACME_DIR/acme.sh" "${issue_args[@]}" --force 2>&1 | tail -20 || true
    fi

    "$ACME_DIR/acme.sh" --install-cert -d "$DOMAIN" \
        --cert-file      "$CERT_DIR/cert.pem"       \
        --key-file       "$CERT_DIR/key.pem"         \
        --fullchain-file "$CERT_DIR/fullchain.pem"   \
        --reloadcmd      "systemctl reload $SERVICE_NAME 2>/dev/null || true"

    [[ ! -f "$CERT_DIR/fullchain.pem" ]] && log_error "Certificate installation failed."
    log_info "Certificate ready: $CERT_DIR"
}

# ==================== Hysteria2 Config ====================
create_config() {
    log_step "Writing hysteria2 config..."
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    cat > "$CONFIG_DIR/config.yaml" <<EOF
# HApp (Hysteria2) Server Config
# Auto-generated by installer. Do not edit manually.

listen: :${PORT}

tls:
  cert: ${CERT_DIR}/fullchain.pem
  key:  ${CERT_DIR}/key.pem

auth:
  type: password
  password: "${PASSWORD}"

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true

bandwidth:
  up:   1 gbps
  down: 1 gbps

ignoreClientBandwidth: false

quic:
  initStreamReceiveWindow:     8388608
  maxStreamReceiveWindow:      8388608
  initConnReceiveWindow:       20971520
  maxConnReceiveWindow:        20971520
  maxIdleTimeout:              30s
  maxIncomingStreams:          1024
  disablePathMTUDiscovery:     false

log:
  level: ${LOG_LEVEL}
  file:  ${LOG_DIR}/${SERVICE_NAME}.log
EOF

    log_info "Config: $CONFIG_DIR/config.yaml"
}

# ==================== Systemd ====================
create_service() {
    log_step "Creating systemd service: $SERVICE_NAME"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=HApp Network Service
After=network.target network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/happ-run ${INSTALL_DIR}/${BINARY_NAME} server --config ${CONFIG_DIR}/config.yaml
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
        ufw allow "$PORT/udp" &>/dev/null
        ufw allow "$PORT/tcp" &>/dev/null
        ufw allow "80/tcp"    &>/dev/null
        log_info "UFW: opened $PORT/udp, $PORT/tcp, 80/tcp"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/udp" &>/dev/null
        firewall-cmd --permanent --add-port="${PORT}/tcp" &>/dev/null
        firewall-cmd --permanent --add-port="80/tcp"      &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_info "Firewalld: opened $PORT/udp, $PORT/tcp, 80/tcp"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p tcp --dport 80      -j ACCEPT
        log_info "iptables: opened $PORT/udp, $PORT/tcp, 80/tcp"
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
    echo -e "${BLUE}── Port Listening (UDP) ──${NC}"
    if ss -ulnp 2>/dev/null | grep -q ":${PORT}"; then
        echo -e "  ${GREEN}✅ :$PORT/udp (hysteria2)${NC}"
    else
        echo -e "  ${RED}❌ :$PORT/udp not listening${NC}"
    fi

    echo ""
    echo -e "${BLUE}── Certificate ──${NC}"
    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" \
                 | cut -d'=' -f2)
        echo -e "  ${GREEN}✅ Certificate valid until: $expiry${NC}"
    else
        echo -e "  ${RED}❌ Certificate not found${NC}"
    fi
}

verify_patch() {
    echo ""
    echo -e "${BLUE}── Binary Patch ──${NC}"
    python3 - "$INSTALL_DIR/$BINARY_NAME" <<'PYEOF'
import sys
filepath = sys.argv[1]
targets = [b'hysteria', b'Hysteria', b'HYSTERIA', b'apernet']
try:
    with open(filepath, 'rb') as f:
        data = f.read()
    any_found = False
    for t in targets:
        count = data.count(t)
        if count > 0:
            print(f"  [REMAIN] {t.decode()!r:16s}: {count}x (may be in compressed section)")
            any_found = True
    if not any_found:
        print("  ✅ No sensitive strings in raw binary.")
except Exception as e:
    print(f"  ERROR: {e}", file=sys.stderr)
PYEOF
}

# ==================== Result ====================
print_result() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         HApp (Hysteria2) Install Complete! ✅       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"

    echo ""
    echo -e "${BLUE}=== Client Config (Clash/Mihomo YAML) ===${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat <<EOF
proxies:
  - name: "${DOMAIN}"
    type: hysteria2
    server: ${DOMAIN}
    port: ${PORT}
    password: "${PASSWORD}"
    udp: true
    sni: ${DOMAIN}
    skip-cert-verify: false
EOF
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo ""
    echo -e "${BLUE}=== Management ===${NC}"
    echo "  systemctl {start|stop|restart|status} ${SERVICE_NAME}"
    echo "  journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo -e "${BLUE}=== Config Files ===${NC}"
    echo "  Config  : $CONFIG_DIR/config.yaml"
    echo "  Certs   : $CERT_DIR/"
    echo "  Logs    : $LOG_DIR/"
    echo ""
}

# ==================== Uninstall ====================
do_uninstall() {
    log_step "Uninstalling HApp..."
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "$INSTALL_DIR/$BINARY_NAME"
    rm -f "$INSTALL_DIR/${BINARY_NAME}.orig"
    rm -f "$INSTALL_DIR/happ-run"
    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    systemctl daemon-reload
    log_info "HApp removed."
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
    download_hysteria2
    patch_binary
    create_log_filter_wrapper
    install_acme
    issue_cert
    create_config
    create_service
    configure_firewall
    verify_install
    verify_patch
    print_result
}

main "$@"