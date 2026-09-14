#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

LAUNCHER="/usr/local/bin/DaggerLauncher"
LAUNCHER_ZIP_URL="https://github.com/parhampahlevann/dagger/releases/download/v1.0/DaggerConnect3.2.zip"
CONFIG_DIR="/etc/DaggerConnect"
CONFIG=""
CONFIG_FMT=""
SERVICE_NAME=""
SERVICE_FILE=""
TRANSPORT=""
XHTTP_CDN="false"
XHTTP_CDN_HOST=""
XHTTP_CDN_PORT="443"
XHTTP_CDN_IPS=""
XHTTP_INSECURE="true"
XHTTP_ORIGIN_PORT="8443"
XHTTP_PEER_IP=""
XHTTP_PUBLIC_IP=""
XHTTP_CDN_POOL="6"
XHTTP_UP_MAX_BYTES="65536"
XHTTP_BUFFER_BYTES="32768"
XHTTP_PROBE_MS="8000"
XHTTP_SOCKET_BUF_BYTES="131072"
SERVER_PUBLIC_IP=""
SSL_MODE=""
DOMAIN=""
CERT_FILE=""
KEY_FILE=""
HEALTH_CHECK_ENABLED="true"

_ts()   { date '+%H:%M:%S'; }
info()  { echo -e "${DIM}$(_ts)${NC} ${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${DIM}$(_ts)${NC} ${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${DIM}$(_ts)${NC} ${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${DIM}$(_ts)${NC} ${MAGENTA}[STEP]${NC}  $*"; }

error() { echo -e "${DIM}$(_ts)${NC} ${RED}[ERR ]${NC}  $*"; exit 1; }
hr()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

ensure_runtime_dependencies() {
    local missing=0 cmd
    for cmd in curl unzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done
    [ "$missing" -eq 0 ] && return 0

    info "Installing dependencies needed to fetch and unpack the launcher..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq ca-certificates curl unzip
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q ca-certificates curl unzip
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q ca-certificates curl unzip
    else
        error "Missing curl/unzip and no supported package manager was found."
    fi
    for cmd in curl unzip; do
        command -v "$cmd" >/dev/null 2>&1 || error "Required command is still missing after installation: ${cmd}"
    done
}

ensure_swap() {
    local total_ram_mb swap_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    swap_mb=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
    total_ram_mb="${total_ram_mb:-1024}"
    swap_mb="${swap_mb:-0}"

    if [ "$swap_mb" -lt 512 ] && [ "$total_ram_mb" -le 2048 ]; then
        info "Low RAM detected (${total_ram_mb}MB) with insufficient swap (${swap_mb}MB)."
        step "Configuring 2GB swap file to prevent OOM kills..."
        if [ ! -f /swapfile ]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
        fi
        swapon /swapfile 2>/dev/null || true
        if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
        ok "Swap file active and persisted."
    fi
}

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

ask_service_name() {
    LABEL="dagger1"
    CONFIG_FMT="json"
    SERVICE_NAME="${LABEL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.${CONFIG_FMT}"

    info "Service Name : ${SERVICE_NAME} (default)"
    info "Config File  : ${CONFIG}"
}

detect_server_public_ip() {
    if [ -n "$DC_SERVER_PUBLIC_IP" ]; then
        echo "$DC_SERVER_PUBLIC_IP"
        return 0
    fi

    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    return 1
}

validate_ip() {
    echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

ask_server_public_ip() {
    echo ""
    local detected
    detected=$(detect_server_public_ip)

    if [ -n "$detected" ]; then
        info "Public IP : ${detected}  (auto-detected from local routing)"
        ask USE_DETECTED "Use this IP? (y/n)" "y"
        if [ "$USE_DETECTED" = "y" ] || [ "$USE_DETECTED" = "Y" ]; then
            SERVER_PUBLIC_IP="$detected"
            return
        fi
    else
        warn "Could not auto-detect this server's IP."
    fi

    while true; do
        ask SERVER_PUBLIC_IP "Enter server public IP manually" "$detected"
        if [ -z "$SERVER_PUBLIC_IP" ]; then
            warn "IP cannot be empty."
            continue
        fi
        if validate_ip "$SERVER_PUBLIC_IP"; then
            break
        fi
        warn "Invalid IP format. Example: 31.171.101.23"
    done
    info "Public IP : ${SERVER_PUBLIC_IP}  (manual)"
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}Available Transports:${NC}"
    echo "    1)  tcp      — Raw TCP tunnel"
    echo "    2)  ws       — WebSocket tunnel"
    echo "    3)  wss      — WebSocket Secure (TLS) tunnel"
    echo "    4)  http     — HTTP Mimicry tunnel"
    echo "    5)  https    — HTTP Mimicry Secure (TLS) tunnel"
    echo "    6)  quantum  — Raw-packet tunnel"
    echo "    7)  quantum+ — KCP over UDP"
    echo "    8)  tun      — TUN kernel interface tunnel"
    echo "    9)  xhttp    — real HTTP carrier (passes through a CDN)"
    echo "   10)  xhttps   — real HTTPS carrier + Cloudflare edge addresses"
    echo ""
    while true; do
        ask T_CHOICE "Transport" "8"
        case "$T_CHOICE" in
            1|tcp)      TRANSPORT="tcp";      break ;;
            2|ws)       TRANSPORT="ws";       break ;;
            3|wss)      TRANSPORT="wss";      break ;;
            4|http)     TRANSPORT="http";     break ;;
            5|https)    TRANSPORT="https";    break ;;
            6|quantum)  TRANSPORT="quantum";  break ;;
            7|quantum+|quantumplus|qplus) TRANSPORT="quantum+"; break ;;
            8|tun)      TRANSPORT="tun";      break ;;
            9|xhttp)    TRANSPORT="xhttp";    break ;;
            10|xhttps)  TRANSPORT="xhttps";   break ;;
            *) warn "Please enter 1-10 or transport name." ;;
        esac
    done
    info "Transport : ${TRANSPORT}"
}

