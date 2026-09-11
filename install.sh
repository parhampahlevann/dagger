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
TUN_NAME="dagger0"
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
        ask LABEL "Service Name (e.g. dagger-srv, dagger-cli)" "tunnel"
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
        ask TUN_LOCAL_IP "Server real IP (or 0.0.0.0 to bind all)" "0.0.0.0"
        ask_required TUN_PEER_IP "Client real public IP"
        ask TUN_LOCAL_ADDR  "TUN local IP  (server side)" "10.0.0.1"
        ask TUN_REMOTE_ADDR "TUN remote IP (client side)" "10.0.0.2"
    else
        ask TUN_LOCAL_IP "Client real IP (or 0.0.0.0 to bind all)" "0.0.0.0"
        TUN_PEER_IP="$SERVER_IP"
        ask TUN_LOCAL_ADDR  "TUN local IP  (client side)" "10.0.0.2"
        ask TUN_REMOTE_ADDR "TUN remote IP (server side)" "10.0.0.1"
    fi

    TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
    TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"

    ask TUN_IFACE "Network interface (leave empty for auto-detect)" ""

    local _default_tun_name
    _default_tun_name="dg-$(echo "$SERVICE_NAME" | tr -cd 'A-Za-z0-9' | cut -c1-10)"
    [ "$_default_tun_name" = "dg-" ] && _default_tun_name="dagger0"

    while true; do
        ask TUN_NAME "TUN device name" "$_default_tun_name"
        if ip link show "$TUN_NAME" >/dev/null 2>&1; then
            warn "Interface '${TUN_NAME}' already exists on host. Pick another name or delete it first."
            continue
        fi
        break
    done

    TUN_HEARTBEAT_SEC="0"
    TUN_IDLE_TIMEOUT_SEC="3600"

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
    if [ "$TRANSPORT" = "tun" ]; then
        cat << EOF
  "health_check": {
    "enabled": false
  },
EOF
        return
    fi

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
    if [ "$TRANSPORT" = "tun" ]; then
        cat << EOF
health_check:
  enabled: false

EOF
        return
    fi

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
            tcp|ws|wss|http|https|quantum)
                cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "$TRANSPORT",
  "psk": "$PSK",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:$PORT",
      "transport": "$TRANSPORT",
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
        esac
    else
        cat > "$CONFIG" << EOF
mode: server
transport: $TRANSPORT
psk: "$PSK"
log_level: info
listeners:
  - addr: "0.0.0.0:$PORT"
    transport: $TRANSPORT
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
  sock_buf: 1048576
$(build_healthcheck_yaml true)
$(build_advanced_yaml)
EOF
    fi
}

