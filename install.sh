#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'
if [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ] || [ -n "${NO_COLOR+x}" ]; then
    RED='' GREEN='' YELLOW='' CYAN='' MAGENTA='' DIM='' BOLD='' NC=''
fi

LAUNCHER="/usr/local/bin/DaggerConnect"
CORE_ZIP_URL="https://github.com/parhampahlevann/dagger/releases/download/v1.0/DaggerConnect3.2.zip"
LOCAL_ZIP_CACHE="/var/tmp/DaggerConnect3.2.zip"
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
CHANNEL="offline"
VERSION="v3.2"
SERVER_PUBLIC_IP=""
SSL_MODE=""
DOMAIN=""
CERT_FILE=""
KEY_FILE=""

info()  { printf '  %b•%b %s\n' "$CYAN" "$NC" "$*"; }
ok()    { printf '  %b✓ OK%b  %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '  %b!%b  %s\n' "$YELLOW" "$NC" "$*"; }
step()  { printf '\n  %b▸ %s%b\n' "$BOLD" "$*" "$NC"; }
error() { printf '  %b✗ Error:%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
hr()    { printf '\n  %b━━━ %s ━━━%b\n\n' "$MAGENTA$BOLD" "$*" "$NC"; }

have_libpcap() {
    if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q 'libpcap\.so'; then
        return 0
    fi
    local d
    for d in /usr/lib /usr/lib64 /lib /lib64 /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu \
             /lib/x86_64-linux-gnu /lib/aarch64-linux-gnu /usr/local/lib; do
        compgen -G "${d}/libpcap.so*" >/dev/null 2>&1 && return 0
    done
    return 1
}

install_packages() {
    local -a apt=() rpm=() apk=() pac=()
    local mode=apt arg
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            case "$mode" in apt) mode=rpm ;; rpm) mode=apk ;; apk) mode=pac ;; esac
            continue
        fi
        case "$mode" in apt) apt+=("$arg") ;; rpm) rpm+=("$arg") ;; apk) apk+=("$arg") ;; pac) pac+=("$arg") ;; esac
    done
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt[@]}" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${rpm[@]}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${rpm[@]}" >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install "${rpm[@]}" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${apk[@]}" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed "${pac[@]}" >/dev/null 2>&1
    else
        return 1
    fi
}

ensure_runtime_dependencies() {
    local missing=0 cmd
    for cmd in curl od cmp wc python3 iptables ip unzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done
    have_libpcap || missing=1
    [ "$missing" -eq 0 ] && return 0

    info "Checking and installing required system packages..."
    if ! install_packages ca-certificates curl coreutils python3 iptables iproute2 unzip -- \
             ca-certificates curl coreutils python3 iptables iproute unzip -- \
             ca-certificates curl coreutils python3 iptables iproute2 unzip -- \
             ca-certificates curl coreutils python gawk iptables iproute2 unzip; then
        command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 ||
            warn "Some tools are missing and no supported online package manager succeeded."
    fi
    if ! have_libpcap; then
        install_packages libpcap0.8t64 -- libpcap -- libpcap -- libpcap ||
            install_packages libpcap0.8 -- libpcap -- libpcap -- libpcap || true
    fi
    for cmd in od cmp wc python3; do
        command -v "$cmd" >/dev/null 2>&1 || error "Required command is missing: ${cmd}"
    done
    command -v iptables >/dev/null 2>&1 || warn "iptables is not installed: raw transports may disconnect soon after they connect."
    command -v ip >/dev/null 2>&1 || warn "iproute2 (ip) is not installed: the tun transport cannot create its device."
    have_libpcap || warn "libpcap is not installed: install it (libpcap0.8 / libpcap) before starting the service."
}

ask() {
    local var="$1" prompt="$2" default="$3" input
    while true; do
        if [ -n "$default" ]; then
            printf '  %b?%b %s [%b%s%b]: ' "$CYAN" "$NC" "$prompt" "$GREEN" "$default" "$NC"
        else
            printf '  %b?%b %s: ' "$CYAN" "$NC" "$prompt"
        fi
        if ! read -r input; then
            printf '\n' >&2
            exit 130
        fi
        [ -z "$input" ] && [ -n "$default" ] && input="$default"
        case "$prompt" in
            *'(y/n)'*)
                case "${input,,}" in
                    y|yes) input=y ;;
                    n|no) input=n ;;
                    *) warn "Enter y or n."; continue ;;
                esac ;;
            *'(yes/no)'*)
                case "${input,,}" in
                    yes) input=yes ;;
                    no) input=no ;;
                    *) warn "Enter yes or no."; continue ;;
                esac ;;
        esac
        break
    done
    printf -v "$var" '%s' "$input"
}

ask_required() {
    local var="$1" prompt="$2" default="${3:-}"
    while true; do
        ask "$var" "$prompt" "$default"
        [ -n "${!var}" ] && break
        warn "This field cannot be empty."
    done
}

validate_label() {
    echo "$1" | grep -qE '^[A-Za-z0-9_-]+$'
}

ask_service_name() {
    local svc_name svc_file rand_suffix def_label

    while true; do
        rand_suffix=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
        [ -z "$rand_suffix" ] && rand_suffix="$((RANDOM % 9000 + 1000))"
        def_label="dc-${rand_suffix}"

        ask LABEL "Service name (Enter for random)" "$def_label"
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
            ask OVERWRITE "Overwrite? (y/n)" "y"
            if [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ]; then
                break
            fi
            info "Enter a different service name."
            echo ""
            continue
        fi

        break
    done

    CONFIG_FMT="json"
    SERVICE_NAME="${LABEL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.${CONFIG_FMT}"

    echo ""
    info "Service Name : ${SERVICE_NAME}"
    info "Config File  : ${CONFIG}"
}

detect_server_public_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')
    if validate_ip "$ip"; then
        echo "$ip"
        return 0
    fi
    return 1
}

validate_ip() {
    local value="$1" part
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local -a octets
    IFS=. read -r -a octets <<< "$value"
    for part in "${octets[@]}"; do
        [[ "$part" = "0" || "$part" != 0* ]] || return 1
        (( 10#$part <= 255 )) || return 1
    done
}

validate_public_ip() {
    validate_ip "$1" || return 1
    return 0
}

ask_server_public_ip() {
    SERVER_PUBLIC_IP=$(detect_server_public_ip || echo "0.0.0.0")
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}${CYAN}Select Transport Protocol:${NC}"
    echo -e "  ┌──────────────────────────────────────────────────────────┐"
    echo -e "  │  ${GREEN}1)${NC} tcp              ${GREEN}6)${NC} quantum          ${GREEN}11)${NC} dc6         │"
    echo -e "  │  ${GREEN}2)${NC} ws               ${GREEN}7)${NC} quantum+         ${GREEN}12)${NC} q-gaming    │"
    echo -e "  │  ${GREEN}3)${NC} wss              ${GREEN}8)${NC} tun              ${GREEN}13)${NC} nova        │"
    echo -e "  │  ${GREEN}4)${NC} http             ${GREEN}9)${NC} xhttp                            │"
    echo -e "  │  ${GREEN}5)${NC} https           ${GREEN}10)${NC} xhttps                           │"
    echo -e "  └──────────────────────────────────────────────────────────┘"
    echo ""
    QM_PROFILE=""
    while true; do
        ask T_CHOICE "Transport" "1"
        case "$T_CHOICE" in
            1|tcp)     TRANSPORT="tcp";     break ;;
            2|ws)      TRANSPORT="ws";      break ;;
            3|wss)     TRANSPORT="wss";     break ;;
            4|http)    TRANSPORT="http";    break ;;
            5|https)   TRANSPORT="https";   break ;;
            6|quantum) TRANSPORT="quantum"; break ;;
            7|quantum+|quantumplus|qplus) TRANSPORT="quantum+"; break ;;
            8|tun)     TRANSPORT="tun";     break ;;
            9|xhttp)   TRANSPORT="xhttp";   break ;;
            10|xhttps) TRANSPORT="xhttps";  break ;;
            11|dc6)    TRANSPORT="dc6";     break ;;
            12|quantum-gaming|quantumgaming|qgaming)
                TRANSPORT="quantum"; QM_PROFILE="gaming"
                info "Quantum Gaming is Quantum with quantum.profile=gaming. Use it on BOTH endpoints."
                break ;;
            13|nova)   TRANSPORT="nova";    break ;;
            *) warn "Please enter 1-13 or transport name." ;;
        esac
    done
}

select_transport_release() {
    CHANNEL="offline"
    VERSION="v3.2"
    info "Core Binary : DaggerConnect ${VERSION} (Offline Standalone)"
    return 0
}

version_at_least() {
    return 0
}

config_needs_new_transport_core() {
    return 1
}

validate_transport_ip() {
    python3 -c '
import ipaddress, sys
try:
    value, family, side = sys.argv[1:]
    if "%" in value: raise ValueError()
    ip = ipaddress.ip_address(value)
    valid = ip.version == int(family) and not ip.is_multicast and not ip.is_loopback and not ip.is_link_local
    if ip.version == 6:
        valid = valid and ip.ipv4_mapped is None and (not ip.is_unspecified or side == "server")
    else:
        valid = valid and not ip.is_unspecified and str(ip) != "255.255.255.255"
    sys.exit(0 if valid else 1)
except ValueError:
    sys.exit(1)
' "$1" "$2" "$3"
}