ask_xhttp() {
    local side="$1"
    echo ""
    echo -e "  ${BOLD}xhttp settings${NC}"
    echo -e "  ${DIM}The path is a URL prefix and must match on both ends.${NC}"
    echo -e "  ${DIM}Pick something an ordinary site would have, not /tunnel.${NC}"
    ask XHTTP_PATH "URL path  (must match the other side)" "/api/v2"
    case "$XHTTP_PATH" in
        /*) ;;
        *) XHTTP_PATH="/$XHTTP_PATH" ;;
    esac

    if [ "$side" = "client" ]; then
        echo ""
        echo -e "  ${BOLD}How should uploads be sent?${NC}"
        echo "    1)  auto        — try the fast way, fall back if the path won't carry it  (recommended)"
        echo "    2)  streaming  — one long upload request. Fastest, but some CDNs buffer it and it stalls"
        echo "    3)  sequenced  — many small upload requests. A little slower, gets through almost anything"
        echo ""
        echo -e "  ${DIM}Through Cloudflare, auto usually settles on sequenced after about${NC}"
        echo -e "  ${DIM}20 seconds. Choosing sequenced outright skips that wait.${NC}"
        echo ""
        ask XHTTP_MODE_CHOICE "Upload mode" "1"
        case "$XHTTP_MODE_CHOICE" in
            2|stream|streaming|stream-up) XHTTP_MODE="stream-up" ;;
            3|packet|sequenced|packet-up) XHTTP_MODE="packet-up" ;;
            *) XHTTP_MODE="auto" ;;
        esac
        info "Upload mode : ${XHTTP_MODE}"
    else
        XHTTP_MODE="auto"
    fi
}

ask_xhttp_cdn() {
    local side="$1"
    XHTTP_CDN="false"
    XHTTP_CDN_HOST=""
    XHTTP_CDN_PORT="443"
    XHTTP_CDN_IPS=""
    XHTTP_INSECURE="true"
    XHTTP_ORIGIN_PORT="8443"
    XHTTP_PEER_IP=""
    XHTTP_PUBLIC_IP=""

    echo ""
    echo -e "  ${YELLOW}Answer the same on both sides.${NC}"
    echo ""
    ask XHTTP_CDN_CHOICE "Use Cloudflare (y/n)" "n"
    case "$XHTTP_CDN_CHOICE" in
        y|Y|yes) ;;
        *) return ;;
    esac

    XHTTP_CDN="true"
    XHTTP_INSECURE="false"

    if [ "$side" = "client" ]; then
        echo ""
        echo -e "  ${BOLD}This side is the origin${NC}"
        echo -e "  ${DIM}Cloudflare connects to THIS machine. Point your domain's DNS record${NC}"
        echo -e "  ${DIM}here, orange cloud on, and open the port below in the firewall.${NC}"
        echo ""
        ask XHTTP_ORIGIN_PORT "Port to wait on" "8443"
        ok "Waiting for Cloudflare on port ${XHTTP_ORIGIN_PORT}"

        echo ""
        local mine
        mine=$(detect_server_public_ip)
        while true; do
            ask XHTTP_PUBLIC_IP "Client IP  (blank = skip)" "$mine"
            [ -z "$XHTTP_PUBLIC_IP" ] && break
            validate_ip "$XHTTP_PUBLIC_IP" && break
            warn "That is not an IP address."
        done
        return
    fi

    ask_required XHTTP_CDN_HOST "Your Cloudflare-proxied domain  (e.g. cdn.example.com)"
    echo ""
    echo -e "  ${YELLOW}That domain's DNS record must point at the FOREIGN server,${NC}"
    echo -e "  ${YELLOW}not at this one, with the orange cloud on.${NC}"
    echo ""
    echo -e "  ${DIM}Cloudflare forwards these HTTPS ports only:${NC}"
    echo -e "  ${DIM}443, 2053, 2083, 2087, 2096, 8443${NC}"
    echo -e "  ${DIM}Use the same port the far side waits on.${NC}"
    ask XHTTP_CDN_PORT "Port" "443"
    echo ""
    echo -e "  ${BOLD}Edge addresses${NC}"
    echo -e "  ${DIM}Every Cloudflare address accepts every domain behind Cloudflare and${NC}"
    echo -e "  ${DIM}works out where to send the request from the domain name, not from${NC}"
    echo -e "  ${DIM}the address dialled. So put any addresses that are not blocked from${NC}"
    echo -e "  ${DIM}here, separated by commas. They are tried in order; if one stops${NC}"
    echo -e "  ${DIM}working the next is used.${NC}"
    echo -e "  ${DIM}Example: 104.17.12.5,162.159.36.7,172.67.180.44${NC}"
    echo ""
    while true; do
        ask_required XHTTP_CDN_IPS "Edge addresses"
        if validate_edge_ips "$XHTTP_CDN_IPS"; then
            break
        fi
    done
    XHTTP_CDN_IPS="$(normalize_edge_ips "$XHTTP_CDN_IPS")"
    ok "Edge addresses: ${XHTTP_CDN_IPS}"

    echo ""
    echo -e "  ${BOLD}How many connections should it keep open?${NC}"
    echo -e "  ${DIM}In Cloudflare mode this side dials, so the pool lives here.${NC}"
    echo ""
    ask XHTTP_CDN_POOL "Connections" "6"
    case "$XHTTP_CDN_POOL" in
        ''|*[!0-9]*) XHTTP_CDN_POOL="4" ;;
    esac

    echo ""
    ask XHTTP_PEER_IP "Client IP  (blank = accept any)" ""
    [ -n "$XHTTP_PEER_IP" ] && ok "Only ${XHTTP_PEER_IP} will be accepted"
}

validate_edge_ips() {
    local list="$1" ip bad=0 count=0
    IFS=',' read -ra _VIPS <<< "$list"
    for ip in "${_VIPS[@]}"; do
        ip="$(echo "$ip" | xargs)"
        [ -z "$ip" ] && continue
        count=$((count + 1))
        if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            warn "\"${ip}\" is not an IP address."
            bad=1
            continue
        fi
        local o
        for o in ${ip//./ }; do
            if [ "$o" -gt 255 ] 2>/dev/null; then
                warn "\"${ip}\" is not a valid IP address (${o} is above 255)."
                bad=1
                break
            fi
        done
    done
    if [ "$count" -eq 0 ]; then
        warn "Enter at least one address."
        return 1
    fi
    [ "$bad" -eq 0 ]
}

normalize_edge_ips() {
    local list="$1" out="" ip
    IFS=',' read -ra _NIPS <<< "$list"
    for ip in "${_NIPS[@]}"; do
        ip="$(echo "$ip" | xargs)"
        [ -z "$ip" ] && continue
        [ -n "$out" ] && out="${out},"
        out="${out}${ip}"
    done
    printf '%s' "$out"
}

build_edge_ips_json() {
    local ips="$1" out="" ip
    [ -z "$ips" ] && { printf ''; return; }
    IFS=',' read -ra _EIPS <<< "$ips"
    for ip in "${_EIPS[@]}"; do
        ip="$(echo "$ip" | xargs)"
        [ -z "$ip" ] && continue
        [ -n "$out" ] && out="${out}, "
        out="${out}\"${ip}\""
    done
    printf '%s' "$out"
}

build_edge_ips_yaml() {
    printf '[%s]' "$(build_edge_ips_json "$1")"
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

install_openssl() {
    command -v openssl &>/dev/null && return
    info "Installing openssl..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq openssl
    elif command -v yum &>/dev/null; then
        yum install -y -q openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y -q openssl
    else
        error "Cannot install openssl — package manager not found. Install it manually."
    fi
}

make_self_signed_cert() {
    local domain="$1"
    local dir="/etc/daggerconnect/tls"

    install_openssl
    mkdir -p "$dir"
    CERT_FILE="${dir}/${SERVICE_NAME}.crt"
    KEY_FILE="${dir}/${SERVICE_NAME}.key"

    info "Creating a self-signed certificate for ${domain} ..."
    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=${domain}" \
            -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -subj "/CN=${domain}" >/dev/null 2>&1 \
            || error "openssl could not create the certificate."
    fi
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    ok "Cert : ${CERT_FILE}"
    ok "Key  : ${KEY_FILE}"
    ok "Valid for 10 years. Set Cloudflare's SSL mode to \"Full\"."
}

ask_ssl_cert() {
    echo ""
    echo -e "  ${BOLD}Certificate:${NC}"
    echo "    1)  Self-signed  — made here with openssl (use Cloudflare SSL mode \"Full\")"
    echo "    2)  Let's Encrypt — certbot, needs port 80 open and DNS pointing here"
    echo "    3)  Custom        — paths to a cert and key you already have"
    echo ""
    while true; do
        ask SSL_CHOICE "Certificate" "1"
        case "$SSL_CHOICE" in
            1|self|selfsigned) SSL_MODE="self";   break ;;
            2|auto|letsencrypt) SSL_MODE="auto";  break ;;
            3|custom)          SSL_MODE="custom"; break ;;
            *) warn "Please enter 1, 2 or 3." ;;
        esac
    done

    case "$SSL_MODE" in
        self)
            echo ""
            local def_domain="${XHTTP_CDN_HOST:-daggerconnect.local}"
            ask DOMAIN "Domain name" "$def_domain"
            echo ""
            make_self_signed_cert "$DOMAIN"
            ;;
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

check_ptrace_scope() {
    local f=/proc/sys/kernel/yama/ptrace_scope
    [ -r "$f" ] || return 0
    local val
    val=$(cat "$f" 2>/dev/null)
    if [ "$val" = "0" ]; then
        echo ""
        warn "kernel.yama.ptrace_scope is 0 -- any same-user process can ptrace-attach and dump this binary from memory."
        echo -e "  ${DIM}Recommended: sysctl -w kernel.yama.ptrace_scope=2   (or 3, which needs a reboot to undo)${NC}"
        echo -e "  ${DIM}Persist across reboots: echo 'kernel.yama.ptrace_scope=2' >> /etc/sysctl.d/99-daggerconnect.conf${NC}"
    fi
}

tune_network() {
    hr "Network Tuning (fq + BBR, bounded buffers)"

    ensure_swap

    local total_ram_mb max_buf def_buf
    total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    total_ram_mb="${total_ram_mb:-1024}"

    if [ "$total_ram_mb" -le 1024 ]; then
        max_buf=4194304
        def_buf=131072
    elif [ "$total_ram_mb" -le 2048 ]; then
        max_buf=8388608
        def_buf=262144
    else
        max_buf=16777216
        def_buf=262144
    fi

    local sysctl_file="/etc/sysctl.d/99-daggerconnect-net.conf"
    step "Writing ${sysctl_file}"
    cat > "$sysctl_file" << EOF
# DaggerConnect network tuning -- managed by setup.sh (safe to keep).
net.core.rmem_max = ${max_buf}
net.core.wmem_max = ${max_buf}
net.core.rmem_default = ${def_buf}
net.core.wmem_default = ${def_buf}
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 ${def_buf} ${max_buf}
net.ipv4.tcp_wmem = 4096 ${def_buf} ${max_buf}
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.ip_forward = 1
vm.swappiness = 10
EOF

    modprobe tcp_bbr 2>/dev/null || true
    if [ ! -f /etc/modules-load.d/daggerconnect-bbr.conf ]; then
        echo "tcp_bbr" > /etc/modules-load.d/daggerconnect-bbr.conf 2>/dev/null || true
    fi

    step "Applying now (sysctl)"
    if sysctl -p "$sysctl_file" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1; then
        ok "Applied and persisted (survives reboot)."
    else
        warn "Could not apply all sysctls now -- they will still take effect on next reboot."
    fi

    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    info "Congestion control: ${BOLD}${cc:-unknown}${NC}   qdisc: ${BOLD}${qd:-unknown}${NC}"
    if [ "$cc" != "bbr" ]; then
        warn "BBR not active (kernel may lack tcp_bbr). Throughput tuning still applied; consider a newer kernel for BBR."
    fi
    echo ""
}

download_launcher_zip() {
    local tmp_dir zip_path bin_path found size magic

    tmp_dir=$(mktemp -d)
    zip_path="${tmp_dir}/launcher.zip"

    if ! curl --fail --silent --show-error --location \
        --retry 3 --retry-delay 2 --retry-connrefused \
        --connect-timeout 15 --max-time 300 \
        -o "$zip_path" "$LAUNCHER_ZIP_URL"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! unzip -oq "$zip_path" -d "$tmp_dir"; then
        rm -rf "$tmp_dir"
        warn "Downloaded file is not a valid zip archive."
        return 1
    fi

    found=""
    while IFS= read -r -d '' f; do
        magic=$(LC_ALL=C od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
        if [ "$magic" = "7f454c46" ]; then
            found="$f"
            break
        fi
    done < <(find "$tmp_dir" -type f -print0)

    if [ -z "$found" ]; then
        rm -rf "$tmp_dir"
        warn "No Linux ELF executable found inside the release zip."
        return 1
    fi

    size=$(wc -c < "$found" 2>/dev/null || echo 0)
    if [ "$size" -lt 1048576 ]; then
        rm -rf "$tmp_dir"
        warn "Extracted launcher binary looks too small (size=${size}); refusing to install it."
        return 1
    fi

    mkdir -p "$(dirname "$LAUNCHER")"
    chmod 0755 "$found"
    if [ -f "$LAUNCHER" ] && cmp -s "$found" "$LAUNCHER"; then
        rm -rf "$tmp_dir"
        info "DaggerLauncher already matches this release."
        return 0
    fi
    mv -f "$found" "$LAUNCHER"
    rm -rf "$tmp_dir"
    return 0
}

ensure_launcher() {
    info "Fetching DaggerLauncher from the release archive..."
    if download_launcher_zip; then
        ok "DaggerLauncher ready : ${LAUNCHER}"
        return 0
    fi
    if [ -x "$LAUNCHER" ]; then
        warn "Could not fetch the launcher archive; keeping the existing executable."
        return 0
    fi
    error "Failed to download/extract DaggerLauncher from ${LAUNCHER_ZIP_URL} -- check network/DNS, or place a Linux launcher at ${LAUNCHER}, chmod +x it, and re-run."
}

update_launcher() {
    hr "Update Launcher"
    echo ""

    step "Downloading launcher from ${LAUNCHER_ZIP_URL} ..."
    if ! download_launcher_zip; then
        error "Download failed -- check network/DNS. ${LAUNCHER} was left untouched."
    fi
    ok "DaggerLauncher updated : ${LAUNCHER}"

    mapfile -t SERVICES < <(list_services)
    local running=()
    for svc in "${SERVICES[@]}"; do
        systemctl is-active --quiet "$svc" && running+=("$svc")
    done

    if [ ${#running[@]} -eq 0 ]; then
        info "No running services to restart. The new launcher will be used the next time a service starts."
        return 0
    fi

    echo ""
    echo -e "  ${DIM}A running service keeps using the OLD launcher process in memory until${NC}"
    echo -e "  ${DIM}it restarts -- the file on disk alone isn't enough.${NC}"
    echo "    Currently running: ${running[*]}"
    echo ""
    ask RESTART_NOW "Restart these now so the update takes effect? (y/n)" "y"
    if [ "$RESTART_NOW" = "y" ] || [ "$RESTART_NOW" = "Y" ]; then
        for svc in "${running[@]}"; do
            step "Restarting ${svc} ..."
            systemctl restart "$svc"
            sleep 2
            if systemctl is-active --quiet "$svc"; then ok "Running."; else warn "Failed to start -- check: journalctl -u ${svc}"; fi
        done
    else
        warn "Not restarted -- the update won't take effect until you restart manually (menu option 4, or 'systemctl restart <service>')."
    fi
}

ask_ports() {
    echo ""
    echo -e "  Ports to forward. One per line, or comma-separated. Empty line when done."
    echo -e "        Example : 443                    (forward :443 -> target :443)"
    echo -e "        Example : 2222=22                (bind :2222 -> target :22)"
    echo -e "        Example : 80,443,2053,2083      (multiple at once)"
    echo -e "  ${DIM}Options: tcp, udp, or both (recommended for proxies).${NC}"
    PORTS=()
    while true; do
        ask P "Port" ""
        [ -z "$P" ] && break
        local ptype
        while true; do
            ask ptype "Type for '$P' - both, tcp or udp" "both"
            ptype="$(echo "$ptype" | tr '[:upper:]' '[:lower:]')"
            case "$ptype" in
                tcp|udp|both) break ;;
                *) warn "Please type 'both', 'tcp', or 'udp'." ;;
            esac
        done
        IFS="," read -ra _parts <<< "$P"
        for _p in "${_parts[@]}"; do
            _p="${_p// /}"
            [ -z "$_p" ] && continue
            if [[ "$_p" == */* ]]; then
                PORTS+=("$_p")
            elif [ "$ptype" = "both" ]; then
                PORTS+=("${_p}/tcp")
                PORTS+=("${_p}/udp")
            else
                PORTS+=("${_p}/${ptype}")
            fi
        done
    done
    if [ ${#PORTS[@]} -eq 0 ]; then
        warn "No ports defined. Adding default 443 (both)."
        PORTS=("443/tcp" "443/udp")
    fi
}

parse_port_entry() {
    local entry="$1" ptype="tcp" pbind ptarget
    if [[ "$entry" == */* ]]; then
        ptype="${entry##*/}"
        entry="${entry%/*}"
        ptype="$(echo "$ptype" | tr '[:upper:]' '[:lower:]')"
        case "$ptype" in
            udp|both|any) ;;
            *) ptype="tcp" ;;
        esac
    fi
    if [[ "$entry" == *=* ]]; then
        pbind="${entry%%=*}"
        ptarget="${entry#*=}"
    else
        pbind="$entry"
        ptarget="$entry"
    fi
    echo "${ptype}|${pbind}|${ptarget}"
}