write_client_config() {
    mkdir -p "$CONFIG_DIR"

    if [ "$CONFIG_FMT" = "json" ]; then
        case "$TRANSPORT" in
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
            tcp|ws|wss|http|https|quantum)
                cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "$TRANSPORT",
  "psk": "$PSK",
  "log_level": "info",
  "paths": [
    {
      "transport": "$TRANSPORT",
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
        esac
    else
        cat > "$CONFIG" << EOF
mode: client
transport: $TRANSPORT
psk: "$PSK"
log_level: info
paths:
  - transport: $TRANSPORT
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
  sock_buf: 1048576
$(build_healthcheck_yaml false)
$(build_advanced_yaml)
EOF
    fi
}

install_watchdog() {
    cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
SVC="${SERVICE_NAME}"
TRANSPORT_TYPE="${TRANSPORT}"
REMOTE_HOST="${SERVER_IP}"
REMOTE_PORT="${PORT}"
FAILURES=0
MAX_FAILS=3
LAST_LOG_TS=\$(date +%s)

while true; do
    sleep 10
    NOW_TS=\$(date +%s)

    if ! systemctl is-active --quiet "\$SVC"; then
        systemctl restart "\$SVC"
        sleep 5
        LAST_LOG_TS=\$NOW_TS
        continue
    fi

    FAIL_THIS_ROUND=0

    if [ "\$TRANSPORT_TYPE" = "tun" ]; then
        # TUN mode: Only restart if a true fatal panic occurs
        if journalctl -u "\$SVC" --since "@\$LAST_LOG_TS" --no-pager 2>/dev/null | grep -qiE "panic:|fatal error|runtime error"; then
            FAIL_THIS_ROUND=1
        fi
    else
        if journalctl -u "\$SVC" --since "@\$LAST_LOG_TS" --no-pager 2>/dev/null | grep -qiE "broken pipe|connection reset|handshake failed|disconnect|eof|i/o timeout"; then
            FAIL_THIS_ROUND=1
        fi
    fi
    LAST_LOG_TS=\$NOW_TS

    if [ "\$FAIL_THIS_ROUND" -eq 1 ]; then
        FAILURES=\$((FAILURES+1))
    else
        FAILURES=0
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
Description=DaggerConnect Watchdog (${SERVICE_NAME})
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
    ok "Watchdog deployed & enabled."
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
        if ! ip addr show dev "\${DEV}" | grep -q "\${LOCAL_ADDR}"; then
            # Point-to-point /32 with peer avoids subnet route overlap
            ip addr add "\${LOCAL_ADDR}/32" peer "\${REMOTE_ADDR}" dev "\${DEV}" 2>/dev/null || ip addr add "\${LOCAL_ADDR}/32" dev "\${DEV}" 2>/dev/null
        fi
    fi
    sleep 2
done
EOF
    chmod +x "$ADDRGUARD_SCRIPT"

    cat > "$ADDRGUARD_FILE" << EOF
[Unit]
Description=DaggerConnect TUN Address Guardian (${SERVICE_NAME})
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
    ok "TUN Address Guardian deployed (${local_addr} -> ${remote_addr} on ${dev})."
}

install_service() {
    local tun_fw_proto=""
    if [ "$TRANSPORT" = "tun" ] && [ "$TUN_ENCAP" = "ipx" ]; then
        case "$TUN_PROFILE" in
            icmp|bip) tun_fw_proto="icmp" ;;
            gre)      tun_fw_proto="47" ;;
            ipip)     tun_fw_proto="4" ;;
        esac
    fi

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Tunnel Engine (${SERVICE_NAME})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'sysctl -w net.ipv4.ip_forward=1 net.ipv4.ip_nonlocal_bind=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.all.send_redirects=0 net.ipv4.icmp_echo_ignore_broadcasts=1 >/dev/null 2>&1 || true'
ExecStartPre=/bin/sh -c 'iptables -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT'
$( [ -n "$tun_fw_proto" ] && printf "ExecStartPre=/bin/sh -c 'iptables -C INPUT -p %s -j ACCEPT 2>/dev/null || iptables -I INPUT -p %s -j ACCEPT'\n" "$tun_fw_proto" "$tun_fw_proto" )
$( [ -n "$tun_fw_proto" ] && printf "ExecStartPre=/bin/sh -c 'iptables -C OUTPUT -p %s -j ACCEPT 2>/dev/null || iptables -I OUTPUT -p %s -j ACCEPT'\n" "$tun_fw_proto" "$tun_fw_proto" )
$( [ -n "$tun_fw_proto" ] && printf "ExecStartPre=/bin/sh -c 'iptables -C FORWARD -p %s -j ACCEPT 2>/dev/null || iptables -I FORWARD -p %s -j ACCEPT'\n" "$tun_fw_proto" "$tun_fw_proto" )
$( [ "$TRANSPORT" = "tun" ] && printf "ExecStartPre=/bin/sh -c 'iptables -C INPUT -i %s -j ACCEPT 2>/dev/null || iptables -I INPUT -i %s -j ACCEPT 2>/dev/null || true'\n" "$TUN_NAME" "$TUN_NAME" )
$( [ "$TRANSPORT" = "tun" ] && printf "ExecStartPre=/bin/sh -c 'iptables -C FORWARD -i %s -j ACCEPT 2>/dev/null || iptables -I FORWARD -i %s -j ACCEPT 2>/dev/null || true'\n" "$TUN_NAME" "$TUN_NAME" )
$( [ "$TRANSPORT" = "tun" ] && printf "ExecStartPre=/bin/sh -c 'iptables -C FORWARD -o %s -j ACCEPT 2>/dev/null || iptables -I FORWARD -o %s -j ACCEPT 2>/dev/null || true'\n" "$TUN_NAME" "$TUN_NAME" )
ExecStartPre=/bin/sh -c 'iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true'
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
    hr "Server Installation (Port: ${PORT})"
    ensure_binary_offline
    ask_service_name
    ask_psk "server"
    ask_transport

    case "$TRANSPORT" in
        ws|wss)     ask WS_PATH "WebSocket Path" "/ws" ;;
        http|https) ask HTTP_DOMAIN "Fake Domain" "www.cloudflare.com"; ask HTTP_PATH "Fake Path" "/cdn-cgi" ;;
        quantum)    ask QM_MTU "Quantum MTU" "1350"; ask QM_BLOCK "Cipher block (aes/salsa20/none)" "aes" ;;
        tun)        ask_tun_config "server" ;;
    esac

    ask_ports
    write_server_config
    install_service
    [ "$TRANSPORT" = "tun" ] && install_addr_guard "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_NAME"

    ask ENABLE_WATCHDOG "Enable auto-restart watchdog? (y/n)" "n"
    [ "$ENABLE_WATCHDOG" = "y" ] || [ "$ENABLE_WATCHDOG" = "Y" ] && install_watchdog
    start_service
    ok "Server setup completed."
}

