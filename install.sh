#!/bin/bash
# ==============================================================================
# Private IPv6 (SIT) + FRP + UDP2RAW Tunnel Manager (Fixed & Fast Edition)
# Supported OS: Ubuntu / Debian | Architectures: x86_64 (amd64), aarch64 (arm64)
# ==============================================================================

# Root check
if [[ $EUID -ne 0 ]]; then
    echo -e "\e[91m[ERROR] This script must be run as root (sudo -i).\e[0m"
    exit 1
fi

# Colors
RED='\e[91m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
CYAN='\e[96m'
NC='\e[0m'

# Directories & Configs
CONF_DIR="/etc/azumi"
BIN_DIR="/usr/local/bin"
STATE_FILE="$CONF_DIR/tunnel.conf"
FRP_VERSION="0.52.3"

mkdir -p "$CONF_DIR"

# Detect CPU Architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        FRP_ARCH="amd64"
        UDP2RAW_BIN="udp2raw_amd64"
        ;;
    aarch64|arm64)
        FRP_ARCH="arm64"
        UDP2RAW_BIN="udp2raw_arm"
        ;;
    *)
        echo -e "${RED}[ERROR] Unsupported CPU architecture: $ARCH${NC}"
        exit 1
        ;;
esac

# ==============================================================================
# Helper Functions
# ==============================================================================
enable_kernel_optimizations() {
    cat <<EOF > /etc/sysctl.d/99-azumi-tunnel.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system &>/dev/null
}

is_ipv6() {
    [[ "$1" == *":"* ]]
}

get_service_badge() {
    local svc=$1
    if systemctl is-active --quiet "$svc"; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}STOPPED${NC}"
    fi
}

get_tunnel_quick_status() {
    if ! ip link show dev azumi &>/dev/null; then
        echo -e "${RED}NOT CONFIGURED${NC}"
        return
    fi

    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if [[ -n "$PEER_IPV6" ]]; then
            local ping_out
            ping_out=$(ping6 -c 1 -W 1 "$PEER_IPV6" 2>/dev/null || ping -6 -c 1 -W 1 "$PEER_IPV6" 2>/dev/null)
            if [[ $? -eq 0 ]]; then
                local rtt
                rtt=$(echo "$ping_out" | grep 'time=' | sed -E 's/.*time=([0-9.]+).*/\1/')
                echo -e "${GREEN}CONNECTED${NC} (${CYAN}${ROLE}${NC} <-> Peer: ${GREEN}${rtt} ms${NC})"
            else
                echo -e "${RED}DISCONNECTED (Ping Failed to $PEER_IPV6)${NC}"
            fi
            return
        fi
    fi
    echo -e "${YELLOW}INTERFACE UP (Peer Unknown)${NC}"
}

