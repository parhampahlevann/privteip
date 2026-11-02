#!/bin/bash

# ==============================================================================
# GRETAP + Backhaul Reverse Tunnel Manager (v2.0 - Fixed & Hardened)
# Iran IP: 10.10.1.1/30 | Kharej IP: 10.10.1.2/30 | MSS: 1240
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_DIR="/etc/backhaul-gretap"
BACKHAUL_BIN="/usr/local/bin/backhaul"
GRETAP_SH="$CONFIG_DIR/gretap-up.sh"
GRETAP_DOWN_SH="$CONFIG_DIR/gretap-down.sh"
BACKHAUL_TOML="$CONFIG_DIR/config.toml"

GRETAP_SERVICE="/etc/systemd/system/gretap-tunnel.service"
BACKHAUL_SERVICE="/etc/systemd/system/backhaul-tunnel.service"

TUN_IR_IP="10.10.1.1"
TUN_KH_IP="10.10.1.2"
MSS_VAL="1240"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root!${NC}"
    exit 1
fi

install_dependencies() {
    echo -e "${CYAN}[*] Installing dependencies & tuning kernel parameters...${NC}"
    apt-get update -y -qq
    apt-get install -y iproute2 iptables curl wget tar -qq

    # Enable IP forwarding & disable strict rp_filter for GRETAP stability
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1

    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
    fi
}

install_backhaul_core() {
    mkdir -p "$CONFIG_DIR"
    if [[ -f "$BACKHAUL_BIN" ]]; then
        echo -e "${GREEN}[+] Backhaul binary already installed.${NC}"
        return
    fi

    echo -e "${CYAN}[*] Downloading Backhaul Core...${NC}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        FILE_NAME="backhaul_linux_amd64.tar.gz"
    elif [[ "$ARCH" == "aarch64" ]]; then
        FILE_NAME="backhaul_linux_arm64.tar.gz"
    else
        echo -e "${RED}[!] Unsupported architecture: $ARCH${NC}"
        exit 1
    fi

    LATEST_URL="https://github.com/Musixal/Backhaul/releases/latest/download/$FILE_NAME"
    curl -L -s --connect-timeout 15 "$LATEST_URL" -o "/tmp/backhaul.tar.gz"

    if [[ ! -s "/tmp/backhaul.tar.gz" ]]; then
        echo -e "${YELLOW}[!] Direct GitHub download failed.${NC}"
        read -p "Enter custom direct download URL for Backhaul tar.gz: " CUSTOM_URL
        if [[ -n "$CUSTOM_URL" ]]; then
            curl -L -s "$CUSTOM_URL" -o "/tmp/backhaul.tar.gz"
        fi
    fi

    tar -xzf "/tmp/backhaul.tar.gz" -C /tmp/ 2>/dev/null
    if [[ -f "/tmp/backhaul" ]]; then
        mv /tmp/backhaul "$BACKHAUL_BIN"
        chmod +x "$BACKHAUL_BIN"
        rm -f /tmp/backhaul.tar.gz
        echo -e "${GREEN}[+] Backhaul Core installed successfully.${NC}"
    else
        echo -e "${RED}[!] Failed to extract Backhaul binary.${NC}"
        exit 1
    fi
}

create_systemd_services() {
    cat <<EOF > "$GRETAP_SERVICE"
[Unit]
Description=GRETAP Layer-2 Tunnel & Iptables Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $GRETAP_SH
ExecStop=/bin/bash $GRETAP_DOWN_SH

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > "$BACKHAUL_SERVICE"
[Unit]
Description=Backhaul Reverse Tunnel Service over GRETAP
After=gretap-tunnel.service
Requires=gretap-tunnel.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 2
ExecStart=$BACKHAUL_BIN -c $BACKHAUL_TOML
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gretap-tunnel.service backhaul-tunnel.service >/dev/null 2>&1
}