build_ports_json() {
    local target_host="$1"
    shift
    [ -z "$target_host" ] && target_host="127.0.0.1"
    local first=1 p ptype pbind ptarget
    for p in "$@"; do
        IFS='|' read -r ptype pbind ptarget <<< "$(parse_port_entry "$p")"
        if [ "$first" = "1" ]; then
            printf '    { "type": "%s", "bind": "0.0.0.0:%s", "target": "%s:%s" }' "$ptype" "$pbind" "$target_host" "$ptarget"
            first=0
        else
            printf ',\n    { "type": "%s", "bind": "0.0.0.0:%s", "target": "%s:%s" }' "$ptype" "$pbind" "$target_host" "$ptarget"
        fi
    done
    echo ""
}

build_ports_yaml() {
    local target_host="$1"
    shift
    [ -z "$target_host" ] && target_host="127.0.0.1"
    local p ptype pbind ptarget
    for p in "$@"; do
        IFS='|' read -r ptype pbind ptarget <<< "$(parse_port_entry "$p")"
        printf '      - type: "%s"\n        bind: "0.0.0.0:%s"\n        target: "%s:%s"\n' "$ptype" "$pbind" "$target_host" "$ptarget"
    done
}

SOCKS5_ENABLED="false"
SOCKS5_BIND=""
CLIENT_CONN_POOL="6"

ask_connection_pool() {
    echo ""
    echo -e "  ${BOLD}Connection Pool:${NC}"
    echo -e "        Multiple parallel connections per path -- if one drops, the"
    echo -e "        others keep traffic flowing while it reconnects."
    echo ""
    ask CLIENT_CONN_POOL "Connections per path" "6"
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
TUN_TUNE_PROFILE="gaming"
TUN_MTU="1360"
TUN_SOCK_BUF=""
TUN_RX_QUEUE="128"
TUN_TXQUEUELEN="100"
ADV_PROFILE="auto"
ADV_TCP_KEEPALIVE="30"
ADV_CONN_TIMEOUT="30"
ADV_SESSION_TIMEOUT="60"
ADV_CLEANUP_INTERVAL="3"
ADV_TCP_READ_BUF="4194304"
ADV_TCP_WRITE_BUF="4194304"
ADV_UDP_BUF="4194304"
ADV_CHANNEL_BACKLOG="4096"
ADV_STREAM_CHAN_BUF="512"
ADV_KEEPALIVE_SEC="15"
ADV_DEAD_TIMEOUT_SEC="60"
ADV_HEALTH_PROBE_SEC="10"
ADV_HEALTH_PROBE_TIMEOUT_MS="3000"
ADV_HEALTH_MAX_MISSED="4"
ADV_HANDSHAKE_TIMEOUT_SEC="30"

apply_profile() {
    local p="$1"
    ADV_PROFILE="$p"
    case "$p" in
        stable)
            ADV_TCP_READ_BUF="4194304";   ADV_TCP_WRITE_BUF="4194304"
            ADV_UDP_BUF="4194304"
            ADV_CHANNEL_BACKLOG="4096";   ADV_STREAM_CHAN_BUF="512"
            ADV_TCP_KEEPALIVE="30";       ADV_CONN_TIMEOUT="30"
            ADV_SESSION_TIMEOUT="60";     ADV_CLEANUP_INTERVAL="3"
            ADV_KEEPALIVE_SEC="15";       ADV_DEAD_TIMEOUT_SEC="60"
            ADV_HEALTH_PROBE_SEC="10";    ADV_HEALTH_PROBE_TIMEOUT_MS="3000"
            ADV_HEALTH_MAX_MISSED="4";    ADV_HANDSHAKE_TIMEOUT_SEC="30"
            ;;
        aggressive)
            ADV_TCP_READ_BUF="16777216";  ADV_TCP_WRITE_BUF="16777216"
            ADV_UDP_BUF="16777216"
            ADV_CHANNEL_BACKLOG="8192";   ADV_STREAM_CHAN_BUF="2048"
            ADV_TCP_KEEPALIVE="30";       ADV_CONN_TIMEOUT="60"
            ADV_SESSION_TIMEOUT="120";    ADV_CLEANUP_INTERVAL="5"
            ADV_KEEPALIVE_SEC="20";       ADV_DEAD_TIMEOUT_SEC="80"
            ADV_HEALTH_PROBE_SEC="10";    ADV_HEALTH_PROBE_TIMEOUT_MS="3000"
            ADV_HEALTH_MAX_MISSED="4";    ADV_HANDSHAKE_TIMEOUT_SEC="30"
            ;;
        low_latency)
            ADV_TCP_READ_BUF="2097152";   ADV_TCP_WRITE_BUF="2097152"
            ADV_UDP_BUF="2097152"
            ADV_CHANNEL_BACKLOG="2048";   ADV_STREAM_CHAN_BUF="256"
            ADV_TCP_KEEPALIVE="20";       ADV_CONN_TIMEOUT="20"
            ADV_SESSION_TIMEOUT="30";     ADV_CLEANUP_INTERVAL="2"
            ADV_KEEPALIVE_SEC="10";       ADV_DEAD_TIMEOUT_SEC="45"
            ADV_HEALTH_PROBE_SEC="8";      ADV_HEALTH_PROBE_TIMEOUT_MS="2500"
            ADV_HEALTH_MAX_MISSED="4";    ADV_HANDSHAKE_TIMEOUT_SEC="30"
            ;;
        low_hardware)
            ADV_TCP_READ_BUF="524288";    ADV_TCP_WRITE_BUF="524288"
            ADV_UDP_BUF="524288"
            ADV_CHANNEL_BACKLOG="512";    ADV_STREAM_CHAN_BUF="128"
            ADV_TCP_KEEPALIVE="30";       ADV_CONN_TIMEOUT="30"
            ADV_SESSION_TIMEOUT="45";     ADV_CLEANUP_INTERVAL="3"
            ADV_KEEPALIVE_SEC="30";       ADV_DEAD_TIMEOUT_SEC="90"
            ADV_HEALTH_PROBE_SEC="15";    ADV_HEALTH_PROBE_TIMEOUT_MS="4000"
            ADV_HEALTH_MAX_MISSED="4";    ADV_HANDSHAKE_TIMEOUT_SEC="45"
            ;;
    esac
}

