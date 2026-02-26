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
DEFAULT_TROJAN_INTERNAL_PORT=16663
DEFAULT_LOG_LEVEL="warning"
DEFAULT_CA="letsencrypt"
INSTALL_DIR="/usr/local/bin"
ACME_DIR="/root/.acme.sh"
NGINX_CONF_D="/etc/nginx/conf.d"
NGINX_STREAM_CONF_D="/etc/nginx/stream.conf.d"

# ==================== Variables ====================
INSTALL_MODE=""
PORT=""
TROJAN_INTERNAL_PORT=""
LOG_LEVEL=$DEFAULT_LOG_LEVEL
CA=$DEFAULT_CA
DOMAIN=""
PASSWORD=""
CF_TOKEN=""
CF_EMAIL=""
ACME_EMAIL=""
USE_CF=false

SERVICE_NAME=""
BINARY_NAME=""
CONFIG_DIR=""
LOG_DIR=""
CERT_DIR=""

# ==================== Helpers ====================
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step()  { echo -e "\n${BLUE}[STEP]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   Trojan-Go / TApp + Nginx SNI Installer v2.1  ║"
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

# ==================== Mode Selection ====================
select_install_mode() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              Select Installation Mode               ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}1)${NC} TApp Mode (stealth)                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}     Patched binary + Nginx SNI, service: tapp       ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${CYAN}2)${NC} Standard Trojan-Go + Nginx SNI                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}     Original binary + Nginx SNI, service: trojan-go ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    while true; do
        read -rp "$(echo -e "${YELLOW}Select mode [1/2]:${NC} ")" mode_input
        case "$mode_input" in
            1) INSTALL_MODE="tapp";   _set_mode_vars_tapp;   break ;;
            2) INSTALL_MODE="trojan"; _set_mode_vars_trojan; break ;;
            *) echo -e "${RED}  Please enter 1 or 2.${NC}" ;;
        esac
    done
}

_set_mode_vars_tapp() {
    SERVICE_NAME="tapp"
    BINARY_NAME="tapp"
    CONFIG_DIR="/etc/tapp"
    LOG_DIR="/var/log/tapp"
    CERT_DIR="/etc/tapp/ssl"
}

_set_mode_vars_trojan() {
    SERVICE_NAME="trojan-go"
    BINARY_NAME="trojan-go"
    CONFIG_DIR="/etc/trojan-go"
    LOG_DIR="/var/log/trojan-go"
    CERT_DIR="/etc/trojan-go/ssl"
}

# ==================== Args ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -port|--port)
                PORT="$2"; shift 2 ;;
            -internal-port|--internal-port)
                TROJAN_INTERNAL_PORT="$2"; shift 2 ;;
            -domain|--domain)
                DOMAIN="$2"; shift 2 ;;
            -password|--password)
                PASSWORD="$2"; shift 2 ;;
            -log|--log)
                LOG_LEVEL="$2"; shift 2 ;;
            -ca|--ca)
                CA="$2"; shift 2 ;;
            -cf-token|--cf-token)
                CF_TOKEN="$2"; USE_CF=true; shift 2 ;;
            -cf-email|--cf-email)
                CF_EMAIL="$2"; shift 2 ;;
            -email|--email)
                ACME_EMAIL="$2"; shift 2 ;;
            -mode|--mode)
                case "$2" in
                    tapp|1)   INSTALL_MODE="tapp";   _set_mode_vars_tapp   ;;
                    trojan|2) INSTALL_MODE="trojan"; _set_mode_vars_trojan ;;
                    *) log_warn "Unknown mode '$2'" ;;
                esac
                shift 2 ;;
            -h|--help)  print_help; exit 0 ;;
            uninstall)  uninstall_prompt; exit 0 ;;
            *)          log_warn "Unknown argument: $1"; shift ;;
        esac
    done
}

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -mode          tapp|trojan        Installation mode
  -port          <port>             External port Nginx listens on (default: $DEFAULT_PORT)
  -internal-port <port>             Internal trojan-go port on 127.0.0.1 (default: $DEFAULT_TROJAN_INTERNAL_PORT)
  -domain        <domain>           Domain name (SNI matching)
  -password      <pass>             Trojan-Go password (default: random)
  -email         <email>            Email for Let's Encrypt registration
  -cf-token      <token>            Cloudflare API Token (for DNS-01)
  -cf-email      <email>            Cloudflare account email (for DNS API auth)
  uninstall                         Uninstall

