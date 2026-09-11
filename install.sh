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
PSK="123"

CONFIG=""
CONFIG_FMT="json"
SERVICE_NAME=""
SERVICE_FILE=""
WATCHDOG_FILE=""
WATCHDOG_SCRIPT=""
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
TUN_NAME="dagger0"
TUN_ENCAP="tcp"
TUN_PROFILE="icmp"
TUN_IFACE=""
TUN_SPOOF_SRC=""
TUN_SPOOF_DST=""
TUN_DCPI="no"
TUN_HEARTBEAT_SEC="0"
TUN_IDLE_TIMEOUT_SEC="60"
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

    error "DaggerConnect binary not found at ${BINARY} or ./DaggerConnect. Offline mode requires pre-placing the binary."
}

ask_service_name() {
    local svc_name svc_file
    while true; do
        ask LABEL "Service Name (e.g. dagger-srv, dagger-cli)" ""
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
            ask OVERWRITE "Overwrite? (y/n)" "n"
            if [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ]; then
                break
            fi
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
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.${CONFIG_FMT}"
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}Available Transports (Fixed Port: ${PORT} | Token: ${PSK}):${NC}"
    echo "    1)  tcp     — Raw TCP tunnel"
    echo "    2)  ws      — WebSocket tunnel"
    echo "    3)  wss     — WebSocket Secure (TLS) tunnel"
    echo "    4)  http    — HTTP Mimicry tunnel"
    echo "    5)  https   — HTTP Mimicry Secure (TLS) tunnel"
    echo "    6)  quantum — Raw-packet / KCP tunnel"
    echo "    7)  tun     — Tunneled TUN L3 Interface"
    echo ""
    while true; do
        ask T_CHOICE "Transport choice" "1"
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
    echo "    1)  tcp   — plain TCP over TUN"
    echo "    2)  ipx   — raw IP encapsulation (icmp/gre/ipip/bip)"
    echo ""
    ask TUN_ENCAP_CHOICE "Encapsulation" "2"
    case "$TUN_ENCAP_CHOICE" in
        1|tcp) TUN_ENCAP="tcp" ;;
        *)     TUN_ENCAP="ipx" ;;
    esac

    if [ "$TUN_ENCAP" = "ipx" ]; then
        echo ""
        echo -e "  ${BOLD}IPX Profile:${NC}"
        echo "    1)  icmp  — ICMP encapsulation"
        echo "    2)  gre   — GRE (proto 47)"
        echo "    3)  ipip  — IP-in-IP (proto 4)"
        echo "    4)  bip   — BIP/ICMP custom"
        echo ""
        ask TUN_PROFILE_CHOICE "Profile" "4"
        case "$TUN_PROFILE_CHOICE" in
            1|icmp) TUN_PROFILE="icmp" ;;
            2|gre)  TUN_PROFILE="gre"  ;;
            3|ipip) TUN_PROFILE="ipip" ;;
            *)      TUN_PROFILE="bip"  ;;
        esac
    else
        TUN_PROFILE="icmp"
    fi

    local _default_ip
    _default_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

    if [ "$mode" = "server" ]; then
        ask TUN_LOCAL_IP "Server real IP" "${_default_ip}"
        ask_required TUN_PEER_IP "Client real IP"
        ask TUN_LOCAL_ADDR  "TUN local IP  (server side)" "10.0.0.1"
        ask TUN_REMOTE_ADDR "TUN remote IP (client side)" "10.0.0.2"
    else
        ask TUN_LOCAL_IP "Client real IP" "${_default_ip}"
        TUN_PEER_IP="$SERVER_IP"
        ask TUN_LOCAL_ADDR  "TUN local IP  (client side)" "10.0.0.2"
        ask TUN_REMOTE_ADDR "TUN remote IP (server side)" "10.0.0.1"
    fi

    TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
    TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"

    ask TUN_IFACE "Network interface (leave empty for auto-detect)" ""
    ask TUN_NAME  "TUN device name" "dagger0"
    ask TUN_HEARTBEAT_SEC    "Heartbeat interval (sec) [0 = disabled to stop extra data]" "0"
    ask TUN_IDLE_TIMEOUT_SEC "Idle timeout (sec)" "60"

    ask TUN_SPOOF_CHOICE "Enable IP Spoof (y/n)" "n"
    if [ "$TUN_SPOOF_CHOICE" = "y" ] || [ "$TUN_SPOOF_CHOICE" = "Y" ]; then
        ask TUN_SPOOF_SRC "Spoof Source IP" ""
        ask TUN_SPOOF_DST "Spoof Dest IP" ""
    else
        TUN_SPOOF_SRC="" TUN_SPOOF_DST=""
    fi

    ask TUN_DCPI_CHOICE "Enable DCPI Mode (ICMPv6/proto58) (y/n)" "n"
    [ "$TUN_DCPI_CHOICE" = "y" ] || [ "$TUN_DCPI_CHOICE" = "Y" ] && TUN_DCPI="yes" || TUN_DCPI="no"
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