install_client() {
    hr "Client Installation (Port: ${PORT})"
    ensure_binary_offline
    ask_service_name
    ask_psk "client"
    ask_transport

    [ "$TRANSPORT" != "tun" ] && ask CLIENT_CONN_POOL "Connection Pool Size" "4"
    ask_required SERVER_IP "Remote Server IP"

    case "$TRANSPORT" in
        ws|wss)     ask WS_PATH "WebSocket Path (matches server)" "/ws" ;;
        http|https) ask HTTP_DOMAIN "Fake Domain (matches server)" "www.cloudflare.com"; ask HTTP_PATH "Fake Path (matches server)" "/cdn-cgi" ;;
        quantum)    ask QM_MTU "Quantum MTU (matches server)" "1350"; ask QM_BLOCK "Cipher block (matches server)" "aes" ;;
        tun)        ask_tun_config "client" ;;
    esac

    write_client_config
    install_service
    [ "$TRANSPORT" = "tun" ] && install_addr_guard "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_NAME"

    ask ENABLE_WATCHDOG "Enable auto-restart watchdog? (y/n)" "n"
    [ "$ENABLE_WATCHDOG" = "y" ] || [ "$ENABLE_WATCHDOG" = "Y" ] && install_watchdog
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
        local wd="${svc%.service}-watchdog.service"
        [ -f "/etc/systemd/system/${wd}" ] && systemctl status "$wd" --no-pager --lines=1 2>/dev/null || true
        local ag="${svc%.service}-addrguard.service"
        [ -f "/etc/systemd/system/${ag}" ] && systemctl status "$ag" --no-pager --lines=1 2>/dev/null || true
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
    PICKED_SVC="${SERVICES[$((IDX-1))]}"
    return 0
}