Architecture:
  Internet → Nginx :PORT (stream SNI) → 127.0.0.1:INTERNAL_PORT (trojan-go)
                                      ↘ fallback: 127.0.0.1:8080 (nginx http)
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

    # External Port (Nginx)
    if [[ -z "$PORT" ]]; then
        read -rp "$(echo -e "${YELLOW}External port (Nginx) [Enter=${DEFAULT_PORT}]:${NC} ")" input_port
        if [[ -z "$input_port" ]]; then
            PORT=$DEFAULT_PORT
        elif [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            PORT=$input_port
        else
            log_warn "Invalid port, using $DEFAULT_PORT"
            PORT=$DEFAULT_PORT
        fi
    fi
    log_info "External port (Nginx): $PORT"

    # Internal Port (trojan-go, 127.0.0.1 only)
    if [[ -z "$TROJAN_INTERNAL_PORT" ]]; then
        read -rp "$(echo -e "${YELLOW}Internal trojan-go port [Enter=${DEFAULT_TROJAN_INTERNAL_PORT}]:${NC} ")" input_iport
        if [[ -z "$input_iport" ]]; then
            TROJAN_INTERNAL_PORT=$DEFAULT_TROJAN_INTERNAL_PORT
        elif [[ "$input_iport" =~ ^[0-9]+$ ]] && (( input_iport >= 1 && input_iport <= 65535 )); then
            TROJAN_INTERNAL_PORT=$input_iport
        else
            log_warn "Invalid port, using $DEFAULT_TROJAN_INTERNAL_PORT"
            TROJAN_INTERNAL_PORT=$DEFAULT_TROJAN_INTERNAL_PORT
        fi
    fi
    log_info "Internal port (trojan-go @ 127.0.0.1): $TROJAN_INTERNAL_PORT"

    # Validate ports differ
    if [[ "$PORT" == "$TROJAN_INTERNAL_PORT" ]]; then
        log_error "External port and internal port must be different!"
    fi

    # Password
    if [[ -z "$PASSWORD" ]]; then
        local gen_pwd
        gen_pwd=$(generate_password)
        read -rsp "$(echo -e "${YELLOW}Password [Enter=random]:${NC} ")" input_pwd
        echo ""
        PASSWORD="${input_pwd:-$gen_pwd}"
    fi
    log_info "Password: [set]"

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
    [[ "$INSTALL_MODE" == "tapp" ]] \
        && echo -e "  Mode            : ${GREEN}TApp (stealth)${NC}" \
        || echo -e "  Mode            : ${CYAN}Standard Trojan-Go${NC}"
    echo -e "  Domain          : ${GREEN}$DOMAIN${NC}"
    echo -e "  External Port   : ${GREEN}$PORT${NC}    ← Nginx listens here"
    echo -e "  Internal Port   : ${GREEN}$TROJAN_INTERNAL_PORT${NC} ← trojan-go @ 127.0.0.1 only"
    echo -e "  Password        : ${GREEN}$PASSWORD${NC}"
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
    echo -e "${CYAN}  Architecture:${NC}"
    echo "  Internet"
    echo "    └─→ Nginx :$PORT (stream SNI routing)"
    echo "          ├─ SNI=$DOMAIN → 127.0.0.1:$TROJAN_INTERNAL_PORT (trojan-go)"
    echo "          └─ other SNI   → 127.0.0.1:8080 (fallback web)"
    echo ""
    read -rp "$(echo -e "${YELLOW}Proceed? (Y/n):${NC} ")" confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "Cancelled."; exit 0; }
}

# ==================== Dependencies ====================
install_deps() {
    log_step "Installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl wget unzip socat cron openssl python3 binutils nginx
    elif command -v yum &>/dev/null; then
        yum install -y -q curl wget unzip socat cronie openssl python3 binutils nginx
        systemctl enable --now crond &>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl wget unzip socat cronie openssl python3 binutils nginx
        systemctl enable --now crond &>/dev/null || true
    else
        log_error "Unsupported package manager"
    fi

    check_nginx_stream
    log_info "Dependencies ready."
}