build_ports_yaml() {
    for p in "$@"; do
        printf '      - "%s"\n' "$p"
    done
}

build_healthcheck_json() {
    local is_server="$1"
    if [ "$is_server" = "true" ]; then
        cat << EOF
  "health_check": {
    "enabled": true,
    "port": 5550,
    "interval_sec": 3,
    "timeout_ms": 3000,
    "max_consecutive_fails": 3
  },
EOF
    else
        cat << EOF
  "health_check": {
    "enabled": true,
    "interval_sec": 3,
    "timeout_ms": 3000,
    "max_consecutive_fails": 3
  },
EOF
    fi
}

build_healthcheck_yaml() {
    local is_server="$1"
    if [ "$is_server" = "true" ]; then
        cat << EOF
health_check:
  enabled: true
  port: 5550
  interval_sec: 3
  timeout_ms: 3000
  max_consecutive_fails: 3

EOF
    else
        cat << EOF
health_check:
  enabled: true
  interval_sec: 3
  timeout_ms: 3000
  max_consecutive_fails: 3

EOF
    fi
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

build_advanced_yaml() {
    cat << EOF
advanced:
  auto_tune: true
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 15
  session_timeout: 30
  cleanup_interval: 2
  tcp_read_buffer: 2097152
  tcp_write_buffer: 2097152
  udp_buffer_size: 2097152
  channel_backlog: 2048
  stream_chan_buf: 256
  keepalive_sec: 0
  dead_timeout_sec: 45
EOF
}

write_server_config() {
    mkdir -p "$CONFIG_DIR"
    local ports_json ports_yaml
    ports_json=$(build_ports_json "${PORTS[@]}")
    ports_yaml=$(build_ports_yaml "${PORTS[@]}")

    if [ "$CONFIG_FMT" = "json" ]; then
        case "$TRANSPORT" in
            tcp)
                cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "tcp",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "tcp",
      "ports": [
$ports_json
      ]
    }
  ],
$(build_healthcheck_json true)
$(build_advanced_json)
}
EOF
                ;;
            ws)
                cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "ws",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "ws",
      "ports": [
$ports_json
      ]
    }
  ],
  "ws_settings": {
    "path": "$WS_PATH"
  },
$(build_healthcheck_json true)
$(build_advanced_json)
}
EOF
                ;;
            wss)
                cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "wss",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "wss",
      "cert_file": "$CERT_FILE",
      "key_file": "$KEY_FILE",
      "ports": [
$ports_json
      ]
    }
  ],
  "ws_settings": {
    "path": "$WS_PATH"
  },
$(build_healthcheck_json true)
$(build_advanced_json)
}
EOF
                ;;
            http)
                cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "http",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "http",
      "ports": [
$ports_json
      ]
    }
  ],
  "http_settings": {
    "fake_domain": "$HTTP_DOMAIN",
    "path": "$HTTP_PATH"
  },
$(build_healthcheck_json true)
$(build_advanced_json)
}
EOF
                ;;
            https)
                cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "https",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "https",
      "cert_file": "$CERT_FILE",
      "key_file": "$KEY_FILE",
      "ports": [
$ports_json
      ]
    }
  ],
  "http_settings": {
    "fake_domain": "$HTTP_DOMAIN",
    "path": "$HTTP_PATH"
  },
$(build_healthcheck_json true)
$(build_advanced_json)
}
EOF
                ;;
            quantum)
                cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "quantum",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "quantum",
      "ports": [
$ports_json
      ]
    }
  ],
  "quantum": {
    "mtu": $QM_MTU,
    "block": "$QM_BLOCK"
  },