ask_num_range() {
    local __var="$1" prompt="$2" def="$3" lo="$4" hi="$5" val
    while true; do
        ask val "$prompt" "$def"
        case "$val" in
            ''|*[!0-9]*) warn "Enter a whole number." ; continue ;;
        esac
        if [ "$val" -lt "$lo" ] || [ "$val" -gt "$hi" ]; then
            warn "Out of range — expected ${lo}..${hi}."
            continue
        fi
        printf -v "$__var" '%s' "$val"
        return
    done
}

ask_tun_custom() {
    echo ""
    echo -e "  ${BOLD}Custom TUN values${NC}  ${DIM}(press Enter to accept recommended defaults)${NC}"
    echo ""
    ask_num_range TUN_MTU "   mtu              (bytes)" "1360" 576 9000
    ask_num_range TUN_SOCK_BUF "   sock_buf         (bytes)" "524288" 131072 67108864
    ask_num_range TUN_RX_QUEUE "   rx_queue         (frames)" "128" 64 8192
    ask_num_range TUN_TXQUEUELEN "   txqueuelen       (packets)" "100" 10 10000
}

ask_tun_profile() {
    echo ""
    echo -e "  ${BOLD}TUN Performance Profile:${NC}"
    echo "    1)  gaming  — Shortest queues: lowest and flattest ping, no bufferbloat (recommended)"
    echo "    2)  stable  — Balanced: low, steady ping with moderate bandwidth"
    echo "    3)  speed   — Maximum throughput; deeper buffers, higher ping under load"
    echo "    4)  custom  — Set every value yourself"
    echo ""
    ask TUN_PROF_CHOICE "TUN Profile" "1"
    TUN_MTU="1360"; TUN_SOCK_BUF="524288"; TUN_RX_QUEUE="128"; TUN_TXQUEUELEN="100"
    case "$TUN_PROF_CHOICE" in
        1|gaming) TUN_TUNE_PROFILE="gaming"; TUN_TXQUEUELEN="100"; TUN_RX_QUEUE="128" ;;
        2|stable) TUN_TUNE_PROFILE="stable"; TUN_TXQUEUELEN="300"; TUN_RX_QUEUE="256" ;;
        3|speed)  TUN_TUNE_PROFILE="speed";  TUN_TXQUEUELEN="1000"; TUN_RX_QUEUE="512" ;;
        4|custom) TUN_TUNE_PROFILE="custom"; ask_tun_custom ;;
        *)        TUN_TUNE_PROFILE="gaming" ;;
    esac

    echo ""
    info "TUN Profile : ${TUN_TUNE_PROFILE} (MTU: ${TUN_MTU}, txqueuelen: ${TUN_TXQUEUELEN})"
    warn "Use the SAME TUN profile on BOTH ends."
}

ask_advanced() {
    local total_ram_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    total_ram_mb="${total_ram_mb:-1024}"

    if [ "$TRANSPORT" = "tun" ]; then
        ADV_AUTO_TUNE="true"
        if [ "$total_ram_mb" -le 1024 ]; then
            apply_profile "low_hardware"
        else
            apply_profile "stable"
        fi
        info "Tuner Mode : not applicable to tun — TUN is tuned by its own profile above."
        return
    fi
    echo ""
    echo -e "  ${BOLD}Tuner Mode:${NC}"
    echo "    1)  auto          — Adaptive auto-tuner (recommended)"
    echo "    2)  stable        — Balanced, reliable for most setups"
    echo "    3)  aggressive    — Max throughput, high memory usage"
    echo "    4)  low_latency   — Minimum delay, small buffers"
    echo "    5)  low_hardware  — Weak VPS / low RAM"
    echo "    6)  custom        — Set every value manually"
    echo ""
    ask ADV_CHOICE "Tuner Mode" "1"
    echo ""
    case "$ADV_CHOICE" in
        1|auto)
            ADV_AUTO_TUNE="true"
            if [ "$total_ram_mb" -le 1024 ]; then
                apply_profile "low_hardware"
            else
                apply_profile "stable"
            fi
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
            ask ADV_TCP_KEEPALIVE    "tcp_keepalive       (sec)"    "30"
            ask ADV_CONN_TIMEOUT     "connection_timeout  (sec)"    "30"
            ask ADV_SESSION_TIMEOUT  "session_timeout     (sec)"    "60"
            ask ADV_CLEANUP_INTERVAL "cleanup_interval    (sec)"    "3"
            echo ""
            ask ADV_KEEPALIVE_SEC    "keepalive_sec       (sec)"    "15"
            ask ADV_DEAD_TIMEOUT_SEC "dead_timeout_sec    (sec)"    "60"
            echo ""
            ask ADV_HEALTH_PROBE_SEC        "health_probe_sec       (sec)" "10"
            ask ADV_HEALTH_PROBE_TIMEOUT_MS "health_probe_timeout_ms (ms)" "3000"
            ask ADV_HEALTH_MAX_MISSED       "health_max_missed     (count)" "4"
            ask ADV_HANDSHAKE_TIMEOUT_SEC   "handshake_timeout_sec  (sec)" "30"
            echo ""
            ask ADV_TCP_READ_BUF     "tcp_read_buffer     (bytes)"  "4194304"
            ask ADV_TCP_WRITE_BUF    "tcp_write_buffer    (bytes)"  "4194304"
            ask ADV_UDP_BUF          "udp_buffer_size     (bytes)"  "4194304"
            echo ""
            ask ADV_CHANNEL_BACKLOG  "channel_backlog     (count)"  "4096"
            ask ADV_STREAM_CHAN_BUF  "stream_chan_buf     (count)"  "512"
            ;;
        *)
            ADV_AUTO_TUNE="true"
            if [ "$total_ram_mb" -le 1024 ]; then
                apply_profile "low_hardware"
            else
                apply_profile "stable"
            fi
            ;;
    esac
    info "Tuner Profile : ${ADV_PROFILE}$([ "$ADV_AUTO_TUNE" = "true" ] && echo " (adaptive)" || echo " (fixed)")"
}

build_health_check_json() {
    printf '  "health_check": {\n    "enabled": %s\n  },\n' "$HEALTH_CHECK_ENABLED"
}

build_health_check_yaml() {
    printf "health_check:\n  enabled: %s\n\n" "$HEALTH_CHECK_ENABLED"
}

build_advanced_json() {
    printf '  "advanced": {\n'
    printf '    "auto_tune": %s,\n'          "$ADV_AUTO_TUNE"
    printf '    "tcp_nodelay": true,\n'
    printf '    "tcp_keepalive": %s,\n'       "$ADV_TCP_KEEPALIVE"
    printf '    "connection_timeout": %s,\n' "$ADV_CONN_TIMEOUT"
    printf '    "session_timeout": %s,\n'    "$ADV_SESSION_TIMEOUT"
    printf '    "cleanup_interval": %s,\n'   "$ADV_CLEANUP_INTERVAL"
    printf '    "tcp_read_buffer": %s,\n'    "$ADV_TCP_READ_BUF"
    printf '    "tcp_write_buffer": %s,\n'   "$ADV_TCP_WRITE_BUF"
    printf '    "udp_buffer_size": %s,\n'    "$ADV_UDP_BUF"
    printf '    "channel_backlog": %s,\n'    "$ADV_CHANNEL_BACKLOG"
    printf '    "stream_chan_buf": %s,\n'      "$ADV_STREAM_CHAN_BUF"
    printf '    "keepalive_sec": %s,\n'       "$ADV_KEEPALIVE_SEC"
    printf '    "dead_timeout_sec": %s,\n'   "$ADV_DEAD_TIMEOUT_SEC"
    printf '    "health_probe_sec": %s,\n' "$ADV_HEALTH_PROBE_SEC"
    printf '    "health_probe_timeout_ms": %s,\n' "$ADV_HEALTH_PROBE_TIMEOUT_MS"
    printf '    "health_max_missed": %s,\n' "$ADV_HEALTH_MAX_MISSED"
    printf '    "handshake_timeout_sec": %s\n' "$ADV_HANDSHAKE_TIMEOUT_SEC"
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
    printf "  tcp_keepalive: %s\n"       "$ADV_TCP_KEEPALIVE"
    printf "  connection_timeout: %s\n" "$ADV_CONN_TIMEOUT"
    printf "  session_timeout: %s\n"    "$ADV_SESSION_TIMEOUT"
    printf "  cleanup_interval: %s\n"   "$ADV_CLEANUP_INTERVAL"
    printf "  tcp_read_buffer: %s\n"    "$ADV_TCP_READ_BUF"
    printf "  tcp_write_buffer: %s\n"   "$ADV_TCP_WRITE_BUF"
    printf "  udp_buffer_size: %s\n"    "$ADV_UDP_BUF"
    printf "  channel_backlog: %s\n"    "$ADV_CHANNEL_BACKLOG"
    printf "  stream_chan_buf: %s\n"     "$ADV_STREAM_CHAN_BUF"
    printf "  keepalive_sec: %s\n"      "$ADV_KEEPALIVE_SEC"
    printf "  dead_timeout_sec: %s\n"  "$ADV_DEAD_TIMEOUT_SEC"
    printf "  health_probe_sec: %s\n" "$ADV_HEALTH_PROBE_SEC"
    printf "  health_probe_timeout_ms: %s\n" "$ADV_HEALTH_PROBE_TIMEOUT_MS"
    printf "  health_max_missed: %s\n" "$ADV_HEALTH_MAX_MISSED"
    printf "  handshake_timeout_sec: %s\n" "$ADV_HANDSHAKE_TIMEOUT_SEC"
}

dc_applies() {
    case "$TRANSPORT" in
        quantum|tun) return 1 ;;
        *) return 0 ;;
    esac
}

build_dc_json() {
    printf '  "profile_id": "%s",\n' "${PAIR_PROFILE_ID:-default}"
    dc_applies || return 0
    [ "$DC_PROFILE" = "auto" ] && return 0
    printf '  "dc": {\n    "streams_per_carrier": %s,\n    "max_carriers": %s,\n    "carrier_lifetime_secs": %s,\n    "window_bytes": %s\n  },\n' "$DC_STREAMS" "$DC_CARRIERS" "$DC_LIFETIME" "$DC_WINDOW"
}