setup_iran_server() {
    echo -e "\n${CYAN}--- Configuring IRAN Server (GRETAP: $TUN_IR_IP) ---${NC}"
    DEFAULT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    read -p "Enter IRAN Server Public IP [$DEFAULT_IP]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$DEFAULT_IP}

    read -p "Enter KHAREJ Client Public IP: " REMOTE_IP
    if [[ -z "$REMOTE_IP" ]]; then
        echo -e "${RED}[!] Remote IP cannot be empty!${NC}"
        return
    fi

    read -p "Enter Backhaul Reverse Communication Port [default: 3080]: " BH_PORT
    BH_PORT=${BH_PORT:-3080}

    read -p "Enter Tunnel Secret Token [default: 123456]: " BH_TOKEN
    BH_TOKEN=${BH_TOKEN:-123456}

    read -p "Select Backhaul Transport (tcp / tcpmux / ws) [default: tcp]: " BH_TRANS
    BH_TRANS=${BH_TRANS:-tcp}

    echo -e "\n${YELLOW}[?] Enter ports to forward through the tunnel (comma-separated, e.g.: 1080,443,80):${NC}"
    read -p "Ports: " RAW_PORTS
    if [[ -z "$RAW_PORTS" ]]; then
        RAW_PORTS="1080,443"
    fi

    install_dependencies
    install_backhaul_core

    CLEAN_PORTS=$(echo "$RAW_PORTS" | tr -d ' ')
    IFS=',' read -ra PORT_ARRAY <<< "$CLEAN_PORTS"

    # Bind Backhaul ports on 10.10.1.1 and forward to Kharej local 127.0.0.1 (or 10.10.1.2)
    TOML_PORTS=""
    for p in "${PORT_ARRAY[@]}"; do
        if [[ -n "$TOML_PORTS" ]]; then
            TOML_PORTS+=", "
        fi
        TOML_PORTS+="\"$TUN_IR_IP:$p=$p\""
    done

    # Create GRETAP UP script
    cat <<EOF > "$GRETAP_SH"
#!/bin/bash
ip link del gretap1 2>/dev/null || true
ip link add gretap1 type gretap local $LOCAL_IP remote $REMOTE_IP ttl 255
ip addr add $TUN_IR_IP/30 dev gretap1
ip link set gretap1 mtu 1400
ip link set gretap1 up

# Disable rp_filter on gretap1
sysctl -w net.ipv4.conf.gretap1.rp_filter=0 >/dev/null 2>&1

# Allow GRE protocol & all traffic on gretap1 (Prevents Connection Refused!)
iptables -I INPUT 1 -p gre -j ACCEPT
iptables -I INPUT 1 -i gretap1 -j ACCEPT
iptables -I FORWARD 1 -i gretap1 -j ACCEPT
iptables -I FORWARD 1 -o gretap1 -j ACCEPT

# Clamp MSS to $MSS_VAL
iptables -t mangle -I FORWARD 1 -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
iptables -t mangle -I FORWARD 1 -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
iptables -t mangle -I OUTPUT 1 -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
iptables -t mangle -I INPUT 1 -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL

# Port Forwarding via iptables DNAT to Backhaul listener on $TUN_IR_IP
EOF

    for p in "${PORT_ARRAY[@]}"; do
        cat <<EOF >> "$GRETAP_SH"
iptables -t nat -A PREROUTING -p tcp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p
iptables -t nat -A PREROUTING -p udp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p
EOF
    done

    cat <<EOF >> "$GRETAP_SH"
iptables -t nat -A POSTROUTING -d $TUN_IR_IP/30 -j MASQUERADE
iptables -t nat -A POSTROUTING -o gretap1 -j MASQUERADE
EOF

    # Create GRETAP DOWN script
    cat <<EOF > "$GRETAP_DOWN_SH"
#!/bin/bash
iptables -D INPUT -p gre -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i gretap1 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i gretap1 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o gretap1 -j ACCEPT 2>/dev/null || true

iptables -t mangle -D FORWARD -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
iptables -t mangle -D FORWARD -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
iptables -t mangle -D OUTPUT -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
iptables -t mangle -D INPUT -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
EOF

    for p in "${PORT_ARRAY[@]}"; do
        cat <<EOF >> "$GRETAP_DOWN_SH"
iptables -t nat -D PREROUTING -p tcp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p 2>/dev/null || true
iptables -t nat -D PREROUTING -p udp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p 2>/dev/null || true
EOF
    done

    cat <<EOF >> "$GRETAP_DOWN_SH"
iptables -t nat -D POSTROUTING -d $TUN_IR_IP/30 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o gretap1 -j MASQUERADE 2>/dev/null || true
ip link del gretap1 2>/dev/null || true
EOF

    chmod +x "$GRETAP_SH" "$GRETAP_DOWN_SH"

    # Bind Backhaul control channel to 0.0.0.0:$BH_PORT so 10.10.1.1:$BH_PORT never refuses connections
    cat <<EOF > "$BACKHAUL_TOML"
[server]
bind_addr = "0.0.0.0:$BH_PORT"
transport = "$BH_TRANS"
token = "$BH_TOKEN"
keepalive_period = 75
nodelay = true
heartbeat = 40
channel_size = 2048
sniffer = false
log_level = "info"
ports = [
    $TOML_PORTS
]
EOF

    create_systemd_services
    systemctl restart gretap-tunnel.service
    systemctl restart backhaul-tunnel.service

    echo -e "\n${GREEN}[✓] IRAN Server setup completed successfully!${NC}"
}