$(build_healthcheck_json true)
$(build_advanced_json)
}
EOF
                ;;
            tun)
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
    $( [ "$TUN_DCPI" = "yes" ] && printf '"dcpi_mode": true,\n' )
    $( [ -n "$TUN_SPOOF_SRC" ] && printf '"spoof_src_ip": "%s",\n' "$TUN_SPOOF_SRC" )
    $( [ -n "$TUN_SPOOF_DST" ] && printf '"spoof_dst_ip": "%s",\n' "$TUN_SPOOF_DST" )
    "sock_buf": 1048576
  },
$(build_healthcheck_json true)
$(build_advanced_json)
}
EOF
                ;;
        esac
    else
        case "$TRANSPORT" in
            tcp)
                cat > "$CONFIG" << EOF
mode: server
transport: tcp
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: tcp
    ports:
$ports_yaml
$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
                ;;
            ws)
                cat > "$CONFIG" << EOF
mode: server
transport: ws
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: ws
    ports:
$ports_yaml
ws_settings:
  path: "$WS_PATH"

$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
                ;;
            wss)
                cat > "$CONFIG" << EOF
mode: server
transport: wss
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: wss
    cert_file: "$CERT_FILE"
    key_file: "$KEY_FILE"
    ports:
$ports_yaml
ws_settings:
  path: "$WS_PATH"

$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
                ;;
            http)
                cat > "$CONFIG" << EOF
mode: server
transport: http
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: http
    ports:
$ports_yaml
http_settings:
  fake_domain: "$HTTP_DOMAIN"
  path: "$HTTP_PATH"

$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
                ;;
            https)
                cat > "$CONFIG" << EOF
mode: server
transport: https
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: https
    cert_file: "$CERT_FILE"
    key_file: "$KEY_FILE"
    ports:
$ports_yaml
http_settings:
  fake_domain: "$HTTP_DOMAIN"
  path: "$HTTP_PATH"

$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
                ;;
            quantum)
                cat > "$CONFIG" << EOF
mode: server
transport: quantum
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: quantum
    ports:
$ports_yaml
quantum:
  mtu: $QM_MTU
  block: "$QM_BLOCK"

$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
                ;;
            tun)
                cat > "$CONFIG" << EOF
mode: server
transport: tun
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: tun
    ports:
$ports_yaml
tun:
  encapsulation: "$TUN_ENCAP"
  name: "$TUN_NAME"
  local_addr: "$TUN_LOCAL_ADDR"
  remote_addr: "$TUN_REMOTE_ADDR"
  mtu: 1380
  heartbeat_sec: $TUN_HEARTBEAT_SEC
  idle_timeout_sec: $TUN_IDLE_TIMEOUT_SEC

ipx:
  mode: server
  profile: "$TUN_PROFILE"
  listen_ip: "$TUN_LOCAL_IP"
  dst_ip: "$TUN_PEER_IP"
  $( [ -n "$TUN_IFACE" ] && printf 'interface: "%s"\n' "$TUN_IFACE" )
  $( [ "$TUN_DCPI" = "yes" ] && printf 'dcpi_mode: true\n' )
  $( [ -n "$TUN_SPOOF_SRC" ] && printf 'spoof_src_ip: "%s"\n' "$TUN_SPOOF_SRC" )
  $( [ -n "$TUN_SPOOF_DST" ] && printf 'spoof_dst_ip: "%s"\n' "$TUN_SPOOF_DST" )
  sock_buf: 1048576

$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
                ;;
        esac
    fi
}

write_client_config() {
    mkdir -p "$CONFIG_DIR"

    if [ "$CONFIG_FMT" = "json" ]; then
        case "$TRANSPORT" in
            tcp)
                cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "tcp",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "tcp",
      "addr": "$SERVER_IP:$PORT",
      "connection_pool": $CLIENT_CONN_POOL,
      "retry_interval": 2,
      "dial_timeout": 8
    }
  ],
$(build_healthcheck_json false)
$(build_advanced_json)
}
EOF
                ;;
            ws)
                cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "ws",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "ws",
      "addr": "$SERVER_IP:$PORT",
      "connection_pool": $CLIENT_CONN_POOL,
      "retry_interval": 2,
      "dial_timeout": 8
    }
  ],
  "ws_settings": {
    "path": "$WS_PATH"
  },
