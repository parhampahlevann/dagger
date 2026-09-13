#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

BINARY="/usr/local/bin/DaggerConnect"
GITHUB_REPO="parhampahlevann/dagger"
LATEST_RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
CONFIG_DIR="/etc/DaggerConnect"
CONFIG=""
CONFIG_FMT=""
SERVICE_NAME=""
SERVICE_FILE=""
TRANSPORT=""
SSL_MODE=""
DOMAIN=""
CERT_FILE=""
KEY_FILE=""

_ts()   { date '+%H:%M:%S'; }
info()  { echo -e "${DIM}$(_ts)${NC} ${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${DIM}$(_ts)${NC} ${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${DIM}$(_ts)${NC} ${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${DIM}$(_ts)${NC} ${MAGENTA}[STEP]${NC}  $*"; }

error() { echo -e "${DIM}$(_ts)${NC} ${RED}[ERR ]${NC}  $*"; exit 1; }
hr()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

ask() {
    local var="$1" prompt="$2" default="$3"
    if [ -n "$default" ]; then
        echo -ne "${YELLOW}?${NC} $prompt [${default}]: "
    else
        echo -ne "${YELLOW}?${NC} $prompt: "
    fi
    read -r input
    [ -z "$input" ] && [ -n "$default" ] && input="$default"
    eval "$var=\"$input\""
}

ask_required() {
    local var="$1" prompt="$2"
    while true; do
        ask "$var" "$prompt" ""
        eval "local val=\$$var"
        [ -n "$val" ] && break
        warn "This field cannot be empty."
    done
}

validate_label() {
    echo "$1" | grep -qE '^[A-Za-z0-9_-]+$'
}

# Generates a short random, always-unique-enough tunnel/service name so the
# user can just press Enter instead of typing one (e.g. "dg-a1b2c3").
random_service_name() {
    local rnd
    rnd=$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6)
    [ -z "$rnd" ] && rnd=$((RANDOM % 900000 + 100000))
    echo "dg-${rnd}"
}

ask_service_name() {
    local svc_name svc_file suggested

    while true; do
        suggested="$(random_service_name)"
        ask LABEL "Service Name    (e.g. iran1, client-home, relay01)" "$suggested"
        if [ -z "$LABEL" ]; then
            warn "Service Name cannot be empty."
            continue
        fi
        if ! validate_label "$LABEL"; then
            warn "Only letters, numbers, - and _ are allowed."
            continue
        fi

        svc_name="${LABEL}"
        svc_file="/etc/systemd/system/${svc_name}.service"

        if [ -f "$svc_file" ] || \
           [ -f "${CONFIG_DIR}/${svc_name}.json" ] || \
           [ -f "${CONFIG_DIR}/${svc_name}.yaml" ]; then
            echo ""
            warn "Already exists: ${svc_name}"
            ask OVERWRITE "Overwrite? (y/n)" "n"
            if [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ]; then
                break
            fi
            info "Enter a different service name."
            echo ""
            continue
        fi

        break
    done

    while true; do
        ask FMT "Config Format   (json/yaml)" "json"
        case "$FMT" in
            json|yaml) break ;;
            *) warn "Please enter json or yaml." ;;
        esac
    done

    CONFIG_FMT="$FMT"
    SERVICE_NAME="${LABEL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.${CONFIG_FMT}"

    echo ""
    info "Service Name : ${SERVICE_NAME}"
    info "Config File  : ${CONFIG}"
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}Available Transports:${NC}"
    echo "    1)  tcp     — Raw TCP tunnel"
    echo "    2)  ws      — WebSocket tunnel"
    echo "    3)  wss     — WebSocket Secure (TLS) tunnel"
    echo "    4)  http    — HTTP Mimicry tunnel"
    echo "    5)  https   — HTTP Mimicry Secure (TLS) tunnel"
    echo "    6)  quantum — Raw-packet tunnel (KCP over forged TCP; auto NIC/IP/gateway)"
    echo "    7)  tun     — TUN kernel interface tunnel"
    echo ""
    while true; do
        ask T_CHOICE "Transport" "1"
        case "$T_CHOICE" in
            1|tcp)     TRANSPORT="tcp";     break ;;
            2|ws)      TRANSPORT="ws";      break ;;
            3|wss)     TRANSPORT="wss";     break ;;
            4|http)    TRANSPORT="http";    break ;;
            5|https)   TRANSPORT="https";   break ;;
            6|quantum) TRANSPORT="quantum"; break ;;
            7|tun)     TRANSPORT="tun";     break ;;
            *) warn "Please enter 1-7 or transport name." ;;
        esac
    done
    info "Transport : ${TRANSPORT}"
}

install_certbot() {
    if command -v certbot &>/dev/null; then
        ok "certbot already installed."
        return
    fi
    info "Installing certbot..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq certbot
    elif command -v yum &>/dev/null; then
        yum install -y -q certbot
    elif command -v dnf &>/dev/null; then
        dnf install -y -q certbot
    else
        error "Cannot install certbot — package manager not found. Install it manually."
    fi
    ok "certbot installed."
}

obtain_cert_auto() {
    local domain="$1"
    local cert_dir="/etc/letsencrypt/live/${domain}"

    install_certbot

    if ss -tlnp 2>/dev/null | grep -q ':80 '; then
        warn "Port 80 is in use. Trying --webroot or stopping may be needed."
        warn "Attempting standalone anyway (will fail if 80 is busy)."
    fi

    info "Obtaining SSL certificate for: ${domain}"
    if certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$domain" \
        --http-01-port 80 2>&1 | grep -E "Congratulations|Certificate|error|Error|failed|Failed"; then
        ok "Certificate obtained successfully."
    else
        error "certbot failed. Make sure port 80 is open and domain points to this server."
    fi

    CERT_FILE="${cert_dir}/fullchain.pem"
    KEY_FILE="${cert_dir}/privkey.pem"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        error "Certificate files not found at ${cert_dir}"
    fi

    ok "Cert : ${CERT_FILE}"
    ok "Key  : ${KEY_FILE}"

    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$hook_dir"
    cat > "${hook_dir}/daggerconnect-${SERVICE_NAME}.sh" << EOF
#!/bin/bash
systemctl restart ${SERVICE_NAME} 2>/dev/null || true
EOF
    chmod +x "${hook_dir}/daggerconnect-${SERVICE_NAME}.sh"
    ok "Auto-renew hook installed."
}

ask_ssl_server() {
    echo ""
    echo -e "  ${BOLD}SSL Mode:${NC}"
    echo "    1)  Automatic SSL  — Let's Encrypt (certbot)"
    echo "    2)  Custom SSL     — Provide your own cert/key paths"
    echo ""
    while true; do
        ask SSL_CHOICE "SSL Mode" "1"
        case "$SSL_CHOICE" in
            1|auto)   SSL_MODE="auto";   break ;;
            2|custom) SSL_MODE="custom"; break ;;
            *) warn "Please enter 1 (auto) or 2 (custom)." ;;
        esac
    done

    case "$SSL_MODE" in
        auto)
            echo ""
            ask_required DOMAIN "Domain name  (e.g. tunnel.example.com)"
            echo ""
            obtain_cert_auto "$DOMAIN"
            ;;
        custom)
            echo ""
            while true; do
                ask_required CERT_FILE "Certificate file path  (e.g. /etc/ssl/certs/cert.pem)"
                [ -f "$CERT_FILE" ] && break
                warn "File not found: ${CERT_FILE}"
            done
            while true; do
                ask_required KEY_FILE "Private key file path  (e.g. /etc/ssl/private/key.pem)"
                [ -f "$KEY_FILE" ] && break
                warn "File not found: ${KEY_FILE}"
            done
            echo ""
            ok "Cert : ${CERT_FILE}"
            ok "Key  : ${KEY_FILE}"
            ;;
    esac
}

ask_ssl_client() {
    echo ""
    echo -e "  ${BOLD}Server Certificate Verification:${NC}"
    echo "    1)  Verify  — Recommended (server has valid cert)"
    echo "    2)  Skip    — Skip TLS verification (self-signed)"
    echo ""
    while true; do
        ask TLS_CHOICE "TLS Verify" "1"
        case "$TLS_CHOICE" in
            1|verify) TLS_INSECURE="false"; break ;;
            2|skip)   TLS_INSECURE="true";  break ;;
            *) warn "Please enter 1 (verify) or 2 (skip)." ;;
        esac
    done
}

# Used during install_server/install_client: only cares whether a binary
# exists at all. Never touches an existing binary regardless of its version
# -- that's what the explicit "Update Core" menu action (download_binary)
# is for. If nothing is installed yet, asks before downloading rather than
# doing it silently.
ensure_binary() {
    if [ -f "$BINARY" ]; then
        chmod +x "$BINARY"
        return 0
    fi

    echo ""
    warn "No DaggerConnect binary found at ${BINARY}."
    ask DOWNLOAD_CHOICE "Download the latest release now? (y/n)" "y"
    if [ "$DOWNLOAD_CHOICE" != "y" ] && [ "$DOWNLOAD_CHOICE" != "Y" ]; then
        error "Cannot continue without a binary. Place one at ${BINARY} manually, or run this installer again and choose to download it."
    fi

    download_binary
}