local_has_transport_ip() {
    ip -j addr show 2>/dev/null | python3 -c '
import ipaddress, json, sys
try:
    wanted = ipaddress.ip_address(sys.argv[1])
    found = any(ipaddress.ip_address(a["local"]) == wanted
                for iface in json.load(sys.stdin) for a in iface.get("addr_info", []) if "local" in a)
    sys.exit(0 if found else 1)
except (ValueError, KeyError):
    sys.exit(1)
' "$1"
}

ask_dc6_address() {
    local side="$1" value default=""
    [ "$side" = "server" ] && default="::"
    info "IPv6 tunnel configuration."
    while true; do
        if [ "$side" = "server" ]; then
            ask value "Local IPv6 to listen on (:: = all IPv6 interfaces, no port)" "$default"
        else
            ask_required value "Server IPv6 for tunnel traffic (address only, no port)"
        fi
        value="${value#[}"; value="${value%]}"
        if ! validate_transport_ip "$value" 6 "$side"; then
            warn "Enter an IPv6 unicast address; no IPv4, zone, link-local address or port."
            continue
        fi
        if [ "$side" = "server" ] && [ "$value" != "::" ] && ! local_has_transport_ip "$value"; then
            warn "That IPv6 is not assigned locally. Choose a local address or ::."
            continue
        fi
        DC6_IPV6="$value"
        break
    done
}

lane_tcp_port() {
    local p="$1"
    if [ $((p + 256)) -le 65535 ]; then echo $((p + 256)); else echo $((p - 257)); fi
}

show_firewall_note() {
    local port="$1" lane knock
    lane=$(lane_tcp_port "$port")
    knock=$((port + 10000)); [ "$knock" -gt 65535 ] && knock=$((port - 1000))
    case "$TRANSPORT" in
        tcp|ws|wss|http|https)
            echo -e "  ${DIM}Firewall: TCP ${port}; also UDP ${port} (the KCP carrier takes over when TCP will not connect).${NC}" ;;
        xhttp|xhttps)
            [ "$XHTTP_CDN" = "true" ] || echo -e "  ${DIM}Firewall: TCP ${port}; also UDP ${port} (KCP carrier).${NC}" ;;
        quantum+)
            echo -e "  ${YELLOW}Firewall: UDP ${port}, UDP ${knock} (knock) and TCP ${lane} (lane, used where UDP is cut).${NC}" ;;
        quantum)
            echo -e "  ${YELLOW}Firewall: TCP ${port}..$((port + 255)) (raw range) and TCP ${lane} (lane).${NC}" ;;
        nova)
            echo -e "  ${YELLOW}Firewall: TCP ${port}..$((port + 255)) (raw range) and TCP ${lane} (lane).${NC}" ;;
        tun)
            echo -e "  ${YELLOW}Firewall: TCP $(lane_tcp_port "${TUN_L4_PORT:-443}") (lane; the raw wire needs no port).${NC}" ;;
    esac
}

show_new_transport_summary() {
    local side="$1" port
    if [ "$side" = "server" ]; then port="$PORT"; else port="$SERVER_PORT"; fi
    case "$TRANSPORT" in
        dc6)
            info "IPv6 tunnel endpoint : [${DC6_IPV6}]:${port}"
            warn "Allow TCP and UDP on the tunnel port in the server's IPv6 firewall; both hosts need working IPv6 routing."
            ;;
    esac
    return 0
}