$(build_healthcheck_json false)
$(build_advanced_json)
}
EOF
                ;;
            wss)
                cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "wss",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "wss",
      "addr": "$SERVER_IP:$PORT",
      "connection_pool": $CLIENT_CONN_POOL,
      "retry_interval": 2,
      "dial_timeout": 8
    }
  ],
  "ws_settings": {
    "path": "$WS_PATH"
  },
  "tls_insecure": true,
$(build_healthcheck_json false)
$(build_advanced_json)
}
EOF
                ;;
            http)
                cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "http",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "http",
      "addr": "$SERVER_IP:$PORT",
      "connection_pool": $CLIENT_CONN_POOL,
      "retry_interval": 2,
      "dial_timeout": 8
    }
  ],
  "http_settings": {
    "fake_domain": "$HTTP_DOMAIN",
    "path": "$HTTP_PATH"
  },
$(build_healthcheck_json false)
$(build_advanced_json)
}
EOF
                ;;
            https)
                cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "https",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "https",
      "addr": "$SERVER_IP:$PORT",
      "connection_pool": $CLIENT_CONN_POOL,
      "retry_interval": 2,
      "dial_timeout": 8
    }
  ],
  "http_settings": {
    "fake_domain": "$HTTP_DOMAIN",
    "path": "$HTTP_PATH"
  },
  "tls_insecure": true,
$(build_healthcheck_json false)
$(build_advanced_json)
}
EOF
                ;;
            quantum)
                cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "quantum",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "quantum",
      "addr": "$SERVER_IP:$PORT",
      "connection_pool": $CLIENT_CONN_POOL,
      "retry_interval": 2,
      "dial_timeout": 8
    }
  ],
  "quantum": {
    "mtu": $QM_MTU,
    "block": "$QM_BLOCK"
  },
$(build_healthcheck_json false)
$(build_advanced_json)
}
EOF
                ;;
            tun)
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
    $( [ "$TUN_DCPI" = "yes" ] && printf '"dcpi_mode": true,\n' )
    $( [ -n "$TUN_SPOOF_SRC" ] && printf '"spoof_src_ip": "%s",\n' "$TUN_SPOOF_SRC" )
    $( [ -n "$TUN_SPOOF_DST" ] && printf '"spoof_dst_ip": "%s",\n' "$TUN_SPOOF_DST" )
    "sock_buf": 1048576
  },
$(build_healthcheck_json false)
$(build_advanced_json)
}
EOF
                ;;
        esac
    else
        case "$TRANSPORT" in
            tcp)
                cat > "$CONFIG" << EOF
mode: client
transport: tcp
psk: "$PSK"
log_level: info
paths:
  - transport: tcp
    addr: "$SERVER_IP:$PORT"
    connection_pool: $CLIENT_CONN_POOL
    retry_interval: 2
    dial_timeout: 8

$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
                ;;
            ws)
                cat > "$CONFIG" << EOF
mode: client
transport: ws
psk: "$PSK"
log_level: info
paths:
  - transport: ws
    addr: "$SERVER_IP:$PORT"
    connection_pool: $CLIENT_CONN_POOL
    retry_interval: 2
    dial_timeout: 8

ws_settings:
  path: "$WS_PATH"

$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
                ;;
            wss)
                cat > "$CONFIG" << EOF
mode: client
transport: wss
psk: "$PSK"
log_level: info
paths:
  - transport: wss
    addr: "$SERVER_IP:$PORT"
    connection_pool: $CLIENT_CONN_POOL
    retry_interval: 2
    dial_timeout: 8

ws_settings:
  path: "$WS_PATH"

tls_insecure: true

$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
                ;;
            http)
                cat > "$CONFIG" << EOF
mode: client
transport: http
psk: "$PSK"
log_level: info
paths:
  - transport: http
    addr: "$SERVER_IP:$PORT"
    connection_pool: $CLIENT_CONN_POOL
    retry_interval: 2
    dial_timeout: 8

http_settings:
  fake_domain: "$HTTP_DOMAIN"
  path: "$HTTP_PATH"

$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
                ;;
            https)
                cat > "$CONFIG" << EOF
mode: client
transport: https
psk: "$PSK"
log_level: info
paths:
  - transport: https
    addr: "$SERVER_IP:$PORT"
    connection_pool: $CLIENT_CONN_POOL
    retry_interval: 2
    dial_timeout: 8

http_settings:
  fake_domain: "$HTTP_DOMAIN"
  path: "$HTTP_PATH"