setup_kharej_client() {
    echo -e "\n${CYAN}--- Configuring KHAREJ Client (GRETAP: $TUN_KH_IP) ---${NC}"
    DEFAULT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    read -p "Enter KHAREJ Client Public IP [$DEFAULT_IP]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$DEFAULT_IP}

    read -p "Enter IRAN Server Public IP: " REMOTE_IP
    if [[ -z "$REMOTE_IP" ]]; then
        echo -e "${RED}[!] Remote IP cannot be empty!${NC}"
        return
    fi

    read -p "Enter Backhaul Reverse Communication Port [default: 3080]: " BH_PORT
    BH_PORT=${BH_PORT:-3080}

    read -p "Enter Tunnel Secret Token [default: 123456]: " BH_TOKEN
    BH_TOKEN=${BH_TOKEN:-123456}

    read -p "Select Backhaul Transport (tcp / tcpmux / ws) [default: tcp]: " BH_TRANS
    BH_TRANS=${BH_TRANS:-tcp}

    install_dependencies
    install_backhaul_core

    cat <<EOF > "$GRETAP_SH"
#!/bin/bash
ip link del gretap1 2>/dev/null || true
ip link add gretap1 type gretap local $LOCAL_IP remote $REMOTE_IP ttl 255
ip addr add $TUN_KH_IP/30 dev gretap1
ip link set gretap1 mtu 1400
ip link set gretap1 up

sysctl -w net.ipv4.conf.gretap1.rp_filter=0 >/dev/null 2>&1

# Allow GRE & GRETAP traffic through firewall
iptables -I INPUT 1 -p gre -j ACCEPT
iptables -I INPUT 1 -i gretap1 -j ACCEPT
iptables -I FORWARD 1 -i gretap1 -j ACCEPT
iptables -I FORWARD 1 -o gretap1 -j ACCEPT

# Clamp MSS to $MSS_VAL
iptables -t mangle -I FORWARD 1 -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
iptables -t mangle -I FORWARD 1 -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
iptables -t mangle -I OUTPUT 1 -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
iptables -t mangle -I INPUT 1 -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL
EOF

    cat <<EOF > "$GRETAP_DOWN_SH"
#!/bin/bash
iptables -D INPUT -p gre -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i gretap1 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i gretap1 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o gretap1 -j ACCEPT 2>/dev/null || true

iptables -t mangle -D FORWARD -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
iptables -t mangle -D FORWARD -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
iptables -t mangle -D OUTPUT -o gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
iptables -t mangle -D INPUT -i gretap1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS_VAL 2>/dev/null || true
ip link del gretap1 2>/dev/null || true
EOF

    chmod +x "$GRETAP_SH" "$GRETAP_DOWN_SH"

    cat <<EOF > "$BACKHAUL_TOML"
[client]
remote_addr = "$TUN_IR_IP:$BH_PORT"
transport = "$BH_TRANS"
token = "$BH_TOKEN"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
sniffer = false
log_level = "info"
EOF

    create_systemd_services
    systemctl restart gretap-tunnel.service
    systemctl restart backhaul-tunnel.service

    echo -e "\n${GREEN}[✓] KHAREJ Client setup completed successfully!${NC}"
}

show_status() {
    echo -e "\n${CYAN}================ TUNNEL STATUS ================${NC}"
    if ip link show gretap1 >/dev/null 2>&1; then
        echo -e "${GREEN}[●] GRETAP Interface (gretap1): UP${NC}"
        ip -4 addr show gretap1 | grep inet | awk '{print "    IP Address: " $2}'
    else
        echo -e "${RED}[×] GRETAP Interface (gretap1): DOWN${NC}"
    fi

    echo -e "\n${CYAN}[*] Testing Ping over GRETAP:${NC}"
    if ip addr show gretap1 2>/dev/null | grep -q "$TUN_IR_IP"; then
        ping -c 2 -W 2 "$TUN_KH_IP" >/dev/null 2>&1 && echo -e "    Ping to $TUN_KH_IP: ${GREEN}SUCCESS${NC}" || echo -e "    Ping to $TUN_KH_IP: ${RED}FAILED${NC}"
    elif ip addr show gretap1 2>/dev/null | grep -q "$TUN_KH_IP"; then
        ping -c 2 -W 2 "$TUN_IR_IP" >/dev/null 2>&1 && echo -e "    Ping to $TUN_IR_IP: ${GREEN}SUCCESS${NC}" || echo -e "    Ping to $TUN_IR_IP: ${RED}FAILED${NC}"
    fi

    echo -e "\n${CYAN}[*] Backhaul Service & Listening Ports:${NC}"
    if systemctl is-active --quiet backhaul-tunnel.service; then
        echo -e "    Service: ${GREEN}ACTIVE (RUNNING)${NC}"
        ss -tulnp | grep backhaul | awk '{print "    Listening: " $5}'
    else
        echo -e "    Service: ${RED}INACTIVE / FAILED${NC}"
    fi

    echo -e "\n${CYAN}[*] Recent Backhaul Logs:${NC}"
    journalctl -u backhaul-tunnel.service -n 8 --no-pager

    echo -e "\n${CYAN}[*] Active MSS & NAT Iptables Rules:${NC}"
    iptables -t mangle -S | grep "1240" || echo "    No MSS rules found."
    iptables -t nat -S PREROUTING | grep "$TUN_IR_IP" || echo "    No DNAT port forwarding rules on this node."
    echo -e "${CYAN}===============================================${NC}\n"
}