build_dc_yaml() {
    printf 'profile_id: "%s"\n' "${PAIR_PROFILE_ID:-default}"
    dc_applies || return 0
    [ "$DC_PROFILE" = "auto" ] && return 0
    printf 'dc:\n  streams_per_carrier: %s\n  max_carriers: %s\n  carrier_lifetime_secs: %s\n  window_bytes: %s\n\n' "$DC_STREAMS" "$DC_CARRIERS" "$DC_LIFETIME" "$DC_WINDOW"
}

ask_dc() {
    DC_PROFILE="auto"; DC_STREAMS=8; DC_CARRIERS=32; DC_LIFETIME=1500; DC_WINDOW=1048576

    if ! dc_applies; then
        info "DC core : not used by ${TRANSPORT}"
        return
    fi

    echo ""
    echo -e "  ${BOLD}DC core — how many connections share one carrier${NC}"
    echo "    1) Balanced   — 8 per carrier    (recommended)"
    echo "    2) Stability  — 4 per carrier    (lossy or heavily filtered path)"
    echo "    3) Speed      — 12 per carrier   (clean path, fewer connections)"
    echo "    4) Custom"
    echo ""
    while true; do
        ask DC_CHOICE "Profile" "1"
        case "$DC_CHOICE" in
            1|balanced|auto)
                DC_PROFILE="auto"
                info "DC core : balanced (8 per carrier, up to 32 carriers)"
                break ;;
            2|stability|stable)
                DC_PROFILE="stable"; DC_STREAMS=4; DC_CARRIERS=16; DC_LIFETIME=1500; DC_WINDOW=1048576
                info "DC core : stability (4 per carrier, up to 16 carriers, 1MB window)"
                break ;;
            3|speed|fast)
                DC_PROFILE="speed"; DC_STREAMS=12; DC_CARRIERS=16; DC_LIFETIME=1800; DC_WINDOW=2097152
                info "DC core : speed (12 per carrier, up to 16 carriers, 2MB window)"
                break ;;
            4|custom)
                DC_PROFILE="custom"
                ask_num_range DC_STREAMS "Connections per carrier" 8 1 64
                ask_num_range DC_CARRIERS "Maximum carriers" 32 2 64
                ask_num_range DC_LIFETIME "Renew a carrier after (seconds, 0 = never)" 1500 0 86400
                ask_num_range DC_WINDOW "Per-stream receive window (bytes)" 1048576 262144 8388608
                [ "$DC_LIFETIME" = "0" ] && DC_LIFETIME=-1
                info "DC core : custom (${DC_STREAMS} per carrier, up to ${DC_CARRIERS} carriers)"
                break ;;
            *) warn "Please enter 1-4." ;;
        esac
    done
}