tls_insecure: true

$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
                ;;
            quantum)
                cat > "$CONFIG" << EOF
mode: client
transport: quantum
psk: "$PSK"
log_level: info
paths:
  - transport: quantum
    addr: "$SERVER_IP:$PORT"
    connection_pool: $CLIENT_CONN_POOL
    retry_interval: 2
    dial_timeout: 8

quantum:
  mtu: $QM_MTU
  block: "$QM_BLOCK"

$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
                ;;
            tun)
                cat > "$CONFIG" << EOF
mode: client
transport: tun
psk: "$PSK"
log_level: info
paths:
  - transport: tun
    addr: "$SERVER_IP:$PORT"
    retry_interval: 2
    dial_timeout: 10

tun:
  encapsulation: "$TUN_ENCAP"
  name: "$TUN_NAME"
  local_addr: "$TUN_LOCAL_ADDR"
  remote_addr: "$TUN_REMOTE_ADDR"
  mtu: 1380
  heartbeat_sec: $TUN_HEARTBEAT_SEC
  idle_timeout_sec: $TUN_IDLE_TIMEOUT_SEC

ipx:
  mode: client
  profile: "$TUN_PROFILE"
  listen_ip: "$TUN_LOCAL_IP"
  dst_ip: "$TUN_PEER_IP"
  $( [ -n "$TUN_IFACE" ] && printf 'interface: "%s"\n' "$TUN_IFACE" )
  $( [ "$TUN_DCPI" = "yes" ] && printf 'dcpi_mode: true\n' )
  $( [ -n "$TUN_SPOOF_SRC" ] && printf 'spoof_src_ip: "%s"\n' "$TUN_SPOOF_SRC" )
  $( [ -n "$TUN_SPOOF_DST" ] && printf 'spoof_dst_ip: "%s"\n' "$TUN_SPOOF_DST" )
  sock_buf: 1048576

$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
                ;;
        esac
    fi
}

install_watchdog() {
    local target_check=""
    if [ "$TRANSPORT" = "tun" ]; then
        target_check="$TUN_REMOTE_ADDR"
    else
        target_check="127.0.0.1"
    fi

    cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
TARGET="${target_check}"
SVC="${SERVICE_NAME}"
TRANSPORT_TYPE="${TRANSPORT}"
FAILURES=0
MAX_FAILS=3

while true; do
    sleep 10
    if ! systemctl is-active --quiet "\$SVC"; then
        systemctl restart "\$SVC"
        sleep 5
        continue
    fi

    if [ "\$TRANSPORT_TYPE" = "tun" ]; then
        if ! ping -c 1 -W 2 "\$TARGET" >/dev/null 2>&1; then
            FAILURES=\$((FAILURES+1))
        else
            FAILURES=0
        fi
    else
        if journalctl -u "\$SVC" -n 10 --no-pager | grep -qiE "broken pipe|connection reset|handshake failed|disconnect"; then
            FAILURES=\$((FAILURES+1))
        else
            FAILURES=0
        fi
    fi

    if [ "\$FAILURES" -ge "\$MAX_FAILS" ]; then
        FAILURES=0
        systemctl restart "\$SVC"
        sleep 3
    fi
done
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_FILE" << EOF
[Unit]
Description=DaggerConnect Active Watchdog (${SERVICE_NAME})
After=${SERVICE_NAME}.service
Wants=${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-watchdog" > /dev/null 2>&1
    systemctl restart "${SERVICE_NAME}-watchdog" > /dev/null 2>&1
    ok "Active Connection Watchdog deployed & enabled."
}

install_service() {
    # Systemd with Anti-Leak, Anti-Multicast, Anti-Loop quarantine for TUN
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Tunnel Engine (${SERVICE_NAME})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'sysctl -w net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.default.rp_filter=1 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.all.send_redirects=0 net.ipv4.icmp_echo_ignore_broadcasts=1 >/dev/null 2>&1 || true'
ExecStartPre=/bin/sh -c 'sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true'
ExecStartPre=/bin/sh -c 'iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true'
ExecStartPre=/bin/sh -c 'iptables -C OUTPUT -o ${TUN_NAME} -d 224.0.0.0/4 -j DROP >/dev/null 2>&1 || iptables -A OUTPUT -o ${TUN_NAME} -d 224.0.0.0/4 -j DROP 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'iptables -C OUTPUT -o ${TUN_NAME} -d 255.255.255.255 -j DROP >/dev/null 2>&1 || iptables -A OUTPUT -o ${TUN_NAME} -d 255.255.255.255 -j DROP 2>/dev/null || true'
ExecStart=${BINARY} -c ${CONFIG}
Restart=always
RestartSec=2
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
    sleep 1
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
    hr "Server Installation (Port: ${PORT} | Token: ${PSK})"
    ensure_binary_offline
    ask_service_name
    ask_transport

    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket Path" "/ws"
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake Domain" "www.cloudflare.com"
            ask HTTP_PATH   "Fake Path" "/cdn-cgi"
            ;;
        quantum)
            ask QM_MTU   "Quantum MTU" "1350"
            ask QM_BLOCK "Cipher block (aes/salsa20/none)" "aes"
            ;;
        tun)
            ask_tun_config "server"
            ;;
    esac

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "https" ]; then
        info "Provide custom TLS certificate paths:"
        ask_required CERT_FILE "Certificate file path (e.g. /etc/ssl/cert.pem)"
        ask_required KEY_FILE  "Private key file path (e.g. /etc/ssl/key.pem)"
    fi

    ask_ports
    write_server_config
    install_service
    install_watchdog
    start_service

    echo ""
    ok "Server setup completed. Configuration written to: ${CONFIG}"
}