# ==============================================================================
# 1. Fast Core Installation (FRP & UDP2RAW)
# ==============================================================================
install_core() {
    clear
    echo -e "${CYAN}=== Installing Core Dependencies & Binaries ===${NC}"
    enable_kernel_optimizations
    echo -e "${GREEN}[OK]${NC} Kernel IPv4/IPv6 forwarding & BBR enabled."

    # Install required tools quickly only if missing
    for pkg in wget curl tar iproute2 cron; do
        if ! command -v "$pkg" &>/dev/null; then
            echo -e "${YELLOW}[..] Installing missing package: $pkg${NC}"
            apt-get update -y &>/dev/null
            apt-get install -y wget curl tar iproute2 cron &>/dev/null
            break
        fi
    done

    # Install FRP
    echo -e "${YELLOW}[..] Downloading FRP v${FRP_VERSION} (${FRP_ARCH})...${NC}"
    local frp_url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    if wget -q --timeout=15 --tries=2 "$frp_url" -O /tmp/frp.tar.gz; then
        tar -xzf /tmp/frp.tar.gz -C /tmp
        cp -f "/tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" "$BIN_DIR/frps"
        cp -f "/tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc" "$BIN_DIR/frpc"
        chmod +x "$BIN_DIR/frps" "$BIN_DIR/frpc"
        rm -rf /tmp/frp*
        echo -e "${GREEN}[OK]${NC} FRP installed to $BIN_DIR/frps & $BIN_DIR/frpc"
    else
        echo -e "${RED}[ERROR] Failed to download FRP. Check internet/DNS.${NC}"
    fi

    # Install UDP2RAW (Official release tarball + Raw fallback)
    echo -e "${YELLOW}[..] Downloading UDP2RAW (${UDP2RAW_BIN})...${NC}"
    local udp_tar_url="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"
    local udp_raw_url="https://raw.githubusercontent.com/69learn/udp2raw-core/main/${UDP2RAW_BIN}"

    if wget -q --timeout=15 --tries=2 "$udp_tar_url" -O /tmp/udp2raw.tar.gz; then
        tar -xzf /tmp/udp2raw.tar.gz -C /tmp
        cp -f "/tmp/${UDP2RAW_BIN}" "$BIN_DIR/udp2raw"
        chmod +x "$BIN_DIR/udp2raw"
        rm -rf /tmp/udp2raw* /tmp/version.txt
        echo -e "${GREEN}[OK]${NC} UDP2RAW installed to $BIN_DIR/udp2raw"
    elif wget -q --timeout=15 --tries=2 "$udp_raw_url" -O "$BIN_DIR/udp2raw"; then
        chmod +x "$BIN_DIR/udp2raw"
        echo -e "${GREEN}[OK]${NC} UDP2RAW installed via mirror to $BIN_DIR/udp2raw"
    else
        echo -e "${RED}[ERROR] Failed to download UDP2RAW.${NC}"
    fi

    echo -e "\n${GREEN}✔ Fast installation completed!${NC}"
}

# ==============================================================================
# 2. Private IPv6 (SIT Tunnel) Setup
# ==============================================================================
configure_private_ip() {
    clear
    echo -e "${CYAN}=== Configure Private IPv6 (SIT Tunnel) ===${NC}"
    echo "1) Configure KHAREJ (Client Side - ::1)"
    echo "2) Configure IRAN   (Server Side - ::2)"
    echo "0) Back to Main Menu"
    echo "------------------------------------------------"
    read -e -p "Select Role [0-2]: " role_choice

    case "$role_choice" in
        1)
            ROLE="KHAREJ"
            HOST_SUFFIX="1"
            PEER_SUFFIX="2"
            read -e -p "Enter KHAREJ (Local) IPv4 Address : " local_ipv4
            read -e -p "Enter IRAN   (Remote) IPv4 Address: " remote_ipv4
            ;;
        2)
            ROLE="IRAN"
            HOST_SUFFIX="2"
            PEER_SUFFIX="1"
            read -e -p "Enter IRAN   (Local) IPv4 Address : " local_ipv4
            read -e -p "Enter KHAREJ (Remote) IPv4 Address: " remote_ipv4
            ;;
        0) return ;;
        *) echo -e "${RED}Invalid option.${NC}"; return ;;
    esac

    read -e -p "How many Private IPv6 addresses do you want? [Default: 1]: " num_ips
    num_ips=${num_ips:-1}

    enable_kernel_optimizations

    # Clean existing tunnel if present
    ip link set dev azumi down 2>/dev/null
    ip tunnel del azumi 2>/dev/null

    # Generate persistent setup script
    cat <<EOF > "$CONF_DIR/private_up.sh"
#!/bin/bash
ip link set dev azumi down 2>/dev/null
ip tunnel del azumi 2>/dev/null
ip tunnel add azumi mode sit remote $remote_ipv4 local $local_ipv4 ttl 255
ip link set dev azumi mtu 1480 up
EOF

    echo -e "\n${YELLOW}Assigned Private IPv6 Addresses ($ROLE):${NC}"
    echo "------------------------------------------------"
    for ((i=1; i<=num_ips; i++)); do
        hex_idx=$(printf "%x" "$i")
        ipv6_addr="fd1d:fc98:b73e:b48${hex_idx}::${HOST_SUFFIX}"
        echo "ip -6 addr add ${ipv6_addr}/64 dev azumi" >> "$CONF_DIR/private_up.sh"
        echo -e " IP #$i : ${GREEN}${ipv6_addr}${NC}"
    done
    echo "------------------------------------------------"

    chmod +x "$CONF_DIR/private_up.sh"
    bash "$CONF_DIR/private_up.sh"

    # Save state for status checker & keepalive
    PRIMARY_LOCAL_IPV6="fd1d:fc98:b73e:b481::${HOST_SUFFIX}"
    PRIMARY_PEER_IPV6="fd1d:fc98:b73e:b481::${PEER_SUFFIX}"

    cat <<EOF > "$STATE_FILE"
