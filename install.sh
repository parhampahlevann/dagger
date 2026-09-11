#!/bin/bash

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

BINARY="/usr/local/bin/DaggerConnect"
CONFIG_DIR="/etc/DaggerConnect"
PORT="8443"
PSK=""
DEFAULT_PSK="1238877"

CONFIG=""
CONFIG_FMT="json"
SERVICE_NAME=""
SERVICE_FILE=""
WATCHDOG_FILE=""
WATCHDOG_SCRIPT=""
ADDRGUARD_FILE=""
ADDRGUARD_SCRIPT=""
TRANSPORT=""
LABEL=""
OVERWRITE=""
T_CHOICE=""
WS_PATH=""
HTTP_DOMAIN=""
HTTP_PATH=""
CERT_FILE=""
KEY_FILE=""
SERVER_IP=""
TUN_LOCAL_IP=""
TUN_PEER_IP=""
TUN_LOCAL_ADDR=""
TUN_REMOTE_ADDR=""
TUN_NAME="dg0"
TUN_ENCAP="ipx"
TUN_PROFILE="bip"
TUN_IFACE=""
TUN_SPOOF_SRC=""
TUN_SPOOF_DST=""
TUN_DCPI="no"
TUN_HEARTBEAT_SEC="0"
TUN_IDLE_TIMEOUT_SEC="3600"
QM_MTU=""
QM_BLOCK=""
CLIENT_CONN_POOL="4"
PORTS=()
P=""
FMT=""
ACT=""
CHOICE=""
CONFIRM=""
DORESTART=""
IDX=""

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

ensure_binary_offline() {
    if [ -f "$BINARY" ]; then
        chmod +x "$BINARY"
        return 0
    fi

    local local_bin="./DaggerConnect"
    if [ -f "$local_bin" ]; then
        info "Local binary detected. Deploying to ${BINARY}..."
        mkdir -p "/usr/local/bin"
        cp "$local_bin" "$BINARY"
        chmod +x "$BINARY"
        ok "Binary deployed successfully."
        return 0
    fi

    error "DaggerConnect binary not found at ${BINARY} or ./DaggerConnect."
}

ask_service_name() {
    local svc_name svc_file
    while true; do
        ask LABEL "Service Name" "tunnel"
        if [ -z "$LABEL" ]; then
            warn "Service Name cannot be empty."
            continue
        fi
        if ! validate_label "$LABEL"; then
            warn "Only letters, numbers, hyphens (-), and underscores (_) are allowed."
            continue
        fi

        svc_name="${LABEL}"
        svc_file="/etc/systemd/system/${svc_name}.service"

        if [ -f "$svc_file" ] || [ -f "${CONFIG_DIR}/${svc_name}.json" ] || [ -f "${CONFIG_DIR}/${svc_name}.yaml" ]; then
            warn "Service or config '${svc_name}' already exists."
            ask OVERWRITE "Overwrite? (y/n)" "y"
            [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ] && break
            continue
        fi
        break
    done

    while true; do
        ask FMT "Config Format (json/yaml)" "json"
        case "$FMT" in
            json|yaml) break ;;
            *) warn "Please enter json or yaml." ;;
        esac
    done

    CONFIG_FMT="$FMT"
    SERVICE_NAME="${LABEL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    WATCHDOG_FILE="/etc/systemd/system/${SERVICE_NAME}-watchdog.service"
    WATCHDOG_SCRIPT="/usr/local/bin/${SERVICE_NAME}-watchdog.sh"
    ADDRGUARD_FILE="/etc/systemd/system/${SERVICE_NAME}-addrguard.service"
    ADDRGUARD_SCRIPT="/usr/local/bin/${SERVICE_NAME}-addrguard.sh"
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.${CONFIG_FMT}"
}

ask_psk() {
    local mode="$1"
    echo ""
    if [ "$mode" = "server" ]; then
        echo -e "  ${BOLD}Security Token (PSK):${NC}"
        ask PSK "PSK (Enter = use default)" "$DEFAULT_PSK"
        ok "Token for this service: ${BOLD}${PSK}${NC}"
    else
        ask PSK "Enter the PSK/token" "$DEFAULT_PSK"
    fi
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}Available Transports (Fixed Port: ${PORT}):${NC}"
    echo "    1)  tcp     — Raw TCP tunnel"
    echo "    2)  ws      — WebSocket tunnel"
    echo "    3)  wss     — WebSocket Secure (TLS) tunnel"
    echo "    4)  http    — HTTP Mimicry tunnel"
    echo "    5)  https   — HTTP Mimicry Secure (TLS) tunnel"
    echo "    6)  quantum — Raw-packet / KCP tunnel"
    echo "    7)  tun     — Tunneled TUN L3 Interface"
    echo ""
    while true; do
        ask T_CHOICE "Transport choice" "7"
        case "$T_CHOICE" in
            1|tcp)     TRANSPORT="tcp";     break ;;
            2|ws)      TRANSPORT="ws";      break ;;
            3|wss)     TRANSPORT="wss";     break ;;
            4|http)    TRANSPORT="http";    break ;;
            5|https)   TRANSPORT="https";   break ;;
            6|quantum) TRANSPORT="quantum"; break ;;
            7|tun)     TRANSPORT="tun";     break ;;
            *) warn "Select an option between 1 and 7." ;;
        esac
    done
    info "Selected transport: ${TRANSPORT}"
}