install_client() {
    hr "Client Installation (Port: ${PORT} | Token: ${PSK})"
    ensure_binary_offline
    ask_service_name
    ask_transport

    if [ "$TRANSPORT" != "tun" ]; then
        ask CLIENT_CONN_POOL "Connection Pool Size" "4"
    fi

    ask_required SERVER_IP "Remote Server IP"

    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket Path (matches server)" "/ws"
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake Domain (matches server)" "www.cloudflare.com"
            ask HTTP_PATH   "Fake Path (matches server)" "/cdn-cgi"
            ;;
        quantum)
            ask QM_MTU   "Quantum MTU (matches server)" "1350"
            ask QM_BLOCK "Cipher block (matches server)" "aes"
            ;;
        tun)
            ask_tun_config "client"
            ;;
    esac

    write_client_config
    install_service
    install_watchdog
    start_service

    echo ""
    ok "Client setup completed. Configuration written to: ${CONFIG}"
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
        local wd="${svc%.service}-watchdog.service"
        if [ -f "/etc/systemd/system/${wd}" ]; then
            systemctl status "$wd" --no-pager --lines=1 2>/dev/null || true
        fi
        echo ""
    done
}

PICKED_SVC=""
pick_service() {
    PICKED_SVC=""
    mapfile -t SERVICES < <(list_services)
    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No registered services found."
        return 1
    fi
    if [ ${#SERVICES[@]} -eq 1 ]; then
        PICKED_SVC="${SERVICES[0]}"
        return 0
    fi
    echo -e "  ${BOLD}Installed Services:${NC}"
    for i in "${!SERVICES[@]}"; do
        local st="stopped"
        systemctl is-active --quiet "${SERVICES[$i]}" && st="${GREEN}running${NC}" || st="${RED}stopped${NC}"
        echo -e "    $((i+1))) ${SERVICES[$i]} [${st}]"
    done
    echo ""
    ask IDX "Select service number" "1"
    if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt ${#SERVICES[@]} ]; then
        warn "Invalid selection."
        return 1
    fi
    PICKED_SVC="${SERVICES[$((IDX-1))]}"
    return 0
}

service_control() {
    hr "Manage Service"
    pick_service || return 0
    local svc="$PICKED_SVC"
    local wd="${svc%.service}-watchdog"
    echo -e "Target: ${BOLD}${svc}${NC}\n"
    echo "  1) Restart"
    echo "  2) Stop"
    echo "  3) Start"
    echo "  0) Back"
    echo ""
    ask ACT "Action" "1"
    case "$ACT" in
        1)
            systemctl restart "$svc"
            [ -f "/etc/systemd/system/${wd}.service" ] && systemctl restart "$wd" 2>/dev/null || true
            ok "Service and watchdog restarted."
            ;;
        2)
            systemctl stop "$svc"
            [ -f "/etc/systemd/system/${wd}.service" ] && systemctl stop "$wd" 2>/dev/null || true
            ok "Service and watchdog stopped."
            ;;
        3)
            systemctl start "$svc"
            [ -f "/etc/systemd/system/${wd}.service" ] && systemctl start "$wd" 2>/dev/null || true
            ok "Service and watchdog started."
            ;;
        0|"") return 0 ;;
        *) warn "Invalid selection." ;;
    esac
}