download_binary() {
    echo ""
    step "Checking for the latest DaggerConnect release ..."

    RELEASE_JSON=$(curl -fsSL "$LATEST_RELEASE_API" 2>/dev/null)

    LATEST_VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    ZIP_URL=$(echo "$RELEASE_JSON" | grep '"browser_download_url":' | grep -Eo 'https://[^"]+\.zip' | head -1)

    if [ -z "$LATEST_VERSION" ] || [ -z "$ZIP_URL" ]; then
        warn "Could not reach GitHub or find a release asset."
        if [ -f "$BINARY" ]; then
            chmod +x "$BINARY"
            ok "Using existing local binary: ${BINARY}"
            return 0
        fi
        error "No local binary found and GitHub is unreachable. Cannot continue."
    fi

    info "Latest release : ${LATEST_VERSION}"
    info "Asset          : $(basename "$ZIP_URL")"

    CURRENT_VERSION=""
    if [ -f "$BINARY" ]; then
        chmod +x "$BINARY"
        CURRENT_VERSION=$("$BINARY" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    fi

    if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        ok "Already on the latest version (${CURRENT_VERSION})."
        return 0
    fi

    if [ -n "$CURRENT_VERSION" ]; then
        step "Updating DaggerConnect: ${CURRENT_VERSION} -> ${LATEST_VERSION} ..."
    else
        step "Downloading DaggerConnect ${LATEST_VERSION} ..."
    fi

    mkdir -p "$(dirname "$BINARY")"
    TMP_DIR=$(mktemp -d)
    ZIP_PATH="${TMP_DIR}/dagger.zip"

    [ -f "$BINARY" ] && cp "$BINARY" "${BINARY}.backup"

    if curl -fL --progress-bar "$ZIP_URL" -o "$ZIP_PATH"; then
        if ! command -v unzip &>/dev/null; then
            info "Installing unzip..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq unzip
            elif command -v yum &>/dev/null; then
                yum install -y -q unzip
            elif command -v dnf &>/dev/null; then
                dnf install -y -q unzip
            fi
        fi

        unzip -oq "$ZIP_PATH" -d "$TMP_DIR"

        # Search the whole archive tree (not just the top level) so a binary
        # placed inside a sub-folder by the release asset is still found,
        # instead of silently falling back to a stale local binary.
        EXTRACTED=$(find "$TMP_DIR" -type f -iname "DaggerConnect*" ! -name "*.zip" | head -1)
        [ -z "$EXTRACTED" ] && EXTRACTED=$(find "$TMP_DIR" -type f -perm -u+x ! -name "*.zip" | head -1)
        [ -z "$EXTRACTED" ] && EXTRACTED=$(find "$TMP_DIR" -type f ! -name "*.zip" | head -1)

        if [ -z "$EXTRACTED" ]; then
            warn "No binary found inside the downloaded zip."
            rm -rf "$TMP_DIR"
            [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY"
            return 1
        fi

        chmod +x "$EXTRACTED"
        if "$EXTRACTED" -v >/dev/null 2>&1; then
            mv -f "$EXTRACTED" "$BINARY"
            rm -f "${BINARY}.backup"
            rm -rf "$TMP_DIR"
            ok "DaggerConnect updated to ${LATEST_VERSION}."

            mapfile -t SERVICES < <(list_services)
            if [ ${#SERVICES[@]} -gt 0 ]; then
                echo ""
                warn "Running services are still using the old binary in memory until restarted."
                ask RESTART_CHOICE "Restart all DaggerConnect services now? (y/n)" "y"
                if [ "$RESTART_CHOICE" = "y" ] || [ "$RESTART_CHOICE" = "Y" ]; then
                    for svc in "${SERVICES[@]}"; do
                        systemctl restart "$svc" && ok "Restarted: ${svc}" || warn "Failed to restart: ${svc}"
                    done
                fi
            fi
        else
            warn "Downloaded binary failed to run -- keeping the previous version."
            rm -rf "$TMP_DIR"
            [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY"
        fi
    else
        rm -rf "$TMP_DIR"
        warn "Download failed."
        if [ -f "${BINARY}.backup" ]; then
            mv -f "${BINARY}.backup" "$BINARY"
            warn "Keeping existing binary."
        elif [ -f "$BINARY" ]; then
            ok "Using existing binary: ${BINARY}"
        else
            error "No binary available and download failed. Cannot continue."
        fi
    fi
}

ask_ports() {
    echo ""
    echo -e "  Ports to forward. One per line, or comma-separated. Empty line when done."
    echo -e "        Example : 22                   (bind :22 -> target :22)"
    echo -e "        Example : 2222=22              (bind :2222 -> target :22)"
    echo -e "        Example : 800,3005,4155,6550   (multiple at once)"
    PORTS=()
    while true; do
        ask P "Port" ""
        [ -z "$P" ] && break
        IFS="," read -ra _parts <<< "$P"
        for _p in "${_parts[@]}"; do
            _p="${_p// /}"
            [ -n "$_p" ] && PORTS+=("$_p")
        done
    done
    if [ ${#PORTS[@]} -eq 0 ]; then
        warn "No ports defined. Adding default 2222=22."
        PORTS=("2222=22")
    fi
}

build_ports_json() {
    local first=1
    for p in "$@"; do
        if [ "$first" = "1" ]; then
            printf '    "%s"' "$p"
            first=0
        else
            printf ',\n    "%s"' "$p"
        fi
    done
    echo ""
}

build_ports_yaml() {
    for p in "$@"; do
        printf '      - "%s"\n' "$p"
    done
}

SOCKS5_ENABLED="false"
SOCKS5_BIND=""

CLIENT_CONN_POOL="8"

ask_connection_pool() {
    echo ""
    echo -e "  ${BOLD}Connection Pool:${NC}"
    echo -e "        Multiple parallel connections per path -- if one drops, the"
    echo -e "        others keep traffic flowing while it reconnects."
    echo ""
    ask CLIENT_CONN_POOL "Connections per path" "8"
}

ask_socks5() {
    echo ""
    echo -e "  ${BOLD}Standalone SOCKS5 Proxy:${NC}"
    echo -e "        Independent of the transport and port maps above — opens a local"
    echo -e "        SOCKS5 proxy on this server whose traffic is tunneled to the client."
    echo ""
    ask SOCKS5_CHOICE "Enable SOCKS5 proxy? (y/n)" "n"
    if [ "$SOCKS5_CHOICE" = "y" ] || [ "$SOCKS5_CHOICE" = "Y" ]; then
        SOCKS5_ENABLED="true"
        ask SOCKS5_BIND "SOCKS5 bind address  (keep on 127.0.0.1 unless you add auth)" "127.0.0.1:6060"
    else
        SOCKS5_ENABLED="false"
        SOCKS5_BIND=""
    fi
}

ADV_AUTO_TUNE="true"
ADV_PROFILE="auto"
ADV_TCP_KEEPALIVE="1"
ADV_CONN_TIMEOUT="30"
ADV_SESSION_TIMEOUT="60"
ADV_CLEANUP_INTERVAL="3"
ADV_TCP_READ_BUF="4194304"
ADV_TCP_WRITE_BUF="4194304"
ADV_UDP_BUF="4194304"
ADV_CHANNEL_BACKLOG="4096"
ADV_STREAM_CHAN_BUF="512"

apply_profile() {
    local p="$1"
    ADV_PROFILE="$p"
    case "$p" in
        stable)
            ADV_TCP_READ_BUF="4194304"   ADV_TCP_WRITE_BUF="4194304"
            ADV_UDP_BUF="4194304"
            ADV_CHANNEL_BACKLOG="4096"   ADV_STREAM_CHAN_BUF="512"
            ADV_TCP_KEEPALIVE="1"        ADV_CONN_TIMEOUT="30"
            ADV_SESSION_TIMEOUT="60"     ADV_CLEANUP_INTERVAL="3"
            ADV_KEEPALIVE_SEC="20"       ADV_DEAD_TIMEOUT_SEC="60"
            ;;
        aggressive)
            ADV_TCP_READ_BUF="16777216"  ADV_TCP_WRITE_BUF="16777216"
            ADV_UDP_BUF="16777216"
            ADV_CHANNEL_BACKLOG="8192"   ADV_STREAM_CHAN_BUF="2048"
            ADV_TCP_KEEPALIVE="1"        ADV_CONN_TIMEOUT="60"
            ADV_SESSION_TIMEOUT="120"    ADV_CLEANUP_INTERVAL="5"
            ADV_KEEPALIVE_SEC="20"       ADV_DEAD_TIMEOUT_SEC="80"
            ;;
        low_latency)
            ADV_TCP_READ_BUF="2097152"   ADV_TCP_WRITE_BUF="2097152"
            ADV_UDP_BUF="2097152"
            ADV_CHANNEL_BACKLOG="2048"   ADV_STREAM_CHAN_BUF="256"
            ADV_TCP_KEEPALIVE="1"        ADV_CONN_TIMEOUT="15"
            ADV_SESSION_TIMEOUT="30"     ADV_CLEANUP_INTERVAL="2"
            ADV_KEEPALIVE_SEC="10"       ADV_DEAD_TIMEOUT_SEC="30"
            ;;
        low_hardware)
            ADV_TCP_READ_BUF="524288"    ADV_TCP_WRITE_BUF="524288"
            ADV_UDP_BUF="524288"
            ADV_CHANNEL_BACKLOG="512"    ADV_STREAM_CHAN_BUF="128"
            ADV_TCP_KEEPALIVE="5"        ADV_CONN_TIMEOUT="20"
            ADV_SESSION_TIMEOUT="45"     ADV_CLEANUP_INTERVAL="3"
            ADV_KEEPALIVE_SEC="30"       ADV_DEAD_TIMEOUT_SEC="90"
            ;;
    esac
}

ask_advanced() {
    echo ""
    echo -e "  ${BOLD}Tuner Mode:${NC}"
    echo "    1)  auto         — Adaptive auto-tuner (recommended)"
    echo "    2)  stable       — Balanced, reliable for most setups"
    echo "    3)  aggressive   — Max throughput, high memory usage"
    echo "    4)  low_latency  — Minimum delay, small buffers"
    echo "    5)  low_hardware — Weak VPS / low RAM"
    echo "    6)  custom       — Set every value manually"
    echo ""
    ask ADV_CHOICE "Tuner Mode" "1"
    echo ""
    case "$ADV_CHOICE" in
        1|auto)
            ADV_AUTO_TUNE="true"
            apply_profile "stable"
            ;;
        2|stable)
            ADV_AUTO_TUNE="false"
            apply_profile "stable"
            ;;
        3|aggressive)
            ADV_AUTO_TUNE="false"
            apply_profile "aggressive"
            ;;
        4|low_latency)
            ADV_AUTO_TUNE="false"
            apply_profile "low_latency"
            ;;
        5|low_hardware)
            ADV_AUTO_TUNE="false"
            apply_profile "low_hardware"
            ;;
        6|custom)
            ADV_AUTO_TUNE="false"
            ADV_PROFILE="custom"
            echo -e "  ${BOLD}Timeouts & Intervals:${NC}"
            ask ADV_TCP_KEEPALIVE    "tcp_keepalive       (sec)"    "1"
            ask ADV_CONN_TIMEOUT     "connection_timeout  (sec)"    "30"
            ask ADV_SESSION_TIMEOUT  "session_timeout     (sec)"    "60"
            ask ADV_CLEANUP_INTERVAL "cleanup_interval    (sec)"    "3"
            echo ""
            echo -e "  ${BOLD}Heartbeat  (session-level keepalive, all transports except tun):${NC}"
            ask ADV_KEEPALIVE_SEC    "keepalive_sec       (sec)"    "20"
            ask ADV_DEAD_TIMEOUT_SEC "dead_timeout_sec    (sec)"    "60"
            echo ""
            echo -e "  ${BOLD}Buffers  (bytes, e.g. 4194304 = 4MB):${NC}"
            ask ADV_TCP_READ_BUF     "tcp_read_buffer     (bytes)"  "4194304"
            ask ADV_TCP_WRITE_BUF    "tcp_write_buffer    (bytes)"  "4194304"
            ask ADV_UDP_BUF          "udp_buffer_size     (bytes)"  "4194304"
            echo ""
            echo -e "  ${BOLD}Channel / Stream sizes:${NC}"
            ask ADV_CHANNEL_BACKLOG  "channel_backlog     (count)"  "4096"
            ask ADV_STREAM_CHAN_BUF  "stream_chan_buf     (count)"  "512"
            ;;
        *)
            ADV_AUTO_TUNE="true"
            apply_profile "stable"
            ;;
    esac
    info "Tuner Profile : ${ADV_PROFILE}$([ "$ADV_AUTO_TUNE" = "true" ] && echo " (adaptive)" || echo " (fixed)")"
}