ask_xhttp() {
    local side="$1"
    echo ""
    echo -e "  ${BOLD}xhttp settings${NC}"
    ask XHTTP_PATH "URL path (must match the other side)" "/api/v2"
    case "$XHTTP_PATH" in
        /*) ;;
        *) XHTTP_PATH="/$XHTTP_PATH" ;;
    esac

    if [ "$side" = "client" ]; then
        echo ""
        echo -e "  ${BOLD}Upload mode${NC}"
        printf '    1) auto\n    2) streaming\n    3) sequenced\n\n'
        while true; do
            ask XHTTP_MODE_CHOICE "Upload mode" "1"
            case "$XHTTP_MODE_CHOICE" in
                1|auto) XHTTP_MODE="auto"; break ;;
                2|stream|streaming|stream-up) XHTTP_MODE="stream-up"; break ;;
                3|packet|sequenced|packet-up) XHTTP_MODE="packet-up"; break ;;
                *) warn "Choose 1-3." ;;
            esac
        done
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
        ask_num_range XHTTP_ORIGIN_PORT "Origin port" 8443 1 65535

        echo ""
        local mine
        mine=$(detect_server_public_ip)
        while true; do
            ask XHTTP_PUBLIC_IP "Client IP (blank = skip)" "$mine"
            [ -z "$XHTTP_PUBLIC_IP" ] && break
            validate_ip "$XHTTP_PUBLIC_IP" && break
            warn "That is not an IP address."
        done
        return
    fi

    ask_required XHTTP_CDN_HOST "Your Cloudflare-proxied domain (e.g. cdn.example.com)"
    echo ""
    echo -e "  ${YELLOW}That domain's DNS record must point at the FOREIGN server,${NC}"
    echo -e "  ${YELLOW}not at this one, with the orange cloud on.${NC}"
    echo ""
    echo -e "  ${DIM}Cloudflare forwards these HTTPS ports only:${NC}"
    echo -e "  ${DIM}443, 2053, 2083, 2087, 2096, 8443${NC}"
    echo -e "  ${DIM}Use the same port the far side waits on.${NC}"
    ask_num_range XHTTP_CDN_PORT "Port" 8443 1 65535
    echo ""
    echo -e "  ${BOLD}Edge IPv4 addresses (comma-separated)${NC}"
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
    ask_num_range XHTTP_CDN_POOL "Connections" 6 1 64

    echo ""
    while true; do
        ask XHTTP_PEER_IP "Client IPv4 (blank = any)" ""
        [ -z "$XHTTP_PEER_IP" ] && break
        validate_ip "$XHTTP_PEER_IP" && break
        warn "Enter a valid IPv4 address."
    done
    [ -n "$XHTTP_PEER_IP" ] && ok "Only ${XHTTP_PEER_IP} will be accepted"
    return 0
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
    local -a _NIPS
    IFS=',' read -ra _NIPS <<< "$list"
    for ip in "${_NIPS[@]}"; do
        ip="$(echo "$ip" | xargs)"
        [ -z "$ip" ] && continue
        case ",${out}," in *",${ip},"*) continue ;; esac
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
        error "Port 80 is busy. Free it before requesting a certificate."
    fi

    info "Obtaining SSL certificate for: ${domain}"
    if certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$domain" \
        --http-01-port 80; then
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
    echo "    1)  Self-signed"
    echo "    2)  Let's Encrypt"
    echo "    3)  Custom"
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
            info "DNS must point here and TCP port 80 must be reachable."
            ask_required DOMAIN "Domain name (e.g. tunnel.example.com)"
            echo ""
            obtain_cert_auto "$DOMAIN"
            ;;
        custom)
            echo ""
            while true; do
                ask_required CERT_FILE "Certificate file path (e.g. /etc/ssl/certs/cert.pem)"
                [ -f "$CERT_FILE" ] && break
                warn "File not found: ${CERT_FILE}"
            done
            while true; do
                ask_required KEY_FILE "Private key file path (e.g. /etc/ssl/private/key.pem)"
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
        echo -e "  ${DIM}Recommended: sysctl -w kernel.yama.ptrace_scope=2${NC}"
    fi
}

tune_network() {
    info "This core tunes kernel buffer/queue ceilings automatically at tunnel startup."
    info "Existing sysctl files, congestion control and interface queues are preserved."
}

extract_zip_to_launcher() {
    local zip_path="$1"
    local tmp_dir found_bin="" f magic size
    tmp_dir=$(mktemp -d /var/tmp/dc-extract.XXXXXX) || return 1

    if ! python3 -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "r") as z:
    z.extractall(sys.argv[2])
' "$zip_path" "$tmp_dir" 2>/dev/null; then
        if command -v unzip >/dev/null 2>&1; then
            unzip -q -o "$zip_path" -d "$tmp_dir" >/dev/null 2>&1 || { rm -rf "$tmp_dir"; return 1; }
        else
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    while IFS= read -r -d '' f; do
        size=$(wc -c < "$f" 2>/dev/null || echo 0)
        magic=$(LC_ALL=C od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
        if [ "$magic" = "7f454c46" ] && [ "$size" -gt 100000 ]; then
            found_bin="$f"
            break
        fi
    done < <(find "$tmp_dir" -type f -print0)

    if [ -z "$found_bin" ]; then
        rm -rf "$tmp_dir"
        warn "No valid Linux ELF binary found inside ${zip_path}."
        return 1
    fi

    mkdir -p "$(dirname "$LAUNCHER")"
    chmod 0755 "$found_bin"
    mv -f "$found_bin" "$LAUNCHER"
    ln -sf "$LAUNCHER" /usr/local/bin/DaggerLauncher 2>/dev/null || true
    rm -rf "$tmp_dir"
    return 0
}

download_latest_launcher() {
    local cand
    for cand in "./DaggerConnect3.2.zip" "/root/DaggerConnect3.2.zip" "/tmp/DaggerConnect3.2.zip" "$LOCAL_ZIP_CACHE"; do
        if [ -f "$cand" ]; then
            info "Found local offline archive: ${cand}"
            if extract_zip_to_launcher "$cand"; then
                return 0
            fi
        fi
    done

    local tmp_zip
    tmp_zip=$(mktemp /var/tmp/dc-zip.XXXXXX.zip) || return 1
    info "Fetching DaggerConnect3.2.zip from repository..."
    if ! curl --fail --silent --show-error --location \
        --retry 3 --retry-delay 2 --retry-connrefused \
        --connect-timeout 15 --max-time 180 \
        -o "$tmp_zip" "$CORE_ZIP_URL"; then
        rm -f "$tmp_zip"
        return 1
    fi

    cp -f "$tmp_zip" "$LOCAL_ZIP_CACHE" 2>/dev/null || true
    if extract_zip_to_launcher "$tmp_zip"; then
        rm -f "$tmp_zip"
        return 0
    fi
    rm -f "$tmp_zip"
    return 1
}

ensure_launcher() {
    if [ -x "$LAUNCHER" ]; then
        ok "Offline Core binary ready : ${LAUNCHER}"
        return 0
    fi
    info "Installing DaggerConnect core binary..."
    if download_latest_launcher; then
        ok "DaggerConnect binary installed : ${LAUNCHER}"
        return 0
    fi
    error "Failed to install DaggerConnect binary. Place DaggerConnect3.2.zip in /root or current directory for offline setup, or check your network."
}

update_launcher() {
    hr "Reinstall / Update Core Binary"
    echo ""

    step "Installing DaggerConnect from DaggerConnect3.2.zip..."
    rm -f "$LOCAL_ZIP_CACHE" 2>/dev/null || true
    if ! download_latest_launcher; then
        error "Installation failed -- check network or place DaggerConnect3.2.zip in /root."
    fi
    ok "DaggerConnect binary updated : ${LAUNCHER}"

    mapfile -t SERVICES < <(list_services)
    local running=()
    for svc in "${SERVICES[@]}"; do
        systemctl is-active --quiet "$svc" && running+=("$svc")
    done

    if [ ${#running[@]} -eq 0 ]; then
        info "No running services to restart. The binary will be used the next time a service starts."
        return 0
    fi

    echo ""
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
        warn "Not restarted -- restart manually for changes to take effect."
    fi
}

ask_version() {
    CHANNEL="offline"
    VERSION="v3.2"
    info "Selected : DaggerConnect ${VERSION} (Offline Core)"
}

ask_channel_manual() {
    CHANNEL="offline"
    VERSION="v3.2"
    info "Selected : DaggerConnect ${VERSION} (Offline Core)"
}

switch_channel() {
    hr "Core Version / Reinstall Offline Binary"
    echo ""
    info "Current Mode : Offline Standalone Binary (DaggerConnect v3.2)"
    info "Source URL   : ${CORE_ZIP_URL}"
    echo ""
    ask REINSTALL_CORE "Re-extract / update core binary and restart services? (y/n)" "y"
    case "$REINSTALL_CORE" in
        y|Y) update_launcher ;;
        *) info "Cancelled."; return 0 ;;
    esac
}

ask_ports() {
    local default_type=tcp ptype _p parsed normalized previous duplicate
    local -a _parts
    echo ""
    info "Port mappings: 8080 or 8080=80, separated by commas. Press Enter (blank) to finish."
    PORTS=()
    while true; do
        ask P "Port" ""
        [ -z "$P" ] && break
        while true; do
            ask ptype "Type for '$P' - tcp or udp" "$default_type"
            ptype="$(echo "$ptype" | tr '[:upper:]' '[:lower:]')"
            case "$ptype" in
                tcp|udp) break ;;
                *) warn "Please type 'tcp' or 'udp'." ;;
            esac
        done
        IFS="," read -ra _parts <<< "$P"
        for _p in "${_parts[@]}"; do
            _p="${_p// /}"
            [ -z "$_p" ] && continue
            [[ "$_p" == */* ]] || _p="${_p}/${ptype}"
            if ! parsed=$(parse_port_entry "$_p"); then
                warn "Invalid mapping: $_p. Use ports 1-65535 and tcp/udp/both."
                continue
            fi
            local protocol bind target
            IFS='|' read -r protocol bind target <<< "$parsed"
            normalized="${bind}=${target}/${protocol}"
            duplicate=false
            for previous in "${PORTS[@]}"; do
                if [ "$previous" = "$normalized" ]; then duplicate=true; break; fi
                if [[ "$previous" == "$bind="* ]] &&
                   { [[ "$previous" == */both ]] || [ "$protocol" = both ] || [[ "$previous" == */"$protocol" ]]; }; then
                    warn "Port ${bind}/${protocol} already has a mapping."
                    duplicate=true
                    break
                fi
            done
            [ "$duplicate" = true ] || PORTS+=("$normalized")
        done
    done
    if [ ${#PORTS[@]} -eq 0 ]; then
        info "No port mappings."
    fi
}

parse_port_entry() {
    local entry="$1" ptype="tcp" pbind ptarget
    if [[ "$entry" == */* ]]; then
        ptype="${entry##*/}"
        entry="${entry%/*}"
        ptype="$(echo "$ptype" | tr '[:upper:]' '[:lower:]')"
        case "$ptype" in
            tcp|udp|both) ;;
            any) ptype=both ;;
            *) return 1 ;;
        esac
    fi
    if [[ "$entry" == *=* ]]; then
        pbind="${entry%%=*}"
        ptarget="${entry#*=}"
    else
        pbind="$entry"
        ptarget="$entry"
    fi
    [[ "$pbind" =~ ^[0-9]{1,5}$ && "$ptarget" =~ ^[0-9]{1,5}$ ]] || return 1
    pbind=$((10#$pbind)); ptarget=$((10#$ptarget))
    (( pbind >= 1 && pbind <= 65535 && ptarget >= 1 && ptarget <= 65535 )) || return 1
    printf '%s|%s|%s\n' "$ptype" "$pbind" "$ptarget"
}

build_ports_json() {
    local first=1 p ptype pbind ptarget parsed
    for p in "$@"; do
        parsed=$(parse_port_entry "$p") || return 1
        IFS='|' read -r ptype pbind ptarget <<< "$parsed"
        if [ "$first" = "1" ]; then
            printf '        { "type": "%s", "bind": "0.0.0.0:%s", "target": "127.0.0.1:%s" }' "$ptype" "$pbind" "$ptarget"
            first=0
        else
            printf ',\n        { "type": "%s", "bind": "0.0.0.0:%s", "target": "127.0.0.1:%s" }' "$ptype" "$pbind" "$ptarget"
        fi
    done
    echo ""
}

build_ports_yaml() {
    local p ptype pbind ptarget parsed
    for p in "$@"; do
        parsed=$(parse_port_entry "$p") || return 1
        IFS='|' read -r ptype pbind ptarget <<< "$parsed"
        printf '      - type: "%s"\n        bind: "0.0.0.0:%s"\n        target: "127.0.0.1:%s"\n' "$ptype" "$pbind" "$ptarget"
    done
}

SOCKS5_ENABLED="false"
SOCKS5_BIND=""

CLIENT_CONN_POOL="6"

ask_connection_pool() {
    local default_pool=6
    echo ""
    echo -e "  ${BOLD}Connection Pool:${NC}"
    ask_num_range CLIENT_CONN_POOL "Minimum connections per path" "$default_pool" 1 64
}

ask_socks5() {
    echo ""
    echo -e "  ${BOLD}Standalone SOCKS5 Proxy:${NC}"
    ask SOCKS5_CHOICE "Enable SOCKS5 proxy? (y/n)" "n"
    if [ "$SOCKS5_CHOICE" = "y" ] || [ "$SOCKS5_CHOICE" = "Y" ]; then
        SOCKS5_ENABLED="true"
        ask SOCKS5_BIND "SOCKS5 bind address" "127.0.0.1:6060"
    else
        SOCKS5_ENABLED="false"
        SOCKS5_BIND=""
    fi
}

ask_num_range() {
    local __var="$1" prompt="$2" def="$3" lo="$4" hi="$5" val
    while true; do
        ask val "$prompt" "$def"
        case "$val" in
            ''|*[!0-9]*) warn "Enter a whole number." ; continue ;;
        esac
        if [ "${#val}" -gt 9 ]; then
            warn "Number is too large."
            continue
        fi
        val=$((10#$val))
        if [ "$val" -lt "$lo" ] || [ "$val" -gt "$hi" ]; then
            warn "Out of range — expected ${lo}..${hi}."
            continue
        fi
        printf -v "$__var" '%s' "$val"
        return
    done
}

ask_tun_encapsulation() {
    printf '\n  %bTUN encapsulation%b\n    1) tcp\n    2) udp\n    3) icmp\n    4) gre\n    5) ipip\n    6) bip\n\n' "$BOLD" "$NC"
    while true; do
        ask TUN_PROFILE_CHOICE "Profile (match both ends)" 1
        case "$TUN_PROFILE_CHOICE" in
            1|tcp) TUN_PROFILE=tcp; break ;;
            2|udp) TUN_PROFILE=udp; break ;;
            3|icmp) TUN_PROFILE=icmp; break ;;
            4|gre) TUN_PROFILE=gre; break ;;
            5|ipip) TUN_PROFILE=ipip; break ;;
            6|bip) TUN_PROFILE=bip; break ;;
            *) warn "Choose 1-6." ;;
        esac
    done
    TUN_ENCAP=ipx
    TUN_L4_PORT=""
    case "$TUN_PROFILE" in
        tcp|udp) ask_num_range TUN_L4_PORT "Service port (match both ends)" 8443 1 65535 ;;
    esac
    return 0
}