ROLE="$ROLE"
LOCAL_IPV4="$local_ipv4"
REMOTE_IPV4="$remote_ipv4"
LOCAL_IPV6="$PRIMARY_LOCAL_IPV6"
PEER_IPV6="$PRIMARY_PEER_IPV6"
NUM_IPS="$num_ips"
EOF

    # Create systemd service for SIT Tunnel persistence
    cat <<EOF > /etc/systemd/system/azumi-sit.service
[Unit]
Description=Azumi SIT IPv6 Private Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $CONF_DIR/private_up.sh
ExecStop=/sbin/ip tunnel del azumi
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Create lightweight Keepalive service
    cat <<EOF > "$CONF_DIR/keepalive.sh"
#!/bin/bash
while true; do
    ping6 -c 2 -W 2 $PRIMARY_PEER_IPV6 >/dev/null 2>&1 || ping -6 -c 2 -W 2 $PRIMARY_PEER_IPV6 >/dev/null 2>&1
    sleep 25
done
EOF
    chmod +x "$CONF_DIR/keepalive.sh"

    cat <<EOF > /etc/systemd/system/ping_v6.service
[Unit]
Description=Azumi IPv6 Tunnel Keepalive
After=azumi-sit.service

[Service]
ExecStart=/bin/bash $CONF_DIR/keepalive.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now azumi-sit.service &>/dev/null
    systemctl restart ping_v6.service &>/dev/null
    systemctl enable ping_v6.service &>/dev/null

    echo -e "${GREEN}[OK]${NC} SIT Tunnel & Keepalive services enabled."
    echo -e "${YELLOW}[..] Testing connection to peer ($PRIMARY_PEER_IPV6)...${NC}"
    ping6 -c 2 -W 2 "$PRIMARY_PEER_IPV6" 2>/dev/null || ping -6 -c 2 -W 2 "$PRIMARY_PEER_IPV6" 2>/dev/null || echo -e "${YELLOW}[INFO] Peer not responding yet (Configure the other server to complete link).${NC}"
}

# ==============================================================================
# 3 & 4. FRP Tunnel Setup (TCP & WireGuard UDP)
# ==============================================================================
configure_frp_tunnel() {
    local proto_mode=$1 # "tcp" or "udp"
    clear
    echo -e "${CYAN}=== Configure FRP ${proto_mode^^} Tunnel ===${NC}"
    if [[ ! -x "$BIN_DIR/frps" ]] || [[ ! -x "$BIN_DIR/frpc" ]]; then
        echo -e "${YELLOW}[!] FRP binaries not found. Running fast installer first...${NC}"
        install_core
    fi

    echo "1) Configure IRAN   Server (frps - Receiver)"
    echo "2) Configure KHAREJ Client (frpc - Forwarder)"
    echo "0) Back to Main Menu"
    echo "------------------------------------------------"
    read -e -p "Select Server Role [0-2]: " frp_role

    case "$frp_role" in
        1)
            read -e -p "Enter FRP Communication Port [Default: 443]: " bind_port
            bind_port=${bind_port:-443}
            read -e -p "Enter Tunnel Token [Default: 123456]: " token
            token=${token:-123456}

            cat <<EOF > "$CONF_DIR/frps.ini"
[common]
bind_addr = ::
bind_port = $bind_port
authentication_method = token
token = $token
tcp_mux = true
EOF

            cat <<EOF > /etc/systemd/system/azumifrps.service
[Unit]
Description=Azumi FRP Server (Iran)
After=network.target azumi-sit.service