add_new_ports() {
    if [[ ! -f "$BACKHAUL_TOML" ]] || ! grep -q "\[server\]" "$BACKHAUL_TOML"; then
        echo -e "${RED}[!] Port forwarding is only configured on the IRAN Server!${NC}"
        return
    fi

    read -p "Enter new comma-separated ports (e.g. 1080,443,80): " NEW_PORTS
    if [[ -z "$NEW_PORTS" ]]; then
        echo -e "${RED}[!] No ports entered.${NC}"
        return
    fi

    CLEAN_PORTS=$(echo "$NEW_PORTS" | tr -d ' ')
    IFS=',' read -ra PORT_ARRAY <<< "$CLEAN_PORTS"

    TOML_PORTS=""
    for p in "${PORT_ARRAY[@]}"; do
        if [[ -n "$TOML_PORTS" ]]; then
            TOML_PORTS+=", "
        fi
        TOML_PORTS+="\"$TUN_IR_IP:$p=$p\""
    done

    systemctl stop gretap-tunnel.service

    sed -i '/DNAT --to-destination/d' "$GRETAP_SH"
    sed -i '/DNAT --to-destination/d' "$GRETAP_DOWN_SH"

    for p in "${PORT_ARRAY[@]}"; do
        echo "iptables -t nat -A PREROUTING -p tcp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p" >> "$GRETAP_SH"
        echo "iptables -t nat -A PREROUTING -p udp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p" >> "$GRETAP_SH"
        echo "iptables -t nat -D PREROUTING -p tcp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p 2>/dev/null || true" >> "$GRETAP_DOWN_SH"
        echo "iptables -t nat -D PREROUTING -p udp ! -s $TUN_KH_IP --dport $p -j DNAT --to-destination $TUN_IR_IP:$p 2>/dev/null || true" >> "$GRETAP_DOWN_SH"
    done

    sed -i '/ports = \[/,/\]/c\ports = [\n    '"$TOML_PORTS"'\n]' "$BACKHAUL_TOML"

    systemctl start gretap-tunnel.service
    systemctl restart backhaul-tunnel.service
    echo -e "${GREEN}[✓] Forwarded ports updated to: $CLEAN_PORTS${NC}"
}

uninstall_all() {
    echo -e "\n${YELLOW}[!] Uninstalling GRETAP + Backhaul Tunnel completely...${NC}"
    systemctl stop backhaul-tunnel.service gretap-tunnel.service 2>/dev/null
    systemctl disable backhaul-tunnel.service gretap-tunnel.service 2>/dev/null
    rm -f "$BACKHAUL_SERVICE" "$GRETAP_SERVICE"
    systemctl daemon-reload

    rm -rf "$CONFIG_DIR"
    rm -f "$BACKHAUL_BIN"
    ip link del gretap1 2>/dev/null || true

    echo -e "${GREEN}[✓] Tunnel, services, and iptables rules completely removed.${NC}"
}

main_menu() {
    clear
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}   GRETAP + Backhaul Reverse Tunnel Manager v2.0        ${NC}"
    echo -e "${CYAN}   Iran: 10.10.1.1/30  <--->  Kharej: 10.10.1.2/30      ${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e " 1) Configure ${GREEN}IRAN Server${NC} (GRETAP + Backhaul Server + Iptables)"
    echo -e " 2) Configure ${YELLOW}KHAREJ Client${NC} (GRETAP + Backhaul Client)"
    echo -e " 3) Check Tunnel Status & Logs"
    echo -e " 4) Update Forwarded Ports (Iran Server)"
    echo -e " 5) Restart Tunnel Services"
    echo -e " 6) ${RED}Uninstall Tunnel Completely${NC}"
    echo -e " 0) Exit"
    echo -e "${CYAN}========================================================${NC}"
    read -p "Select an option [0-6]: " choice

    case $choice in
        1) setup_iran_server ;;
        2) setup_kharej_client ;;
        3) show_status ;;
        4) add_new_ports ;;
        5)
            systemctl restart gretap-tunnel.service backhaul-tunnel.service
            echo -e "${GREEN}[✓] Both GRETAP and Backhaul services restarted.${NC}"
            ;;
        6) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}[!] Invalid option!${NC}" ;;
    esac
}

main_menu