quantum_profile_json() {
    if [ "${QM_PROFILE:-}" = gaming ]; then
        printf ',\n    "profile": "gaming"'
    fi
    return 0
}

quantum_profile_yaml() {
    if [ "${QM_PROFILE:-}" = gaming ]; then
        printf '\n  profile: gaming'
    fi
    return 0
}

ask_quantum_settings() {
    ask_num_range QM_MTU "MTU" 1350 512 9000
    while true; do
        ask QM_BLOCK "Header cipher (aes/salsa20/none; match both ends)" aes
        case "$QM_BLOCK" in
            aes|salsa20|none) break ;;
            *) warn "Choose aes, salsa20 or none." ;;
        esac
    done
}

ask_server_endpoint() {
    while true; do
        ask_required SERVER_ADDR "Server IPv4 (or IPv4:port, default port 8443)"
        if [[ "$SERVER_ADDR" != *:* ]]; then
            SERVER_IP="$SERVER_ADDR"
            SERVER_PORT="8443"
        else
            SERVER_IP="${SERVER_ADDR%%:*}"
            SERVER_PORT="${SERVER_ADDR##*:}"
        fi
        if ! validate_ip "$SERVER_IP" || ! [[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] ||
           [ "$SERVER_PORT" -lt 1 ] || [ "$SERVER_PORT" -gt 65535 ]; then
            warn "Enter a valid IPv4 or IPv4:port (1-65535)."
            continue
        fi
        if [ "$TRANSPORT" = dc6 ] && ! validate_transport_ip "$SERVER_IP" 4 client; then
            warn "Enter a unicast IPv4 address."
            continue
        fi
        SERVER_PORT=$((10#$SERVER_PORT))
        break
    done
}

ask_tun_liveness() {
    local device_default
    device_default="dc$(printf '%s' "$SERVICE_NAME" | cksum | awk '{print $1}' | cut -c1-6)"
    while true; do
        ask TUN_NAME "TUN device name (unique for this profile)" "$device_default"
        [[ "$TUN_NAME" =~ ^[A-Za-z0-9_-]{1,15}$ ]] && break
        warn "Use 1-15 letters, digits, underscores or hyphens."
    done
    ask_num_range TUN_HEARTBEAT_SEC "Heartbeat interval (sec)" 10 1 60
    local min_idle=$((TUN_HEARTBEAT_SEC * 3))
    local default_idle=90
    [ "$default_idle" -lt "$min_idle" ] && default_idle=$min_idle
    ask_num_range TUN_IDLE_TIMEOUT_SEC "Peer silence before confirmation (sec)" "$default_idle" "$min_idle" 3600
}

build_socks5_json() {
    printf '  "socks5": {\n    "enabled": %s,\n    "bind": "%s"\n  },\n' "$SOCKS5_ENABLED" "$SOCKS5_BIND"
}

build_socks5_yaml() {
    printf 'socks5:\n  enabled: %s\n  bind: "%s"\n\n' "$SOCKS5_ENABLED" "$SOCKS5_BIND"
}

build_dc_json() {
    printf '  "profile_id": "%s"\n' "${PAIR_PROFILE_ID:-default}"
}

build_dc_yaml() {
    printf 'profile_id: "%s"\n' "${PAIR_PROFILE_ID:-default}"
}

write_native_dc_config() {
    local role="$1" transport="$2" endpoint="$3" license_addr="$4" ipv6_addr="$5" psk="$6"
    shift 6
    local common maps socks tmp
    common="{$(build_dc_json)}"
    maps=$(build_ports_json "$@") || error "Invalid port mapping; config unchanged."
    maps="[$maps]"
    socks="{$(build_socks5_json)\"_end\":0}"
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR" || error "Cannot create config directory."
    fi
    tmp=$(umask 077; mktemp "${CONFIG}.XXXXXX") || error "Cannot create temporary config."
    if ! python3 -c '
import ipaddress, json, sys
role, transport, endpoint, license_addr, ipv6_addr, psk, common, maps, socks, pool = sys.argv[1:]
def address(value, family, wildcard=False):
    host, port = value.rsplit(":", 1)
    if family == 6:
        if not (host.startswith("[") and host.endswith("]")): raise ValueError("IPv6 brackets required")
        host = host[1:-1]
    ip = ipaddress.ip_address(host)
    if ("%" in host or ip.version != family or ip.is_multicast or ip.is_loopback or ip.is_link_local
        or (ip.is_unspecified and not wildcard) or (family == 6 and ip.ipv4_mapped is not None)
        or str(ip) == "255.255.255.255" or not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535):
        raise ValueError("invalid transport endpoint")
    return int(port)
if role not in ("server", "client") or transport != "dc6" or not psk:
    raise ValueError("invalid transport configuration")
port = address(endpoint, 6 if transport == "dc6" else 4, role == "server" and transport == "dc6")
doc = json.loads(common)
doc.update(mode=role, transport=transport, psk=psk, log_level="info")
if role == "server":
    mappings = json.loads(maps)
    for m in mappings:
        for key in ("bind", "target"):
            mp = m[key].rsplit(":", 1)[-1]
            if not mp.isascii() or not mp.isdigit() or not 1 <= int(mp) <= 65535:
                raise ValueError("mapped ports must be 1..65535")
    doc["listeners"] = [dict(addr=endpoint, transport=transport, maps=mappings)]
    doc["socks5"] = json.loads(socks)["socks5"]
else:
    address(license_addr, 4)
    pool = int(pool)
    if not 1 <= pool <= 64: raise ValueError("invalid connection pool")
    path = dict(transport=transport, addr=license_addr, connection_pool=pool, retry_interval=3, dial_timeout=10)
    if transport == "dc6":
        address(ipv6_addr, 6)
        path["ipv6_addr"] = ipv6_addr
    doc["paths"] = [path]
print(json.dumps(doc, indent=2))
' "$role" "$transport" "$endpoint" "$license_addr" "$ipv6_addr" "$psk" \
        "$common" "$maps" "$socks" "${CLIENT_CONN_POOL:-2}" > "$tmp"; then
        rm -f "$tmp"
        error "Invalid transport configuration; existing config left unchanged."
    fi
    mv -f "$tmp" "$CONFIG" || error "Cannot install configuration."
}

write_server_config_dc6() {
    local port="$1" psk="$2" ipv6="$3"
    shift 3
    write_native_dc_config server dc6 "[${ipv6}]:${port}" "" "" "$psk" "$@"
}

write_client_config_dc6() {
    write_native_dc_config client dc6 "[$4]:$2" "$1:$2" "[$4]:$2" "$3"
}

write_server_config_tcp() {
    local port="$1" psk="$2"
    shift 2
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "tcp",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "tcp",\n      "maps": [\n%s\n      ]\n    }\n  ],\n' "$psk" "$port" "$ports_json"; build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: tcp\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: tcp\n    maps:\n%s\n' "$psk" "$port" "$ports_yaml"; build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
    fi
}

finalize_nova_config() {
    python3 - "$CONFIG" "$CONFIG_FMT" <<'PY'
import json, re, sys
file, fmt = sys.argv[1:]
text = open(file, encoding="utf-8").read()
if fmt == "json":
    data = json.loads(text)
    data["transport"] = "nova"
    for entry in data.get("listeners", []) + data.get("paths", []):
        entry["transport"] = "nova"
    text = json.dumps(data, indent=2) + "\n"
else:
    text = re.sub(r'(?m)^(\s*(?:- )?transport:)\s*"?tcp"?\s*$', r'\1 nova', text)
with open(file, "w", encoding="utf-8") as out:
    out.write(text)
PY
}

write_server_config_nova() { write_server_config_tcp "$@" && finalize_nova_config; }
write_client_config_nova() { write_client_config_tcp "$@" && finalize_nova_config; }

write_client_config_tcp() {
    local server_ip="$1" server_port="$2" psk="$3"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "tcp",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "tcp",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: tcp\npsk: "%s"\nlog_level: info\npaths:\n  - transport: tcp\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_dc_yaml; } > "$CONFIG"
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
        { printf '{\n  "mode": "server",\n  "transport": "ws",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "ws",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$ws_path"; build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: ws\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: ws\n    maps:\n%s\nws_settings:\n  path: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$ws_path"; build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
    fi
}

write_client_config_ws() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "ws",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "ws",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: ws\npsk: "%s"\nlog_level: info\npaths:\n  - transport: ws\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nws_settings:\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_dc_yaml; } > "$CONFIG"
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
        { printf '{\n  "mode": "server",\n  "transport": "wss",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "wss",\n      "cert_file": "%s",\n      "key_file": "%s",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$port" "$cert" "$key" "$ports_json" "$ws_path"; build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: wss\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: wss\n    cert_file: "%s"\n    key_file: "%s"\n    maps:\n%s\nws_settings:\n  path: "%s"\n\n' "$psk" "$port" "$cert" "$key" "$ports_yaml" "$ws_path"; build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
    fi
}