service_control() {
    hr "Manage Service"
    pick_service || return 0
    local svc="$PICKED_SVC"
    local wd="${svc%.service}-watchdog"
    local ag="${svc%.service}-addrguard"
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
            [ -f "/etc/systemd/system/${ag}.service" ] && systemctl restart "$ag" 2>/dev/null || true
            ok "Service restarted."
            ;;
        2)
            systemctl stop "$svc"
            [ -f "/etc/systemd/system/${wd}.service" ] && systemctl stop "$wd" 2>/dev/null || true
            [ -f "/etc/systemd/system/${ag}.service" ] && systemctl stop "$ag" 2>/dev/null || true
            ok "Service stopped."
            ;;
        3)
            systemctl start "$svc"
            [ -f "/etc/systemd/system/${wd}.service" ] && systemctl start "$wd" 2>/dev/null || true
            [ -f "/etc/systemd/system/${ag}.service" ] && systemctl start "$ag" 2>/dev/null || true
            ok "Service started."
            ;;
    esac
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

extract_tun_name_from_config() {
    local cfg_json="$1" cfg_yaml="$2" dev=""
    if [ -f "$cfg_json" ]; then
        dev=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg_json" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    elif [ -f "$cfg_yaml" ]; then
        dev=$(grep -E '^[[:space:]]*name:' "$cfg_yaml" | head -1 | sed -E 's/.*name:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/')
    fi
    echo "$dev"
}

remove_tun_leftovers() {
    local dev="$1"
    [ -z "$dev" ] && return 0
    if ip link show "$dev" >/dev/null 2>&1; then
        info "Removing leftover TUN interface: ${dev}"
        ip link delete "$dev" 2>/dev/null || true
    fi
}

uninstall() {
    hr "Uninstall Service"
    pick_service || return 0
    local svc_name="${PICKED_SVC%.service}"
    ask CONFIRM "Delete ${svc_name}? (yes/no)" "no"
    [ "$CONFIRM" != "yes" ] && { info "Aborted."; return 0; }

    local cfg_json="${CONFIG_DIR}/${svc_name}.json"
    local cfg_yaml="${CONFIG_DIR}/${svc_name}.yaml"
    local tun_dev
    tun_dev=$(extract_tun_name_from_config "$cfg_json" "$cfg_yaml")

    for suffix in "" "-watchdog" "-addrguard"; do
        systemctl stop "${svc_name}${suffix}" 2>/dev/null || true
        systemctl disable "${svc_name}${suffix}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc_name}${suffix}.service"
        rm -f "/usr/local/bin/${svc_name}${suffix}.sh"
    done
    rm -f "$cfg_json" "$cfg_yaml"

    remove_tun_leftovers "$tun_dev"
    systemctl daemon-reload
    ok "Service ${svc_name} uninstalled."
}

purge_all() {
    hr "Purge ALL Services"
    ask CONFIRM "Permanently purge all services and flush configs? (yes/no)" "no"
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

    ip link delete dagger0 2>/dev/null || true
    systemctl daemon-reload
    ok "All services and configs purged."
}

pause() {
    echo ""
    echo -ne "${YELLOW}?${NC} Press Enter to return to main menu: "
    read -r _
}

[ "$EUID" -ne 0 ] && error "Execution failed: Root privileges required."

while true; do
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}══ DaggerConnect Manager (Fixed TUN BIP/ICMP) ══${NC}\n"
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Service Status"
    echo "  4) Service Control (Restart/Stop/Start)"
    echo "  5) View Logs"
    echo "  6) Follow Live Logs"
    echo "  7) Uninstall Service"
    echo "  8) Purge ALL Services"
    echo "  0) Exit"
    echo ""
    ask CHOICE "Choose an option" ""

    case "$CHOICE" in
        1) install_server ;;
        2) install_client ;;
        3) show_status ;;
        4) service_control ;;
        5) show_logs ;;
        6) show_logs_live ;;
        7) uninstall ;;
        8) purge_all ;;
        0) echo -e "\n${CYAN}Exiting.${NC}\n"; exit 0 ;;
        *) warn "Invalid input" ;;
    esac
    pause
done