[Service]
ExecStart=$BIN_DIR/frps -c $CONF_DIR/frps.ini
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload
            systemctl enable azumifrps.service &>/dev/null
            systemctl restart azumifrps.service
            echo -e "${GREEN}✔ Iran FRP Server (frps) configured and started on port $bind_port!${NC}"
            ;;

        2)
            local default_iran_ip="fd1d:fc98:b73e:b481::2"
            read -e -p "Enter IRAN Private IPv6 (or IPv4) [Default: $default_iran_ip]: " server_addr
            server_addr=${server_addr:-$default_iran_ip}
            read -e -p "Enter FRP Communication Port [Default: 443]: " server_port
            server_port=${server_port:-443}
            read -e -p "Enter Tunnel Token [Default: 123456]: " token
            token=${token:-123456}
            read -e -p "How many ports/configs do you want to forward? [Default: 1]: " port_count
            port_count=${port_count:-1}

            cat <<EOF > "$CONF_DIR/frpc.ini"
[common]
server_addr = $server_addr
server_port = $server_port
authentication_method = token
token = $token
tcp_mux = true
login_fail_exit = false
EOF

            for ((i=1; i<=port_count; i++)); do
                echo "------------------------------------------------"
                echo -e "${YELLOW}Port Rule #$i (${proto_mode^^}):${NC}"
                read -e -p "Enter Local Target IP on Kharej [Default: 127.0.0.1]: " local_ip
                local_ip=${local_ip:-127.0.0.1}
                read -e -p "Enter Kharej Local Port (e.g. 2083 / 51820): " local_port
                read -e -p "Enter Iran Remote Port  (e.g. 2083 / 51820): " remote_port

                cat <<EOF >> "$CONF_DIR/frpc.ini"

[${proto_mode}_rule_${i}]
type = $proto_mode
local_ip = $local_ip
local_port = $local_port
remote_port = $remote_port
use_encryption = true
use_compression = true
EOF
            done

            cat <<EOF > /etc/systemd/system/azumifrpc.service
[Unit]
Description=Azumi FRP Client (Kharej)
After=network.target azumi-sit.service

[Service]
ExecStart=$BIN_DIR/frpc -c $CONF_DIR/frpc.ini
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload
            systemctl enable azumifrpc.service &>/dev/null
            systemctl restart azumifrpc.service
            echo -e "${GREEN}✔ Kharej FRP Client (frpc) configured and started!${NC}"
            ;;
        0) return ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
}

# ==============================================================================
# 5. UDP2RAW Tunnel Setup
# ==============================================================================
configure_udp2raw() {
    clear
    echo -e "${CYAN}=== Configure UDP2RAW Tunnel ===${NC}"
    if [[ ! -x "$BIN_DIR/udp2raw" ]]; then
        echo -e "${YELLOW}[!] UDP2RAW binary not found. Running fast installer first...${NC}"
        install_core
    fi

    echo "1) Configure KHAREJ Server (udp2raw -s)"
    echo "2) Configure IRAN   Client (udp2raw -c)"
    echo "0) Back to Main Menu"
    echo "------------------------------------------------"
    read -e -p "Select Role [0-2]: " u_role
    [[ "$u_role" == "0" ]] && return

    read -e -p "Enter Tunnel Port [Default: 443]: " tunnel_port
    tunnel_port=${tunnel_port:-443}
    read -e -p "Enter WireGuard / Local UDP Port [Default: 51820]: " wg_port
    wg_port=${wg_port:-51820}
    read -e -p "Enter Tunnel Password [Default: 123456]: " password
    password=${password:-123456}

    echo "Select Raw Mode (Must match on both servers):"
    echo "1) faketcp (Recommended)"
    echo "2) udp"
    echo "3) icmp"
    read -e -p "Choice [1-3, Default: 1]: " mode_choice
    case "$mode_choice" in
        2) raw_mode="udp" ;;
        3) raw_mode="icmp" ;;
        *) raw_mode="faketcp" ;;
    esac

    if [[ "$u_role" == "1" ]]; then
        cat <<EOF > /etc/systemd/system/azumi-udp2raws.service
[Unit]
Description=Azumi UDP2RAW Server (Kharej)
After=network.target azumi-sit.service

