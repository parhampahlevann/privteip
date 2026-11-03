#!/bin/bash
# ==============================================================================
# GRETAP + Backhaul Reverse Tunnel Manager  v3.0  (full rewrite)
#
#   Iran : 10.10.1.1/30  <== GRETAP (MTU 1400 / MSS 1240) ==>  Kharej : 10.10.1.2/30
#
# Data path
#   user -> Iran public IP:PORT --(iptables DNAT)--> 10.10.1.1:PORT (Backhaul server)
#        -> Backhaul control + data channels travel INSIDE the GRETAP link
#        -> Kharej Backhaul client -> 127.0.0.1:TARGET_PORT on the Kharej box
#
# What changed compared to v2.x (all of these were real bugs or footguns)
#   1. Forwarded ports arrive on the PUBLIC NIC, not on gretap1 -> explicit INPUT
#      accept rules per forwarded port (the "ping works, forward does not" bug).
#   2. Backhaul now uses its OWN binary (/usr/local/bin/backhaul-gretap). Another
#      script/cron deleting or replacing /usr/local/bin/backhaul can no longer
#      break this tunnel or cause a version mismatch between the two servers.
#   3. Setup refuses a control/forward port that another program already listens
#      on. That situation produces exactly "failed to read message length from
#      net.Conn: EOF" on the Kharej client (the client talks to the OTHER program,
#      which hangs up). Port owners are shown by Diagnose.
#   4. Iran Backhaul server binds to 10.10.1.1 only (v2 exposed the control port
#      on every interface) and the unit waits until gretap1 really has its IP.
#   5. Firewall rules are tagged (comment BHGT), applied idempotently and removed
#      by tag, so restarts/port updates never leave duplicates or stale rules.
#      Tunnel traffic is exempted from any foreign DNAT/REDIRECT rules.
#   6. No more sed-editing of TOML: everything is regenerated from tunnel.conf.
#   7. Real input validation, curl -f (HTML error pages were saved as "binaries"),
#      binary sanity check + version + sha256 shown so both sides can be compared,
#      offline install from a local file/URL, accept_udp only when asked for,
#      menu loop, Diagnose + Verify steps, no global sysctl/ip_forward changes.
# ==============================================================================

VERSION="3.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_DIR="/etc/backhaul-gretap"
CONF_FILE="$CONFIG_DIR/tunnel.conf"
TOML_FILE="$CONFIG_DIR/config.toml"
CTL_SH="$CONFIG_DIR/gretap-ctl.sh"

BACKHAUL_BIN="/usr/local/bin/backhaul-gretap"
LEGACY_BIN="/usr/local/bin/backhaul"

UNIT_DIR="/etc/systemd/system"
GRETAP_SVC="gretap-tunnel.service"
BACKHAUL_SVC="backhaul-tunnel.service"

IFACE="gretap1"
TUN_IR_IP="10.10.1.1"
TUN_KH_IP="10.10.1.2"
MSS_VAL="1240"
MTU_VAL="1400"

# ------------------------------------------------------------------------------
# small helpers
# ------------------------------------------------------------------------------
info() { echo -e "${CYAN}[*] $*${NC}"; }
ok()   { echo -e "${GREEN}[+] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
err()  { echo -e "${RED}[x] $*${NC}"; }
res()  { # res ok|bad|warn "message"
    case $1 in
        ok)  echo -e "  ${GREEN}[PASS]${NC} $2" ;;
        bad) echo -e "  ${RED}[FAIL]${NC} $2" ;;
        *)   echo -e "  ${YELLOW}[WARN]${NC} $2" ;;
    esac
}
pause() { read -r -p "Press Enter to continue..." _ || exit 0; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root!${NC}"
    exit 1
fi
if (( BASH_VERSINFO[0] < 4 )); then
    echo -e "${RED}[ERROR] bash >= 4 is required.${NC}"
    exit 1
fi

ask() { # ask VAR "prompt" ["default"]
    local __var=$1 __prompt=$2 __def=${3:-} __ans
    if [[ -n $__def ]]; then
        read -r -p "$__prompt [$__def]: " __ans || { echo; exit 1; }
        __ans=${__ans:-$__def}
    else
        read -r -p "$__prompt: " __ans || { echo; exit 1; }
    fi
    __ans=${__ans#"${__ans%%[![:space:]]*}"}
    __ans=${__ans%"${__ans##*[![:space:]]}"}
    printf -v "$__var" '%s' "$__ans"
}

ask_valid() { # ask_valid VAR "prompt" "default" validator "error message"
    local __v
    while true; do
        ask __v "$2" "${3:-}"
        if "$4" "$__v"; then
            printf -v "$1" '%s' "$__v"
            return 0
        fi
        err "$5"
    done
}

ask_yn() { # ask_yn "question" default(y|n)  -> exit status 0 = yes
    local def=${2:-n} a hint="y/N"
    [[ $def == y ]] && hint="Y/n"
    read -r -p "$1 [$hint]: " a || exit 1
    a=${a:-$def}
    [[ $a =~ ^[Yy] ]]
}

valid_ipv4() {
    local o
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}
valid_port()      { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_token()     { [[ $1 =~ ^[A-Za-z0-9._~@%+=-]{1,64}$ ]]; }
valid_transport() { case $1 in tcp|tcpmux|ws|wsmux) return 0 ;; *) return 1 ;; esac; }

detect_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1
}