ask_tun_config() {
    local mode="$1"
    echo ""
    echo -e "  ${BOLD}TUN Encapsulation:${NC}"
    echo "    1)  tcp   — plain TCP over TUN (Most reliable, NAT/Firewall safe)"
    echo "    2)  ipx   — raw IP encapsulation (bip/icmp/gre/ipip)"
    echo ""
    ask TUN_ENCAP_CHOICE "Encapsulation" "2"
    case "$TUN_ENCAP_CHOICE" in
        1|tcp) TUN_ENCAP="tcp" ;;
        *)     TUN_ENCAP="ipx" ;;
    esac

    if [ "$TUN_ENCAP" = "ipx" ]; then
        echo ""
        echo -e "  ${BOLD}IPX Profile:${NC}"
        echo "    1)  bip   — BIP/ICMP custom (Recommended for TUN IPX)"
        echo "    2)  icmp  — Pure ICMP encapsulation"
        echo "    3)  gre   — GRE (proto 47)"
        echo "    4)  ipip  — IP-in-IP (proto 4)"
        echo ""
        ask TUN_PROFILE_CHOICE "Profile" "1"
        case "$TUN_PROFILE_CHOICE" in
            1|bip)  TUN_PROFILE="bip"  ;;
            2|icmp) TUN_PROFILE="icmp" ;;
            3|gre)  TUN_PROFILE="gre"  ;;
            4|ipip) TUN_PROFILE="ipip" ;;
            *)      TUN_PROFILE="bip"  ;;
        esac
    else
        TUN_PROFILE="icmp"
    fi

    local _default_ip
    _default_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

    if [ "$mode" = "server" ]; then
        ask TUN_LOCAL_IP "Server public IP (Used for BIP/ICMP socket)" "${_default_ip}"
        ask_required TUN_PEER_IP "Client public IP"
        ask TUN_LOCAL_ADDR  "TUN local IP  (server side)" "10.0.0.1"
        ask TUN_REMOTE_ADDR "TUN remote IP (client side)" "10.0.0.2"
    else
        ask TUN_LOCAL_IP "Client public IP (Used for BIP/ICMP socket)" "${_default_ip}"
        TUN_PEER_IP="$SERVER_IP"
        ask TUN_LOCAL_ADDR  "TUN local IP  (client side)" "10.0.0.2"
        ask TUN_REMOTE_ADDR "TUN remote IP (server side)" "10.0.0.1"
    fi

    TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
    TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"

    ask TUN_IFACE "Physical interface (leave empty for auto-detect)" ""
    ask TUN_NAME "TUN device name (keep identical on server and client)" "dg0"

    TUN_HEARTBEAT_SEC="0"
    TUN_IDLE_TIMEOUT_SEC="3600"
    TUN_SPOOF_SRC=""
    TUN_SPOOF_DST=""
    TUN_DCPI="no"
}