write_client_config_wss() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "wss",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "wss",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "ws_settings": {\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: wss\npsk: "%s"\nlog_level: info\npaths:\n  - transport: wss\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nws_settings:\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$ws_path"; build_dc_yaml; } > "$CONFIG"
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
        { printf '{\n  "mode": "server",\n  "transport": "http",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "http",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$port" "$ports_json" "$http_domain" "$http_path"; build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: http\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: http\n    maps:\n%s\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$port" "$ports_yaml" "$http_domain" "$http_path"; build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
    fi
}

write_server_config_xhttp() {
    local port="$1" psk="$2" path="$3" secure="$4" cert="$5" key="$6"
    local cdn="$7" cdn_host="$8" cdn_port="$9" cdn_ips="${10}" insecure="${11}"
    local pool="${12}" peer_ip="${13}"
    shift 13
    local ports_json ports_yaml transport edge_json edge_yaml peer_json peer_yaml up_concurrency
    local cert_json cert_yaml

    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
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
            printf '{\n  "mode": "server",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "connection_pool": %s,\n      "peer_ips": [%s],\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "auto",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s,\n    "allow_insecure_tls": %s,\n    "cdn": {\n      "enabled": true,\n      "host": "%s",\n      "port": %s,\n      "edge_ips": [%s]\n    }\n  },\n' \
  "$transport" "$psk" "$port" "$pool" "$peer_json" "$ports_json" \
  "$path" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" \
  "$insecure" "$cdn_host" "$cdn_port" "$edge_json"
        else
            printf '{\n  "mode": "server",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",%s\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "auto",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s\n  },\n' \
  "$transport" "$psk" "$cert_json" "$port" "$ports_json" "$path" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES"
        fi
        build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        {
        if [ "$cdn" = "true" ]; then
            printf 'mode: server\ntransport: %s\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    connection_pool: %s\n    peer_ips: %s\n    maps:\n%s\nxhttp:\n  path: "%s"\n  mode: auto\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n  allow_insecure_tls: %s\n  cdn:\n    enabled: true\n    host: "%s"\n    port: %s\n    edge_ips: %s\n\n' \
  "$transport" "$psk" "$port" "$pool" "$peer_yaml" "$ports_yaml" \
  "$path" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" \
  "$insecure" "$cdn_host" "$cdn_port" "$edge_yaml"
        else
            printf 'mode: server\ntransport: %s\npsk: "%s"\nlog_level: info%s\nlisteners:\n  - addr: "0.0.0.0:%s"\n    maps:\n%s\nxhttp:\n  path: "%s"\n  mode: auto\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n\n' \
  "$transport" "$psk" "$cert_yaml" "$port" "$ports_yaml" "$path" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES"
        fi
        build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
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
            printf '{\n  "mode": "client",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",%s\n  "paths": [\n    {\n      "addr": "%s",\n      "peer_ips": [%s],\n      "public_ip": "%s",\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "%s",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s,\n    "cdn": {\n      "enabled": true,\n      "origin_bind": "0.0.0.0:%s"\n    }\n  },\n' \
  "$transport" "$psk" "$cert_json" "$addr" "$peer_json" "$public_ip" \
  "$path" "$mode" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$origin_port"
        else
            printf '{\n  "mode": "client",\n  "transport": "%s",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "addr": "%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "xhttp": {\n    "path": "%s",\n    "mode": "%s",\n    "up_max_bytes": %s,\n    "up_concurrency": %s,\n    "buffer_bytes": %s,\n    "separate_conns": true,\n    "probe_ms": %s,\n    "socket_buf_bytes": %s,\n    "allow_insecure_tls": %s\n  },\n' \
  "$transport" "$psk" "$addr" "$CLIENT_CONN_POOL" "$path" "$mode" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$insecure"
        fi
        build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        {
        if [ "$cdn" = "true" ]; then
            printf 'mode: client\ntransport: %s\npsk: "%s"\nlog_level: info%s\npaths:\n  - addr: "%s"\n    peer_ips: %s\n    public_ip: "%s"\n    retry_interval: 3\n    dial_timeout: 10\n\nxhttp:\n  path: "%s"\n  mode: "%s"\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n  cdn:\n    enabled: true\n    origin_bind: "0.0.0.0:%s"\n\n' \
  "$transport" "$psk" "$cert_yaml" "$addr" "$peer_yaml" "$public_ip" \
  "$path" "$mode" "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$origin_port"
        else
            printf 'mode: client\ntransport: %s\npsk: "%s"\nlog_level: info\npaths:\n  - addr: "%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nxhttp:\n  path: "%s"\n  mode: "%s"\n  up_max_bytes: %s\n  up_concurrency: %s\n  buffer_bytes: %s\n  separate_conns: true\n  probe_ms: %s\n  socket_buf_bytes: %s\n  allow_insecure_tls: %s\n\n' \
  "$transport" "$psk" "$addr" "$CLIENT_CONN_POOL" "$path" "$mode" \
  "$XHTTP_UP_MAX_BYTES" "$up_concurrency" "$XHTTP_BUFFER_BYTES" "$XHTTP_PROBE_MS" "$XHTTP_SOCKET_BUF_BYTES" "$insecure"
        fi
        build_dc_yaml; } > "$CONFIG"
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
        { printf '{\n  "mode": "server",\n  "transport": "https",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "https",\n      "cert_file": "%s",\n      "key_file": "%s",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$port" "$cert" "$key" "$ports_json" "$http_domain" "$http_path"; build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: https\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: https\n    cert_file: "%s"\n    key_file: "%s"\n    maps:\n%s\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$port" "$cert" "$key" "$ports_yaml" "$http_domain" "$http_path"; build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
    fi
}

write_client_config_https() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "https",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "https",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: https\npsk: "%s"\nlog_level: info\npaths:\n  - transport: https\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_dc_yaml; } > "$CONFIG"
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
        { printf '{\n  "mode": "server",\n  "transport": "quantum",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "quantum",\n      "maps": [\n%s\n      ]\n    }\n  ],\n  "quantum": {\n    "mtu": %s,\n    "block": "%s"%s\n  },\n' "$psk" "$port" "$ports_json" "$mtu" "$block" "$(quantum_profile_json)"; build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: quantum\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: quantum\n    maps:\n%s\nquantum:\n  mtu: %s\n  block: "%s"%s\n\n' "$psk" "$port" "$ports_yaml" "$mtu" "$block" "$(quantum_profile_yaml)"; build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
    fi
}

write_client_config_quantum() {
    local server_ip="$1" server_port="$2" psk="$3" mtu="$4" block="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "quantum",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "quantum",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "quantum": {\n    "mtu": %s,\n    "block": "%s"%s\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$mtu" "$block" "$(quantum_profile_json)"; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: quantum\npsk: "%s"\nlog_level: info\npaths:\n  - transport: quantum\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nquantum:\n  mtu: %s\n  block: "%s"%s\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$mtu" "$block" "$(quantum_profile_yaml)"; build_dc_yaml; } > "$CONFIG"
    fi
}

write_server_config_quantumplus() {
    local port="$1" psk="$2"
    shift 2
    local ports_json ports_yaml
    ports_json=$(build_ports_json "$@")
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "server",\n  "transport": "quantum+",\n  "psk": "%s",\n  "log_level": "info",\n  "listeners": [\n    {\n      "addr": "0.0.0.0:%s",\n      "transport": "quantum+",\n      "maps": [\n%s\n      ]\n    }\n  ],\n' "$psk" "$port" "$ports_json"; build_socks5_json; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: server\ntransport: "quantum+"\npsk: "%s"\nlog_level: info\nlisteners:\n  - addr: "0.0.0.0:%s"\n    transport: "quantum+"\n    maps:\n%s\n' "$psk" "$port" "$ports_yaml"; build_socks5_yaml; build_dc_yaml; } > "$CONFIG"
    fi
}

write_client_config_quantumplus() {
    local server_ip="$1" server_port="$2" psk="$3"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "quantum+",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "quantum+",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: "quantum+"\npsk: "%s"\nlog_level: info\npaths:\n  - transport: "quantum+"\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL"; build_dc_yaml; } > "$CONFIG"
    fi
}

write_client_config_http() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        { printf '{\n  "mode": "client",\n  "transport": "http",\n  "psk": "%s",\n  "log_level": "info",\n  "paths": [\n    {\n      "transport": "http",\n      "addr": "%s:%s",\n      "connection_pool": %s,\n      "retry_interval": 3,\n      "dial_timeout": 10\n    }\n  ],\n  "http_settings": {\n    "fake_domain": "%s",\n    "path": "%s"\n  },\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_dc_json; printf '}\n'; } > "$CONFIG"
    else
        { printf 'mode: client\ntransport: http\npsk: "%s"\nlog_level: info\npaths:\n  - transport: http\n    addr: "%s:%s"\n    connection_pool: %s\n    retry_interval: 3\n    dial_timeout: 10\n\nhttp_settings:\n  fake_domain: "%s"\n  path: "%s"\n\n' "$psk" "$server_ip" "$server_port" "$CLIENT_CONN_POOL" "$http_domain" "$http_path"; build_dc_yaml; } > "$CONFIG"
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
            printf '  "psk": "%s",\n'        "$psk"
            printf '  "log_level": "info",\n'
            printf '  "listeners": [\n'
            printf '    {\n'
            printf '      "addr": "0.0.0.0:%s",\n' "$port"
            printf '      "transport": "tun",\n'
            printf '      "maps": [\n'
            printf '%s\n'                    "$ports_json"
            printf '      ]\n'
            printf '    }\n'
            printf '  ],\n'
            printf '  "tun": {\n'
            printf '    "encapsulation": "%s",\n' "$encap"
            printf '    "name": "%s",\n'            "$tun_name"
            printf '    "local_addr": "%s",\n'      "$local_addr"
            printf '    "remote_addr": "%s",\n'     "$remote_addr"
            printf '    "encrypt": true,\n'
            printf '    "heartbeat_sec": %s,\n' "$heartbeat_sec"
            printf '    "idle_timeout_sec": %s\n' "$idle_timeout_sec"
            printf '  },\n'
            printf '  "ipx": {\n'
            printf '    "mode": "server",\n'
            printf '    "profile": "%s",\n'         "$profile"
            { [ "$profile" = "tcp" ] || [ "$profile" = "udp" ]; } && [ -n "$TUN_L4_PORT" ] && printf '    "l4_port": %s,\n' "$TUN_L4_PORT"
            printf '    "listen_ip": "%s",\n'       "$listen_ip"
            printf '    "dst_ip": "%s",\n'          "$dst_ip"
            [ -n "$iface"     ] && printf '    "interface": "%s",\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '    "dcpi_mode": true,\n'
            [ -n "$spoof_src" ] && printf '    "spoof_src_ip": "%s",\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '    "spoof_dst_ip": "%s",\n' "$spoof_dst"
            printf '    "sock_buf": %s\n' 0
            printf '  },\n'
            build_socks5_json
            build_dc_json
            printf '}\n'
        } > "$CONFIG"
    else
        {
            printf 'mode: server\n'
            printf 'transport: tun\n'
            printf 'psk: "%s"\n'         "$psk"
            printf 'log_level: info\n'
            printf 'listeners:\n'
            printf '  - addr: "0.0.0.0:%s"\n' "$port"
            printf '    transport: tun\n'
            if [ -n "$ports_yaml" ]; then
                printf '    maps:\n'
                printf '%s\n'                "$ports_yaml"
            else
                printf '    maps: []\n'
            fi
            printf 'tun:\n'
            printf '  encapsulation: "%s"\n' "$encap"
            printf '  name: "%s"\n'           "$tun_name"
            printf '  local_addr: "%s"\n'     "$local_addr"
            printf '  remote_addr: "%s"\n'    "$remote_addr"
            printf '  encrypt: true\n'
            printf '  heartbeat_sec: %s\n' "$heartbeat_sec"
            printf '  idle_timeout_sec: %s\n\n' "$idle_timeout_sec"
            printf 'ipx:\n'
            printf '  mode: server\n'
            printf '  profile: "%s"\n'        "$profile"
            { [ "$profile" = "tcp" ] || [ "$profile" = "udp" ]; } && [ -n "$TUN_L4_PORT" ] && printf '  l4_port: %s\n' "$TUN_L4_PORT"
            printf '  listen_ip: "%s"\n'      "$listen_ip"
            printf '  dst_ip: "%s"\n'         "$dst_ip"
            [ -n "$iface"     ] && printf '  interface: "%s"\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '  dcpi_mode: true\n'
            [ -n "$spoof_src" ] && printf '  spoof_src_ip: "%s"\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '  spoof_dst_ip: "%s"\n' "$spoof_dst"
            printf '  sock_buf: %s\n\n' 0
            build_socks5_yaml
            build_dc_yaml
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
            printf '  "psk": "%s",\n'         "$psk"
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
            printf '    "name": "%s",\n'            "$tun_name"
            printf '    "local_addr": "%s",\n'      "$local_addr"
            printf '    "remote_addr": "%s",\n'     "$remote_addr"
            printf '    "encrypt": true,\n'
            printf '    "heartbeat_sec": %s,\n' "$heartbeat_sec"
            printf '    "idle_timeout_sec": %s\n' "$idle_timeout_sec"
            printf '  },\n'
            printf '  "ipx": {\n'
            printf '    "mode": "client",\n'
            printf '    "profile": "%s",\n'         "$profile"
            { [ "$profile" = "tcp" ] || [ "$profile" = "udp" ]; } && [ -n "$TUN_L4_PORT" ] && printf '    "l4_port": %s,\n' "$TUN_L4_PORT"
            printf '    "listen_ip": "%s",\n'       "$listen_ip"
            printf '    "dst_ip": "%s",\n'          "$dst_ip"
            [ -n "$iface"     ] && printf '    "interface": "%s",\n'   "$iface"
            [ "$dcpi" = "yes" ] && printf '    "dcpi_mode": true,\n'
            [ -n "$spoof_src" ] && printf '    "spoof_src_ip": "%s",\n' "$spoof_src"
            [ -n "$spoof_dst" ] && printf '    "spoof_dst_ip": "%s",\n' "$spoof_dst"
            printf '    "sock_buf": %s\n' 0
            printf '  },\n'
            build_dc_json
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
            printf '  name: "%s"\n'           "$tun_name"
            printf '  local_addr: "%s"\n'     "$local_addr"
            printf '  remote_addr: "%s"\n'    "$remote_addr"
            printf '  encrypt: true\n'
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
            printf '  sock_buf: %s\n\n' 0
            build_dc_yaml
        } > "$CONFIG"
    fi
}