write_server_config_tcp() {
    local port="$1" psk="$2"
    shift 2
    local ports_json ports_yaml
    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "tcp",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "tcp",\n      "maps": [\n%s\n      ]\n    }\n  ],\n' "$psk" "$port" "$ports_json"; build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: tcp\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: tcp\n    maps:\n%s\n' "$psk" "$port" "$ports_yaml"; build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_tcp() {
    local server_ip="$1" server_port="$2" psk="$3"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "tcp",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "tcp",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: tcp\npsk: "%s"\nlog_level: info\npaths:\n  - transport: tcp\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_ws() {
    local port="$1" psk="$2" ws_path="$3"
    shift 3
    local ports_json ports_yaml
    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "ws",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "ws",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$ws_path"; build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: ws\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: ws\n    maps:\n%s\nws_settings:\n  path: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$ws_path"; build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_ws() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "ws",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "ws",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: ws\npsk: "%s"\nlog_level: info\npaths:\n  - transport: ws\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nws_settings:\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_wss() {
    local port="$1" psk="$2" ws_path="$3" cert="$4" key="$5"
    shift 5
    local ports_json ports_yaml
    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "wss",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "wss",\n      "cert_file": "%s",\n      "key_file": "%s",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$port" "$cert" "$key" "$ports_json" "$ws_path"; build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: wss\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: wss\n    cert_file: "%s"\n    key_file: "%s"\n    maps:\n%s\nws_settings:\n  path: "%s"\n\n' "$psk" "$port" "$cert" "$key" "$ports_yaml" "$ws_path"; build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_wss() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "wss",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "wss",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: wss\npsk: "%s"\nlog_level: info\npaths:\n  - transport: wss\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nws_settings:\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_http() {
    local port="$1" psk="$2" http_domain="$3" http_path="$4"
    shift 4
    local ports_json ports_yaml
    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "http",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "http",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$http_domain" "$http_path"; build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: http\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: http\n    maps:\n%s\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$http_domain" "$http_path"; build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_xhttp() {
    local port="$1" psk="$2" path="$3" secure="$4" cert="$5" key="$6"
    local cdn="$7" cdn_host="$8" cdn_port="$9" cdn_ips="${10}" insecure="${11}"
    local pool="${12}" peer_ip="${13}"
    shift 13
    local ports_json ports_yaml transport edge_json edge_yaml peer_json peer_yaml up_concurrency
    local cert_json cert_yaml

    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    edge_json=$(build_edge_ips_json "$cdn_ips")
    edge_yaml=$(build_edge_ips_yaml "$cdn_ips")
    peer_json=$(build_edge_ips_json "$peer_ip")
    peer_yaml=$(build_edge_ips_yaml "$peer_ip")

    transport="xhttp"
    [ "$secure" = "true" ] && transport="xhttps"
    [ -z "$pool" ] && pool=6
    up_concurrency=2
    [ "$cdn" = "true" ] && up_concurrency=8

    cert_json=""
    cert_yaml=""
    if [ "$cdn" != "true" ] && [ "$secure" = "true" ]; then
        cert_json=$(printf '\n  "cert_file": "%s",\n  "key_file": "%s",' "$cert" "$key")
        cert_yaml=$(printf '\ncert_file: "%s"\nkey_file: "%s"' "$cert" "$key")
    fi

    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {
        if [ "$cdn" = "true" ]; then
            printf '{\n  "mode": "server",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "connection_pool": %s,\n      "peer_ips": [%s],\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "auto",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s,\n    "allow_insecure_tls": %s,\n    "cdn": {\n      "enabled": true,\n      "host": "%s",\n      "port": %s,\n      "edge_ips": [%s]\n    }\n  },\n' "$transport" "$psk" "$port" "$pool" "$peer_json" "$ports_json" \
  "$path" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" \
  "$insecure" "$cdn_host" "$cdn_port" "$edge_json"
        else
            printf '{\n  "mode": "server",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",%s\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "auto",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s\n  },\n' "$transport" "$psk" "$cert_json" "$port" "$ports_json" "$path" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES"
        fi
        build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {
        if [ "$cdn" = "true" ]; then
            printf 'mode: server\ntransport: %s\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    connection_pool: %s\n    peer_ips: %s\n    maps:\n%s\nxhttp:\n  path: "%s"\n  mode: auto\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n  allow_insecure_tls: %s\n  cdn:\n    enabled: true\n    host: "%s"\n    port: %s\n    edge_ips: %s\n\n' "$transport" "$psk" "$port" "$pool" "$peer_yaml" "$ports_yaml" \
  "$path" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" \
  "$insecure" "$cdn_host" "$cdn_port" "$edge_yaml"
        else
            printf 'mode: server\ntransport: %s\npsk: "%s"\nlog_level: info%s\nlisteners:\n  - addr: "0.0.0.0:%s"\n    maps:\n%s\nxhttp:\n  path: "%s"\n  mode: auto\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n\n' "$transport" "$psk" "$cert_yaml" "$port" "$ports_yaml" "$path" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES"
        fi
        build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_xhttp() {
    local server_ip="$1" server_port="$2" psk="$3" path="$4" mode="$5" secure="$6"
    local insecure="$7" cdn="$8" cdn_host="$9" cdn_port="${10}" cdn_ips="${11}"
    local origin_port="${12}" cert="${13}" key="${14}" public_ip="${15}"
    local transport addr peer_json peer_yaml cert_json cert_yaml up_concurrency

    transport="xhttp"
    [ "$secure" = "true" ] && transport="xhttps"
    up_concurrency=2
    [ "$cdn" = "true" ] && up_concurrency=8

    addr="${server_ip}:${server_port}"
    peer_json=$(build_edge_ips_json "$(echo "$server_ip" | xargs)")
    peer_yaml=$(build_edge_ips_yaml "$(echo "$server_ip" | xargs)")

    cert_json=""
    cert_yaml=""
    if [ "$cdn" = "true" ] && [ -n "$cert" ] && [ -n "$key" ]; then
        cert_json=$(printf '\n  "cert_file": "%s",\n  "key_file": "%s",' "$cert" "$key")
        cert_yaml=$(printf '\ncert_file: "%s"\nkey_file: "%s"' "$cert" "$key")
    fi

    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        {
        if [ "$cdn" = "true" ]; then
            printf '{\n  "mode": "client",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",%s\n  "paths": [\n    {\n      "addr": "%s",\n      "peer_ips": [%s],\n      "public_ip": "%s",\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "%s",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s,\n    "cdn": {\n      "enabled": true,\n      "origin_bind": "0.0.0.0:%s"\n    }\n  },\n' "$transport" "$psk" "$cert_json" "$addr" "$peer_json" "$public_ip" \
  "$path" "$mode" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$origin_port"
        else
            printf '{\n  "mode": "client",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "addr": "%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "%s",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s,\n    "allow_insecure_tls": %s\n  },\n' "$transport" "$psk" "$addr" "$CLIENT_CONN_POOL" "$path" "$mode" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$insecure"
        fi
        build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        {
        if [ "$cdn" = "true" ]; then
            printf 'mode: client\ntransport: %s\npsk: "%s"\nlog_level: info%s\npaths:\n  - addr: "%s"\n    peer_ips: %s\n    public_ip: "%s"\n    retry_interval: 3\n    dial_timeout: 10\n\nxhttp:\n  path: "%s"\n  mode: "%s"\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n  cdn:\n    enabled: true\n    origin_bind: "0.0.0.0:%s"\n\n' "$transport" "$psk" "$cert_yaml" "$addr" "$peer_yaml" "$public_ip" \
  "$path" "$mode" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$origin_port"
        else
            printf 'mode: client\ntransport: %s\npsk: "%s"\nlog_level: info\npaths:\n  - addr: "%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nxhttp:\n  path: "%s"\n  mode: "%s"\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n  allow_insecure_tls: %s\n\n' "$transport" "$psk" "$addr" "$CLIENT_CONN_POOL" "$path" "$mode" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$insecure"
        fi
        build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_https() {
    local port="$1" psk="$2" http_domain="$3" http_path="$4" cert="$5" key="$6"
    shift 6
    local ports_json ports_yaml
    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "https",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "https",\n      "cert_file": "%s",\n      "key_file": "%s",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$port" "$cert" "$key" "$ports_json" "$http_domain" "$http_path"; build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: https\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: https\n    cert_file: "%s"\n    key_file: "%s"\n    maps:\n%s\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$port" "$cert" "$key" "$ports_yaml" "$http_domain" "$http_path"; build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_https() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "https",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "https",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: https\npsk: "%s"\nlog_level: info\npaths:\n  - transport: https\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_quantum() {
    local port="$1" psk="$2" mtu="$3" block="$4"
    shift 4
    local ports_json ports_yaml
    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "quantum",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "quantum",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "quantum": {\n    "mtu": %s,\n    "block": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$mtu" "$block"; build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: quantum\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: quantum\n    maps:\n%s\nquantum:\n  mtu: %s\n  block: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$mtu" "$block"; build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_quantum() {
    local server_ip="$1" server_port="$2" psk="$3" mtu="$4" block="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "quantum",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "quantum",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "quantum": {\n    "mtu": %s,\n    "block": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$mtu" "$block"; build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: quantum\npsk: "%s"\nlog_level: info\npaths:\n  - transport: quantum\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nquantum:\n  mtu: %s\n  block: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$mtu" "$block"; build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_quantumplus() {
    local port="$1" psk="$2"
    shift 2
    local ports_json ports_yaml
    ports_json=$(build_ports_json "127.0.0.1" "$@")
    ports_yaml=$(build_ports_yaml "127.0.0.1" "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "quantum+",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "quantum+",\n      "maps": [\n%s\n      ]\n    }\n  ],\n' "$psk" "$port" "$ports_json"; build_health_check_json; build_socks5_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: "quantum+"\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: "quantum+"\n    maps:\n%s\n' "$psk" "$port" "$ports_yaml"; build_health_check_yaml; build_socks5_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_quantumplus() {
    local server_ip="$1" server_port="$2" psk="$3"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "quantum+",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "quantum+",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: "quantum+"\npsk: "%s"\nlog_level: info\npaths:\n  - transport: "quantum+"\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_client_config_http() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "http",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "http",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_health_check_json; build_dc_json; build_advanced_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: http\npsk: "%s"\nlog_level: info\npaths:\n  - transport: http\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_health_check_yaml; build_dc_yaml; build_advanced_yaml; } > "$CONFIG"
    fi
}

write_server_config_tun() {
    local port="$1" psk="$2" listen_ip="$3" dst_ip="$4" local_addr="$5" remote_addr="$6"
    local encap="$7" profile="$8" iface="$9" spoof_src="${10}" spoof_dst="${11}" dcpi="${12}" tun_name="${13}"
    local heartbeat_sec="${14}" idle_timeout_sec="${15}"
    shift 15
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$remote_addr" "$@")
    ports_yaml=$(build_ports_yaml "$remote_addr" "$@")
    [ -z "$tun_name" ] && tun_name="dagger0"

    local def_sock_buf="524288"
    local actual_sock_buf="${TUN_SOCK_BUF:-$def_sock_buf}"

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
            printf '      "maps": [\n'
            printf '%s\n'                   "$ports_json"
            printf '      ]\n'
            printf '    }\n'
            printf '  ],\n'
            printf '  "tun": {\n'
            printf '    "encapsulation": "%s",\n' "$encap"
            printf '    "name": "%s",\n'          "$tun_name"
            printf '    "local_addr": "%s",\n'     "$local_addr"
            printf '    "remote_addr": "%s",\n'    "$remote_addr"
            printf '    "profile": "%s",\n' "$TUN_TUNE_PROFILE"
            printf '    "encrypt": true,\n'
            [ -n "$TUN_MTU"        ] && printf '    "mtu": %s,\n' "$TUN_MTU"
            [ -n "$TUN_RX_QUEUE"   ] && printf '    "rx_queue": %s,\n' "$TUN_RX_QUEUE"
            [ -n "$TUN_TXQUEUELEN" ] && printf '    "tx_queue_len": %s,\n' "$TUN_TXQUEUELEN"
            printf '    "heartbeat_sec": %s,\n' "$heartbeat_sec"
            printf '    "idle_timeout_sec": %s\n' "$idle_timeout_sec"
            printf '  },\n'
            printf '  "ipx": {\n'
            printf '    "mode": "server",\n'
            printf '    "profile": "%s",\n'        "$profile"
            { [ "$profile" = "tcp" ] || [ "$profile" = "udp" ]; } && [ -n "$TUN_L4_PORT" ] && printf '    "l4_port": %s,\n' "$TUN_L4_PORT"
            printf '    "listen_ip": "%s",\n'      "$listen_ip"
            printf '    "dst_ip": "%s",\n'         "$dst_ip"
            [ -n "$iface"     ] && printf '    "interface": "%s",\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '    "dcpi_mode": true,\n'
            [ -n "$spoof_src" ] && printf '    "spoof_src_ip": "%s",\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '    "spoof_dst_ip": "%s",\n' "$spoof_dst"
            printf '    "sock_buf": %s\n' "$actual_sock_buf"
            printf '  },\n'
            build_health_check_json
            build_socks5_json
            build_dc_json
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
            printf '    maps:\n'
            printf '%s\n'               "$ports_yaml"
            printf 'tun:\n'
            printf '  encapsulation: "%s"\n' "$encap"
            printf '  name: "%s"\n'          "$tun_name"
            printf '  local_addr: "%s"\n'    "$local_addr"
            printf '  remote_addr: "%s"\n'   "$remote_addr"
            printf '  profile: "%s"\n' "$TUN_TUNE_PROFILE"
            printf '  encrypt: true\n'
            [ -n "$TUN_MTU"        ] && printf '  mtu: %s\n' "$TUN_MTU"
            [ -n "$TUN_RX_QUEUE"   ] && printf '  rx_queue: %s\n' "$TUN_RX_QUEUE"
            [ -n "$TUN_TXQUEUELEN" ] && printf '  tx_queue_len: %s\n' "$TUN_TXQUEUELEN"
            printf '  heartbeat_sec: %s\n' "$heartbeat_sec"
            printf '  idle_timeout_sec: %s\n\n' "$idle_timeout_sec"
            printf 'ipx:\n'
            printf '  mode: server\n'
            printf '  profile: "%s"\n'       "$profile"
            { [ "$profile" = "tcp" ] || [ "$profile" = "udp" ]; } && [ -n "$TUN_L4_PORT" ] && printf '  l4_port: %s\n' "$TUN_L4_PORT"
            printf '  listen_ip: "%s"\n'     "$listen_ip"
            printf '  dst_ip: "%s"\n'        "$dst_ip"
            [ -n "$iface"     ] && printf '  interface: "%s"\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '  dcpi_mode: true\n'
            [ -n "$spoof_src" ] && printf '  spoof_src_ip: "%s"\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '  spoof_dst_ip: "%s"\n' "$spoof_dst"
            printf '  sock_buf: %s\n\n' "$actual_sock_buf"
            build_health_check_yaml
            build_socks5_yaml
            build_dc_yaml
            build_advanced_yaml
        } > "$CONFIG"
    fi
}

write_client_config_tun() {
    local server_port="$1" psk="$2" listen_ip="$3" dst_ip="$4" local_addr="$5" remote_addr="$6"
    local encap="$7" profile="$8" iface="$9" spoof_src="${10}" spoof_dst="${11}" dcpi="${12}" tun_name="${13}"
    local heartbeat_sec="${14}" idle_timeout_sec="${15}"
    [ -z "$tun_name" ] && tun_name="dagger0"

    local def_sock_buf="524288"
    local actual_sock_buf="${TUN_SOCK_BUF:-$def_sock_buf}"

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
            printf '    "profile": "%s",\n' "$TUN_TUNE_PROFILE"
            printf '    "encrypt": true,\n'
            [ -n "$TUN_MTU"        ] && printf '    "mtu": %s,\n' "$TUN_MTU"
            [ -n "$TUN_RX_QUEUE"   ] && printf '    "rx_queue": %s,\n' "$TUN_RX_QUEUE"
            [ -n "$TUN_TXQUEUELEN" ] && printf '    "tx_queue_len": %s,\n' "$TUN_TXQUEUELEN"
            printf '    "heartbeat_sec": %s,\n' "$heartbeat_sec"
            printf '    "idle_timeout_sec": %s\n' "$idle_timeout_sec"
            printf '  },\n'
            printf '  "ipx": {\n'
            printf '    "mode": "client",\n'
            printf '    "profile": "%s",\n'        "$profile"
            { [ "$profile" = "tcp" ] || [ "$profile" = "udp" ]; } && [ -n "$TUN_L4_PORT" ] && printf '    "l4_port": %s,\n' "$TUN_L4_PORT"
            printf '    "listen_ip": "%s",\n'      "$listen_ip"
            printf '    "dst_ip": "%s",\n'         "$dst_ip"
            [ -n "$iface"     ] && printf '    "interface": "%s",\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '    "dcpi_mode": true,\n'
            [ -n "$spoof_src" ] && printf '    "spoof_src_ip": "%s",\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '    "spoof_dst_ip": "%s",\n' "$spoof_dst"
            printf '    "sock_buf": %s\n' "$actual_sock_buf"
            printf '  },\n'
            build_health_check_json
            build_dc_json
            build_advanced_json
            printf '}\n'
        } > "$CONFIG"
    else
        {
            printf 'mode: client\n'
            printf 'transport: tun\n'
            printf 'psk: "%s"\n'          "$psk"
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
            printf '  profile: "%s"\n' "$TUN_TUNE_PROFILE"
            printf '  encrypt: true\n'
            [ -n "$TUN_MTU"        ] && printf '  mtu: %s\n' "$TUN_MTU"
            [ -n "$TUN_RX_QUEUE"   ] && printf '  rx_queue: %s\n' "$TUN_RX_QUEUE"
            [ -n "$TUN_TXQUEUELEN" ] && printf '  tx_queue_len: %s\n' "$TUN_TXQUEUELEN"
            printf '  heartbeat_sec: %s\n' "$heartbeat_sec"
            printf '  idle_timeout_sec: %s\n\n' "$idle_timeout_sec"
            printf 'ipx:\n'
            printf '  mode: client\n'
            printf '  profile: "%s"\n'        "$profile"
            { [ "$profile" = "tcp" ] || [ "$profile" = "udp" ]; } && [ -n "$TUN_L4_PORT" ] && printf '  l4_port: %s\n' "$TUN_L4_PORT"
            printf '  listen_ip: "%s"\n'      "$listen_ip"
            printf '  dst_ip: "%s"\n'         "$dst_ip"
            [ -n "$iface"     ] && printf '  interface: "%s"\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '  dcpi_mode: true\n'
            [ -n "$spoof_src" ] && printf '  spoof_src_ip: "%s"\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '  spoof_dst_ip: "%s"\n' "$spoof_dst"
            printf '  sock_buf: %s\n\n' "$actual_sock_buf"
            build_health_check_yaml
            build_dc_yaml
            build_advanced_yaml
        } > "$CONFIG"
    fi
}

install_service() {
    local extra_env=""
    if [ -n "$SERVER_PUBLIC_IP" ]; then
        extra_env="Environment=DC_SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP}"
    fi
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Tunnel (${SERVICE_NAME})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
${extra_env}
ExecStartPre=-/bin/sh -c 'ip link set dev dagger0 down 2>/dev/null; ip link delete dev dagger0 2>/dev/null; ip route del 10.0.0.1 2>/dev/null; ip route del 10.0.0.2 2>/dev/null || true'
ExecStart=${LAUNCHER} -c ${CONFIG}
ExecStopPost=-/bin/sh -c 'ip link set dev dagger0 down 2>/dev/null; ip link delete dev dagger0 2>/dev/null || true'
Restart=always
RestartSec=5
RestartPreventExitStatus=78
TimeoutStopSec=15
KillSignal=SIGTERM
OOMScoreAdjust=-500
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
SyslogIdentifier=DaggerConnect

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    ok "Service installed: ${SERVICE_NAME}"
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

ask_pair_profile_id() {
    echo "Use the SAME profile ID on this server and all clients of this profile."
    echo "Use a DIFFERENT ID for each separate server profile (for example tunnel-a)."
    while true; do
        ask_required PAIR_PROFILE_ID "Pairing profile ID"
        if [[ "$PAIR_PROFILE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
            break
        fi
        warn "Use 1-64 ASCII letters, digits, dots, underscores or hyphens."
    done
}

install_server() {
    hr "Install Server"
    ensure_launcher
    check_ptrace_scope
    tune_network
    echo ""

    ask_service_name
    ask_pair_profile_id
    echo ""

    ask_server_public_ip
    echo ""

    ask_transport
    echo ""

    PORT="8443"
    info "Listen Port : ${PORT} (default)"
    echo ""

    PSK="123"
    info "PSK         : ${PSK} (default)"
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
        xhttp|xhttps)
            ask_xhttp server
            if [ "$TRANSPORT" = "xhttps" ]; then
                ask_xhttp_cdn server
            else
                XHTTP_CDN="false"; XHTTP_CDN_HOST=""; XHTTP_CDN_PORT="80"
                XHTTP_CDN_IPS=""; XHTTP_INSECURE="true"; XHTTP_ORIGIN_PORT="8443"
                XHTTP_PEER_IP=""; XHTTP_PUBLIC_IP=""; XHTTP_CDN_POOL="6"
            fi
            if [ "$XHTTP_CDN" = "true" ]; then
                PORT="$XHTTP_CDN_PORT"
            else
                PORT="8443"
            fi
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
            echo -e "  ${BOLD}TUN Encapsulation (profile):${NC}"
            echo "    1)  tcp   — forged TCP segments"
            echo "    2)  udp   — forged UDP datagrams"
            echo "    3)  icmp  — ICMP encapsulation"
            echo "    4)  gre   — GRE   (proto 47)"
            echo "    5)  ipip  — IP-in-IP (proto 4)"
            echo "    6)  bip   — BIP/ICMP custom (raw IP_HDRINCL)"
            echo ""
            ask TUN_PROFILE_CHOICE "Profile" "1"
            case "$TUN_PROFILE_CHOICE" in
                2|udp)  TUN_PROFILE="udp"  ;;
                3|icmp) TUN_PROFILE="icmp" ;;
                4|gre)  TUN_PROFILE="gre"  ;;
                5|ipip) TUN_PROFILE="ipip" ;;
                6|bip)  TUN_PROFILE="bip"  ;;
                *)      TUN_PROFILE="tcp"  ;;
            esac
            TUN_ENCAP="ipx"
            TUN_L4_PORT=""
            if [ "$TUN_PROFILE" = "tcp" ] || [ "$TUN_PROFILE" = "udp" ]; then
                echo ""
                echo -e "  ${DIM}Service port = destination port of client→server frames.${NC}"
                echo -e "  ${DIM}443 looks like HTTPS and clears the most restrictive egress firewalls.${NC}"
                ask TUN_L4_PORT "L4 service port" "443"
            fi
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Server real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Client real IP"
            echo ""
            ask TUN_LOCAL_ADDR  "TUN local IP    (server side)" "10.0.0.1"
            ask TUN_REMOTE_ADDR "TUN remote IP  (client side)" "10.0.0.2"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface  (leave empty for auto-detect)" ""
            ask TUN_NAME  "TUN device name" "dagger0"
            echo ""
            ask TUN_HEARTBEAT_SEC    "Heartbeat interval (sec)" "10"
            ask TUN_IDLE_TIMEOUT_SEC "Idle timeout (sec)" "90"
            ask_tun_profile
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

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "https" ] || \
       { [ "$TRANSPORT" = "xhttps" ] && [ "$XHTTP_CDN" != "true" ]; }; then
        ask_ssl_cert
        echo ""
    fi

    ask_ports
    echo ""

    ask_socks5
    echo ""

    ask_dc
    ask_advanced
    echo ""

    case "$TRANSPORT" in
        tcp)      write_server_config_tcp     "$PORT" "$PSK" "${PORTS[@]}" ;;
        ws)       write_server_config_ws      "$PORT" "$PSK" "$WS_PATH" "${PORTS[@]}" ;;
        wss)      write_server_config_wss     "$PORT" "$PSK" "$WS_PATH" "$CERT_FILE" "$KEY_FILE" "${PORTS[@]}" ;;
        http)     write_server_config_http    "$PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "${PORTS[@]}" ;;
        https)    write_server_config_https   "$PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "$CERT_FILE" "$KEY_FILE" "${PORTS[@]}" ;;
        quantum)  write_server_config_quantum "$PORT" "$PSK" "$QM_MTU" "$QM_BLOCK" "${PORTS[@]}" ;;
        quantum+) write_server_config_quantumplus "$PORT" "$PSK" "${PORTS[@]}" ;;
        xhttp)    write_server_config_xhttp   "$PORT" "$PSK" "$XHTTP_PATH" "false" "" "" \
                      "$XHTTP_CDN" "$XHTTP_CDN_HOST" "$XHTTP_CDN_PORT" "$XHTTP_CDN_IPS" "$XHTTP_INSECURE" \
                      "$XHTTP_CDN_POOL" "$XHTTP_PEER_IP" "${PORTS[@]}" ;;
        xhttps)   write_server_config_xhttp   "$PORT" "$PSK" "$XHTTP_PATH" "true" "$CERT_FILE" "$KEY_FILE" \
                      "$XHTTP_CDN" "$XHTTP_CDN_HOST" "$XHTTP_CDN_PORT" "$XHTTP_CDN_IPS" "$XHTTP_INSECURE" \
                      "$XHTTP_CDN_POOL" "$XHTTP_PEER_IP" "${PORTS[@]}" ;;
        tun)      write_server_config_tun     "$PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_ENCAP" "$TUN_PROFILE" "$TUN_IFACE" "$TUN_SPOOF_SRC" "$TUN_SPOOF_DST" "$TUN_DCPI" "$TUN_NAME" "$TUN_HEARTBEAT_SEC" "$TUN_IDLE_TIMEOUT_SEC" "${PORTS[@]}" ;;
    esac
    chmod 0600 "$CONFIG"
    ok "Config written: ${CONFIG}"

    install_service
    start_service

    echo ""
    echo -e "${GREEN}${BOLD}  Server installed successfully.${NC}"
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
}