build_healthcheck_json_server() {
    printf '  "health_check": {\n    "enabled": true,\n    "port": 5550,\n    "interval_sec": 3,\n    "timeout_ms": 3000,\n    "max_consecutive_fails": 3\n  },\n'
}

build_healthcheck_json_client() {
    printf '  "health_check": {\n    "enabled": true,\n    "interval_sec": 3,\n    "timeout_ms": 3000,\n    "max_consecutive_fails": 3\n  },\n'
}

build_healthcheck_yaml_server() {
    printf "health_check:\n  enabled: true\n  port: 5550\n  interval_sec: 3\n  timeout_ms: 3000\n  max_consecutive_fails: 3\n\n"
}

build_healthcheck_yaml_client() {
    printf "health_check:\n  enabled: true\n  interval_sec: 3\n  timeout_ms: 3000\n  max_consecutive_fails: 3\n\n"
}

build_advanced_json() {
    printf '  "advanced": {\n'
    printf '    "auto_tune": %s,\n'          "$ADV_AUTO_TUNE"
    printf '    "tcp_nodelay": true,\n'
    printf '    "tcp_keepalive": %s,\n'      "$ADV_TCP_KEEPALIVE"
    printf '    "connection_timeout": %s,\n' "$ADV_CONN_TIMEOUT"
    printf '    "session_timeout": %s,\n'    "$ADV_SESSION_TIMEOUT"
    printf '    "cleanup_interval": %s,\n'   "$ADV_CLEANUP_INTERVAL"
    printf '    "tcp_read_buffer": %s,\n'    "$ADV_TCP_READ_BUF"
    printf '    "tcp_write_buffer": %s,\n'   "$ADV_TCP_WRITE_BUF"
    printf '    "udp_buffer_size": %s,\n'    "$ADV_UDP_BUF"
    printf '    "channel_backlog": %s,\n'    "$ADV_CHANNEL_BACKLOG"
    printf '    "stream_chan_buf": %s,\n'      "$ADV_STREAM_CHAN_BUF"
    printf '    "keepalive_sec": %s,\n'      "$ADV_KEEPALIVE_SEC"
    printf '    "dead_timeout_sec": %s\n'   "$ADV_DEAD_TIMEOUT_SEC"
    printf '  }'
}

build_socks5_json() {
    printf '  "socks5": {\n    "enabled": %s,\n    "bind": "%s"\n  },\n' "$SOCKS5_ENABLED" "$SOCKS5_BIND"
}

build_socks5_yaml() {
    printf "socks5:\n  enabled: %s\n  bind: \"%s\"\n\n" "$SOCKS5_ENABLED" "$SOCKS5_BIND"
}

build_advanced_yaml() {
    printf "advanced:\n"
    printf "  auto_tune: %s\n"          "$ADV_AUTO_TUNE"
    printf "  tcp_nodelay: true\n"
    printf "  tcp_keepalive: %s\n"      "$ADV_TCP_KEEPALIVE"
    printf "  connection_timeout: %s\n" "$ADV_CONN_TIMEOUT"
    printf "  session_timeout: %s\n"    "$ADV_SESSION_TIMEOUT"
    printf "  cleanup_interval: %s\n"   "$ADV_CLEANUP_INTERVAL"
    printf "  tcp_read_buffer: %s\n"    "$ADV_TCP_READ_BUF"
    printf "  tcp_write_buffer: %s\n"   "$ADV_TCP_WRITE_BUF"
    printf "  udp_buffer_size: %s\n"    "$ADV_UDP_BUF"
    printf "  channel_backlog: %s\n"    "$ADV_CHANNEL_BACKLOG"
    printf "  stream_chan_buf: %s\n"     "$ADV_STREAM_CHAN_BUF"
    printf "  keepalive_sec: %s\n"     "$ADV_KEEPALIVE_SEC"
    printf "  dead_timeout_sec: %s\n"  "$ADV_DEAD_TIMEOUT_SEC"
}