install_service() {
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG" >/dev/null 2>&1; then
        error "Invalid JSON configuration; service unchanged. Check quoted input values."
    fi
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Tunnel (${SERVICE_NAME})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${LAUNCHER} -c ${CONFIG}
Restart=always
RestartSec=5
TimeoutStopSec=20
KillSignal=SIGTERM
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
    info "Match the profile ID on both ends (press Enter for default)."
    while true; do
        ask PAIR_PROFILE_ID "Pairing profile ID" "default"
        if [[ "$PAIR_PROFILE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
            break
        fi
        warn "Use 1-64 ASCII letters, digits, dots, underscores or hyphens."
    done
}

install_server() {
    hr "Install Server (Offline Core)"
    ensure_launcher server
    check_ptrace_scope
    tune_network
    echo ""

    ask_service_name
    ask_pair_profile_id
    echo ""

    ask_server_public_ip

    ask_transport
    select_transport_release server || return 1
    echo ""

    if [ "$TRANSPORT" = "tun" ]; then
        PORT="8443"
    elif [ "$TRANSPORT" = "xhttp" ] || [ "$TRANSPORT" = "xhttps" ]; then
        :
    else
        ask_num_range PORT "Listen port" 8443 1 65535
        echo ""
    fi

    ask PSK "PSK (must match client)" "123"
    echo ""

    case "$TRANSPORT" in
        dc6) ask_dc6_address server ;;
        ws|wss)
            ask WS_PATH "WebSocket path" "/ws"
            echo ""
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain (e.g. www.google.com)" "www.google.com"
            ask HTTP_PATH   "Fake path   (e.g. /search)" "/search"
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
                echo ""
                ask_num_range PORT "Listen port" 8443 1 65535
            fi
            echo ""
            ;;
        quantum)
            ask_quantum_settings
            echo ""
            ;;
        tun)
            ask_tun_encapsulation
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Server real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Client real IP"
            echo ""
            ask TUN_LOCAL_ADDR  "TUN local IP   (server side)" "10.0.0.1"
            ask TUN_REMOTE_ADDR "TUN remote IP  (client side)" "10.0.0.2"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface (leave empty for auto-detect)" ""
            ask_tun_liveness
            echo ""
            ask TUN_DCPI_CHOICE "Enable DCPI (IPv4/proto58) (y/n)" "n"
            [ "$TUN_DCPI_CHOICE" = "y" ] || [ "$TUN_DCPI_CHOICE" = "Y" ] && TUN_DCPI="yes" || TUN_DCPI="no"
            TUN_SPOOF_CHOICE="n"
            if [ "$TUN_DCPI" != "yes" ]; then
                ask TUN_SPOOF_CHOICE "Enable IP Spoof (y/n)" "n"
            fi
            if [ "$TUN_SPOOF_CHOICE" = "y" ] || [ "$TUN_SPOOF_CHOICE" = "Y" ]; then
                ask TUN_SPOOF_SRC "Spoof Source IP" ""
                ask TUN_SPOOF_DST "Spoof Dest IP  " ""
            else
                TUN_SPOOF_SRC="" TUN_SPOOF_DST=""
            fi
            echo ""
            ;;
    esac

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "https" ] ||
       { [ "$TRANSPORT" = "xhttps" ] && [ "$XHTTP_CDN" != "true" ]; }; then
        ask_ssl_cert
        echo ""
    fi

    ask_ports
    echo ""

    ask_socks5
    echo ""

    info "Bandwidth, buffers, windows, carrier counts : automatic (the core measures the path)"
    echo ""

    case "$TRANSPORT" in
        dc6)      write_server_config_dc6 "$PORT" "$PSK" "$DC6_IPV6" "${PORTS[@]}" ;;
        nova)     write_server_config_nova "$PORT" "$PSK" "${PORTS[@]}" || return 1 ;;
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
    echo -e "${GREEN}${BOLD}  ✓ Server installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Core      : ${BOLD}${VERSION} (${CHANNEL})${NC}"
    echo -e "  Server IP : ${BOLD}${SERVER_PUBLIC_IP}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Port      : ${BOLD}${PORT}${NC}"
    show_new_transport_summary server
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
        if [ "${QM_PROFILE:-}" = gaming ]; then
            echo -e "  Profile   : ${BOLD}gaming${NC}  ${DIM}(set it on both endpoints)${NC}"
        fi
    fi
    show_firewall_note "$PORT"
    if [ "$TRANSPORT" = "xhttp" ] || [ "$TRANSPORT" = "xhttps" ]; then
        echo -e "  URL path  : ${BOLD}${XHTTP_PATH}${NC}  ${DIM}(the other side must use the same one)${NC}"
        if [ "$XHTTP_CDN" = "true" ]; then
            echo -e "  Cloudflare: ${BOLD}on — this side dials OUT${NC}"
            echo -e "  Domain    : ${BOLD}${XHTTP_CDN_HOST}${NC}"
            echo -e "  CF port   : ${BOLD}${XHTTP_CDN_PORT}${NC}"
            echo -e "  Edge IPs  : ${BOLD}${XHTTP_CDN_IPS}${NC}"
        fi
        if [ "$TRANSPORT" = "xhttps" ] && [ "$XHTTP_CDN" != "true" ]; then
            echo -e "  SSL Mode  : ${BOLD}${SSL_MODE}${NC}"
            [ "$SSL_MODE" = "auto" ] && echo -e "  Domain    : ${BOLD}${DOMAIN}${NC}"
            echo -e "  Cert      : ${BOLD}${CERT_FILE}${NC}"
        fi
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
        echo -e "  SOCKS5    : ${BOLD}${SOCKS5_BIND}${NC}"
    fi
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
}