install_client() {
    hr "Install Client"
    ensure_launcher
    check_ptrace_scope
    tune_network
    echo ""

    ask_service_name
    ask_pair_profile_id
    echo ""

    ask_transport
    echo ""

    if [ "$TRANSPORT" != "tun" ] && [ "$TRANSPORT" != "xhttp" ] && [ "$TRANSPORT" != "xhttps" ]; then
        ask_connection_pool
    fi

    SERVER_PORT="8443"
    if [ "$TRANSPORT" = "tun" ]; then
        :
    elif [ "$TRANSPORT" = "xhttp" ] || [ "$TRANSPORT" = "xhttps" ]; then
        :
    else
        while true; do
            ask SERVER_ADDR "Server IP" ""
            if [ -z "$SERVER_ADDR" ]; then
                warn "IP cannot be empty."
                continue
            fi
            if [[ "$SERVER_ADDR" == *:* ]]; then
                SERVER_IP="${SERVER_ADDR%%:*}"
                SERVER_PORT="${SERVER_ADDR##*:}"
            else
                SERVER_IP="$SERVER_ADDR"
                SERVER_PORT="8443"
            fi
            if validate_ip "$SERVER_IP"; then
                break
            fi
            warn "Invalid IP format."
        done
        info "Target : ${SERVER_IP}:${SERVER_PORT}"
        echo ""
    fi

    PSK="123"
    info "PSK    : ${PSK} (default)"
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
        xhttp|xhttps)
            ask_xhttp client
            if [ "$TRANSPORT" = "xhttps" ]; then
                ask_xhttp_cdn client
            else
                XHTTP_CDN="false"; XHTTP_CDN_HOST=""; XHTTP_CDN_PORT="80"
                XHTTP_CDN_IPS=""; XHTTP_INSECURE="true"; XHTTP_ORIGIN_PORT="8443"
                XHTTP_PEER_IP=""; XHTTP_PUBLIC_IP=""; XHTTP_CDN_POOL="6"
            fi
            if [ "$XHTTP_CDN" = "true" ]; then
                echo ""
                while true; do
                    ask_required SERVER_IP "Server IP"
                    if ! validate_ip "$SERVER_IP"; then
                        warn "That is not an IP address."
                        continue
                    fi
                    if [ -n "$XHTTP_PUBLIC_IP" ] && [ "$SERVER_IP" = "$XHTTP_PUBLIC_IP" ]; then
                        warn "That is the same as the Client IP (${XHTTP_PUBLIC_IP})."
                        continue
                    fi
                    break
                done
                echo ""
                SERVER_PORT="$XHTTP_ORIGIN_PORT"
                CLIENT_CONN_POOL=6
                ask_ssl_cert
            else
                echo ""
                ask_connection_pool
                while true; do
                    ask SERVER_ADDR "Server IP" ""
                    if [ -z "$SERVER_ADDR" ]; then
                        warn "IP cannot be empty."
                        continue
                    fi
                    if [[ "$SERVER_ADDR" == *:* ]]; then
                        SERVER_IP="${SERVER_ADDR%%:*}"
                        SERVER_PORT="${SERVER_ADDR##*:}"
                    else
                        SERVER_IP="$SERVER_ADDR"
                        SERVER_PORT="8443"
                    fi
                    if validate_ip "$SERVER_IP"; then
                        break
                    fi
                    warn "Invalid IP format."
                done
                info "Target : ${SERVER_IP}:${SERVER_PORT}"
            fi
            echo ""
            ;;
        quantum)
            echo -e "  ${DIM}Quantum auto-detects the network interface, source IP, and gateway MAC at runtime.${NC}"
            echo ""
            ask QM_MTU   "MTU" "1350"
            ask QM_BLOCK "KCP header cipher  (must match server, aes/salsa20/none)" "aes"
            echo ""
            ;;
        tun)
            echo ""
            echo -e "  ${BOLD}TUN Encapsulation / profile (must match server):${NC}"
            echo "    1)  tcp   2)  udp   3)  icmp   4)  gre   5)  ipip   6)  bip"
            echo ""
            ask TUN_PROFILE_CHOICE "Profile" "1"
            case "$TUN_PROFILE_CHOICE" in
                2|udp)  TUN_PROFILE="udp"  ;;
                3|icmp) TUN_PROFILE="icmp" ;;
                4|gre)  TUN_PROFILE="gre"  ;;
                5|ipip) TUN_PROFILE="ipip" ;;
                6|bip)  TUN_PROFILE="bip"  ;;
                *)      TUN_PROFILE="tcp"  ;;
            esac
            TUN_ENCAP="ipx"
            TUN_L4_PORT=""
            if [ "$TUN_PROFILE" = "tcp" ] || [ "$TUN_PROFILE" = "udp" ]; then
                echo ""
                ask TUN_L4_PORT "L4 service port" "443"
            fi
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Client real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Server real IP"
            echo ""
            ask TUN_LOCAL_ADDR  "TUN local IP    (client side)" "10.0.0.2"
            ask TUN_REMOTE_ADDR "TUN remote IP  (server side)" "10.0.0.1"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface  (leave empty for auto-detect)" ""
            ask TUN_NAME  "TUN device name" "dagger0"
            echo ""
            ask TUN_HEARTBEAT_SEC    "Heartbeat interval (sec)" "10"
            ask TUN_IDLE_TIMEOUT_SEC "Idle timeout (sec)" "90"
            ask_tun_profile
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

    ask_dc
    ask_advanced
    echo ""

    case "$TRANSPORT" in
        tcp)      write_client_config_tcp     "$SERVER_IP" "$SERVER_PORT" "$PSK" ;;
        ws)       write_client_config_ws      "$SERVER_IP" "$SERVER_PORT" "$PSK" "$WS_PATH" ;;
        wss)      write_client_config_wss     "$SERVER_IP" "$SERVER_PORT" "$PSK" "$WS_PATH" ;;
        http)     write_client_config_http    "$SERVER_IP" "$SERVER_PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" ;;
        https)    write_client_config_https   "$SERVER_IP" "$SERVER_PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" ;;
        quantum)  write_client_config_quantum "$SERVER_IP" "$SERVER_PORT" "$PSK" "$QM_MTU" "$QM_BLOCK" ;;
        quantum+) write_client_config_quantumplus "$SERVER_IP" "$SERVER_PORT" "$PSK" ;;
        xhttp)    write_client_config_xhttp   "$SERVER_IP" "$SERVER_PORT" "$PSK" "$XHTTP_PATH" "$XHTTP_MODE" "false" \
                      "$XHTTP_INSECURE" "$XHTTP_CDN" "$XHTTP_CDN_HOST" "$XHTTP_CDN_PORT" "$XHTTP_CDN_IPS" \
                      "$XHTTP_ORIGIN_PORT" "$CERT_FILE" "$KEY_FILE" "$XHTTP_PUBLIC_IP" ;;
        xhttps)   write_client_config_xhttp   "$SERVER_IP" "$SERVER_PORT" "$PSK" "$XHTTP_PATH" "$XHTTP_MODE" "true" \
                      "$XHTTP_INSECURE" "$XHTTP_CDN" "$XHTTP_CDN_HOST" "$XHTTP_CDN_PORT" "$XHTTP_CDN_IPS" \
                      "$XHTTP_ORIGIN_PORT" "$CERT_FILE" "$KEY_FILE" "$XHTTP_PUBLIC_IP" ;;
        tun)      write_client_config_tun     "$SERVER_PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_ENCAP" "$TUN_PROFILE" "$TUN_IFACE" "$TUN_SPOOF_SRC" "$TUN_SPOOF_DST" "$TUN_DCPI" "$TUN_NAME" "$TUN_HEARTBEAT_SEC" "$TUN_IDLE_TIMEOUT_SEC" ;;
    esac
    chmod 0600 "$CONFIG"
    ok "Config written: ${CONFIG}"

    install_service
    start_service

    echo ""
    echo -e "${GREEN}${BOLD}  Client installed successfully.${NC}"
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
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
            echo "   $((i+1)))  ${SERVICES[$i]}"
        done
        echo ""
        ask IDX "Select number" "1"
        TARGET="${SERVICES[$((IDX-1))]}"
    fi
    journalctl -u "$TARGET" -n 80 --no-pager
}