write_server_config_tcp() {
    local port="$1" psk="$2"
    shift 2
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "server",\n  "transport": "tcp",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "tcp",\n      "ports": [\n%s\n      ]\n    }\n  ],\n' "$psk" "$port" "$ports_json"; build_healthcheck_json_server; build_socks5_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: server\ntransport: tcp\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: tcp\n    ports:\n%s\n' "$psk" "$port" "$ports_yaml"; build_healthcheck_yaml_server; build_socks5_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_tcp() {
    local server_ip="$1" server_port="$2" psk="$3"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "client",\n  "transport": "tcp",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "tcp",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_healthcheck_json_client; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: client\ntransport: tcp\npsk: "%s"\nlog_level: info\npaths:\n  - transport: tcp\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_healthcheck_yaml_client; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_ws() {
    local port="$1" psk="$2" ws_path="$3"
    shift 3
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "server",\n  "transport": "ws",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "ws",\n      "ports": [\n%s\n      ]\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$ws_path"; build_healthcheck_json_server; build_socks5_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: server\ntransport: ws\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: ws\n    ports:\n%s\nws_settings:\n  path: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$ws_path"; build_healthcheck_yaml_server; build_socks5_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_ws() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "client",\n  "transport": "ws",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "ws",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_healthcheck_json_client; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: client\ntransport: ws\npsk: "%s"\nlog_level: info\npaths:\n  - transport: ws\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nws_settings:\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_healthcheck_yaml_client; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_wss() {
    local port="$1" psk="$2" ws_path="$3" cert="$4" key="$5"
    shift 5
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "server",\n  "transport": "wss",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "wss",\n      "cert_file": "%s",\n      "key_file": "%s",\n      "ports": [\n%s\n      ]\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$port" "$cert" "$key" "$ports_json" "$ws_path"; build_healthcheck_json_server; build_socks5_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: server\ntransport: wss\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: wss\n    cert_file: "%s"\n    key_file: "%s"\n    ports:\n%s\nws_settings:\n  path: "%s"\n\n' "$psk" "$port" "$cert" "$key" "$ports_yaml" "$ws_path"; build_healthcheck_yaml_server; build_socks5_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_wss() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4" tls_insecure="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "client",\n  "transport": "wss",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "wss",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n  "tls_insecure": %s,\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path" "$tls_insecure"; build_healthcheck_json_client; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: client\ntransport: wss\npsk: "%s"\nlog_level: info\npaths:\n  - transport: wss\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nws_settings:\n  path: "%s"\n\ntls_insecure: %s\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path" "$tls_insecure"; build_healthcheck_yaml_client; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_http() {
    local port="$1" psk="$2" http_domain="$3" http_path="$4"
    shift 4
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "server",\n  "transport": "http",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "http",\n      "ports": [\n%s\n      ]\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$http_domain" "$http_path"; build_healthcheck_json_server; build_socks5_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: server\ntransport: http\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: http\n    ports:\n%s\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$http_domain" "$http_path"; build_healthcheck_yaml_server; build_socks5_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_https() {
    local port="$1" psk="$2" http_domain="$3" http_path="$4" cert="$5" key="$6"
    shift 6
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "server",\n  "transport": "https",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "https",\n      "cert_file": "%s",\n      "key_file": "%s",\n      "ports": [\n%s\n      ]\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$port" "$cert" "$key" "$ports_json" "$http_domain" "$http_path"; build_healthcheck_json_server; build_socks5_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: server\ntransport: https\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: https\n    cert_file: "%s"\n    key_file: "%s"\n    ports:\n%s\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$port" "$cert" "$key" "$ports_yaml" "$http_domain" "$http_path"; build_healthcheck_yaml_server; build_socks5_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_https() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5" tls_insecure="$6"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "client",\n  "transport": "https",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "https",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n  "tls_insecure": %s,\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path" "$tls_insecure"; build_healthcheck_json_client; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: client\ntransport: https\npsk: "%s"\nlog_level: info\npaths:\n  - transport: https\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\ntls_insecure: %s\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path" "$tls_insecure"; build_healthcheck_yaml_client; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_quantum() {
    local port="$1" psk="$2" mtu="$3" block="$4"
    shift 4
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "server",\n  "transport": "quantum",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "quantum",\n      "ports": [\n%s\n      ]\n    }\n  ],\n  "quantum": {\n    "mtu": %s,\n    "block": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$mtu" "$block"; build_healthcheck_json_server; build_socks5_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: server\ntransport: quantum\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: quantum\n    ports:\n%s\nquantum:\n  mtu: %s\n  block: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$mtu" "$block"; build_healthcheck_yaml_server; build_socks5_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_quantum() {
    local server_ip="$1" server_port="$2" psk="$3" mtu="$4" block="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "client",\n  "transport": "quantum",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "quantum",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "quantum": {\n    "mtu": %s,\n    "block": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$mtu" "$block"; build_healthcheck_json_client; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: client\ntransport: quantum\npsk: "%s"\nlog_level: info\npaths:\n  - transport: quantum\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nquantum:\n  mtu: %s\n  block: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$mtu" "$block"; build_healthcheck_yaml_client; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_http() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {         printf '{\n  "mode": "client",\n  "transport": "http",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "http",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_healthcheck_json_client; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {         printf 'mode: client\ntransport: http\npsk: "%s"\nlog_level: info\npaths:\n  - transport: http\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_healthcheck_yaml_client; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_tun() {
    local port="$1" psk="$2" listen_ip="$3" dst_ip="$4" local_addr="$5" remote_addr="$6"
    local encap="$7" profile="$8" iface="$9" spoof_src="${10}" spoof_dst="${11}" dcpi="${12}" tun_name="${13}"
    local heartbeat_sec="${14}" idle_timeout_sec="${15}"
    shift 15
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    [ -z "$tun_name" ] && tun_name="dagger0"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {
            printf '{\n'
            printf '  "mode": "server",\n'
            printf '  "transport": "tun",\n'
            printf '  "psk": "%s",\n'       "$psk"
            printf '  "log_level": "info",\n'
            printf '  "listeners": [\n'
            printf '    {\n'
            printf '      "addr": "0.0.0.0:%s",\n' "$port"
            printf '      "transport": "tun",\n'
            printf '      "ports": [\n'
            printf '%s\n'                   "$ports_json"
            printf '      ]\n'
            printf '    }\n'
            printf '  ],\n'
            printf '  "tun": {\n'
            printf '    "encapsulation": "%s",\n' "$encap"
            printf '    "name": "%s",\n'           "$tun_name"
            printf '    "local_addr": "%s",\n'     "$local_addr"
            printf '    "remote_addr": "%s",\n'    "$remote_addr"
            printf '    "mtu": 1420,\n'
            printf '    "heartbeat_sec": %s,\n' "$heartbeat_sec"
            printf '    "idle_timeout_sec": %s\n' "$idle_timeout_sec"
            printf '  },\n'
            printf '  "ipx": {\n'
            printf '    "mode": "server",\n'
            printf '    "profile": "%s",\n'        "$profile"
            printf '    "listen_ip": "%s",\n'      "$listen_ip"
            printf '    "dst_ip": "%s",\n'         "$dst_ip"
            [ -n "$iface"     ] && printf '    "interface": "%s",\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '    "dcpi_mode": true,\n'
            [ -n "$spoof_src" ] && printf '    "spoof_src_ip": "%s",\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '    "spoof_dst_ip": "%s",\n' "$spoof_dst"
            printf '    "sock_buf": 4194304\n'
            printf '  },\n'
            build_socks5_json
            build_advanced_json
            printf '}\n'
        } > "$CONFIG"
    else
        {
            printf 'mode: server\n'
            printf 'transport: tun\n'
            printf 'psk: "%s"\n'        "$psk"
            printf 'log_level: info\n'
            printf 'listeners:\n'
            printf '  - addr: "0.0.0.0:%s"\n' "$port"
            printf '    transport: tun\n'
            printf '    ports:\n'
            printf '%s\n'               "$ports_yaml"
            printf 'tun:\n'
            printf '  encapsulation: "%s"\n' "$encap"
            printf '  name: "%s"\n'          "$tun_name"
            printf '  local_addr: "%s"\n'    "$local_addr"
            printf '  remote_addr: "%s"\n'   "$remote_addr"
            printf '  mtu: 1420\n'
            printf '  heartbeat_sec: %s\n' "$heartbeat_sec"
            printf '  idle_timeout_sec: %s\n\n' "$idle_timeout_sec"
            printf 'ipx:\n'
            printf '  mode: server\n'
            printf '  profile: "%s"\n'       "$profile"
            printf '  listen_ip: "%s"\n'     "$listen_ip"
            printf '  dst_ip: "%s"\n'        "$dst_ip"
            [ -n "$iface"     ] && printf '  interface: "%s"\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '  dcpi_mode: true\n'
            [ -n "$spoof_src" ] && printf '  spoof_src_ip: "%s"\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '  spoof_dst_ip: "%s"\n' "$spoof_dst"
            printf '  sock_buf: 4194304\n\n'
            build_socks5_yaml
            build_advanced_yaml
        } > "$CONFIG"
    fi
}

write_client_config_tun() {
    local server_port="$1" psk="$2" listen_ip="$3" dst_ip="$4" local_addr="$5" remote_addr="$6"
    local encap="$7" profile="$8" iface="$9" spoof_src="${10}" spoof_dst="${11}" dcpi="${12}" tun_name="${13}"
    local heartbeat_sec="${14}" idle_timeout_sec="${15}"
    [ -z "$tun_name" ] && tun_name="dagger0"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {
            printf '{\n'
            printf '  "mode": "client",\n'
            printf '  "transport": "tun",\n'
            printf '  "psk": "%s",\n'        "$psk"
            printf '  "log_level": "info",\n'
            printf '  "paths": [\n'
            printf '    {\n'
            printf '      "transport": "tun",\n'
            printf '      "addr": "%s:%s",\n' "$dst_ip" "$server_port"

            printf '      "retry_interval": 3,\n'
            printf '      "dial_timeout": 30\n'
            printf '    }\n'
            printf '  ],\n'
            printf '  "tun": {\n'
            printf '    "encapsulation": "%s",\n' "$encap"
            printf '    "name": "%s",\n'           "$tun_name"
            printf '    "local_addr": "%s",\n'     "$local_addr"
            printf '    "remote_addr": "%s",\n'    "$remote_addr"
            printf '    "mtu": 1420,\n'
            printf '    "heartbeat_sec": %s,\n' "$heartbeat_sec"
            printf '    "idle_timeout_sec": %s\n' "$idle_timeout_sec"
            printf '  },\n'
            printf '  "ipx": {\n'
            printf '    "mode": "client",\n'
            printf '    "profile": "%s",\n'        "$profile"
            printf '    "listen_ip": "%s",\n'      "$listen_ip"
            printf '    "dst_ip": "%s",\n'         "$dst_ip"
            [ -n "$iface"     ] && printf '    "interface": "%s",\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '    "dcpi_mode": true,\n'
            [ -n "$spoof_src" ] && printf '    "spoof_src_ip": "%s",\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '    "spoof_dst_ip": "%s",\n' "$spoof_dst"
            printf '    "sock_buf": 4194304\n'
            printf '  },\n'
            build_advanced_json
            printf '}\n'
        } > "$CONFIG"
    else
        {
            printf 'mode: client\n'
            printf 'transport: tun\n'
            printf 'psk: "%s"\n'         "$psk"
            printf 'log_level: info\n'
            printf 'paths:\n'
            printf '  - transport: tun\n'
            printf '    addr: "%s:%s"\n' "$dst_ip" "$server_port"

            printf '    retry_interval: 3\n'
            printf '    dial_timeout: 30\n\n'
            printf 'tun:\n'
            printf '  encapsulation: "%s"\n' "$encap"
            printf '  name: "%s"\n'          "$tun_name"
            printf '  local_addr: "%s"\n'    "$local_addr"
            printf '  remote_addr: "%s"\n'   "$remote_addr"
            printf '  mtu: 1420\n'
            printf '  heartbeat_sec: %s\n' "$heartbeat_sec"
            printf '  idle_timeout_sec: %s\n\n' "$idle_timeout_sec"
            printf 'ipx:\n'
            printf '  mode: client\n'
            printf '  profile: "%s"\n'       "$profile"
            printf '  listen_ip: "%s"\n'     "$listen_ip"
            printf '  dst_ip: "%s"\n'        "$dst_ip"
            [ -n "$iface"     ] && printf '  interface: "%s"\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '  dcpi_mode: true\n'
            [ -n "$spoof_src" ] && printf '  spoof_src_ip: "%s"\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '  spoof_dst_ip: "%s"\n' "$spoof_dst"
            printf '  sock_buf: 4194304\n\n'
            build_advanced_yaml
        } > "$CONFIG"
    fi
}

install_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Tunnel (${SERVICE_NAME})
After=network.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${BINARY} -c ${CONFIG}
Restart=always
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-500
StandardOutput=journal
StandardError=journal
SyslogIdentifier=DaggerConnect

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    ok "Service installed: ${SERVICE_NAME}"
    install_watchdog "$SERVICE_NAME"
}

start_service() {
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Service is running."
    else
        warn "Service failed to start. Logs:"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    fi
}

WATCHDOG_BIN="/usr/local/bin/dagger-watchdog.sh"
WATCHDOG_SERVICE_TMPL="/etc/systemd/system/dagger-watchdog@.service"
WATCHDOG_TIMER_TMPL="/etc/systemd/system/dagger-watchdog@.timer"

# Writes the watchdog script + systemd templates once. Safe to call every
# time; it only rewrites the shared files, never touches per-tunnel state.
write_watchdog_files() {
    mkdir -p "$(dirname "$WATCHDOG_BIN")"
    cat > "$WATCHDOG_BIN" << 'WDEOF'
#!/bin/bash
# DaggerConnect Watchdog — runs every ~15s per installed tunnel.
# Detects: crashed service, server not listening, client unable to reach
# server, and error storms in the logs. Restarts the tunnel automatically
# so a connection never stays down or degraded for long.

SVC="$1"
[ -z "$SVC" ] && exit 0
CONFIG_DIR="/etc/DaggerConnect"
TAG="dagger-watchdog[$SVC]"
FAIL_FILE="/run/dagger-watchdog-${SVC}.fails"

log() { logger -t "$TAG" "$1"; }

restart_and_exit() {
    log "$1 -- restarting ${SVC}"
    systemctl restart "$SVC" 2>/dev/null
    rm -f "$FAIL_FILE"
    exit 0
}

# 1) Is the unit even active?
if ! systemctl is-active --quiet "$SVC"; then
    restart_and_exit "Service is not active"
fi

SVC_BASE="${SVC%.service}"
CFG=""
[ -f "${CONFIG_DIR}/${SVC_BASE}.json" ] && CFG="${CONFIG_DIR}/${SVC_BASE}.json"
[ -f "${CONFIG_DIR}/${SVC_BASE}.yaml" ] && CFG="${CONFIG_DIR}/${SVC_BASE}.yaml"
[ -f "$CFG" ] || exit 0

MODE=$(grep -m1 -Eo '"mode"[[:space:]]*:[[:space:]]*"[a-z]+"|^mode:[[:space:]]*[a-z]+' "$CFG" | grep -oE '[a-z]+' | tail -1)

# 2) Transport-aware reachability check.
if [ "$MODE" = "server" ]; then
    PORT=$(grep -m1 -Eo '"0\.0\.0\.0:[0-9]+"|0\.0\.0\.0:[0-9]+' "$CFG" | grep -oE '[0-9]+' | tail -1)
    if [ -n "$PORT" ] && command -v ss >/dev/null 2>&1; then
        if ! ss -ltn 2>/dev/null | grep -q ":${PORT}[[:space:]]" && ! ss -lun 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
            restart_and_exit "Server not listening on port ${PORT}"
        fi
    fi
elif [ "$MODE" = "client" ]; then
    ADDR=$(grep -m1 -Eo '"addr"[[:space:]]*:[[:space:]]*"[0-9a-zA-Z.\-]+:[0-9]+"|addr:[[:space:]]*"[0-9a-zA-Z.\-]+:[0-9]+"' "$CFG" | grep -oE '[0-9a-zA-Z.\-]+:[0-9]+' | head -1)
    if [ -n "$ADDR" ]; then
        HOST="${ADDR%:*}"
        PRT="${ADDR##*:}"
        if timeout 3 bash -c "exec 9<>/dev/tcp/${HOST}/${PRT}" 2>/dev/null; then
            exec 9>&- 2>/dev/null
            echo 0 > "$FAIL_FILE"
        else
            COUNT=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
            echo "$COUNT" > "$FAIL_FILE"
            if [ "$COUNT" -ge 2 ]; then
                restart_and_exit "Cannot reach server ${ADDR} (x${COUNT})"
            fi
        fi
    fi
fi

# 3) Error-storm detection in the recent journal (covers transports where a
#    reachability probe alone can't tell a stuck/half-open session apart).
ERR_COUNT=$(journalctl -u "$SVC" --since "-20 sec" 2>/dev/null | grep -Eic "panic|fatal|connection refused|broken pipe|i/o timeout|reset by peer|handshake failed")
if [ "$ERR_COUNT" -ge 6 ]; then
    restart_and_exit "High error rate in logs (${ERR_COUNT} in 20s)"
fi

exit 0
WDEOF
    chmod +x "$WATCHDOG_BIN"

    cat > "$WATCHDOG_SERVICE_TMPL" << 'EOF'
[Unit]
Description=DaggerConnect Watchdog check for %i

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dagger-watchdog.sh %i
EOF

    cat > "$WATCHDOG_TIMER_TMPL" << 'EOF'
[Unit]
Description=Run the DaggerConnect Watchdog for %i every 15s

[Timer]
OnBootSec=30
OnUnitActiveSec=15
AccuracySec=1
Persistent=false

[Install]
WantedBy=timers.target
EOF
}

# Enables the watchdog timer instance for one tunnel service. Called
# automatically right after every install (server or client), for every
# transport, so no protocol is left unmonitored.
install_watchdog() {
    local svc_name="$1"
    [ -z "$svc_name" ] && return 0
    write_watchdog_files
    systemctl daemon-reload
    systemctl enable --now "dagger-watchdog@${svc_name}.timer" > /dev/null 2>&1
    ok "Watchdog armed for: ${svc_name}  (checks every 15s)"
}

remove_watchdog() {
    local svc_name="$1"
    [ -z "$svc_name" ] && return 0
    systemctl disable --now "dagger-watchdog@${svc_name}.timer" > /dev/null 2>&1
    systemctl stop "dagger-watchdog@${svc_name}.service" > /dev/null 2>&1
    rm -f "/run/dagger-watchdog-${svc_name}.service.fails" 2>/dev/null
}

list_services() {
    local found=()
    for cfg in "${CONFIG_DIR}"/*.json "${CONFIG_DIR}"/*.yaml; do
        [ -f "$cfg" ] || continue
        local name
        name=$(basename "$cfg")
        name="${name%.*}"
        [ -f "/etc/systemd/system/${name}.service" ] && found+=("${name}.service")
    done
    [ ${#found[@]} -eq 0 ] && return 0
    printf '%s\n' "${found[@]}" | sort -u
}

install_server() {
    hr "Install Server"
    ensure_binary
    echo ""

    ask_service_name
    echo ""

    ask_transport
    echo ""

    ask PORT "Listen port" "8443"
    echo ""

    ask PSK "PSK  (must match client)" "123"
    echo ""

    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket path" "/ws"
            echo ""
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain  (e.g. www.google.com)" "www.google.com"
            ask HTTP_PATH   "Fake path    (e.g. /search)" "/search"
            echo ""
            ;;
        quantum)
            echo -e "  ${DIM}Quantum auto-detects the network interface, source IP, and${NC}"
            echo -e "  ${DIM}gateway MAC at runtime — nothing to configure for those.${NC}"
            echo ""
            ask QM_MTU   "MTU" "1350"
            ask QM_BLOCK "KCP header cipher  (aes/salsa20/none)" "aes"
            echo ""
            ;;
        tun)
            echo ""
            echo -e "  ${BOLD}TUN Encapsulation:${NC}"
            echo "    1)  tcp   — plain TCP over TUN"
            echo "    2)  ipx   — raw IP encapsulation (icmp/gre/ipip/bip)"
            echo ""
            ask TUN_ENCAP_CHOICE "Encapsulation" "1"
            case "$TUN_ENCAP_CHOICE" in
                2|ipx) TUN_ENCAP="ipx" ;;
                *)     TUN_ENCAP="tcp" ;;
            esac

            if [ "$TUN_ENCAP" = "ipx" ]; then
                echo ""
                echo -e "  ${BOLD}IPX Profile:${NC}"
                echo "    1)  icmp  — ICMP encapsulation"
                echo "    2)  gre   — GRE (proto 47)"
                echo "    3)  ipip  — IP-in-IP (proto 4)"
                echo "    4)  bip   — BIP/ICMP custom"
                echo ""
                ask TUN_PROFILE_CHOICE "Profile" "1"
                case "$TUN_PROFILE_CHOICE" in
                    2|gre)  TUN_PROFILE="gre"  ;;
                    3|ipip) TUN_PROFILE="ipip" ;;
                    4|bip)  TUN_PROFILE="bip"  ;;
                    *)      TUN_PROFILE="icmp" ;;
                esac
            else
                TUN_PROFILE="icmp"
            fi
            echo ""
            info "TUN : encapsulation=${TUN_ENCAP}  profile=${TUN_PROFILE}"
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Server real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Client real IP"
            echo ""
            ask TUN_LOCAL_ADDR  "TUN local IP   (server side, any IP)" "10.0.0.1"
            ask TUN_REMOTE_ADDR "TUN remote IP  (client side, any IP)" "10.0.0.2"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface  (leave empty for auto-detect)" ""
            ask TUN_NAME  "TUN device name" "dagger0"
            echo ""
            ask TUN_HEARTBEAT_SEC    "Heartbeat interval (sec)  -- lower = faster failure detection" "5"
            ask TUN_IDLE_TIMEOUT_SEC "Idle timeout (sec)  -- how long with no traffic before reconnecting" "40"
            echo ""
            ask TUN_SPOOF_CHOICE "Enable IP Spoof (y/n)" "n"
            if [ "$TUN_SPOOF_CHOICE" = "y" ] || [ "$TUN_SPOOF_CHOICE" = "Y" ]; then
                ask TUN_SPOOF_SRC "Spoof Source IP" ""
                ask TUN_SPOOF_DST "Spoof Dest IP  " ""
            else
                TUN_SPOOF_SRC="" TUN_SPOOF_DST=""
            fi
            echo ""
            ask TUN_DCPI_CHOICE "Enable DCPI Mode  (ICMPv6/proto58) (y/n)" "n"
            [ "$TUN_DCPI_CHOICE" = "y" ] || [ "$TUN_DCPI_CHOICE" = "Y" ] && TUN_DCPI="yes" || TUN_DCPI="no"
            echo ""
            ;;
    esac

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "https" ]; then
        ask_ssl_server
        echo ""
    fi

    ask_ports
    echo ""

    ask_socks5
    echo ""

    ask_advanced
    echo ""

    case "$TRANSPORT" in
        tcp)     write_server_config_tcp     "$PORT" "$PSK" "${PORTS[@]}" ;;
        ws)      write_server_config_ws      "$PORT" "$PSK" "$WS_PATH" "${PORTS[@]}" ;;
        wss)     write_server_config_wss     "$PORT" "$PSK" "$WS_PATH" "$CERT_FILE" "$KEY_FILE" "${PORTS[@]}" ;;
        http)    write_server_config_http    "$PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "${PORTS[@]}" ;;
        https)   write_server_config_https   "$PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "$CERT_FILE" "$KEY_FILE" "${PORTS[@]}" ;;
        quantum) write_server_config_quantum "$PORT" "$PSK" "$QM_MTU" "$QM_BLOCK" "${PORTS[@]}" ;;
        tun)     write_server_config_tun     "$PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_ENCAP" "$TUN_PROFILE" "$TUN_IFACE" "$TUN_SPOOF_SRC" "$TUN_SPOOF_DST" "$TUN_DCPI" "$TUN_NAME" "$TUN_HEARTBEAT_SEC" "$TUN_IDLE_TIMEOUT_SEC" "${PORTS[@]}" ;;
    esac
    ok "Config written: ${CONFIG}"

    install_service
    start_service

    echo ""
    echo -e "${GREEN}${BOLD}  Server installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Port      : ${BOLD}${PORT}${NC}"
    echo -e "  PSK       : ${BOLD}${PSK}${NC}"
    [ "$TRANSPORT" = "ws"  ] && echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
    if [ "$TRANSPORT" = "wss" ]; then
        echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
        echo -e "  SSL Mode  : ${BOLD}${SSL_MODE}${NC}"
        [ "$SSL_MODE" = "auto" ] && echo -e "  Domain    : ${BOLD}${DOMAIN}${NC}"
        echo -e "  Cert      : ${BOLD}${CERT_FILE}${NC}"
        echo -e "  Key       : ${BOLD}${KEY_FILE}${NC}"
    fi
    if [ "$TRANSPORT" = "http" ]; then
        echo -e "  Fake Domain : ${BOLD}${HTTP_DOMAIN}${NC}"
        echo -e "  Fake Path   : ${BOLD}${HTTP_PATH}${NC}"
    fi
    if [ "$TRANSPORT" = "https" ]; then
        echo -e "  Fake Domain : ${BOLD}${HTTP_DOMAIN}${NC}"
        echo -e "  Fake Path   : ${BOLD}${HTTP_PATH}${NC}"
        echo -e "  SSL Mode    : ${BOLD}${SSL_MODE}${NC}"
        [ "$SSL_MODE" = "auto" ] && echo -e "  Domain      : ${BOLD}${DOMAIN}${NC}"
        echo -e "  Cert        : ${BOLD}${CERT_FILE}${NC}"
        echo -e "  Key         : ${BOLD}${KEY_FILE}${NC}"
    fi
    if [ "$TRANSPORT" = "quantum" ]; then
        echo -e "  Interface : ${BOLD}auto-detect${NC}"
        echo -e "  MTU       : ${BOLD}${QM_MTU}${NC}"
        echo -e "  Block     : ${BOLD}${QM_BLOCK}${NC}"
    fi
    if [ "$TRANSPORT" = "tun" ]; then
        echo -e "  Encap     : ${BOLD}${TUN_ENCAP}${NC}"
        echo -e "  Profile   : ${BOLD}${TUN_PROFILE}${NC}"
        echo -e "  TUN Local : ${BOLD}${TUN_LOCAL_ADDR}${NC}"
        echo -e "  TUN Peer  : ${BOLD}${TUN_REMOTE_ADDR}${NC}"
        echo -e "  Wire IP   : ${BOLD}${TUN_LOCAL_IP} -> ${TUN_PEER_IP}${NC}"
        echo -e "  Device    : ${BOLD}${TUN_NAME}${NC}"
    fi
    if [ "$SOCKS5_ENABLED" = "true" ]; then
        echo -e "  SOCKS5    : ${BOLD}${SOCKS5_BIND}${NC}  (standalone, independent of maps)"
    fi
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
}

install_client() {
    hr "Install Client"
    ensure_binary
    echo ""

    ask_service_name
    echo ""

    ask_transport
    echo ""

    if [ "$TRANSPORT" != "tun" ]; then
        ask_connection_pool
    fi

    while true; do
        echo -e "        Example : 1.1.1.1:8443   (or just 1.1.1.1 to use default port 8443)"
        ask SERVER_ADDR "Server IP And Port" ""
        [ -z "$SERVER_ADDR" ] && { warn "Server IP cannot be empty."; continue; }
        if [[ "$SERVER_ADDR" != *:* ]]; then
            SERVER_ADDR="${SERVER_ADDR}:8443"
        fi
        SERVER_IP="${SERVER_ADDR%%:*}"
        SERVER_PORT="${SERVER_ADDR##*:}"
        if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PORT" ] || [ "$SERVER_IP" = "$SERVER_PORT" ]; then
            warn "Invalid format. Use IP:PORT or just IP (e.g. 1.1.1.1:8443 or 1.1.1.1)"
        else
            break
        fi
    done
    echo ""

    ask PSK "PSK  (must match server)" "123"
    echo ""

    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket path  (must match server)" "/ws"
            echo ""
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain  (must match server)" "www.google.com"
            ask HTTP_PATH   "Fake path    (must match server)" "/search"
            echo ""
            ;;
        quantum)
            echo -e "  ${DIM}Quantum auto-detects the network interface, source IP, and${NC}"
            echo -e "  ${DIM}gateway MAC at runtime — nothing to configure for those.${NC}"
            echo ""
            ask QM_MTU   "MTU" "1350"
            ask QM_BLOCK "KCP header cipher  (must match server, aes/salsa20/none)" "aes"
            echo ""
            ;;
        tun)
            echo ""
            echo -e "  ${BOLD}TUN Encapsulation (must match server):${NC}"
            echo "    1)  tcp   — plain TCP over TUN"
            echo "    2)  ipx   — raw IP encapsulation"
            echo ""
            ask TUN_ENCAP_CHOICE "Encapsulation" "1"
            case "$TUN_ENCAP_CHOICE" in
                2|ipx) TUN_ENCAP="ipx" ;;
                *)     TUN_ENCAP="tcp" ;;
            esac
            if [ "$TUN_ENCAP" = "ipx" ]; then
                echo ""
                echo -e "  ${BOLD}IPX Profile (must match server):${NC}"
                echo "    1)  icmp  2)  gre  3)  ipip  4)  bip"
                echo ""
                ask TUN_PROFILE_CHOICE "Profile" "1"
                case "$TUN_PROFILE_CHOICE" in
                    2|gre)  TUN_PROFILE="gre"  ;;
                    3|ipip) TUN_PROFILE="ipip" ;;
                    4|bip)  TUN_PROFILE="bip"  ;;
                    *)      TUN_PROFILE="icmp" ;;
                esac
            else
                TUN_PROFILE="icmp"
            fi
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Client real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Server real IP"
            echo ""
            ask TUN_LOCAL_ADDR  "TUN local IP   (client side, any IP)" "10.0.0.2"
            ask TUN_REMOTE_ADDR "TUN remote IP  (server side, any IP)" "10.0.0.1"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface  (leave empty for auto-detect)" ""
            ask TUN_NAME  "TUN device name" "dagger0"
            echo ""
            ask TUN_HEARTBEAT_SEC    "Heartbeat interval (sec)  -- doesn't need to match the server, but similar values make sense" "5"
            ask TUN_IDLE_TIMEOUT_SEC "Idle timeout (sec)  -- how long with no traffic before reconnecting" "40"
            echo ""
            ask TUN_SPOOF_CHOICE "Enable IP Spoof (y/n)" "n"
            if [ "$TUN_SPOOF_CHOICE" = "y" ] || [ "$TUN_SPOOF_CHOICE" = "Y" ]; then
                ask TUN_SPOOF_SRC "Spoof Source IP" ""
                ask TUN_SPOOF_DST "Spoof Dest IP  " ""
            else
                TUN_SPOOF_SRC="" TUN_SPOOF_DST=""
            fi
            echo ""
            ask TUN_DCPI_CHOICE "Enable DCPI Mode  (ICMPv6/proto58) (y/n)" "n"
            [ "$TUN_DCPI_CHOICE" = "y" ] || [ "$TUN_DCPI_CHOICE" = "Y" ] && TUN_DCPI="yes" || TUN_DCPI="no"
            echo ""
            ;;
    esac

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "https" ]; then
        ask_ssl_client
        echo ""
    fi

    ask_advanced
    echo ""

    case "$TRANSPORT" in
        tcp)     write_client_config_tcp     "$SERVER_IP" "$SERVER_PORT" "$PSK" ;;
        ws)      write_client_config_ws      "$SERVER_IP" "$SERVER_PORT" "$PSK" "$WS_PATH" ;;
        wss)     write_client_config_wss     "$SERVER_IP" "$SERVER_PORT" "$PSK" "$WS_PATH" "$TLS_INSECURE" ;;
        http)    write_client_config_http    "$SERVER_IP" "$SERVER_PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" ;;
        https)   write_client_config_https   "$SERVER_IP" "$SERVER_PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "$TLS_INSECURE" ;;
        quantum) write_client_config_quantum "$SERVER_IP" "$SERVER_PORT" "$PSK" "$QM_MTU" "$QM_BLOCK" ;;
        tun)     write_client_config_tun     "$SERVER_PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_ENCAP" "$TUN_PROFILE" "$TUN_IFACE" "$TUN_SPOOF_SRC" "$TUN_SPOOF_DST" "$TUN_DCPI" "$TUN_NAME" "$TUN_HEARTBEAT_SEC" "$TUN_IDLE_TIMEOUT_SEC" ;;
    esac
    ok "Config written: ${CONFIG}"

    install_service
    start_service

    echo ""
    echo -e "${GREEN}${BOLD}  Client installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Server    : ${BOLD}${SERVER_IP}:${SERVER_PORT}${NC}"
    echo -e "  PSK       : ${BOLD}${PSK}${NC}"
    [ "$TRANSPORT" = "ws"  ] && echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
    if [ "$TRANSPORT" = "wss" ]; then
        echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
        echo -e "  TLS Verify: ${BOLD}$([ "$TLS_INSECURE" = "true" ] && echo "Skipped" || echo "Enabled")${NC}"
    fi
    if [ "$TRANSPORT" = "http" ]; then
        echo -e "  Fake Domain : ${BOLD}${HTTP_DOMAIN}${NC}"
        echo -e "  Fake Path   : ${BOLD}${HTTP_PATH}${NC}"
    fi
    if [ "$TRANSPORT" = "https" ]; then
        echo -e "  Fake Domain : ${BOLD}${HTTP_DOMAIN}${NC}"
        echo -e "  Fake Path   : ${BOLD}${HTTP_PATH}${NC}"
        echo -e "  TLS Verify  : ${BOLD}$([ "$TLS_INSECURE" = "true" ] && echo "Skipped" || echo "Enabled")${NC}"
    fi
    if [ "$TRANSPORT" = "quantum" ]; then
        echo -e "  Interface : ${BOLD}auto-detect${NC}"
        echo -e "  MTU       : ${BOLD}${QM_MTU}${NC}"
        echo -e "  Block     : ${BOLD}${QM_BLOCK}${NC}"
    fi
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
}

show_status() {
    hr "Service Status"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No DaggerConnect services found."
        return
    fi

    for svc in "${SERVICES[@]}"; do
        echo -e "${BOLD}${svc}${NC}"
        systemctl status "$svc" --no-pager --lines=5 2>/dev/null || true
        echo ""
    done
}

show_logs() {
    hr "Logs"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No DaggerConnect services found."
        return
    fi

    if [ ${#SERVICES[@]} -eq 1 ]; then
        TARGET="${SERVICES[0]}"
    else
        echo "Available services:"
        for i in "${!SERVICES[@]}"; do
            echo "  $((i+1)))  ${SERVICES[$i]}"
        done
        echo ""
        ask IDX "Select number" "1"
        TARGET="${SERVICES[$((IDX-1))]}"
    fi

    journalctl -u "$TARGET" -n 80 --no-pager
}

uninstall() {
    hr "Remove"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No DaggerConnect services found."
        return
    fi

    echo "Installed services:"
    for i in "${!SERVICES[@]}"; do
        echo "  $((i+1)))  ${SERVICES[$i]}"
    done
    echo "  a)  Remove ALL"
    echo ""
    ask IDX "Select number (or a)" ""

    if [ "$IDX" = "a" ]; then
        TARGETS=("${SERVICES[@]}")
    else
        TARGETS=("${SERVICES[$((IDX-1))]}")
    fi

    echo ""
    warn "Will stop and remove: ${TARGETS[*]}"
    ask CONFIRM "Confirm? (yes/no)" "no"
    [ "$CONFIRM" != "yes" ] && { info "Cancelled."; return; }

    for svc in "${TARGETS[@]}"; do
        svc_name="${svc%.service}"
        remove_watchdog "$svc_name"
        systemctl stop    "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc_name}.service"
        cfg_json="${CONFIG_DIR}/${svc_name}.json"
        cfg_yaml="${CONFIG_DIR}/${svc_name}.yaml"
        [ -f "$cfg_json" ] && rm -f "$cfg_json" && ok "Removed config: ${cfg_json}"
        [ -f "$cfg_yaml" ] && rm -f "$cfg_yaml" && ok "Removed config: ${cfg_yaml}"
        rm -f "/etc/letsencrypt/renewal-hooks/deploy/daggerconnect-${svc_name}.sh" 2>/dev/null || true
        ok "Removed service: ${svc_name}"
    done

    systemctl daemon-reload
    [ -d "$CONFIG_DIR" ] && [ -z "$(ls -A "$CONFIG_DIR")" ] && rmdir "$CONFIG_DIR"
    ok "Done."
}

PICKED_SVC=""
pick_service() {
    PICKED_SVC=""
    local prompt="${1:-Select service}"
    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No DaggerConnect services found."
        return 1
    fi

    if [ ${#SERVICES[@]} -eq 1 ]; then
        PICKED_SVC="${SERVICES[0]}"
        return 0
    fi

    echo -e "  ${BOLD}Available services:${NC}"
    for i in "${!SERVICES[@]}"; do
        local st="stopped"
        systemctl is-active --quiet "${SERVICES[$i]}" && st="${GREEN}running${NC}" || st="${RED}stopped${NC}"
        echo -e "    $((i+1)))  ${SERVICES[$i]}   [${st}]"
    done
    echo ""
    ask IDX "$prompt (number)" "1"
    if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt ${#SERVICES[@]} ]; then
        warn "Invalid selection."
        return 1
    fi
    PICKED_SVC="${SERVICES[$((IDX-1))]}"
    return 0
}

show_logs_live() {
    hr "Live Logs"
    echo ""
    pick_service "Follow logs for" || return 0
    info "Following ${PICKED_SVC} — press Ctrl+C to return to the menu."
    echo ""
    trap ' ' INT
    journalctl -u "$PICKED_SVC" -n 40 -f --no-pager
    trap - INT
    echo ""
    ok "Stopped following logs."
}

service_control() {
    hr "Service Control"
    echo ""
    pick_service "Manage" || return 0
    local svc="$PICKED_SVC"

    echo ""
    local st
    systemctl is-active --quiet "$svc" && st="${GREEN}running${NC}" || st="${RED}stopped${NC}"
    echo -e "  Selected : ${BOLD}${svc}${NC}   [${st}]"
    echo ""
    echo "  1)  Restart"
    echo "  2)  Stop"
    echo "  3)  Start"
    echo "  4)  Status"
    echo "  0)  Back"
    echo ""
    ask ACT "Action" "1"

    case "$ACT" in
        1)
            step "Restarting ${svc} ..."
            systemctl restart "$svc"
            sleep 2
            if systemctl is-active --quiet "$svc"; then ok "Running."; else warn "Failed to start — see logs."; fi
            ;;
        2)
            step "Stopping ${svc} ..."
            systemctl stop "$svc" && ok "Stopped." || warn "Could not stop."
            ;;
        3)
            step "Starting ${svc} ..."
            systemctl start "$svc"
            sleep 2
            if systemctl is-active --quiet "$svc"; then ok "Running."; else warn "Failed to start — see logs."; fi
            ;;
        4)
            systemctl status "$svc" --no-pager --lines=10 2>/dev/null || true
            ;;
        0|"") return 0 ;;
        *) warn "Invalid action." ;;
    esac
}

edit_config() {
    hr "Edit Config"
    echo ""
    pick_service "Edit config for" || return 0
    local svc="${PICKED_SVC%.service}"

    local cfg=""
    [ -f "${CONFIG_DIR}/${svc}.json" ] && cfg="${CONFIG_DIR}/${svc}.json"
    [ -f "${CONFIG_DIR}/${svc}.yaml" ] && cfg="${CONFIG_DIR}/${svc}.yaml"
    if [ -z "$cfg" ]; then
        warn "No config file found for ${svc}."
        return 0
    fi

    local ed="${EDITOR:-}"
    if [ -z "$ed" ]; then
        for cand in nano vim vi; do
            command -v "$cand" >/dev/null 2>&1 && { ed="$cand"; break; }
        done
    fi
    if [ -z "$ed" ]; then
        warn "No editor found (nano/vim/vi). Install one: apt install nano"
        return 0
    fi

    cp "$cfg" "${cfg}.bak" 2>/dev/null && info "Backup saved: ${cfg}.bak"
    info "Opening ${cfg} in ${ed} ..."
    "$ed" "$cfg"

    echo ""
    ask DORESTART "Restart the service to apply changes? (y/n)" "y"
    if [ "$DORESTART" = "y" ] || [ "$DORESTART" = "Y" ]; then
        step "Restarting ${svc} ..."
        systemctl restart "${svc}"
        sleep 2
        if systemctl is-active --quiet "${svc}"; then ok "Running with new config."; else
            warn "Service failed to start — config may be invalid."
            ask REVERT "Restore backup and restart? (y/n)" "y"
            if [ "$REVERT" = "y" ] || [ "$REVERT" = "Y" ]; then
                cp "${cfg}.bak" "$cfg" && systemctl restart "${svc}" && ok "Reverted to previous config."
            fi
        fi
    fi
}

show_watchdog_log() {
    hr "Watchdog Activity"
    echo ""
    pick_service "Show watchdog log for" || return 0
    local svc="${PICKED_SVC%.service}"
    echo ""
    if journalctl -t "dagger-watchdog[${PICKED_SVC}]" -n 40 --no-pager 2>/dev/null | grep -q .; then
        journalctl -t "dagger-watchdog[${PICKED_SVC}]" -n 40 --no-pager
    else
        ok "No watchdog interventions recorded for ${svc} -- the tunnel has been healthy."
    fi
    echo ""
    systemctl is-active --quiet "dagger-watchdog@${svc}.timer" \
        && ok "Watchdog timer : active  (checks every 15s)" \
        || warn "Watchdog timer : not active for this service"
}

show_banner() {
    echo ""
    echo -e "  ${CYAN}${BOLD}┌──────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}${BOLD}│      DaggerConnect  Installer         │${NC}"
    echo -e "  ${CYAN}${BOLD}└──────────────────────────────────────┘${NC}"
    echo -e "  ${DIM}@DaggerConnect  —  every prompt has a sane default,${NC}"
    echo -e "  ${DIM}just press Enter to accept it and move on.${NC}"
    echo ""
}

show_menu() {
    echo -e "${BOLD}  Select an option:${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Install${NC}"
    echo "    1)  Install Server"
    echo "    2)  Install Client"
    echo ""
    echo -e "  ${CYAN}${BOLD}Manage${NC}"
    echo "    3)  Service Status"
    echo "    4)  Service Control     (restart / stop / start)"
    echo "    5)  Edit Config"
    echo ""
    echo -e "  ${MAGENTA}${BOLD}Logs & Health${NC}"
    echo "    6)  View Logs           (last 80 lines)"
    echo "    7)  Live Logs           (follow)"
    echo "    8)  Watchdog Activity   (auto-heal history)"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Other${NC}"
    echo "    9)  Remove"
    echo "   10)  Update Core (Binary)"
    echo "    0)  Exit"
    echo ""
    ask CHOICE "Choice" ""
}

run_action() {
    ( "$@" )
    return 0
}

pause() {
    echo ""
    echo -ne "${YELLOW}?${NC} Press Enter to return to the menu: "
    read -r _
}

[ "$EUID" -ne 0 ] && { echo -e "${RED}[ERR ]${NC}  Run as root: sudo bash setup.sh"; exit 1; }

while true; do
    clear 2>/dev/null || true
    show_banner
    show_menu

    case "$CHOICE" in
        1)  run_action install_server ;;
        2)  run_action install_client ;;
        3)  run_action show_status     ;;
        4)  run_action service_control ;;
        5)  run_action edit_config     ;;
        6)  run_action show_logs       ;;
        7)  run_action show_logs_live  ;;
        8)  run_action show_watchdog_log ;;
        9)  run_action uninstall       ;;
        10) run_action download_binary ;;
        0)  echo -e "\n  ${CYAN}Bye.${NC}\n"; exit 0 ;;
        *)  warn "Invalid choice: ${CHOICE}" ;;
    esac

    pause
done