[Service]
ExecStart=$BIN_DIR/udp2raw -s -l [::]:${tunnel_port} -r 127.0.0.1:${wg_port} -k "${password}" --raw-mode ${raw_mode} -a --cipher-mode xor --auth-mode simple
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now azumi-udp2raws.service &>/dev/null
        systemctl restart azumi-udp2raws.service
        echo -e "${GREEN}✔ Kharej UDP2RAW Server started (${raw_mode} on port ${tunnel_port})!${NC}"

    elif [[ "$u_role" == "2" ]]; then
        local default_kharej_ip="fd1d:fc98:b73e:b481::1"
        read -e -p "Enter KHAREJ Private IPv6 (or IPv4) [Default: $default_kharej_ip]: " remote_ip
        remote_ip=${remote_ip:-$default_kharej_ip}

        if is_ipv6 "$remote_ip"; then
            remote_target="[${remote_ip}]:${tunnel_port}"
        else
            remote_target="${remote_ip}:${tunnel_port}"
        fi

        cat <<EOF > /etc/systemd/system/azumi-udp2rawc.service
[Unit]
Description=Azumi UDP2RAW Client (Iran)
After=network.target azumi-sit.service

[Service]
ExecStart=$BIN_DIR/udp2raw -c -l 0.0.0.0:${wg_port} -r ${remote_target} -k "${password}" --raw-mode ${raw_mode} -a --cipher-mode xor --auth-mode simple
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now azumi-udp2rawc.service &>/dev/null
        systemctl restart azumi-udp2rawc.service
        echo -e "${GREEN}✔ Iran UDP2RAW Client started (Forwarding UDP ${wg_port} -> ${remote_target})!${NC}"
    fi
}

# ==============================================================================
# 6. Detailed Status & Iran-Kharej Connection Diagnostics
# ==============================================================================
check_tunnel_status() {
    clear
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${CYAN}       IRAN <-> KHAREJ TUNNEL STATUS & DIAGNOSTICS            ${NC}"
    echo -e "${CYAN}==============================================================${NC}"

    # 1. SIT Interface & IPv6 Check
    if ip link show dev azumi &>/dev/null; then
        local mtu_val
        mtu_val=$(ip link show dev azumi | awk '/mtu/ {print $5}')
        echo -e "SIT Interface (azumi) : ${GREEN}UP${NC} (MTU: ${mtu_val})"
        echo -e "Local IPv6 Addresses  :"
        ip -6 addr show dev azumi | awk '/inet6/ {print "  -> " $2}'
    else
        echo -e "SIT Interface (azumi) : ${RED}DOWN / NOT CREATED${NC}"
    fi

    echo "--------------------------------------------------------------"

    # 2. Peer Ping & Packet Loss Test
    local target_peer=""
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        echo -e "Configured Role       : ${YELLOW}${ROLE}${NC} (Local IPv4: $LOCAL_IPV4 <-> Remote IPv4: $REMOTE_IPV4)"
        target_peer="$PEER_IPV6"
    else
        read -e -p "Enter Peer Private IPv6 to test (e.g. fd1d:fc98:b73e:b481::1): " target_peer
    fi

    if [[ -n "$target_peer" ]]; then
        echo -e "${YELLOW}[..] Pinging Peer ($target_peer) with 4 packets...${NC}"
        local ping_output
        ping_output=$(ping6 -c 4 -W 1 -i 0.2 "$target_peer" 2>&1 || ping -6 -c 4 -W 1 -i 0.2 "$target_peer" 2>&1)
        if echo "$ping_output" | grep -q "0% packet loss"; then
            local stats
            stats=$(echo "$ping_output" | tail -n 1)
            echo -e "Tunnel Connection     : ${GREEN}✔ HEALTHY (0% Loss)${NC}"
            echo -e "Latency Stats         : ${CYAN}${stats}${NC}"
        elif echo "$ping_output" | grep -q "received"; then
            local loss
            loss=$(echo "$ping_output" | grep -oE "[0-9]+% packet loss")
            echo -e "Tunnel Connection     : ${YELLOW}⚠ UNSTABLE ($loss)${NC}"
        else
            echo -e "Tunnel Connection     : ${RED}✘ DISCONNECTED (100% Packet Loss)${NC}"
        fi
    fi

    echo "--------------------------------------------------------------"
    # 3. Services Status
    echo -e "SIT Tunnel Service    : $(get_service_badge azumi-sit.service)"
    echo -e "Keepalive Ping        : $(get_service_badge ping_v6.service)"
    echo -e "FRP Server (Iran)     : $(get_service_badge azumifrps.service)"
    echo -e "FRP Client (Kharej)   : $(get_service_badge azumifrpc.service)"
    echo -e "UDP2RAW Server        : $(get_service_badge azumi-udp2raws.service)"
    echo -e "UDP2RAW Client        : $(get_service_badge azumi-udp2rawc.service)"
    echo "--------------------------------------------------------------"

    # 4. Recent FRP / UDP2RAW Logs for troubleshooting
    for svc in azumifrps azumifrpc azumi-udp2raws azumi-udp2rawc; do
        if systemctl is-active --quiet "${svc}.service"; then
            echo -e "${YELLOW}Last 3 log lines for ${svc}:${NC}"
            journalctl -u "${svc}.service" -n 3 --no-pager | sed 's/^/  /'
        fi
    done
    echo -e "${CYAN}==============================================================${NC}"
}