ask_ports() {
    echo ""
    echo -e "  ${BOLD}Forwarded Ports (e.g. 2222=22, 80, 4433=443):${NC}"
    PORTS=()
    ask P "Ports to forward" "2222=22"
    IFS="," read -ra _parts <<< "$P"
    for _p in "${_parts[@]}"; do
        _p="${_p// /}"
        [ -n "$_p" ] && PORTS+=("$_p")
    done
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

build_healthcheck_json() {
    # In TUN mode, TCP port-based health check is disabled to prevent false restarts
    cat << EOF
  "health_check": {
    "enabled": false
  },
EOF
}

build_advanced_json() {
    cat << EOF
  "advanced": {
    "auto_tune": true,
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 15,
    "session_timeout": 30,
    "cleanup_interval": 2,
    "tcp_read_buffer": 2097152,
    "tcp_write_buffer": 2097152,
    "udp_buffer_size": 2097152,
    "channel_backlog": 2048,
    "stream_chan_buf": 256,
    "keepalive_sec": 0,
    "dead_timeout_sec": 45
  }
EOF
}

write_server_config() {
    mkdir -p "$CONFIG_DIR"
    local ports_json
    ports_json=$(build_ports_json "${PORTS[@]}")

    cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "tun",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "tun",
      "ports": [
$ports_json
      ]
    }
  ],
  "tun": {
    "encapsulation": "$TUN_ENCAP",
    "name": "$TUN_NAME",
    "local_addr": "$TUN_LOCAL_ADDR",
    "remote_addr": "$TUN_REMOTE_ADDR",
    "mtu": 1380,
    "heartbeat_sec": $TUN_HEARTBEAT_SEC,
    "idle_timeout_sec": $TUN_IDLE_TIMEOUT_SEC
  },
  "ipx": {
    "mode": "server",
    "profile": "$TUN_PROFILE",
    "listen_ip": "$TUN_LOCAL_IP",
    "dst_ip": "$TUN_PEER_IP",
    $( [ -n "$TUN_IFACE" ] && printf '"interface": "%s",\n' "$TUN_IFACE" )
    "sock_buf": 1048576
  },
$(build_healthcheck_json)
$(build_advanced_json)
}
EOF
}

write_client_config() {
    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "tun",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "tun",
      "addr": "$SERVER_IP:$PORT",
      "retry_interval": 2,
      "dial_timeout": 10
    }
  ],
  "tun": {
    "encapsulation": "$TUN_ENCAP",
    "name": "$TUN_NAME",
    "local_addr": "$TUN_LOCAL_ADDR",
    "remote_addr": "$TUN_REMOTE_ADDR",
    "mtu": 1380,
    "heartbeat_sec": $TUN_HEARTBEAT_SEC,
    "idle_timeout_sec": $TUN_IDLE_TIMEOUT_SEC
  },
  "ipx": {
    "mode": "client",
    "profile": "$TUN_PROFILE",
    "listen_ip": "$TUN_LOCAL_IP",
    "dst_ip": "$TUN_PEER_IP",
    $( [ -n "$TUN_IFACE" ] && printf '"interface": "%s",\n' "$TUN_IFACE" )
    "sock_buf": 1048576
  },
$(build_healthcheck_json)
$(build_advanced_json)
}
EOF
}

install_addr_guard() {
    local local_addr="$1" remote_addr="$2" dev="$3"
    cat > "$ADDRGUARD_SCRIPT" << EOF
#!/bin/bash
LOCAL_ADDR="${local_addr}"
REMOTE_ADDR="${remote_addr}"
DEV="${dev}"

while true; do
    if ip link show "\${DEV}" >/dev/null 2>&1; then
        ip link set dev "\${DEV}" up 2>/dev/null
        
        # Ensure IP is assigned with /24 scope
        if ! ip addr show dev "\${DEV}" | grep -q "\${LOCAL_ADDR}"; then
            ip addr replace "\${LOCAL_ADDR}/24" dev "\${DEV}" 2>/dev/null || true
        fi
        
        # Ensure direct route exists to remote TUN peer
        if ! ip route show | grep -q "\${REMOTE_ADDR} dev \${DEV}"; then
            ip route replace "\${REMOTE_ADDR}" dev "\${DEV}" 2>/dev/null || true
        fi

        # Disable reverse path filtering dynamically on interface
        sysctl -w "net.ipv4.conf.\${DEV}.rp_filter=0" >/dev/null 2>&1 || true
    fi
    sleep 2
done
EOF
    chmod +x "$ADDRGUARD_SCRIPT"

    cat > "$ADDRGUARD_FILE" << EOF
[Unit]
Description=DaggerConnect TUN Address & Route Guardian (${SERVICE_NAME})
After=${SERVICE_NAME}.service
Wants=${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=${ADDRGUARD_SCRIPT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-addrguard" > /dev/null 2>&1
    systemctl restart "${SERVICE_NAME}-addrguard" > /dev/null 2>&1
    ok "TUN Address & Route Guardian deployed."
}

install_service() {
    # Systemd unit with explicit kernel flags, rp_filter disablement, and unblocked IPTables
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Tunnel Engine (${SERVICE_NAME})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'sysctl -w net.ipv4.ip_forward=1 net.ipv4.ip_nonlocal_bind=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.all.send_redirects=0 >/dev/null 2>&1 || true'
ExecStartPre=/bin/sh -c 'iptables -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT -p icmp -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -C OUTPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I OUTPUT -p icmp -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -C FORWARD -p icmp -j ACCEPT 2>/dev/null || iptables -I FORWARD -p icmp -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -C INPUT -i ${TUN_NAME} -j ACCEPT 2>/dev/null || iptables -I INPUT -i ${TUN_NAME} -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -C OUTPUT -o ${TUN_NAME} -j ACCEPT 2>/dev/null || iptables -I OUTPUT -o ${TUN_NAME} -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -C FORWARD -i ${TUN_NAME} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${TUN_NAME} -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -C FORWARD -o ${TUN_NAME} -j ACCEPT 2>/dev/null || iptables -I FORWARD -o ${TUN_NAME} -j ACCEPT'
ExecStartPre=/bin/sh -c 'iptables -I INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true'
ExecStart=${BINARY} -c ${CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=DaggerConnect

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    ok "Systemd unit created: ${SERVICE_NAME}"
}

start_service() {
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Tunnel service is running."
    else
        warn "Service failed to start. Logs:"
        journalctl -u "$SERVICE_NAME" -n 15 --no-pager
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

install_server() {
    hr "Server Installation"
    ensure_binary_offline
    command -v netstat >/dev/null 2>&1 || apt-get install -y net-tools 2>/dev/null || true
    ask_service_name
    ask_psk "server"
    ask_transport

    case "$TRANSPORT" in
        tun) ask_tun_config "server" ;;
        *)   error "This script version is optimized specifically for TUN (BIP/ICMP/TCP)." ;;
    esac

    ask_ports
    write_server_config
    install_service
    install_addr_guard "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_NAME"
    start_service
    ok "Server setup completed."
}

install_client() {
    hr "Client Installation"
    ensure_binary_offline
    command -v netstat >/dev/null 2>&1 || apt-get install -y net-tools 2>/dev/null || true
    ask_service_name
    ask_psk "client"
    ask_transport
    ask_required SERVER_IP "Remote Server IP"

    case "$TRANSPORT" in
        tun) ask_tun_config "client" ;;
        *)   error "This script version is optimized specifically for TUN (BIP/ICMP/TCP)." ;;
    esac

    write_client_config
    install_service
    install_addr_guard "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_NAME"
    start_service
    ok "Client setup completed."
}