# parse_ports "1080, 443, 8443=443" -> PORT_MAP=("1080=1080" "443=443" "8443=443")
# entry "A" means public port A -> Kharej 127.0.0.1:A ; "A=B" means public A -> Kharej 127.0.0.1:B
parse_ports() {
    local raw=${1//[[:space:]]/} entry pub tgt
    local -a entries=()
    local -A seen=()
    PORT_MAP=()
    [[ -n $raw ]] || return 1
    IFS=',' read -ra entries <<< "$raw"
    for entry in "${entries[@]}"; do
        [[ -z $entry ]] && continue
        if [[ $entry == *=* ]]; then
            pub=${entry%%=*}
            tgt=${entry#*=}
        else
            pub=$entry
            tgt=$entry
        fi
        if ! valid_port "$pub" || ! valid_port "$tgt"; then
            err "Invalid port entry: '$entry' (ranges are not supported)"
            return 1
        fi
        pub=$((10#$pub))
        tgt=$((10#$tgt))
        if [[ -n ${seen[$pub]:-} ]]; then
            warn "Duplicate public port $pub ignored."
            continue
        fi
        seen[$pub]=1
        PORT_MAP+=("$pub=$tgt")
    done
    (( ${#PORT_MAP[@]} > 0 ))
}

# listeners that would clash with Backhaul binding TUN_IR_IP:port (wildcard or same IP),
# ignoring our own backhaul-gretap process. Prints "addr process" per clash.
listener_conflicts() { # proto port
    local flags="-ltnpH"
    [[ $1 == udp ]] && flags="-lunpH"
    local laddr proc
    ss $flags "sport = :$2" 2>/dev/null | while read -r _ _ _ laddr _ proc; do
        case ${laddr%:*} in
            "*"|0.0.0.0|"[::]"|"::"|"$TUN_IR_IP") ;;
            *) continue ;;
        esac
        [[ $proc == *'"backhaul-gretap"'* ]] && continue
        echo "$laddr ${proc:-unknown-process}"
    done
}

pick_free_port() {
    local i p
    for i in $(seq 1 60); do
        p=$(( (RANDOM % 20000) + 20000 ))
        [[ -z $(ss -H -ltn "sport = :$p" 2>/dev/null) ]] && { echo "$p"; return; }
    done
    echo 28080
}

# ------------------------------------------------------------------------------
# persistent configuration (single source of truth)
# ------------------------------------------------------------------------------
set_role_ips() {
    if [[ $ROLE == iran ]]; then
        SELF_IP=$TUN_IR_IP
        PEER_IP=$TUN_KH_IP
    else
        SELF_IP=$TUN_KH_IP
        PEER_IP=$TUN_IR_IP
    fi
}

save_conf() {
    mkdir -p "$CONFIG_DIR"
    install -m 600 /dev/null "$CONF_FILE"
    {
        echo "# generated by backhaul-gretap-manager v$VERSION - edit via the menu"
        printf 'ROLE=%q\n'         "$ROLE"
        printf 'LOCAL_IP=%q\n'     "$LOCAL_IP"
        printf 'REMOTE_IP=%q\n'    "$REMOTE_IP"
        printf 'SELF_IP=%q\n'      "$SELF_IP"
        printf 'PEER_IP=%q\n'      "$PEER_IP"
        printf 'BH_PORT=%q\n'      "$BH_PORT"
        printf 'BH_TOKEN=%q\n'     "$BH_TOKEN"
        printf 'BH_TRANS=%q\n'     "$BH_TRANS"
        printf 'ACCEPT_UDP=%q\n'   "${ACCEPT_UDP:-0}"
        printf 'PORTS=%q\n'        "${PORTS:-}"
        printf 'IFACE=%q\n'        "$IFACE"
        printf 'TUN_IR_IP=%q\n'    "$TUN_IR_IP"
        printf 'TUN_KH_IP=%q\n'    "$TUN_KH_IP"
        printf 'MSS_VAL=%q\n'      "$MSS_VAL"
        printf 'MTU_VAL=%q\n'      "$MTU_VAL"
        printf 'BACKHAUL_BIN=%q\n' "$BACKHAUL_BIN"
    } > "$CONF_FILE"
}

load_conf() {
    [[ -f $CONF_FILE ]] || return 1
    # shellcheck disable=SC1090
    source "$CONF_FILE" || return 1
    [[ -n ${ROLE:-} ]]
}

write_toml() {
    local m
    install -m 600 /dev/null "$TOML_FILE"
    if [[ $ROLE == iran ]]; then
        {
            echo "[server]"
            echo "bind_addr = \"$TUN_IR_IP:$BH_PORT\""
            echo "transport = \"$BH_TRANS\""
            if [[ ${ACCEPT_UDP:-0} == 1 ]]; then echo "accept_udp = true"; fi
            echo "token = \"$BH_TOKEN\""
            echo "keepalive_period = 75"
            echo "nodelay = true"
            echo "heartbeat = 40"
            echo "channel_size = 2048"
            echo "sniffer = false"
            echo "log_level = \"info\""
            echo "ports = ["
            for m in $PORTS; do
                echo "    \"$TUN_IR_IP:${m%%=*}=${m#*=}\","
            done
            echo "]"
        } > "$TOML_FILE"
    else
        {
            echo "[client]"
            echo "remote_addr = \"$TUN_IR_IP:$BH_PORT\""
            echo "transport = \"$BH_TRANS\""
            echo "token = \"$BH_TOKEN\""
            echo "connection_pool = 8"
            echo "aggressive_pool = false"
            echo "keepalive_period = 75"
            echo "dial_timeout = 10"
            echo "retry_interval = 3"
            echo "nodelay = true"
            echo "sniffer = false"
            echo "log_level = \"info\""
        } > "$TOML_FILE"
    fi
}

# ------------------------------------------------------------------------------
# the helper that systemd runs (static content, reads tunnel.conf at runtime)
# ------------------------------------------------------------------------------
write_ctl_script() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CTL_SH" <<'CTL_EOF'
#!/bin/bash
# gretap-ctl.sh - managed by backhaul-gretap-manager. Do not edit by hand.
#   up | down | reload | prestart
CONF_FILE="/etc/backhaul-gretap/tunnel.conf"
# shellcheck disable=SC1090
source "$CONF_FILE" || { echo "cannot read $CONF_FILE" >&2; exit 1; }

TAG="BHGT"
if iptables -w 5 -L -n >/dev/null 2>&1; then IPT=(iptables -w 5); else IPT=(iptables); fi

# ipt_ensure <table> <chain> <match/target args...>   (idempotent, inserted at top, tagged)
ipt_ensure() {
    local t=$1 c=$2
    shift 2
    local -a pre=() post=() spec=()
    while (( $# )); do
        if [[ $1 == -j ]]; then post=("$@"); break; fi
        pre+=("$1")
        shift
    done
    spec=("${pre[@]}" -m comment --comment "$TAG" "${post[@]}")
    "${IPT[@]}" -t "$t" -C "$c" "${spec[@]}" 2>/dev/null || "${IPT[@]}" -t "$t" -I "$c" 1 "${spec[@]}"
}

# remove every rule carrying our tag, whatever the current config says
purge_rules() {
    local t line
    local -a words=()
    for t in filter nat mangle; do
        while read -r line; do
            [[ -n $line ]] || continue
            line=${line//\"/}
            line="-D${line#-A}"
            read -ra words <<< "$line"
            "${IPT[@]}" -t "$t" "${words[@]}" 2>/dev/null
        done < <("${IPT[@]}" -t "$t" -S 2>/dev/null | grep -E -- "--comment \"?$TAG\"? ")
    done
    return 0
}

apply_rules() {
    local m pub

    # --- filter: let GRE from the peer in, and everything that rides on the tunnel
    ipt_ensure filter INPUT   -p gre -s "$REMOTE_IP" -j ACCEPT
    ipt_ensure filter INPUT   -i "$IFACE" -j ACCEPT
    ipt_ensure filter FORWARD -i "$IFACE" -j ACCEPT
    ipt_ensure filter FORWARD -o "$IFACE" -j ACCEPT

    # --- mangle: MSS clamp
    ipt_ensure mangle FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VAL"
    ipt_ensure mangle FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VAL"
    ipt_ensure mangle OUTPUT  -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VAL"
    ipt_ensure mangle INPUT   -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VAL"

    if [[ $ROLE == iran ]]; then
        for m in $PORTS; do
            pub=${m%%=*}
            # traffic that arrives on the PUBLIC NIC and is DNATed to the tunnel IP
            # is delivered locally: it needs its own INPUT accept (NOT covered by -i gretap1)
            ipt_ensure filter INPUT -d "$TUN_IR_IP" -p tcp --dport "$pub" -j ACCEPT
            ipt_ensure nat PREROUTING ! -i "$IFACE" -m addrtype --dst-type LOCAL -p tcp --dport "$pub" -j DNAT --to-destination "$TUN_IR_IP:$pub"
            if [[ ${ACCEPT_UDP:-0} == 1 ]]; then
                ipt_ensure filter INPUT -d "$TUN_IR_IP" -p udp --dport "$pub" -j ACCEPT
                ipt_ensure nat PREROUTING ! -i "$IFACE" -m addrtype --dst-type LOCAL -p udp --dport "$pub" -j DNAT --to-destination "$TUN_IR_IP:$pub"
            fi
        done
        # tunnel traffic must never be touched by any other DNAT/REDIRECT rule on the box.
        # Inserted last on purpose so it ends up FIRST in the chain.
        ipt_ensure nat PREROUTING -i "$IFACE" -j ACCEPT
    else
        ipt_ensure nat OUTPUT -o "$IFACE" -j ACCEPT
    fi
}

has_self_ip() { ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q "inet $SELF_IP/"; }

case "$1" in
    up)
        purge_rules
        modprobe ip_gre 2>/dev/null
        ip link del "$IFACE" 2>/dev/null
        if ! ip link add "$IFACE" type gretap local "$LOCAL_IP" remote "$REMOTE_IP" ttl 255; then
            echo "ERROR: cannot create $IFACE (ip_gre/gretap unsupported by this kernel/VPS, or LOCAL_IP $LOCAL_IP is not an address of this host)" >&2
            exit 1
        fi
        ip addr add "$SELF_IP/30" dev "$IFACE" || exit 1
        ip link set "$IFACE" mtu "$MTU_VAL" up || exit 1
        sysctl -qw "net.ipv4.conf.$IFACE.rp_filter=0" 2>/dev/null
        apply_rules
        ;;
    reload)
        purge_rules
        apply_rules
        ;;
    down)
        purge_rules
        ip link del "$IFACE" 2>/dev/null
        exit 0
        ;;
    prestart)
        if [[ ! -x $BACKHAUL_BIN ]]; then
            echo "ERROR: $BACKHAUL_BIN is missing or not executable (reinstall it from the menu)" >&2
            exit 1
        fi
        for _ in $(seq 1 20); do has_self_ip && break; sleep 1; done
        if ! has_self_ip; then
            echo "ERROR: $IFACE has no $SELF_IP address" >&2
            exit 1
        fi
        if [[ $ROLE == kharej ]]; then
            for _ in $(seq 1 10); do ping -c1 -W1 "$PEER_IP" >/dev/null 2>&1 && break; sleep 1; done
        fi
        exit 0
        ;;
    *)
        echo "usage: $0 up|down|reload|prestart" >&2
        exit 2
        ;;
esac
CTL_EOF
    chmod 755 "$CTL_SH"
}

write_units() {
    cat > "$UNIT_DIR/$GRETAP_SVC" <<EOF
[Unit]
Description=GRETAP Layer-2 tunnel and firewall rules (backhaul-gretap)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$CTL_SH up
ExecStop=$CTL_SH down

[Install]
WantedBy=multi-user.target
EOF

    cat > "$UNIT_DIR/$BACKHAUL_SVC" <<EOF
[Unit]
Description=Backhaul reverse tunnel over GRETAP
After=$GRETAP_SVC
Requires=$GRETAP_SVC
PartOf=$GRETAP_SVC
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=$CTL_SH prestart
ExecStart=$BACKHAUL_BIN -c $TOML_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$GRETAP_SVC" "$BACKHAUL_SVC" >/dev/null 2>&1
}

stop_services() {
    systemctl stop "$BACKHAUL_SVC" "$GRETAP_SVC" >/dev/null 2>&1
    pkill -f -- "$BACKHAUL_BIN -c $TOML_FILE" 2>/dev/null
    return 0
}

# ------------------------------------------------------------------------------
# dependencies + Backhaul binary
# ------------------------------------------------------------------------------
ensure_deps() {
    local cmd
    local -a need=()
    for cmd in ip iptables ss curl tar sha256sum systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
    done
    if (( ${#need[@]} > 0 )); then
        info "Missing tools: ${need[*]} - trying to install..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y -qq >/dev/null 2>&1
            apt-get install -y -qq iproute2 iptables curl tar coreutils iputils-ping >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q iproute iptables curl tar coreutils iputils >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q iproute iptables curl tar coreutils iputils >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache iproute2 iptables curl tar coreutils iputils >/dev/null 2>&1
        fi
        for cmd in "${need[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                err "Required command '$cmd' is still missing - install it manually and retry."
                return 1
            fi
        done
    fi
    command -v ping >/dev/null 2>&1 || warn "'ping' not found: diagnostics will be limited (apt install iputils-ping)."
    return 0
}

is_elf() { [[ -s $1 && "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]; }

install_binary_file() { # $1 = .tar.gz archive or raw ELF binary
    local src=$1 tmp found
    tmp=$(mktemp -d) || return 1
    if tar -tzf "$src" >/dev/null 2>&1; then
        tar -xzf "$src" -C "$tmp" || { rm -rf "$tmp"; return 1; }
        found=$(find "$tmp" -type f -name backhaul | head -n1)
        if [[ -z $found ]] || ! is_elf "$found"; then
            err "No valid 'backhaul' executable inside the archive."
            rm -rf "$tmp"
            return 1
        fi
    elif is_elf "$src"; then
        found=$src
    else
        err "The file is neither a .tar.gz archive nor a Linux executable (an HTML error page?)."
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$found" "$BACKHAUL_BIN.new" && mv -f "$BACKHAUL_BIN.new" "$BACKHAUL_BIN"
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

download_to() { # url file
    curl -fL --connect-timeout 15 --max-time 240 -o "$2" "$1" 2>/dev/null && [[ -s $2 ]]
}

bin_version() { timeout 3 "$BACKHAUL_BIN" -v 2>&1 | head -n1; }

show_bin_info() {
    if [[ ! -x $BACKHAUL_BIN ]]; then
        err "Backhaul binary not installed ($BACKHAUL_BIN)."
        return 1
    fi
    echo "    path    : $BACKHAUL_BIN"
    echo "    version : $(bin_version)"
    echo "    size    : $(stat -c %s "$BACKHAUL_BIN") bytes"
    echo "    sha256  : $(sha256sum "$BACKHAUL_BIN" | cut -d' ' -f1)"
    warn "Iran and Kharej MUST run the same binary: compare the sha256 above on both servers."
}

install_backhaul_core() { # [force]
    local force=${1:-0} file url tmp src
    mkdir -p "$CONFIG_DIR"
    if [[ $force != 1 ]] && [[ -x $BACKHAUL_BIN ]] && is_elf "$BACKHAUL_BIN"; then
        ok "Backhaul binary already installed."
        show_bin_info
        return 0
    fi

    case "$(uname -m)" in
        x86_64|amd64)  file="backhaul_linux_amd64.tar.gz" ;;
        aarch64|arm64) file="backhaul_linux_arm64.tar.gz" ;;
        *) err "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac

    tmp=$(mktemp) || return 1
    url="https://github.com/Musixal/Backhaul/releases/latest/download/$file"
    info "Downloading $url"
    if download_to "$url" "$tmp" && install_binary_file "$tmp"; then
        rm -f "$tmp"
        ok "Backhaul installed."
        show_bin_info
        return 0
    fi
    rm -f "$tmp"
    warn "GitHub download failed (blocked / offline?)."

    if [[ -x $LEGACY_BIN ]] && is_elf "$LEGACY_BIN"; then
        warn "Found an existing binary at $LEGACY_BIN (probably installed by another script)."
        if ask_yn "Copy and use it for this tunnel?" n; then
            if install_binary_file "$LEGACY_BIN"; then
                ok "Copied."
                show_bin_info
                return 0
            fi
        fi
    fi

    warn "Give a direct URL (.tar.gz or raw binary) or a local file path. Empty = abort."
    ask src "URL or path" ""
    [[ -n $src ]] || return 1
    if [[ -f $src ]]; then
        install_binary_file "$src" || return 1
    elif [[ $src =~ ^https?:// ]]; then
        tmp=$(mktemp) || return 1
        if download_to "$src" "$tmp" && install_binary_file "$tmp"; then
            rm -f "$tmp"
        else
            rm -f "$tmp"
            err "Download/installation failed."
            return 1
        fi
    else
        err "Not a file and not an http(s) URL."
        return 1
    fi
    ok "Backhaul installed."
    show_bin_info
}

# ------------------------------------------------------------------------------
# prompts shared by setup / update
# ------------------------------------------------------------------------------
prompt_ports() {
    local raw m pub conflicts
    while true; do
        ask raw "Ports to forward (e.g. 1080,443  -  use 8443=443 for public 8443 -> Kharej 443)" ""
        if ! parse_ports "$raw"; then
            err "Enter at least one valid port."
            continue
        fi
        conflicts=""
        for m in "${PORT_MAP[@]}"; do
            pub=${m%%=*}
            conflicts+=$(listener_conflicts tcp "$pub" | sed "s/^/tcp $pub: /")$'\n'
            if [[ ${ACCEPT_UDP:-0} == 1 ]]; then
                conflicts+=$(listener_conflicts udp "$pub" | sed "s/^/udp $pub: /")$'\n'
            fi
        done
        conflicts=$(echo "$conflicts" | sed '/^$/d')
        [[ -z $conflicts ]] && return 0
        warn "These ports are already used by another program on this server:"
        echo "$conflicts" | sed 's/^/        /'
        warn "Backhaul cannot bind them, and the other program would answer instead of the tunnel."
        ask_yn "Enter a different port list?" y || return 0
    done
}

# ------------------------------------------------------------------------------
# setup
# ------------------------------------------------------------------------------
setup_tunnel() { # iran | kharej
    ROLE=$1
    set_role_ips
    local def_ip c lbl_local lbl_remote start_ts
    if [[ $ROLE == iran ]]; then
        lbl_local="IRAN server"; lbl_remote="KHAREJ client"
    else
        lbl_local="KHAREJ client"; lbl_remote="IRAN server"
    fi
    echo -e "\n${CYAN}--- Configuring $lbl_local (GRETAP: $SELF_IP) ---${NC}"

    ensure_deps || return 1

    def_ip=$(detect_ip)
    ask_valid LOCAL_IP "Enter $lbl_local public IP" "$def_ip" valid_ipv4 "Not a valid IPv4 address."
    ask_valid REMOTE_IP "Enter $lbl_remote public IP" "" valid_ipv4 "Not a valid IPv4 address."
    if [[ $LOCAL_IP == "$REMOTE_IP" ]]; then
        err "Local and remote IP are identical."
        return 1
    fi

    while true; do
        ask_valid BH_PORT "Backhaul control port (reached INSIDE the tunnel)" "3080" valid_port "Port must be 1-65535."
        [[ $ROLE == iran ]] || break
        c=$(listener_conflicts tcp "$BH_PORT")
        [[ -z $c ]] && break
        err "Port $BH_PORT is already used on this server by:"
        echo "$c" | sed 's/^/        /'
        err "A Backhaul client would connect to THAT program, which hangs up -> 'failed to read message length ... EOF'."
        warn "Pick another port (for example $(pick_free_port))."
    done

    ask_valid BH_TOKEN "Tunnel secret token (must be identical on both sides)" "123456" valid_token "1-64 chars from: A-Z a-z 0-9 . _ ~ @ % + = -"
    [[ $BH_TOKEN == "123456" ]] && warn "Using the default token. The control port is only reachable inside the tunnel, but a custom token is better."
    ask_valid BH_TRANS "Backhaul transport (tcp / tcpmux / ws / wsmux) - must match on both sides" "tcp" valid_transport "Choose tcp, tcpmux, ws or wsmux."

    ACCEPT_UDP=0
    PORTS=""
    if [[ $ROLE == iran ]]; then
        if [[ $BH_TRANS == tcp || $BH_TRANS == tcpmux ]]; then
            ask_yn "Also forward UDP on those ports (UDP-over-TCP)?" n && ACCEPT_UDP=1
        fi
        prompt_ports
        PORTS="${PORT_MAP[*]}"
    fi

    install_backhaul_core 0 || { err "Cannot continue without the Backhaul binary."; return 1; }

    start_ts=$(date '+%Y-%m-%d %H:%M:%S')
    info "Stopping old services (their own stop hooks remove old firewall rules)..."
    stop_services
    rm -f "$CONFIG_DIR/gretap-up.sh" "$CONFIG_DIR/gretap-down.sh"

    save_conf
    write_toml
    write_ctl_script
    write_units

    info "Starting GRETAP + Backhaul..."
    if ! systemctl restart "$GRETAP_SVC"; then
        err "GRETAP service failed to start:"
        journalctl -u "$GRETAP_SVC" -n 15 --no-pager -o cat
        return 1
    fi
    systemctl restart "$BACKHAUL_SVC"

    verify_setup "$start_ts"

    if [[ $ROLE == kharej ]]; then
        echo
        warn "Backhaul forwards every tunneled port to 127.0.0.1:<target port> ON THIS (Kharej) MACHINE."
        warn "A real service (SOCKS/Xray/...) must listen there, otherwise the tunnel is up but the forwarded connection is refused."
    else
        echo
        info "Forwarded ports on this server are opened by Backhaul only AFTER the Kharej client has connected."
    fi
}

verify_setup() { # start_ts
    local ts=$1 i log errs
    echo
    info "Verifying (up to 25 s)..."
    if [[ $ROLE == iran ]]; then
        for i in $(seq 1 15); do
            if systemctl is-active -q "$BACKHAUL_SVC" && ss -H -ltnp "sport = :$BH_PORT" 2>/dev/null | grep -q backhaul-gretap; then
                res ok "Backhaul server is listening on $TUN_IR_IP:$BH_PORT"
                return 0
            fi
            sleep 1
        done
        res bad "Backhaul server is NOT listening on port $BH_PORT"
        journalctl -u "$BACKHAUL_SVC" --since "$ts" --no-pager -o cat 2>/dev/null | tail -n 15
        echo "    -> run menu option 4 (Diagnose) to see who owns the port / why it exits."
        return 1
    fi

    for i in $(seq 1 25); do
        log=$(journalctl -u "$BACKHAUL_SVC" --since "$ts" --no-pager -o cat 2>/dev/null)
        if grep -qi "channel established" <<< "$log"; then
            res ok "Control channel established with $TUN_IR_IP:$BH_PORT"
            return 0
        fi
        sleep 1
    done
    errs=$(grep -c "\[ERROR\]" <<< "$log")
    if (( errs > 0 )); then
        res bad "Control channel NOT established. Last messages:"
        tail -n 6 <<< "$log" | sed 's/^/        /'
        if grep -qi "refused" <<< "$log"; then
            echo "    -> 'connection refused': the Iran Backhaul server is not running/listening on $TUN_IR_IP:$BH_PORT."
        elif grep -q "EOF" <<< "$log"; then
            echo "    -> 'EOF': TCP connects but the other end hangs up at once. Most common causes:"
            echo "       a) another program owns port $BH_PORT on the Iran server (Diagnose on Iran shows it)"
            echo "       b) token or transport differ between the two servers"
            echo "       c) the two servers run different Backhaul binaries (compare sha256, menu option 7)"
        elif grep -qi "timeout" <<< "$log"; then
            echo "    -> timeouts: packets get lost inside the tunnel (MTU / GRE filtering). Run Diagnose."
        fi
        return 1
    fi
    res warn "No result yet - check again with menu option 3 / 4 in a few seconds."
    return 0
}

# ------------------------------------------------------------------------------
# status / diagnose
# ------------------------------------------------------------------------------
client_state() { # up | down | unknown (based on recent client log lines)
    local log last_ok last_err
    log=$(journalctl -u "$BACKHAUL_SVC" -n 200 --no-pager -o cat 2>/dev/null)
    last_ok=$(grep -n -i "channel established" <<< "$log" | tail -n1 | cut -d: -f1)
    last_err=$(grep -n "\[ERROR\]" <<< "$log" | tail -n1 | cut -d: -f1)
    if [[ -n $last_ok ]] && { [[ -z $last_err ]] || (( last_ok > last_err )); }; then
        echo up
    elif [[ -n $last_err ]]; then
        echo down
    else
        echo unknown
    fi
}

show_status() {
    load_conf || { err "Not configured yet - run option 1 or 2 first."; return 1; }
    echo -e "\n${CYAN}================ TUNNEL STATUS ($ROLE) ================${NC}"
    echo "  Public IPs : local $LOCAL_IP  <->  peer $REMOTE_IP"
    echo "  Tunnel IPs : $SELF_IP  <->  $PEER_IP     control: $TUN_IR_IP:$BH_PORT ($BH_TRANS)"
    [[ $ROLE == iran ]] && echo "  Forwarded  : ${PORTS:-none}   (UDP: $([[ ${ACCEPT_UDP:-0} == 1 ]] && echo yes || echo no))"

    echo
    if ip link show "$IFACE" >/dev/null 2>&1 && ip -4 addr show dev "$IFACE" | grep -q "inet $SELF_IP/"; then
        echo -e "  ${GREEN}[*] $IFACE: UP ($SELF_IP, mtu $(cat /sys/class/net/$IFACE/mtu 2>/dev/null))${NC}"
        if ping -c 2 -W 2 "$PEER_IP" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[*] ping $PEER_IP: SUCCESS${NC}"
        else
            echo -e "  ${RED}[x] ping $PEER_IP: FAILED${NC}"
        fi
    else
        echo -e "  ${RED}[x] $IFACE: DOWN / no $SELF_IP${NC}"
    fi

    local s
    for s in "$GRETAP_SVC" "$BACKHAUL_SVC"; do
        if systemctl is-active -q "$s"; then
            echo -e "  ${GREEN}[*] $s: active${NC}"
        else
            echo -e "  ${RED}[x] $s: $(systemctl is-active "$s")${NC}"
        fi
    done

    if [[ $ROLE == iran ]]; then
        echo -e "\n${CYAN}[*] Listeners (control port + forwarded ports):${NC}"
        ss -H -ltunp 2>/dev/null | grep backhaul-gretap | awk '{print "    " $1 "  " $5}' || true
    else
        echo -e "\n  Tunnel state (from client log): $(client_state)"
    fi

    echo -e "\n${CYAN}[*] Recent Backhaul log:${NC}"
    journalctl -u "$BACKHAUL_SVC" -n 10 --no-pager -o cat 2>/dev/null | sed 's/^/    /'

    echo -e "\n${CYAN}[*] Firewall rules owned by this tunnel (tag BHGT):${NC}"
    local t
    for t in filter nat mangle; do
        iptables -t "$t" -S 2>/dev/null | grep -- "--comment" | grep BHGT | sed "s/-m comment --comment \"\\?BHGT\"\\? //; s/^/    [$t] /"
    done
    echo -e "${CYAN}===============================================${NC}\n"
}

diagnose() {
    load_conf || { err "Not configured yet - run option 1 or 2 first."; return 1; }
    echo -e "\n${CYAN}================ DIAGNOSE ($ROLE) ================${NC}"

    echo -e "\n${CYAN}1) Binary${NC}"
    if [[ -x $BACKHAUL_BIN ]] && is_elf "$BACKHAUL_BIN"; then
        res ok "$BACKHAUL_BIN  [$(bin_version | cut -c1-50)]  sha256=$(sha256sum "$BACKHAUL_BIN" | cut -c1-16)..."
        echo "      (compare this sha256 with the other server - they must be identical)"
    else
        res bad "Backhaul binary missing/invalid: $BACKHAUL_BIN  -> menu option 7"
    fi

    echo -e "\n${CYAN}2) Services${NC}"
    if systemctl is-active -q "$GRETAP_SVC"; then res ok "$GRETAP_SVC active"; else res bad "$GRETAP_SVC is $(systemctl is-active "$GRETAP_SVC")"; fi
    if systemctl is-active -q "$BACKHAUL_SVC"; then
        res ok "$BACKHAUL_SVC active (restarts so far: $(systemctl show -p NRestarts --value "$BACKHAUL_SVC" 2>/dev/null || echo '?'))"
    else
        res bad "$BACKHAUL_SVC is $(systemctl is-active "$BACKHAUL_SVC") (crash loop? see the log below)"
    fi

    echo -e "\n${CYAN}3) GRETAP link${NC}"
    if ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q "inet $SELF_IP/"; then
        res ok "$IFACE has $SELF_IP (mtu $(cat /sys/class/net/$IFACE/mtu 2>/dev/null))"
        if ping -c 2 -W 2 "$PEER_IP" >/dev/null 2>&1; then
            res ok "ping $PEER_IP works"
            local sz best=0
            for sz in 1372 1340 1300 1240 1200 1100 1000; do
                if ping -M do -c 1 -W 2 -s "$sz" "$PEER_IP" >/dev/null 2>&1; then best=$sz; break; fi
            done
            if (( best == 1372 )); then
                res ok "full-size packets (mtu 1400) pass without fragmentation"
            elif (( best > 0 )); then
                res warn "largest unfragmented ping payload is $best (< 1372): the real path MTU is below 1400 -> lower MTU_VAL/MSS_VAL"
            else
                res bad "even 1000-byte DF pings are lost: MTU black hole or GRE filtering for larger packets"
            fi
        else
            res bad "ping $PEER_IP fails: GRE between $LOCAL_IP and $REMOTE_IP is blocked, or the peer is not configured/running"
        fi
    else
        res bad "$IFACE missing or has no $SELF_IP"
    fi

    local m pub owners
    if [[ $ROLE == iran ]]; then
        echo -e "\n${CYAN}4) Control port $BH_PORT on this server${NC}"
        owners=$(ss -H -ltnp "sport = :$BH_PORT" 2>/dev/null)
        if [[ -z $owners ]]; then
            res bad "NOTHING listens on port $BH_PORT -> the Kharej client gets 'connection refused'"
        elif grep -q backhaul-gretap <<< "$owners"; then
            res ok "backhaul-gretap listens: $(awk '{print $4}' <<< "$owners" | head -n1)"
        else
            res bad "Port $BH_PORT is owned by ANOTHER program (the Kharej client talks to it and gets 'EOF'):"
            echo "$owners" | sed 's/^/        /'
            echo "      -> stop that program or run setup again with a different control port."
        fi

        echo -e "\n${CYAN}5) Forwarded ports${NC}"
        for m in $PORTS; do
            pub=${m%%=*}
            if iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "--dport $pub .*BHGT"; then
                res ok "DNAT rule for port $pub present"
            else
                res bad "DNAT rule for port $pub missing (menu 6 to reload)"
            fi
            if ss -H -ltnp "sport = :$pub" 2>/dev/null | grep -q backhaul-gretap; then
                res ok "Backhaul listens on port $pub"
            elif ss -H -ltn "sport = :$pub" 2>/dev/null | grep -q .; then
                res bad "port $pub is held by another program: $(ss -H -ltnp "sport = :$pub" | awk '{print $6}' | head -n1)"
            else
                res warn "nothing listens on $pub yet (normal until the Kharej client has connected)"
            fi
        done
    else
        echo -e "\n${CYAN}4) Reaching the Iran control port${NC}"
        local state rc
        state=$(client_state)
        if [[ $state == up ]]; then
            res ok "Tunnel is established (client log); skipping the raw TCP probe so it cannot disturb live traffic"
        else
            timeout 3 bash -c "exec 3<>/dev/tcp/$PEER_IP/$BH_PORT" 2>/dev/null
            rc=$?
            case $rc in
                0)   res warn "TCP connect to $PEER_IP:$BH_PORT works but no tunnel is established -> the program there hangs up (port owner / token / transport / binary mismatch). Run Diagnose on the IRAN server." ;;
                124) res bad "TCP connect to $PEER_IP:$BH_PORT TIMED OUT (packets dropped inside the tunnel: MTU/firewall)" ;;
                *)   res bad "TCP connect to $PEER_IP:$BH_PORT REFUSED: nothing listens there (Iran Backhaul not running / different port)" ;;
            esac
        fi
        echo
        if ask_yn "Test local target ports on this Kharej server? (e.g. is your SOCKS/Xray listening)" n; then
            local raw
            ask raw "Target ports, comma separated" ""
            if parse_ports "$raw"; then
                for m in "${PORT_MAP[@]}"; do
                    pub=${m#*=}
                    if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$pub" 2>/dev/null; then
                        res ok "127.0.0.1:$pub accepts connections"
                    else
                        res bad "127.0.0.1:$pub refuses connections: forwarded traffic to it will fail"
                    fi
                done
            fi
        fi
    fi

    echo -e "\n${CYAN}Other NAT rules that could hijack traffic${NC}"
    local foreign
    foreign=$(iptables -t nat -S 2>/dev/null | grep -E -- "-j (DNAT|REDIRECT)" | grep -v BHGT | head -n 8)
    if [[ -n $foreign ]]; then
        res warn "foreign DNAT/REDIRECT rules exist (tunnel traffic is exempted, but check them):"
        echo "$foreign" | sed 's/^/        /'
    else
        res ok "none"
    fi

    echo -e "\n${CYAN}Recent Backhaul log${NC}"
    journalctl -u "$BACKHAUL_SVC" -n 12 --no-pager -o cat 2>/dev/null | sed 's/^/    /'

    echo -e "\n${CYAN}How to read 'failed to read message length ... EOF' on the Kharej client${NC}"
    echo "    The TCP connection worked, then the other end closed it immediately. The Backhaul server only does that"
    echo "    for a wrong token / signal. If tokens match, the thing answering is not your Backhaul server (port owner,"
    echo "    see Iran step 4) or runs a different Backhaul build (compare sha256 in step 1 on both servers)."
    echo -e "${CYAN}================================================${NC}\n"
}

# ------------------------------------------------------------------------------
# other menu actions
# ------------------------------------------------------------------------------
update_ports() {
    load_conf || { err "Not configured yet."; return 1; }
    if [[ $ROLE != iran ]]; then
        err "Forwarded ports are configured on the IRAN server only."
        return 1
    fi
    info "Current forwarded ports: ${PORTS:-none}"
    prompt_ports
    PORTS="${PORT_MAP[*]}"
    save_conf
    write_toml
    "$CTL_SH" reload
    systemctl restart "$BACKHAUL_SVC"
    ok "Forwarded ports updated: $PORTS"
}

restart_services() {
    load_conf || { err "Not configured yet."; return 1; }
    systemctl restart "$GRETAP_SVC" "$BACKHAUL_SVC"
    ok "GRETAP and Backhaul restarted."
}

binary_menu() {
    echo
    info "Current Backhaul binary:"
    show_bin_info
    echo
    if ask_yn "Download/replace the binary now?" n; then
        install_backhaul_core 1 || return 1
        if load_conf && [[ -f $TOML_FILE ]]; then
            systemctl restart "$BACKHAUL_SVC"
            ok "Backhaul restarted with the new binary. Do the same on the other server!"
        fi
    fi
}

uninstall_all() {
    echo
    warn "This removes the tunnel, services, firewall rules and config of THIS tunnel only."
    ask_yn "Really uninstall?" n || return 0
    systemctl stop "$BACKHAUL_SVC" "$GRETAP_SVC" >/dev/null 2>&1
    systemctl disable "$BACKHAUL_SVC" "$GRETAP_SVC" >/dev/null 2>&1
    pkill -f -- "$BACKHAUL_BIN -c $TOML_FILE" 2>/dev/null
    [[ -x $CTL_SH ]] && "$CTL_SH" down
    rm -f "$UNIT_DIR/$BACKHAUL_SVC" "$UNIT_DIR/$GRETAP_SVC"
    systemctl daemon-reload
    ip link del "$IFACE" 2>/dev/null
    rm -rf "$CONFIG_DIR"
    rm -f "$BACKHAUL_BIN"
    ok "Tunnel, services and firewall rules removed (the shared $LEGACY_BIN, if any, was not touched)."
}

main_menu() {
    local choice
    while true; do
        clear
        echo -e "${CYAN}========================================================${NC}"
        echo -e "${GREEN}   GRETAP + Backhaul Reverse Tunnel Manager v$VERSION          ${NC}"
        echo -e "${CYAN}   Iran: $TUN_IR_IP/30  <--->  Kharej: $TUN_KH_IP/30     ${NC}"
        echo -e "${CYAN}========================================================${NC}"
        echo -e " 1) Configure ${GREEN}IRAN Server${NC}   (GRETAP + Backhaul server + port forward)"
        echo -e " 2) Configure ${YELLOW}KHAREJ Client${NC} (GRETAP + Backhaul client)"
        echo -e " 3) Status & logs"
        echo -e " 4) Diagnose connection  ${CYAN}(use this when something fails)${NC}"
        echo -e " 5) Update forwarded ports (Iran server)"
        echo -e " 6) Restart tunnel services"
        echo -e " 7) Check / reinstall Backhaul binary (version + sha256)"
        echo -e " 8) Follow live Backhaul log (Ctrl+C to stop)"
        echo -e " 9) ${RED}Uninstall tunnel completely${NC}"
        echo -e " 0) Exit"
        echo -e "${CYAN}========================================================${NC}"
        read -r -p "Select an option [0-9]: " choice || exit 0
        case $choice in
            1) setup_tunnel iran;   pause ;;
            2) setup_tunnel kharej; pause ;;
            3) show_status;         pause ;;
            4) diagnose;            pause ;;
            5) update_ports;        pause ;;
            6) restart_services;    pause ;;
            7) binary_menu;         pause ;;
            8) journalctl -u "$BACKHAUL_SVC" -f -o cat ;;
            9) uninstall_all;       pause ;;
            0) exit 0 ;;
            *) err "Invalid option!"; sleep 1 ;;
        esac
    done
}

main_menu