# ==============================================================================
# 7. Restart Services
# ==============================================================================
restart_services() {
    clear
    echo -e "${YELLOW}[..] Restarting active tunnel services...${NC}"
    systemctl daemon-reload
    for svc in azumi-sit ping_v6 azumifrps azumifrpc azumi-udp2raws azumi-udp2rawc; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            systemctl restart "${svc}.service" 2>/dev/null && echo -e "${GREEN}[OK]${NC} Restarted ${svc}.service"
        fi
    done
}

# ==============================================================================
# 8. Auto-Reset Cron Job (Fixed Logic)
# ==============================================================================
configure_cron() {
    clear
    echo -e "${CYAN}=== Auto-Restart Timer (Every 6 Hours) ===${NC}"
    echo "1) Enable 6-Hour Auto-Restart for Tunnel Services"
    echo "2) Remove Auto-Restart Cron Job"
    echo "0) Back"
    read -e -p "Select [0-2]: " c_choice

    local cron_script="$CONF_DIR/auto_restart.sh"
    local cron_line="0 */6 * * * /bin/bash $cron_script"

    if [[ "$c_choice" == "1" ]]; then
        cat <<EOF > "$cron_script"
#!/bin/bash
systemctl restart azumi-sit.service 2>/dev/null
systemctl restart azumifrps.service 2>/dev/null
systemctl restart azumifrpc.service 2>/dev/null
systemctl restart azumi-udp2raws.service 2>/dev/null
systemctl restart azumi-udp2rawc.service 2>/dev/null
EOF
        chmod +x "$cron_script"
        (crontab -l 2>/dev/null | grep -v "$cron_script"; echo "$cron_line") | crontab -
        echo -e "${GREEN}✔ 6-hour auto-restart timer enabled!${NC}"
    elif [[ "$c_choice" == "2" ]]; then
        crontab -l 2>/dev/null | grep -v "$cron_script" | crontab -
        rm -f "$cron_script"
        echo -e "${GREEN}✔ Auto-restart timer removed!${NC}"
    fi
}