edit_config() {
    hr "Edit Configuration"
    pick_service || return 0
    local svc="${PICKED_SVC%.service}"

    local cfg=""
    [ -f "${CONFIG_DIR}/${svc}.json" ] && cfg="${CONFIG_DIR}/${svc}.json"
    [ -f "${CONFIG_DIR}/${svc}.yaml" ] && cfg="${CONFIG_DIR}/${svc}.yaml"

    if [ -z "$cfg" ]; then
        warn "Configuration file not found for ${svc}."
        return 0
    fi

    local ed="${EDITOR:-}"
    if [ -z "$ed" ]; then
        for cand in nano vim vi; do
            command -v "$cand" >/dev/null 2>&1 && { ed="$cand"; break; }
        done
    fi

    [ -z "$ed" ] && { warn "No text editor found (nano/vim/vi)."; return 0; }

    cp "$cfg" "${cfg}.bak" 2>/dev/null && info "Backup created: ${cfg}.bak"
    "$ed" "$cfg"

    ask DORESTART "Restart service now to apply updates? (y/n)" "y"
    if [ "$DORESTART" = "y" ] || [ "$DORESTART" = "Y" ]; then
        systemctl restart "${svc}"
        sleep 1
        if systemctl is-active --quiet "${svc}"; then
            ok "Service running cleanly with updated config."
        else
            warn "Failed to start. Rolling back configuration..."
            cp "${cfg}.bak" "$cfg"
            systemctl restart "${svc}"
            ok "Restored backup."
        fi
    fi
}

show_logs() {
    hr "Service Logs (Last 60 lines)"
    pick_service || return 0
    journalctl -u "$PICKED_SVC" -n 60 --no-pager
}

show_logs_live() {
    hr "Live Streaming Logs"
    pick_service || return 0
    info "Streaming logs for ${PICKED_SVC}. Press Ctrl+C to stop."
    trap ' ' INT
    journalctl -u "$PICKED_SVC" -n 30 -f --no-pager
    trap - INT
}

uninstall() {
    hr "Uninstall Service"
    pick_service || return 0
    local svc_name="${PICKED_SVC%.service}"
    ask CONFIRM "Are you sure you want to delete ${svc_name} and its watchdog? (yes/no)" "no"
    [ "$CONFIRM" != "yes" ] && { info "Aborted."; return 0; }

    systemctl stop "${svc_name}-watchdog" 2>/dev/null || true
    systemctl disable "${svc_name}-watchdog" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc_name}-watchdog.service"
    rm -f "/usr/local/bin/${svc_name}-watchdog.sh"

    systemctl stop "$svc_name" 2>/dev/null || true
    systemctl disable "$svc_name" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc_name}.service"
    rm -f "${CONFIG_DIR}/${svc_name}.json"
    rm -f "${CONFIG_DIR}/${svc_name}.yaml"
    systemctl daemon-reload
    ok "Service ${svc_name}, watchdog, and configurations removed."
}

pause() {
    echo ""
    echo -ne "${YELLOW}?${NC} Press Enter to return to main menu: "
    read -r _
}

[ "$EUID" -ne 0 ] && error "Execution failed: Root privileges required (run with sudo)."

while true; do
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}══ DaggerConnect Active Manager (Port: 8443 | Token: 123 | Watchdog) ══${NC}\n"
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Service Status"
    echo "  4) Service Control (Restart/Stop/Start)"
    echo "  5) Edit Configuration"
    echo "  6) View Logs"
    echo "  7) Follow Live Logs"
    echo "  8) Uninstall Service"
    echo "  0) Exit"
    echo ""
    ask CHOICE "Choose an option" ""

    case "$CHOICE" in
        1) install_server ;;
        2) install_client ;;
        3) show_status ;;
        4) service_control ;;
        5) edit_config ;;
        6) show_logs ;;
        7) show_logs_live ;;
        8) uninstall ;;
        0) echo -e "\n${CYAN}Exiting.${NC}\n"; exit 0 ;;
        *) warn "Invalid input: ${CHOICE}" ;;
    esac
    pause
done