uninstall() {
    hr "Remove All"
    echo ""
    info "Removing all DaggerConnect services and configurations..."
    mapfile -t SERVICES < <(list_services)
    for svc in "${SERVICES[@]}"; do
        svc_name="${svc%.service}"
        systemctl stop    "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc_name}.service"
        rm -f "${CONFIG_DIR}/${svc_name}.json"
        rm -f "${CONFIG_DIR}/${svc_name}.yaml"
        rm -f "/etc/letsencrypt/renewal-hooks/deploy/daggerconnect-${svc_name}.sh" 2>/dev/null || true
        ok "Removed service: ${svc_name}"
    done
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    systemctl daemon-reload
    ok "All DaggerConnect services and configurations removed successfully."
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
        echo -e "     $((i+1)))  ${SERVICES[$i]}   [${st}]"
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
    local st
    systemctl is-active --quiet "$svc" && st="${GREEN}running${NC}" || st="${RED}stopped${NC}"
    echo -e "  Selected : ${BOLD}${svc}${NC}   [${st}]"
    echo ""
    echo "   1)  Restart"
    echo "   2)  Stop"
    echo "   3)  Start"
    echo "   4)  Status"
    echo "   0)  Back"
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

show_banner() {
    echo ""
    echo -e "  ${CYAN}${BOLD}DaggerConnect Installer${NC}  -  offline build"
    echo ""
}

show_menu() {
    echo -e "${BOLD}Select an option:${NC}"
    echo " 1) Install Server"
    echo " 2) Install Client"
    echo " 3) Service Status"
    echo " 4) Service Control (restart / stop / start)"
    echo " 5) Edit Config"
    echo " 6) View Logs (last 80 lines)"
    echo " 7) Live Logs (follow)"
    echo " 8) Remove"
    echo " 9) Update Launcher"
    echo " 0) Exit"
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

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0 2>/dev/null || true
fi

[ "$EUID" -ne 0 ] && { echo -e "${RED}[ERR ]${NC}  Run as root: sudo bash setup.sh"; exit 1; }
ensure_runtime_dependencies

while true; do
    clear 2>/dev/null || true
    show_banner
    show_menu

    case "$CHOICE" in
        1) run_action install_server ;;
        2) run_action install_client ;;
        3) run_action show_status     ;;
        4) run_action service_control ;;
        5) run_action edit_config     ;;
        6) run_action show_logs       ;;
        7) run_action show_logs_live  ;;
        8) run_action uninstall       ;;
        9) run_action update_launcher ;;
        0) echo -e "\n  ${CYAN}Bye.${NC}\n"; exit 0 ;;
        *) warn "Invalid choice: ${CHOICE}" ;;
    esac

    pause
done