install_client() {
    SERVER_PUBLIC_IP=""
    hr "Install Client (Offline Core)"
    ensure_launcher client
    check_ptrace_scope
    tune_network
    echo ""

    ask_service_name
    ask_pair_profile_id
    echo ""

    ask_transport
    select_transport_release client || return 1
    echo ""

    if [ "$TRANSPORT" != "tun" ] && [ "$TRANSPORT" != "xhttp" ] && [ "$TRANSPORT" != "xhttps" ]; then
        ask_connection_pool
    fi

    if [ "$TRANSPORT" = "tun" ]; then
        SERVER_PORT="8443"
    elif [ "$TRANSPORT" = "xhttp" ] || [ "$TRANSPORT" = "xhttps" ]; then
        :
    else
        [ "$TRANSPORT" = "dc6" ] && info "Enter the server's IPv4 and tunnel port here. IPv6 is requested separately."
        ask_server_endpoint
        echo ""
    fi

    ask PSK "PSK (must match server)" "123"
    echo ""

    case "$TRANSPORT" in
        dc6) ask_dc6_address client ;;
        ws|wss)
            ask WS_PATH "WebSocket path (must match server)" "/ws"
            echo ""
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain (must match server)" "www.google.com"
            ask HTTP_PATH   "Fake path   (must match server)" "/search"
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
                ok "Client IP : ${XHTTP_PUBLIC_IP:-not stated}"
                ok "Server IP : ${SERVER_IP}"
                SERVER_PORT="$XHTTP_ORIGIN_PORT"
                CLIENT_CONN_POOL=6

                echo ""
                echo -e "  ${BOLD}Certificate for Cloudflare to connect to${NC}"
                ask_ssl_cert
            else
                echo ""
                ask_connection_pool
                ask_server_endpoint
            fi
            echo ""
            ;;
        quantum)
            ask_quantum_settings
            echo ""
            ;;
        tun)
            ask_tun_encapsulation
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Client real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Server real IP"
            echo ""
            ask TUN_LOCAL_ADDR  "TUN local IP   (client side)" "10.0.0.2"
            ask TUN_REMOTE_ADDR "TUN remote IP  (server side)" "10.0.0.1"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface (leave empty for auto-detect)" ""
            ask_tun_liveness
            echo ""
            ask TUN_DCPI_CHOICE "Enable DCPI (IPv4/proto58) (y/n)" "n"
            [ "$TUN_DCPI_CHOICE" = "y" ] || [ "$TUN_DCPI_CHOICE" = "Y" ] && TUN_DCPI="yes" || TUN_DCPI="no"
            TUN_SPOOF_CHOICE="n"
            if [ "$TUN_DCPI" != "yes" ]; then
                ask TUN_SPOOF_CHOICE "Enable IP Spoof (y/n)" "n"
            fi
            if [ "$TUN_SPOOF_CHOICE" = "y" ] || [ "$TUN_SPOOF_CHOICE" = "Y" ]; then
                ask TUN_SPOOF_SRC "Spoof Source IP" ""
                ask TUN_SPOOF_DST "Spoof Dest IP  " ""
            else
                TUN_SPOOF_SRC="" TUN_SPOOF_DST=""
            fi
            echo ""
            ;;
    esac

    info "Bandwidth, buffers, windows, carrier counts : automatic (the core measures the path)"
    echo ""

    case "$TRANSPORT" in
        dc6)      write_client_config_dc6 "$SERVER_IP" "$SERVER_PORT" "$PSK" "$DC6_IPV6" ;;
        nova)     write_client_config_nova "$SERVER_IP" "$SERVER_PORT" "$PSK" || return 1 ;;
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
    echo -e "${GREEN}${BOLD}  ✓ Client installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Core      : ${BOLD}${VERSION} (${CHANNEL})${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    if [ "$TRANSPORT" = "tun" ]; then
        echo -e "  Server    : ${BOLD}${TUN_PEER_IP}:${SERVER_PORT}${NC}"
        echo -e "  TUN Local : ${BOLD}${TUN_LOCAL_ADDR}${NC}"
        echo -e "  TUN Peer  : ${BOLD}${TUN_REMOTE_ADDR}${NC}"
    else
        echo -e "  Server    : ${BOLD}${SERVER_IP}:${SERVER_PORT}${NC}"
    fi
    show_new_transport_summary client
    echo -e "  PSK       : ${BOLD}${PSK}${NC}"
    [ "$TRANSPORT" = "ws"  ] && echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
    [ "$TRANSPORT" = "wss" ] && echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
    if [ "$TRANSPORT" = "http" ] || [ "$TRANSPORT" = "https" ]; then
        echo -e "  Fake Domain : ${BOLD}${HTTP_DOMAIN}${NC}"
        echo -e "  Fake Path   : ${BOLD}${HTTP_PATH}${NC}"
    fi
    if [ "$TRANSPORT" = "quantum" ]; then
        echo -e "  Interface : ${BOLD}auto-detect${NC}"
        echo -e "  MTU       : ${BOLD}${QM_MTU}${NC}"
        echo -e "  Block     : ${BOLD}${QM_BLOCK}${NC}"
        if [ "${QM_PROFILE:-}" = gaming ]; then
            echo -e "  Profile   : ${BOLD}gaming${NC}  ${DIM}(set it on both endpoints)${NC}"
        fi
    fi
    if [ "$TRANSPORT" = "xhttp" ] || [ "$TRANSPORT" = "xhttps" ]; then
        echo -e "  URL path  : ${BOLD}${XHTTP_PATH}${NC}"
        echo -e "  Upload    : ${BOLD}${XHTTP_MODE}${NC}"
        if [ "$XHTTP_CDN" = "true" ]; then
            echo -e "  Route     : ${BOLD}Cloudflare — this side is the ORIGIN${NC}"
            echo -e "  Waiting on: ${BOLD}0.0.0.0:${XHTTP_ORIGIN_PORT}${NC}"
        else
            echo -e "  Route     : ${BOLD}direct to the server${NC}"
        fi
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
    hr "Recent Logs"
    pick_service "Logs for" || return 0
    journalctl -u "$PICKED_SVC" -n 80 --no-pager
}