check_nginx_stream() {
    log_info "Checking nginx stream module..."

    # 检查是否内置
    if nginx -V 2>&1 | grep -q '\-\-with-stream'; then
        log_info "  nginx stream module: ✅ built-in"
        return
    fi

    log_warn "  nginx stream module not built-in, attempting to install..."

    if command -v apt-get &>/dev/null; then
        apt-get install -y libnginx-mod-stream \
            && log_info "  ✅ libnginx-mod-stream installed" \
            || log_error "Failed to install libnginx-mod-stream"
    elif command -v yum &>/dev/null; then
        yum install -y nginx-mod-stream \
            && log_info "  ✅ nginx-mod-stream installed" \
            || log_error "Failed to install nginx-mod-stream"
    elif command -v dnf &>/dev/null; then
        dnf install -y nginx-mod-stream \
            && log_info "  ✅ nginx-mod-stream installed" \
            || log_error "Failed to install nginx-mod-stream"
    else
        log_error "Cannot install nginx stream module: unsupported package manager"
    fi

    # 安装后验证（动态模块不会改变 nginx -V 输出，检查模块文件）
    if nginx -V 2>&1 | grep -q '\-\-with-stream' \
        || ls /usr/lib/nginx/modules/ngx_stream_module.so &>/dev/null \
        || ls /etc/nginx/modules-enabled/*stream* &>/dev/null \
        || ls /usr/lib64/nginx/modules/ngx_stream_module.so &>/dev/null; then
        log_info "  nginx stream module: ✅ available (dynamic module)"
    else
        log_error "nginx stream module still not available. Please install manually."
    fi
}

# ==================== Download ====================
download_trojan_go() {
    log_step "Downloading trojan-go binary..."

    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  ARCH_NAME="amd64" ;;
        aarch64) ARCH_NAME="arm64" ;;
        armv7l)  ARCH_NAME="armv7" ;;
        *)       log_error "Unsupported arch: $arch" ;;
    esac

    local latest
    latest=$(curl -fsSL https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest \
             | grep '"tag_name"' | cut -d'"' -f4)
    [[ -z "$latest" ]] && log_error "Failed to fetch latest version."
    log_info "Latest: $latest"

    local url="https://github.com/p4gefau1t/trojan-go/releases/download/${latest}/trojan-go-linux-${ARCH_NAME}.zip"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Downloading: $url"
    curl -fL --progress-bar -o "$tmp_dir/trojan-go.zip" "$url" \
        || log_error "Download failed."

    unzip -q "$tmp_dir/trojan-go.zip" -d "$tmp_dir" \
        || log_error "Unzip failed."

    [[ ! -f "$tmp_dir/trojan-go" ]] && log_error "Binary not found in zip."

    mv "$tmp_dir/trojan-go" "$INSTALL_DIR/$BINARY_NAME"
    chmod +x "$INSTALL_DIR/$BINARY_NAME"
    rm -rf "$tmp_dir"
    log_info "Binary installed: $INSTALL_DIR/$BINARY_NAME"
}

# ==================== Patch ====================
patch_binary() {
    [[ "$INSTALL_MODE" != "tapp" ]] && return

    log_step "Patching binary strings (TApp mode)..."
    local binary="$INSTALL_DIR/$BINARY_NAME"
    cp "$binary" "${binary}.orig"

    python3 - "$binary" <<'PYEOF'
import sys

filepath = sys.argv[1]

replacements = [
    (b'trojan-go',  b'tapp-svcs'),
    (b'Trojan-Go',  b'TApp-Svcs'),
    (b'TROJAN-GO',  b'TAPP-SVCS'),
    (b'p4gefau1t',  b'tapp-proj'),
    (b'trojan-go/', b'tapp-svcs/'),
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
    [[ "$INSTALL_MODE" != "tapp" ]] && return

    log_step "Creating log filter wrapper..."

    cat > "$INSTALL_DIR/tapp-run" <<'WRAPPER'
#!/usr/bin/env python3
"""TApp runtime wrapper - filters sensitive strings from log output"""
import sys
import subprocess
import re

FILTERS = [
    (re.compile(rb'trojan-go',  re.IGNORECASE), b'tapp'),
    (re.compile(rb'trojan_go',  re.IGNORECASE), b'tapp'),
    (re.compile(rb'tapp-svcs',  re.IGNORECASE), b'tapp'),
    (re.compile(rb'tapp-proj',  re.IGNORECASE), b'tapp'),
    (re.compile(rb'p4gefau1t',  re.IGNORECASE), b'tapp'),
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

    chmod +x "$INSTALL_DIR/tapp-run"
    log_info "Wrapper: $INSTALL_DIR/tapp-run"
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
        log_info "Method: HTTP standalone (stopping nginx temporarily)"
        systemctl stop nginx 2>/dev/null || true
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

# ==================== trojan-go Config ====================
convert_log_level() {
    case "$1" in
        debug)   echo 0 ;;
        info)    echo 1 ;;
        warning) echo 2 ;;
        error)   echo 3 ;;
        *)       echo 2 ;;
    esac
}

create_config() {
    log_step "Writing trojan-go config..."
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    cat > "$CONFIG_DIR/config.json" <<EOF
{
    "run_type": "server",
    "local_addr": "127.0.0.1",
    "local_port": ${TROJAN_INTERNAL_PORT},
    "remote_addr": "127.0.0.1",
    "remote_port": 8080,
    "log_level": $(convert_log_level "$LOG_LEVEL"),
    "log_file": "${LOG_DIR}/${SERVICE_NAME}.log",
    "password": [
        "${PASSWORD}"
    ],
    "ssl": {
        "cert": "${CERT_DIR}/fullchain.pem",
        "key":  "${CERT_DIR}/key.pem",
        "sni":  "${DOMAIN}",
        "session_ticket": true,
        "reuse_session":  true,
        "fallback_port":  8080
    },
    "tcp": {
        "no_delay":    true,
        "keep_alive":  true,
        "prefer_ipv4": true
    },
    "mux": {
        "enabled":      true,
        "concurrency":  8,
        "idle_timeout": 60
    }
}
EOF
    log_info "Config: $CONFIG_DIR/config.json"
    log_info "  trojan-go listens on: 127.0.0.1:$TROJAN_INTERNAL_PORT (internal only)"
}

# ==================== Nginx Config ====================
configure_nginx() {
    log_step "Configuring Nginx SNI routing..."

    _ensure_nginx_stream_block
    _write_nginx_stream_conf
    _write_nginx_http_conf

    nginx -t 2>&1 && log_info "Nginx config test passed." \
        || log_error "Nginx config test failed! Check errors above."

    systemctl enable nginx &>/dev/null
    systemctl restart nginx
    sleep 1
    systemctl is-active --quiet nginx \
        && log_info "✅ Nginx running." \
        || log_warn "⚠️  Nginx may have failed. Check: journalctl -u nginx -n 20"
}

_ensure_nginx_stream_block() {
    local nginx_conf="/etc/nginx/nginx.conf"

    mkdir -p "$NGINX_STREAM_CONF_D"

    # 已包含 stream.conf.d
    if grep -q 'stream\.conf\.d' "$nginx_conf" 2>/dev/null; then
        log_info "  nginx.conf already includes stream.conf.d, skipping."
        return
    fi

    # 已有手动写的 stream {} 块但没有 include
    if grep -qE '^\s*stream\s*\{' "$nginx_conf" 2>/dev/null; then
        log_warn "  nginx.conf has existing stream{} block without stream.conf.d include."
        log_warn "  Please manually add inside stream{}: include /etc/nginx/stream.conf.d/*.conf;"
        return
    fi

    log_info "  Appending stream block to nginx.conf..."
    cat >> "$nginx_conf" <<'EOF'

# ── SNI stream routing (auto-added by installer) ──
stream {
    include /etc/nginx/stream.conf.d/*.conf;
}
EOF
    log_info "  ✅ stream block added to nginx.conf"
}

_write_nginx_stream_conf() {
    mkdir -p "$NGINX_STREAM_CONF_D"

    local conf_file="${NGINX_STREAM_CONF_D}/${SERVICE_NAME}-sni.conf"

    cat > "$conf_file" <<EOF
# ── ${SERVICE_NAME} SNI routing ──
# Auto-generated by installer. Do not edit manually.
# Architecture: Internet → Nginx :${PORT} → 127.0.0.1:${TROJAN_INTERNAL_PORT} (trojan-go)

map \$ssl_preread_server_name \$backend {
    ${DOMAIN}    127.0.0.1:${TROJAN_INTERNAL_PORT};
    default       127.0.0.1:8443;
}

server {
    listen ${PORT} reuseport;
    listen [::]:${PORT} reuseport;

    ssl_preread  on;
    proxy_pass   \$backend;

    proxy_connect_timeout 10s;
    proxy_timeout         600s;
    proxy_buffer_size     16k;
}

# fallback HTTPS（伪装站，非目标域名流量）
server {
    listen 127.0.0.1:8443;
    ssl_preread off;
    proxy_pass  127.0.0.1:8080;
    proxy_connect_timeout 5s;
    proxy_timeout         60s;
}
EOF

    log_info "Stream conf: $conf_file"
}

_write_nginx_http_conf() {
    local conf_file="${NGINX_CONF_D}/${SERVICE_NAME}-web.conf"

    cat > "$conf_file" <<EOF
# ── ${SERVICE_NAME} fallback web (伪装站) ──
# Auto-generated by installer.

server {
    listen 127.0.0.1:8080;
    server_name ${DOMAIN};

    root /var/www/${SERVICE_NAME}-web;
    index index.html;

    add_header X-Content-Type-Options  "nosniff"     always;
    add_header X-Frame-Options         "SAMEORIGIN"  always;
    add_header Referrer-Policy         "no-referrer" always;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \.(php|asp|aspx|jsp)$ {
        return 444;
    }

    access_log /var/log/nginx/${SERVICE_NAME}-web-access.log;
    error_log  /var/log/nginx/${SERVICE_NAME}-web-error.log warn;
}
EOF

    mkdir -p "/var/www/${SERVICE_NAME}-web"
    cat > "/var/www/${SERVICE_NAME}-web/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #f5f5f5;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
        }
        .container {
            text-align: center;
            padding: 40px;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.08);
            max-width: 400px;
        }
        h1 { color: #333; font-size: 1.8rem; margin-bottom: 10px; }
        p  { color: #666; font-size: 0.95rem; line-height: 1.6; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome</h1>
        <p>This server is running normally.</p>
    </div>
</body>
</html>
HTML

    log_info "HTTP fallback conf: $conf_file"
    log_info "Decoy web root: /var/www/${SERVICE_NAME}-web/"
}

# ==================== Systemd ====================
create_service() {
    log_step "Creating systemd service: $SERVICE_NAME"

    local exec_start svc_desc
    if [[ "$INSTALL_MODE" == "tapp" ]]; then
        exec_start="${INSTALL_DIR}/tapp-run ${INSTALL_DIR}/${BINARY_NAME} -config ${CONFIG_DIR}/config.json"
        svc_desc="TApp Network Service"
    else
        exec_start="${INSTALL_DIR}/${BINARY_NAME} -config ${CONFIG_DIR}/config.json"
        svc_desc="Trojan-Go Proxy Service"
    fi

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=${svc_desc}
After=network.target network-online.target nginx.service
Requires=nginx.service

[Service]
Type=simple
User=root
ExecStart=${exec_start}
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
        ufw allow "80/tcp"    &>/dev/null
        log_info "UFW: opened $PORT/tcp, 80/tcp"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" &>/dev/null
        firewall-cmd --permanent --add-port="80/tcp"     &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_info "Firewalld: opened $PORT/tcp, 80/tcp"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p tcp --dport 80      -j ACCEPT
        log_info "iptables: opened $PORT/tcp, 80/tcp"
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
    systemctl is-active --quiet nginx \
        && echo -e "  ${GREEN}✅ nginx: running${NC}" \
        || echo -e "  ${RED}❌ nginx: NOT running${NC}"

    echo ""
    echo -e "${BLUE}── Port Listening ──${NC}"
    local listen_tool
    if command -v ss &>/dev/null; then
        listen_tool="ss -tlnp"
    else
        listen_tool="netstat -tlnp"
    fi

    if $listen_tool 2>/dev/null | grep -q ":${PORT}"; then
        echo -e "  ${GREEN}✅ :$PORT (nginx external)${NC}"
    else
        echo -e "  ${RED}❌ :$PORT not listening${NC}"
    fi

    if $listen_tool 2>/dev/null | grep -q "127.0.0.1:${TROJAN_INTERNAL_PORT}"; then
        echo -e "  ${GREEN}✅ 127.0.0.1:$TROJAN_INTERNAL_PORT (trojan-go internal)${NC}"
    else
        echo -e "  ${RED}❌ 127.0.0.1:$TROJAN_INTERNAL_PORT not listening${NC}"
    fi

    if $listen_tool 2>/dev/null | grep "0.0.0.0:${TROJAN_INTERNAL_PORT}" &>/dev/null; then
        echo -e "  ${RED}⚠️  WARNING: trojan-go is listening on 0.0.0.0! Check config.${NC}"
    else
        echo -e "  ${GREEN}✅ trojan-go NOT exposed on 0.0.0.0 (correct)${NC}"
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
    [[ "$INSTALL_MODE" != "tapp" ]] && return

    echo ""
    echo -e "${BLUE}── Binary Patch ──${NC}"
    python3 - "$INSTALL_DIR/$BINARY_NAME" <<'PYEOF'
import sys
filepath = sys.argv[1]
targets = [b'trojan-go', b'Trojan-Go', b'TROJAN-GO', b'p4gefau1t']
try:
    with open(filepath, 'rb') as f:
        data = f.read()
    any_found = False
    for t in targets:
        count = data.count(t)
        if count > 0:
            print(f"  [REMAIN] {t.decode()!r:16s}: {count}x (may be in compressed Go section)")
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
    if [[ "$INSTALL_MODE" == "tapp" ]]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║       TApp + Nginx SNI Install Complete! ✅         ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║    Trojan-Go + Nginx SNI Install Complete! ✅       ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    fi

    echo ""
    echo -e "${BLUE}=== Architecture ===${NC}"
    echo "  Internet"
    echo "    └─→ Nginx :${PORT}  (stream SNI preread, no TLS termination)"
    echo "          ├─ SNI=${DOMAIN}"
    echo "          │    └─→ 127.0.0.1:${TROJAN_INTERNAL_PORT}  ← trojan-go"
    echo "          └─ other SNI"
    echo "               └─→ 127.0.0.1:8443 → :8080  ← fallback web"
    echo ""
    echo -e "${BLUE}=== Client Config (Clash YAML) ===${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat <<EOF
proxies:
  - name: "${DOMAIN}"
    type: trojan
    server: ${DOMAIN}
    port: ${PORT}
    password: "${PASSWORD}"
    udp: true
    sni: ${DOMAIN}
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
EOF
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${BLUE}=== Management ===${NC}"
    echo "  systemctl {start|stop|restart|status} ${SERVICE_NAME}"
    echo "  systemctl {start|stop|restart|status} nginx"
    echo "  journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo -e "${BLUE}=== Config Files ===${NC}"
    echo "  Trojan-Go  : $CONFIG_DIR/config.json"
    echo "  Nginx SNI  : ${NGINX_STREAM_CONF_D}/${SERVICE_NAME}-sni.conf"
    echo "  Nginx Web  : ${NGINX_CONF_D}/${SERVICE_NAME}-web.conf"
    echo "  Certs      : $CERT_DIR/"
    echo "  Logs       : $LOG_DIR/"
    echo ""
}

# ==================== Uninstall ====================
uninstall_prompt() {
    echo ""
    log_step "Uninstall"
    echo "  1) Remove TApp"
    echo "  2) Remove Trojan-Go"
    echo ""
    read -rp "$(echo -e "${YELLOW}Select [1/2]:${NC} ")" choice
    case "$choice" in
        1) _do_uninstall "tapp"      "tapp"      "/etc/tapp"      "/var/log/tapp"      ;;
        2) _do_uninstall "trojan-go" "trojan-go" "/etc/trojan-go" "/var/log/trojan-go" ;;
        *) log_error "Invalid choice." ;;
    esac
}

_do_uninstall() {
    local svc="$1" bin="$2" cfg="$3" logs="$4"
    log_step "Uninstalling $svc..."

    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
    rm -f "$INSTALL_DIR/$bin"
    rm -f "$INSTALL_DIR/${bin}.orig"
    rm -f "$INSTALL_DIR/tapp-run"

    # Nginx stream 子配置
    rm -f "${NGINX_STREAM_CONF_D}/${svc}-sni.conf"
    # Nginx http 子配置
    rm -f "${NGINX_CONF_D}/${svc}-web.conf"
    # 伪装站
    rm -rf "/var/www/${svc}-web"
    # 配置与日志
    rm -rf "$cfg" "$logs"

    systemctl daemon-reload
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    log_info "$svc removed. Nginx SNI rules cleaned."
}

# ==================== Main ====================
main() {
    print_banner
    check_root
    check_os
    parse_args "$@"

    [[ -z "$INSTALL_MODE" ]] && select_install_mode

    interactive_input
    confirm_config
    install_deps
    download_trojan_go
    patch_binary
    create_log_filter_wrapper
    install_acme
    issue_cert
    create_config
    configure_nginx
    create_service
    configure_firewall
    verify_install
    verify_patch
    print_result
}

main "$@"