show_status() {
    hr "Service Status"
    mapfile -t SERVICES < <(list_services)
    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No DaggerConnect services detected."
        return
    fi
    for svc in "${SERVICES[@]}"; do
        echo -e "${BOLD}${svc}${NC}"
        systemctl status "$svc" --no-pager --lines=3 2>/dev/null || true
        local ag="${svc%.service}-addrguard.service"
        [ -f "/etc/systemd/system/${ag}" ] && systemctl status "$ag" --no-pager --lines=1 2>/dev/null || true
        echo ""
    done
}

purge_all() {
    hr "Purge ALL Services"
    ask CONFIRM "Permanently purge all services, configs, and reset interfaces? (yes/no)" "no"
    [ "$CONFIRM" != "yes" ] && { info "Aborted."; return 0; }

    mapfile -t ALL_SERVICES < <(list_services)
    for s in "${ALL_SERVICES[@]}"; do
        local svc="${s%.service}"
        for suffix in "" "-watchdog" "-addrguard"; do
            systemctl stop "${svc}${suffix}" 2>/dev/null || true
            systemctl disable "${svc}${suffix}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}${suffix}.service"
            rm -f "/usr/local/bin/${svc}${suffix}.sh"
        done
        rm -f "${CONFIG_DIR}/${svc}.json" "${CONFIG_DIR}/${svc}.yaml"
    done

    # Remove lingering interfaces
    for iface in dg0 dg-tunnel hj dagger0; do
        ip link delete "$iface" 2>/dev/null || true
    done

    systemctl daemon-reload
    ok "All services, watchdogs, and interfaces purged successfully."
}

show_logs() {
    hr "Service Logs (Last 60 lines)"
    journalctl -u tunnel -n 60 --no-pager 2>/dev/null || journalctl -u "${SERVICE_NAME}" -n 60 --no-pager
}

pause() {
    echo ""
    echo -ne "${YELLOW}?${NC} Press Enter to return to main menu: "
    read -r _
}

[ "$EUID" -ne 0 ] && error "Execution failed: Root privileges required."

while true; do
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}══ DaggerConnect Manager (Zero-Drop TUN BIP/ICMP) ══${NC}\n"
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Service Status"
    echo "  4) Service Logs"
    echo "  5) Purge ALL Services"
    echo "  0) Exit"
    echo ""
    ask CHOICE "Choose an option" ""

    case "$CHOICE" in
        1) install_server ;;
        2) install_client ;;
        3) show_status ;;
        4) show_logs ;;
        5) purge_all ;;
        0) echo -e "\n${CYAN}Exiting.${NC}\n"; exit 0 ;;
        *) warn "Invalid input" ;;
    esac
    pause
done