uninstall() {
    hr "Remove Service"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No DaggerConnect services found."
        return
    fi

    echo "  Installed services:"
    for i in "${!SERVICES[@]}"; do
        echo "    $((i+1)))  ${SERVICES[$i]}"
    done
    echo "    a)  Remove ALL"
    echo ""
    ask IDX "Select number (or a)" "a"

    if [ "$IDX" = "a" ]; then
        TARGETS=("${SERVICES[@]}")
    else
        if ! [[ "$IDX" =~ ^[0-9]{1,9}$ ]] || (( 10#$IDX < 1 || 10#$IDX > ${#SERVICES[@]} )); then
            warn "Invalid selection."
            return 1
        fi
        IDX=$((10#$IDX))
        TARGETS=("${SERVICES[$((IDX-1))]}")
    fi

    echo ""
    warn "Will stop and remove: ${TARGETS[*]}"
    ask CONFIRM "Confirm? (y/n)" "y"
    [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && { info "Cancelled."; return; }

    for svc in "${TARGETS[@]}"; do
        svc_name="${svc%.service}"
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
    ask_num_range IDX "$prompt" 1 1 "${#SERVICES[@]}"
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
    echo "    1)  Restart"
    echo "    2)  Stop"
    echo "    3)  Start"
    echo "    4)  Status"
    echo "    0)  Back"
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

LINKTEST_PROFILE_ID="DC-TEST"
LINKTEST_TMP_CFG=""
LT_PSK=""
LT_PROFILE=""

linktest_cleanup() {
    if [ -n "$LINKTEST_TMP_CFG" ]; then
        rm -f -- "$LINKTEST_TMP_CFG"
        LINKTEST_TMP_CFG=""
    fi
}

linktest_installed_profiles() {
    python3 - "$CONFIG_DIR" <<'PY'
import glob, json, os, sys
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        continue
    if isinstance(d, dict) and d.get("psk") and d.get("mode") in ("server", "client"):
        print("%s\t%s\t%s" % (p, d["mode"], d.get("profile_id") or "default"))
PY
}

linktest_read_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        v = json.load(f).get(sys.argv[2])
except (OSError, ValueError):
    v = None
print("" if v is None else v)
PY
}

linktest_pick_pairing() {
    LT_PSK="123"; LT_PROFILE="$LINKTEST_PROFILE_ID"
    local files=() labels=() f m p c i
    while IFS=$'\t' read -r f m p; do
        [ -n "$f" ] || continue
        files+=("$f")
        labels+=("$(basename "$f" .json)  (${m})")
    done < <(linktest_installed_profiles)

    info "Use the PSK of the tunnel you plan to build (default: 123)."
    if [ "${#files[@]}" -gt 0 ]; then
        echo ""
        for i in "${!labels[@]}"; do
            printf '    %d) Use the PSK of %s\n' "$((i + 1))" "${labels[$i]}"
        done
        printf '    %d) Enter a PSK manually (default 123)\n' "$(( ${#labels[@]} + 1 ))"
        echo ""
        ask c "Choice" "1"
        if [[ "$c" =~ ^[0-9]{1,3}$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#files[@]}" ]; then
            f="${files[$((c - 1))]}"
            LT_PSK=$(linktest_read_field "$f" psk)
            ok "Using the PSK of ${labels[$((c - 1))]}"
            return 0
        fi
    fi
    ask LT_PSK "PSK" "123"
}

linktest_write_config() {
    local role="$1" peer="${2:-}" old_umask
    old_umask=$(umask)
    umask 077
    LINKTEST_TMP_CFG=$(mktemp --suffix=.json /var/tmp/dc-linktest.XXXXXX) || { umask "$old_umask"; error "Cannot create a temporary config."; }
    umask "$old_umask"
    if ! LT_PSK="$LT_PSK" LT_PROFILE="$LT_PROFILE" LT_PEER="$peer" python3 - "$role" "$LINKTEST_TMP_CFG" <<'PY'
import json, os, sys
role, path = sys.argv[1], sys.argv[2]
psk, profile, peer = os.environ["LT_PSK"], os.environ["LT_PROFILE"], os.environ.get("LT_PEER", "")
if role == "server":
    cfg = {"mode": "server", "psk": psk, "profile_id": profile,
           "listeners": [{"addr": "0.0.0.0:8443", "transport": "tcp", "maps": []}]}
else:
    cfg = {"mode": "client", "psk": psk, "profile_id": profile,
           "paths": [{"transport": "tcp", "addr": peer + ":8443"}]}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f)
PY
    then
        linktest_cleanup
        error "Could not write the temporary test config."
    fi
    chmod 600 "$LINKTEST_TMP_CFG"
}

linktest_run_core() {
    local role="$1"; shift
    "$LAUNCHER" -c "$LINKTEST_TMP_CFG" "$@"
    return $?
}

linktest_run() {
    local role="$1" peer="${2:-}" quick="${3:-}" rc args=()
    ensure_launcher "$role"
    echo ""
    linktest_pick_pairing
    if [ "$role" = "server" ]; then
        ask_server_public_ip
        echo ""
        info "On the other server choose Tester > Client and enter this IP: ${SERVER_PUBLIC_IP}"
    fi
    trap linktest_cleanup EXIT
    trap 'linktest_cleanup; exit 130' INT TERM
    linktest_write_config "$role" "$peer"
    echo ""
    if [ "$role" = "server" ]; then
        args=(-linktest listen)
    else
        args=(-linktest probe -lt-peer "$peer")
        [ "$quick" = "quick" ] && args+=(-lt-quick)
    fi
    rc=0
    linktest_run_core "$role" "${args[@]}" || rc=$?
    linktest_cleanup
    return "$rc"
}

linktest_listen() {
    hr "Tester: Server side (waiting for the Client)"
    linktest_run server
}

linktest_probe() {
    local peer="$1" quick="${2:-}"
    hr "Tester: Client side (testing the path to ${peer})"
    linktest_run client "$peer" "$quick"
}

linktest_menu() {
    hr "Tester"
    info "Find out which tunnel works best between two of YOUR servers."
    echo ""
    echo "    1) Server   (this server waits for the test)"
    echo "    2) Client   (this server runs the test against the Server)"
    echo "    0) Back"
    echo ""
    local c peer mode
    ask c "Choice" "1"
    case "$c" in
        1) linktest_listen ;;
        2)
            while true; do
                ask_required peer "Server public IPv4"
                validate_ip "$peer" && break
                warn "Enter an IPv4 address."
            done
            echo ""
            echo "    1) Quick test  (about 1 minute)"
            echo "    2) Full test   (about 2-3 minutes)"
            echo ""
            ask mode "Choice" "1"
            if [ "$mode" = "1" ]; then linktest_probe "$peer" quick; else linktest_probe "$peer"; fi ;;
        0|"") return 0 ;;
        *) warn "Invalid choice: ${c}" ;;
    esac
}

show_banner() {
    local core_st="${RED}Not Installed${NC}"
    [ -x "$LAUNCHER" ] && core_st="${GREEN}Ready (Offline v3.2)${NC}"
    local svc_count
    svc_count=$(list_services | wc -l)

    echo ""
    echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${NC}         ${BOLD}${MAGENTA}⚡ DaggerConnect Offline Tunnel Manager ⚡${NC}         ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC}  Core Status : ${core_st}   │   Active Profiles : ${BOLD}${svc_count}${NC}     ${CYAN}║${NC}"
    echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
}

show_menu() {
    echo ""
    echo -e "  ${BOLD}${CYAN}┌─ Quick Setup ──────────────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  ${GREEN}1)${NC} Install Server ${DIM}(Default Port: 8443 | PSK: 123)${NC}       ${BOLD}${CYAN}│${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  ${GREEN}2)${NC} Install Client ${DIM}(Default Port: 8443 | PSK: 123)${NC}       ${BOLD}${CYAN}│${NC}"
    echo -e "  ${BOLD}${CYAN}├─ Service Management & Logs ────────────────────────────────┤${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  ${YELLOW}3)${NC} Service Status          ${YELLOW}6)${NC} Recent Logs                 ${BOLD}${CYAN}│${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  ${YELLOW}4)${NC} Service Control         ${YELLOW}7)${NC} Live Logs                   ${BOLD}${CYAN}│${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  ${YELLOW}5)${NC} Edit Config             ${RED}8)${NC} Remove Service              ${BOLD}${CYAN}│${NC}"
    echo -e "  ${BOLD}${CYAN}├─ Tools & Core ─────────────────────────────────────────────┤${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC}  ${MAGENTA}9)${NC} Core Version           ${MAGENTA}10)${NC} Reinstall Core Binary       ${BOLD}${CYAN}│${NC}"
    echo -e "  ${BOLD}${CYAN}│${NC} ${MAGENTA}11)${NC} Connection Tester       ${DIM}0)${NC} Exit                        ${BOLD}${CYAN}│${NC}"
    echo -e "  ${BOLD}${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    ask CHOICE "Select an option" ""
}

run_action() {
    ( "$@" )
    return 0
}

pause() {
    echo ""
    printf '  %bPress Enter to return to menu...%b' "$DIM" "$NC"
    read -r _ || exit 130
}

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0 2>/dev/null || true
fi

[ "$EUID" -ne 0 ] && { echo -e "${RED}[ERR]${NC} Run as root: sudo bash setup.sh"; exit 1; }
ensure_runtime_dependencies

while true; do
    clear 2>/dev/null || true
    show_banner
    show_menu

    case "$CHOICE" in
        1)  run_action install_server  ;;
        2)  run_action install_client  ;;
        3)  run_action show_status     ;;
        4)  run_action service_control ;;
        5)  run_action edit_config     ;;
        6)  run_action show_logs       ;;
        7)  run_action show_logs_live  ;;
        8)  run_action uninstall       ;;
        9)  run_action switch_channel  ;;
        10) run_action update_launcher ;;
        11) run_action linktest_menu   ;;
        0)  echo -e "\n  ${CYAN}Goodbye!${NC}\n"; exit 0 ;;
        *)  warn "Invalid choice: ${CHOICE}" ;;
    esac

    pause
done