# ==============================================================================
# 9. Uninstall Everything
# ==============================================================================
uninstall_all() {
    clear
    echo -e "${RED}=== Uninstall Tunnel Services ===${NC}"
    echo "1) Remove Private IPv6 (SIT Tunnel) Only"
    echo "2) Remove FRP Services Only"
    echo "3) Remove UDP2RAW Services Only"
    echo "4) Full Uninstall (Everything)"
    echo "0) Cancel"
    read -e -p "Select [0-4]: " u_choice

    case "$u_choice" in
        1)
            systemctl disable --now azumi-sit.service ping_v6.service 2>/dev/null
            rm -f /etc/systemd/system/azumi-sit.service /etc/systemd/system/ping_v6.service
            ip link set dev azumi down 2>/dev/null
            ip tunnel del azumi 2>/dev/null
            rm -f "$CONF_DIR/private_up.sh" "$CONF_DIR/keepalive.sh" "$STATE_FILE"
            systemctl daemon-reload
            echo -e "${GREEN}✔ Private IPv6 tunnel removed.${NC}"
            ;;
        2)
            systemctl disable --now azumifrps.service azumifrpc.service 2>/dev/null
            rm -f /etc/systemd/system/azumifrps.service /etc/systemd/system/azumifrpc.service
            rm -f "$CONF_DIR/frps.ini" "$CONF_DIR/frpc.ini"
            systemctl daemon-reload
            echo -e "${GREEN}✔ FRP services removed.${NC}"
            ;;
        3)
            systemctl disable --now azumi-udp2raws.service azumi-udp2rawc.service 2>/dev/null
            rm -f /etc/systemd/system/azumi-udp2raws.service /etc/systemd/system/azumi-udp2rawc.service
            systemctl daemon-reload
            echo -e "${GREEN}✔ UDP2RAW services removed.${NC}"
            ;;
        4)
            for svc in azumi-sit ping_v6 azumifrps azumifrpc azumi-udp2raws azumi-udp2rawc; do
                systemctl disable --now "${svc}.service" 2>/dev/null
                rm -f "/etc/systemd/system/${svc}.service"
            done
            ip link set dev azumi down 2>/dev/null
            ip tunnel del azumi 2>/dev/null
            crontab -l 2>/dev/null | grep -v "$CONF_DIR" | grep -v "/etc/private.sh" | grep -v "/etc/res.sh" | crontab -
            rm -rf "$CONF_DIR" "$BIN_DIR/frps" "$BIN_DIR/frpc" "$BIN_DIR/udp2raw"
            systemctl daemon-reload
            echo -e "${GREEN}✔ Complete uninstallation finished.${NC}"
            ;;
    esac
}

# ==============================================================================
# Main Vertical Menu
# ==============================================================================
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================================${NC}"
        echo -e "         ${GREEN}PRIVATE IP & TUNNEL MANAGER (FAST CLI)${NC}         "
        echo -e "${CYAN}========================================================${NC}"
        echo -e " Tunnel Link   : $(get_tunnel_quick_status)"
        echo -e " SIT Service   : $(get_service_badge azumi-sit.service) | Keepalive: $(get_service_badge ping_v6.service)"
        echo -e " FRP Status    : Server: $(get_service_badge azumifrps.service) | Client: $(get_service_badge azumifrpc.service)"
        echo -e " UDP2RAW       : Server: $(get_service_badge azumi-udp2raws.service) | Client: $(get_service_badge azumi-udp2rawc.service)"
        echo -e "${CYAN}--------------------------------------------------------${NC}"
        echo -e " 1) Fast Install Core (FRP & UDP2RAW)"
        echo -e " 2) Configure Private IPv6 (SIT Tunnel Iran/Kharej)"
        echo -e " 3) Configure FRP TCP Tunnel"
        echo -e " 4) Configure FRP WireGuard (UDP) Tunnel"
        echo -e " 5) Configure UDP2RAW Tunnel"
        echo -e " 6) Tunnel Status & Connection Diagnostics (Ping/Logs)"
        echo -e " 7) Restart All Active Services"
        echo -e " 8) Auto-Restart Timer (6-Hour Cron)"
        echo -e " 9) Uninstall Menu"
        echo -e " 0) Exit"
        echo -e "${CYAN}--------------------------------------------------------${NC}"
        read -e -p "Enter your choice [0-9]: " choice

        case "$choice" in
            1) install_core ;;
            2) configure_private_ip ;;
            3) configure_frp_tunnel "tcp" ;;
            4) configure_frp_tunnel "udp" ;;
            5) configure_udp2raw ;;
            6) check_tunnel_status ;;
            7) restart_services ;;
            8) configure_cron ;;
            9) uninstall_all ;;
            0) echo "Exiting..."; exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac

        echo ""
        read -e -p "Press Enter to return to menu..."
    done
}

main_menu
