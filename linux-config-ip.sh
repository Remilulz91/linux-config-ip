#!/usr/bin/env bash
# =============================================================================
#  linux-config-ip — Configure the IPv4 address of a Linux machine (static or DHCP),
#  whatever network manager the machine uses:
#    - NetworkManager   (nmtui / nmcli)           -> desktop installs
#    - ifupdown         (/etc/network/interfaces) -> server installs
#    - systemd-networkd (/etc/systemd/network)    -> cloud / minimal images
#
#  Supported distributions: Debian 11, 12 and 13.
#  (Ubuntu and other distributions: coming soon)
#  License: MIT
# =============================================================================

set -uo pipefail

VERSION="1.2.0"
PROG="linux-config-ip"
# Former project names (to recognise their markers)
OLD_PROGS="debian-config-ip debian-ip-statique"
BACKUP_ROOT="/var/backups/${PROG}"
LOG_FILE="/var/log/${PROG}.log"
NETWORKD_FILE_PREFIX="05-${PROG}"

DRY_RUN=0
ASSUME_YES=0
OPT_IF=""
OPT_ADDR=""
OPT_MASK=""
OPT_GW=""
OPT_GW_SET=0
OPT_DNS=""
OPT_BACKEND=""
OPT_MODE=""        # static | dhcp

# --------------------------------------------------------------------------- #
#  Output
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
    C_RST=$'\e[0m'; C_B=$'\e[1m'; C_R=$'\e[31m'; C_G=$'\e[32m'
    C_Y=$'\e[33m'; C_C=$'\e[36m'
else
    C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

info() { printf '%s[i]%s %s\n' "$C_C" "$C_RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_RST" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_R" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
${PROG} ${VERSION} — Static IP or DHCP on Linux, the easy way

Usage: sudo ./${PROG}.sh [options]

Without options, the script asks the questions one by one.

Options:
  -i, --interface IF     Interface to configure (e.g. ens18)
  -s, --static           Static IP mode (implied by --address)
  -D, --dhcp             Switch the interface back to DHCP
  -a, --address IP[/CIDR]
                         IP address, with or without mask (e.g. 192.168.10.1/24)
  -m, --mask MASK        Mask if not given in --address (255.255.255.0 or 24)
  -g, --gateway IP       Gateway ("none" = no gateway)
  -d, --dns "IP IP"      DNS servers separated by spaces or commas
  -b, --backend NAME     Force: networkmanager | ifupdown | networkd
  -y, --yes              Do not ask for confirmation
  -n, --dry-run          Show what would be done without changing anything
  -h, --help             Show this help
  -V, --version          Show the version

Examples:
  sudo ./${PROG}.sh
  sudo ./${PROG}.sh -i ens18 -a 192.168.10.1/24 -g 192.168.10.254 -d "1.1.1.1 9.9.9.9" -y
  sudo ./${PROG}.sh -i ens18 --dhcp -y
EOF
}

# Read from the terminal (also works with "curl ... | sudo bash")
ask() {
    local prompt=$1 default=${2-} answer
    if [[ -n $default ]]; then
        prompt="${prompt} [${default}]"
    fi
    if ! read -r -p "${C_B}${prompt}: ${C_RST}" answer </dev/tty; then
        echo; die "Cannot read input (no terminal). Use the options, see --help."
    fi
    answer=${answer#"${answer%%[![:space:]]*}"}
    answer=${answer%"${answer##*[![:space:]]}"}
    printf '%s' "${answer:-$default}"
}

confirm() {
    local a
    (( ASSUME_YES )) && return 0
    a=$(ask "$1 (Y/n)" "Y")
    [[ ${a,,} =~ ^(y|yes|o|oui)$ ]]
}

# --------------------------------------------------------------------------- #
#  IPv4 maths
# --------------------------------------------------------------------------- #
valid_ip() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ $o =~ ^(0|[1-9][0-9]*)$ ]] || return 1   # no leading zero
        (( o <= 255 )) || return 1
    done
}

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int_to_ip() {
    local n=$1
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

prefix_to_int() {
    local p=$1
    (( p == 0 )) && { echo 0; return; }
    echo $(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
}

# Accepts "24", "/24" or "255.255.255.0"; prints the prefix (1-32)
mask_to_prefix() {
    local m=${1#/} n inv p=0
    if [[ $m =~ ^[0-9]{1,2}$ ]]; then
        m=$((10#$m))
        (( m >= 1 && m <= 32 )) || return 1
        echo "$m"; return 0
    fi
    valid_ip "$m" || return 1
    n=$(ip_to_int "$m")
    inv=$(( (~n) & 0xFFFFFFFF ))
    (( (inv & (inv + 1)) == 0 )) || return 1      # non-contiguous mask
    while (( n & 0x80000000 )); do
        p=$((p + 1))
        n=$(( (n << 1) & 0xFFFFFFFF ))
    done
    (( p >= 1 )) || return 1
    echo "$p"
}

# Checks that an IP can be used as a host address in its network
check_host_ip() {
    local ip=$1 p=$2 i m net bc
    (( p >= 31 )) && return 0
    i=$(ip_to_int "$ip"); m=$(prefix_to_int "$p")
    net=$(( i & m )); bc=$(( net | (~m & 0xFFFFFFFF) ))
    if (( i == net )); then
        err "$ip is the network address of $(int_to_ip "$net")/$p, not a host address."
        return 1
    fi
    if (( i == bc )); then
        err "$ip is the broadcast address of $(int_to_ip "$net")/$p."
        return 1
    fi
}

same_subnet() {
    local m
    m=$(prefix_to_int "$3")
    (( ($(ip_to_int "$1") & m) == ($(ip_to_int "$2") & m) ))
}

# --------------------------------------------------------------------------- #
#  System detection
# --------------------------------------------------------------------------- #
os_version() {
    local name="unknown" ver=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        name=$(. /etc/os-release; echo "${PRETTY_NAME:-$NAME}")
    fi
    [[ -r /etc/debian_version ]] && ver=$(< /etc/debian_version)
    echo "${name}${ver:+ (debian_version ${ver})}"
}

is_debian_like() {
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    ( . /etc/os-release; [[ ${ID:-} == debian || " ${ID_LIKE:-} " == *" debian "* ]] )
}

list_ifaces() {
    local p n
    for p in /sys/class/net/*; do
        n=${p##*/}
        case $n in
            lo|docker*|veth*|virbr*|br-*|vnet*|tun*|tap*|wg*|bonding_masters) continue ;;
        esac
        echo "$n"
    done
}

default_iface() {
    ip -4 route show default 2>/dev/null |
        awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

default_gw() {
    ip -4 route show default dev "$1" 2>/dev/null |
        awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}'
}

current_addr() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'
}

current_dns() {
    local d=""
    if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        d=$(resolvectl dns 2>/dev/null | awk -F: '{print $2}' | tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -u | xargs)
    fi
    if [[ -z $d && -r /etc/resolv.conf ]]; then
        d=$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ && $2 !~ /^127\./ {print $2}' /etc/resolv.conf | xargs)
    fi
    echo "$d"
}

# Lists ifupdown files (main + interfaces.d)
ifupdown_files() {
    [[ -f /etc/network/interfaces ]] && echo /etc/network/interfaces
    local f
    for f in /etc/network/interfaces.d/*; do
        [[ -f $f ]] && echo "$f"
    done
}

iface_in_ifupdown() {
    local ifc=$1 f
    while IFS= read -r f; do
        awk -v d="$ifc" '
            $1 == "iface" && $2 == d { found = 1 }
            ($1 == "auto" || $1 ~ /^allow-/) { for (i = 2; i <= NF; i++) if ($i == d) found = 1 }
            END { exit !found }' "$f" && return 0
    done < <(ifupdown_files)
    return 1
}

nm_active() {
    command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null
}

networkd_active() {
    systemctl is-active --quiet systemd-networkd 2>/dev/null
}

resolved_active() {
    systemctl is-active --quiet systemd-resolved 2>/dev/null
}

# Picks the manager that ACTUALLY controls this interface
detect_backend() {
    local ifc=$1 st
    # 1. NetworkManager manages the interface (desktop installs)
    if nm_active; then
        st=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$ifc" '$1 == d {print $2; exit}')
        if [[ -n $st && $st != unmanaged* ]]; then
            echo networkmanager; return
        fi
    fi
    # 2. The interface is declared in /etc/network/interfaces
    #    (in that case Debian tells NetworkManager to ignore it)
    if iface_in_ifupdown "$ifc"; then
        echo ifupdown; return
    fi
    # 3. systemd-networkd manages the interface (cloud images, minimal installs)
    if networkd_active && command -v networkctl >/dev/null 2>&1; then
        st=$(networkctl list --no-legend 2>/dev/null | awk -v d="$ifc" '$2 == d {print $5; exit}')
        if [[ -n $st && $st != unmanaged ]]; then
            echo networkd; return
        fi
    fi
    # 4. Nothing manages the interface: use the first available tool
    if nm_active; then echo networkmanager; return; fi
    if command -v ifup >/dev/null 2>&1; then echo ifupdown; return; fi
    if networkd_active; then echo networkd; return; fi
    echo none
}

backend_label() {
    case $1 in
        networkmanager) echo "NetworkManager (nmtui / nmcli)" ;;
        ifupdown)       echo "ifupdown (/etc/network/interfaces)" ;;
        networkd)       echo "systemd-networkd (/etc/systemd/network)" ;;
        *)              echo "$1" ;;
    esac
}

# --------------------------------------------------------------------------- #
#  Write helpers (honour --dry-run)
# --------------------------------------------------------------------------- #
BACKUP_DIR=""

run() {
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "$C_Y" "$C_RST" "$*"
        return 0
    fi
    "$@"
}

backup() {
    local f
    for f in "$@"; do
        [[ -e $f || -L $f ]] || continue
        if (( DRY_RUN )); then
            printf '%s[dry-run]%s backup of %s\n' "$C_Y" "$C_RST" "$f"
            continue
        fi
        mkdir -p "${BACKUP_DIR}$(dirname "$f")"
        cp -a "$f" "${BACKUP_DIR}${f}"
    done
}

restore_backup() {
    [[ -n $BACKUP_DIR && -d $BACKUP_DIR ]] || return 0
    warn "Restoring previous configuration from $BACKUP_DIR"
    (cd "$BACKUP_DIR" && find . -type f -o -type l) | while IFS= read -r rel; do
        cp -a "${BACKUP_DIR}/${rel#./}" "/${rel#./}"
    done
}

# write_file PATH MODE  (content read from stdin)
write_file() {
    local path=$1 mode=${2:-644} content
    content=$(cat)
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s content of %s:\n' "$C_Y" "$C_RST" "$path"
        printf '%s\n' "$content" | sed 's/^/    | /'
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    local tmp
    tmp=$(mktemp "${path}.XXXXXX") || return 1
    printf '%s\n' "$content" >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path"
}

# --------------------------------------------------------------------------- #
#  DNS (outside NetworkManager / networkd+resolved)
# --------------------------------------------------------------------------- #
# DHCP: remove DNS servers forced by this script, the DHCP client takes over
reset_dns_generic() {
    local f="/etc/systemd/resolved.conf.d/${PROG}.conf" o
    for o in $OLD_PROGS; do
        [[ -f /etc/systemd/resolved.conf.d/${o}.conf ]] && f="$f /etc/systemd/resolved.conf.d/${o}.conf"
    done
    for f in $f; do
        [[ -f $f ]] || continue
        backup "$f"
        run rm -f "$f"
        resolved_active && run systemctl restart systemd-resolved
    done
    return 0
}

apply_dns_generic() {
    local ifc=$1; shift
    local dns=("$@")
    (( ${#dns[@]} )) || return 0

    if resolved_active; then
        backup "/etc/systemd/resolved.conf.d/${PROG}.conf"
        write_file "/etc/systemd/resolved.conf.d/${PROG}.conf" <<EOF
# Generated by ${PROG} on $(date '+%F %T')
[Resolve]
DNS=${dns[*]}
EOF
        run systemctl restart systemd-resolved
        return
    fi

    if command -v resolvconf >/dev/null 2>&1 && [[ -L /etc/resolv.conf ]]; then
        # The resolvconf package reads "dns-nameservers" from /etc/network/interfaces
        return 0
    fi

    local keep=""
    if [[ -r /etc/resolv.conf ]]; then
        keep=$(grep -E '^[[:space:]]*(search|domain|options)[[:space:]]' /etc/resolv.conf || true)
    fi
    backup /etc/resolv.conf
    if [[ -L /etc/resolv.conf ]]; then
        run rm -f /etc/resolv.conf
    fi
    {
        echo "# Generated by ${PROG} on $(date '+%F %T')"
        [[ -n $keep ]] && echo "$keep"
        local d
        for d in "${dns[@]}"; do echo "nameserver $d"; done
    } | write_file /etc/resolv.conf 644 || warn "Could not write /etc/resolv.conf."
}

# --------------------------------------------------------------------------- #
#  Backend : NetworkManager
# --------------------------------------------------------------------------- #
apply_networkmanager() {
    local ifc=$1 addr=$2 gw=$3; shift 3
    local dns=("$@") uuid type
    uuid=$(nmcli -g GENERAL.CON-UUID device show "$ifc" 2>/dev/null | head -n1)
    type=$(nmcli -g GENERAL.TYPE device show "$ifc" 2>/dev/null | head -n1)

    backup /etc/NetworkManager/system-connections

    if [[ -z $uuid ]]; then
        # Look for an existing profile bound to this interface
        uuid=$(nmcli -t -f UUID,DEVICE connection show 2>/dev/null | awk -F: -v d="$ifc" '$2 == d {print $1; exit}')
    fi
    if [[ -z $uuid ]]; then
        [[ $type == ethernet || -z $type ]] ||
            die "No NetworkManager profile for $ifc (type $type). Connect once with nmtui first."
        info "Creating NetworkManager profile \"$ifc\""
        if (( DRY_RUN )); then
            run nmcli connection add type ethernet ifname "$ifc" con-name "$ifc"
            uuid="<nouveau-profil>"
        else
            nmcli connection add type ethernet ifname "$ifc" con-name "$ifc" >/dev/null ||
                die "Could not create the NetworkManager profile."
            uuid=$(nmcli -g connection.uuid connection show "$ifc" | head -n1)
        fi
    fi

    local name
    name=$(nmcli -g connection.id connection show "$uuid" 2>/dev/null | head -n1)
    info "NetworkManager profile updated: ${name:-$uuid}"

    # Remember the old config so we can roll back
    local old_method old_addr old_gw old_dns old_ign
    old_method=$(nmcli -g ipv4.method connection show "$uuid" 2>/dev/null)
    old_addr=$(nmcli -g ipv4.addresses connection show "$uuid" 2>/dev/null | sed 's/\\//g')
    old_gw=$(nmcli -g ipv4.gateway connection show "$uuid" 2>/dev/null)
    old_dns=$(nmcli -g ipv4.dns connection show "$uuid" 2>/dev/null | sed 's/\\//g')
    old_ign=$(nmcli -g ipv4.ignore-auto-dns connection show "$uuid" 2>/dev/null)

    local dns_csv
    dns_csv=$(IFS=,; echo "${dns[*]:-}")

    if [[ -z $addr ]]; then
        run nmcli connection modify "$uuid" \
            ipv4.method auto \
            ipv4.addresses "" \
            ipv4.gateway "" \
            ipv4.dns "" \
            ipv4.ignore-auto-dns no \
            connection.autoconnect yes ||
            die "nmcli rejected the configuration."
    else
        run nmcli connection modify "$uuid" \
            ipv4.method manual \
            ipv4.addresses "$addr" \
            ipv4.gateway "$gw" \
            ipv4.dns "$dns_csv" \
            ipv4.ignore-auto-dns yes \
            connection.autoconnect yes ||
            die "nmcli rejected the configuration."
    fi

    if ! run nmcli connection up "$uuid"; then
        err "Activation failed, rolling back to the previous configuration."
        nmcli connection modify "$uuid" \
            ipv4.method "${old_method:-auto}" ipv4.addresses "$old_addr" \
            ipv4.gateway "$old_gw" ipv4.dns "$old_dns" \
            ipv4.ignore-auto-dns "${old_ign:-no}" 2>/dev/null
        nmcli connection up "$uuid" >/dev/null 2>&1
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
#  Backend : ifupdown (/etc/network/interfaces)
# --------------------------------------------------------------------------- #
# Rewrites an ifupdown file:
#  - removes the interface's IPv4 stanza and its auto/allow-* entries
#  - keeps IPv6, comments and other interfaces
#  - if NEW_BLOCK is set (environment variable), inserts it where the
#    old IPv4 stanza was
ifupdown_rewrite() {
    local ifc=$1 file=$2
    awk -v d="$ifc" -v progs="$PROG $OLD_PROGS" '
        function is_stanza(k) {
            return k == "iface" || k == "auto" || k == "mapping" || k == "source" ||
                   k == "source-directory" || k == "rename" || k ~ /^allow-/
        }
        function out(line) {
            if (line ~ /^[[:space:]]*$/) { if (blank) return; blank = 1 } else blank = 0
            print line
        }
        function is_marker(line,   n, i, P) {
            n = split(progs, P, " ")
            for (i = 1; i <= n; i++)
                if (index(line, "# " d " : configured by " P[i]) == 1 ||
                    index(line, "# " d " : configuré par " P[i]) == 1) return 1
            return 0
        }
        BEGIN { block = ENVIRON["NEW_BLOCK"] }
        is_marker($0) { next }
        {
            if (skip) {
                if (is_stanza($1)) {
                    skip = 0
                    np = split(pend, L, "\n")
                    for (i = 1; i < np; i++) out(L[i])
                    pend = ""
                } else if ($0 ~ /^[[:space:]]*(#|$)/) {
                    pend = pend $0 "\n"; next      # may belong to the next stanza
                } else {
                    pend = ""; next                # option of the old stanza
                }
            }
            if ($1 == "iface" && $2 == d && $3 == "inet") {
                skip = 1; pend = ""
                if (block != "" && !done) {
                    nb = split(block, B, "\n")
                    for (i = 1; i <= nb; i++) if (B[i] != "") out(B[i])
                    done = 1
                }
                next
            }
            if ($1 == "auto" || $1 ~ /^allow-/) {
                line = $1; n = 0
                for (i = 2; i <= NF; i++) if ($i != d) { line = line " " $i; n++ }
                if (n) out(line)
                next
            }
            out($0)
        }
        END {
            if (skip) { np = split(pend, L, "\n"); for (i = 1; i < np; i++) out(L[i]) }
            if (block != "" && !done && append) {
                if (!blank) print ""
                nb = split(block, B, "\n")
                for (i = 1; i <= nb; i++) if (B[i] != "") print B[i]
            }
        }' append="${APPEND_BLOCK:-0}" "$file"
}

# First file declaring "iface IF inet"
ifupdown_owner() {
    local ifc=$1 f
    while IFS= read -r f; do
        if awk -v d="$ifc" '$1 == "iface" && $2 == d && $3 == "inet" { found = 1 } END { exit !found }' "$f"; then
            echo "$f"; return 0
        fi
    done < <(ifupdown_files)
    return 1
}

apply_ifupdown() {
    local ifc=$1 addr=$2 gw=$3; shift 3
    local dns=("$@") f
    command -v ifup >/dev/null 2>&1 || die "ifupdown is not installed (apt install ifupdown)."

    local main=/etc/network/interfaces
    if [[ ! -f $main ]]; then
        printf 'source /etc/network/interfaces.d/*\n\nauto lo\niface lo inet loopback\n' | write_file "$main" 644
    fi

    local files=() owner
    while IFS= read -r f; do files+=("$f"); done < <(ifupdown_files)
    owner=$(ifupdown_owner "$ifc") || owner=$main
    backup "${files[@]}"

    # New stanza
    local block
    block="# $ifc : configured by ${PROG} on $(date '+%F %T')"$'\n'"auto $ifc"$'\n'
    if [[ -z $addr ]]; then
        block+="iface $ifc inet dhcp"
    else
        block+="iface $ifc inet static"$'\n'"    address $addr"
        [[ -n $gw ]] && block+=$'\n'"    gateway $gw"
        (( ${#dns[@]} )) && block+=$'\n'"    dns-nameservers ${dns[*]}"
    fi

    # Release the old configuration (DHCP lease, etc.) before rewriting
    if (( ! DRY_RUN )); then
        ifdown --force "$ifc" >/dev/null 2>&1 || true
    else
        run ifdown --force "$ifc"
    fi

    local content
    for f in "${files[@]}"; do
        if [[ $f == "$owner" ]]; then
            content=$(NEW_BLOCK=$block APPEND_BLOCK=1 ifupdown_rewrite "$ifc" "$f")
        else
            content=$(NEW_BLOCK="" ifupdown_rewrite "$ifc" "$f")
        fi
        # Only rewrite if the file actually changes
        if [[ "$content" != "$(cat "$f")" ]]; then
            printf '%s\n' "$content" | write_file "$f" 644
        fi
    done

    if [[ -z $addr ]]; then
        reset_dns_generic
    else
        apply_dns_generic "$ifc" "${dns[@]}"
        # Stop any DHCP client still running on the interface
        if (( ! DRY_RUN )); then
            command -v dhcpcd >/dev/null 2>&1 && dhcpcd -k "$ifc" >/dev/null 2>&1
            local pid arg
            for pid in $(pgrep -x dhclient 2>/dev/null); do
                while IFS= read -r -d '' arg; do
                    if [[ $arg == "$ifc" ]]; then kill "$pid" 2>/dev/null; break; fi
                done < "/proc/$pid/cmdline"
            done
        fi
    fi
    run ip -4 addr flush dev "$ifc"
    if ! run ifup "$ifc"; then
        err "ifup failed."
        if (( ! DRY_RUN )); then
            ifdown --force "$ifc" >/dev/null 2>&1
            restore_backup
            ip -4 addr flush dev "$ifc"
            ifup "$ifc" >/dev/null 2>&1
        fi
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
#  Backend : systemd-networkd
# --------------------------------------------------------------------------- #
apply_networkd() {
    local ifc=$1 addr=$2 gw=$3; shift 3
    local dns=("$@") f target="/etc/systemd/network/${NETWORKD_FILE_PREFIX}-${ifc}.network"

    # Disable other /etc files targeting this interface
    local others=()
    for f in /etc/systemd/network/*.network; do
        [[ -f $f && $f != "$target" ]] || continue
        if grep -Eq "^[[:space:]]*Name=(.*[[:space:]])?${ifc}([[:space:]]|\$)" "$f"; then
            others+=("$f")
        fi
    done
    backup "$target" "${others[@]}"
    for f in "${others[@]}"; do
        info "Disabling $f"
        run mv -f "$f" "${f}.disabled-by-${PROG}"
    done

    {
        echo "# Generated by ${PROG} on $(date '+%F %T')"
        echo "[Match]"
        echo "Name=$ifc"
        echo
        echo "[Network]"
        if [[ -z $addr ]]; then
            echo "DHCP=ipv4"
        else
            echo "DHCP=no"
            echo "Address=$addr"
            [[ -n $gw ]] && echo "Gateway=$gw"
            (( ${#dns[@]} )) && echo "DNS=${dns[*]}"
        fi
    } | write_file "$target" 644

    if [[ -d /etc/netplan ]] && compgen -G "/etc/netplan/*.yaml" >/dev/null; then
        warn "Netplan is present: this file takes precedence, but consider cleaning up /etc/netplan."
    fi

    if [[ -z $addr ]]; then
        reset_dns_generic
    elif ! resolved_active; then
        apply_dns_generic "$ifc" "${dns[@]}"
    fi

    run ip -4 addr flush dev "$ifc"
    run networkctl reload
    if ! run networkctl reconfigure "$ifc"; then
        err "networkctl failed."
        if (( ! DRY_RUN )); then
            rm -f "$target"
            for f in "${others[@]}"; do mv -f "${f}.disabled-by-${PROG}" "$f"; done
            restore_backup
            networkctl reload; networkctl reconfigure "$ifc"
        fi
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
#  Main program
# --------------------------------------------------------------------------- #
parse_args() {
    while (( $# )); do
        case $1 in
            -i|--interface) OPT_IF=${2-}; shift ;;
            -a|--address)   OPT_ADDR=${2-}; shift ;;
            -s|--static)    OPT_MODE=static ;;
            -D|--dhcp)      OPT_MODE=dhcp ;;
            -m|--mask)      OPT_MASK=${2-}; shift ;;
            -g|--gateway)   OPT_GW=${2-}; OPT_GW_SET=1; shift ;;
            -d|--dns)       OPT_DNS=${2-}; shift ;;
            -b|--backend)   OPT_BACKEND=${2-}; shift ;;
            -y|--yes)       ASSUME_YES=1 ;;
            -n|--dry-run)   DRY_RUN=1 ;;
            -h|--help)      usage; exit 0 ;;
            -V|--version)   echo "$PROG $VERSION"; exit 0 ;;
            *) usage >&2; die "Option inconnue : $1" ;;
        esac
        shift
    done
}

choose_iface() {
    local ifaces=() def n i choice
    mapfile -t ifaces < <(list_ifaces)
    (( ${#ifaces[@]} )) || die "No network interface found."
    def=$(default_iface)
    [[ -z $def ]] && def=${ifaces[0]}

    if [[ -n $OPT_IF ]]; then
        [[ -d /sys/class/net/$OPT_IF ]] || die "Interface not found: $OPT_IF"
        echo "$OPT_IF"; return
    fi
    if (( ${#ifaces[@]} == 1 )); then
        echo "${ifaces[0]}"; return
    fi

    {
        echo
        echo "${C_B}Available interfaces:${C_RST}"
        n=1
        for i in "${ifaces[@]}"; do
            printf '  %d) %-12s %-18s %s\n' "$n" "$i" "$(current_addr "$i")" \
                "$([[ $i == "$def" ]] && echo '(default route)')"
            n=$((n + 1))
        done
    } >&2
    while :; do
        choice=$(ask "Interface to configure (number or name)" "$def")
        if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
            echo "${ifaces[choice - 1]}"; return
        fi
        [[ -d /sys/class/net/$choice ]] && { echo "$choice"; return; }
        err "Invalid choice: $choice"
    done
}

current_mode() {
    local ifc=$1
    if ip -4 -o addr show dev "$ifc" 2>/dev/null | grep -q ' dynamic '; then
        echo "DHCP"
    elif [[ -n $(current_addr "$ifc") ]]; then
        echo "static"
    else
        echo "no address"
    fi
}

choose_mode() {
    local cur=$1 choice
    if [[ -n $OPT_MODE ]]; then echo "$OPT_MODE"; return; fi
    if [[ -n $OPT_ADDR ]]; then echo static; return; fi
    {
        echo
        echo "${C_B}What do you want to do?${C_RST}  (current mode: $cur)"
        echo "  1) Static IP address"
        echo "  2) Automatic address (DHCP)"
    } >&2
    while :; do
        choice=$(ask "Choice" "1")
        case ${choice,,} in
            1|s|statique|static) echo static; return ;;
            2|d|dhcp|auto)       echo dhcp; return ;;
        esac
        err "Invalid choice: $choice"
    done
}

# Prints "IP PREFIX"
read_address() {
    local input ip mask p cur
    cur=$1
    while :; do
        if [[ -n $OPT_ADDR ]]; then
            input=$OPT_ADDR
        else
            echo >&2
            echo "Enter the address ${C_B}with its mask${C_RST} (e.g. 192.168.10.1/24)" >&2
            echo "or just the address (e.g. 192.168.10.1): the mask will be asked next." >&2
            input=$(ask "IP address" "$cur")
        fi
        input=${input// /}
        ip=${input%%/*}
        if ! valid_ip "$ip"; then
            err "Invalid IP address: $ip"
            [[ -n $OPT_ADDR ]] && exit 1
            continue
        fi
        if [[ $input == */* ]]; then
            mask=${input#*/}
        elif [[ -n $OPT_MASK ]]; then
            mask=$OPT_MASK
        else
            mask=$(ask "Mask (e.g. 255.255.255.0 or 24)" "255.255.255.0")
        fi
        if ! p=$(mask_to_prefix "$mask"); then
            err "Invalid mask: $mask"
            [[ -n $OPT_ADDR ]] && exit 1
            continue
        fi
        if ! check_host_ip "$ip" "$p"; then
            [[ -n $OPT_ADDR ]] && exit 1
            continue
        fi
        echo "$ip $p"; return
    done
}

read_gateway() {
    local ip=$1 p=$2 ifc=$3 def gw
    if (( OPT_GW_SET )); then
        gw=$OPT_GW
    else
        def=$(default_gw "$ifc")
        if [[ -z $def ]] || ! same_subnet "$def" "$ip" "$p"; then
            # Suggest the first address of the network (or the second if it is the chosen IP)
            local net
            net=$(( $(ip_to_int "$ip") & $(prefix_to_int "$p") ))
            def=$(int_to_ip $((net + 1)))
            [[ $def == "$ip" ]] && def=$(int_to_ip $((net + 2)))
            (( p >= 31 )) && def=""
        fi
        echo >&2
        gw=$(ask "Gateway (type \"none\" for no gateway)" "$def")
    fi
    case ${gw,,} in none|no|aucune|-) gw="" ;; esac
    while [[ -n $gw ]]; do
        if ! valid_ip "$gw"; then
            err "Invalid gateway: $gw"
        elif [[ $gw == "$ip" ]]; then
            err "The gateway cannot be the machine's own address."
        elif ! same_subnet "$gw" "$ip" "$p"; then
            err "Gateway $gw is not in the $ip/$p network."
        else
            break
        fi
        (( OPT_GW_SET )) && exit 1
        gw=$(ask "Gateway" "")
        case ${gw,,} in none|no|aucune|-) gw="" ;; esac
    done
    echo "$gw"
}

read_dns() {
    local def input d out=()
    if [[ -n $OPT_DNS ]]; then
        input=$OPT_DNS
    else
        def=$(current_dns)
        [[ -z $def ]] && def="1.1.1.1 9.9.9.9"
        echo >&2
        input=$(ask "DNS servers (space separated)" "$def")
    fi
    while :; do
        out=()
        local bad=0
        for d in ${input//,/ }; do
            if valid_ip "$d"; then out+=("$d"); else err "Invalid DNS: $d"; bad=1; fi
        done
        (( bad == 0 )) && break
        [[ -n $OPT_DNS ]] && exit 1
        input=$(ask "DNS servers" "1.1.1.1 9.9.9.9")
    done
    echo "${out[*]}"
}

verify_dhcp() {
    local ifc=$1 i a
    (( DRY_RUN )) && return 0
    echo
    info "Waiting for a DHCP address (30 s max)..."
    for (( i = 0; i < 30; i++ )); do
        a=$(current_addr "$ifc")
        [[ -n $a ]] && break
        sleep 1
    done
    ip -br -4 addr show dev "$ifc"
    ip -4 route show default 2>/dev/null | sed 's/^/    /'
    if [[ -n $a ]]; then
        ok "Address obtained via DHCP: $a"
    else
        err "No address received: check that a DHCP server is available on the network."
        return 1
    fi
}

verify() {
    local ifc=$1 ip=$2 gw=$3 dns1=$4 i
    (( DRY_RUN )) && return 0
    echo
    info "Checking..."
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ip -4 -o addr show dev "$ifc" | grep -q " ${ip}/" && break
        sleep 1
    done
    ip -br -4 addr show dev "$ifc"
    ip -4 route show default 2>/dev/null | sed 's/^/    /'
    if ip -4 -o addr show dev "$ifc" | grep -q " ${ip}/"; then
        ok "Address $ip is set on $ifc."
    else
        err "Address $ip does not appear on $ifc."
        return 1
    fi
    if [[ -n $gw ]]; then
        if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then
            ok "Gateway $gw is reachable."
        else
            warn "Gateway $gw does not answer ping (firewall or wrong address?)."
        fi
    fi
    if [[ -n $dns1 ]] && command -v getent >/dev/null 2>&1; then
        if timeout 5 getent hosts deb.debian.org >/dev/null 2>&1; then
            ok "DNS resolution works."
        else
            warn "DNS resolution does not answer (no Internet access?)."
        fi
    fi
}

main() {
    parse_args "$@"

    if (( EUID != 0 )) && (( ! DRY_RUN )); then
        die "This script must be run as root: sudo $0  (or \"su -\" then run it again)"
    fi
    command -v ip >/dev/null 2>&1 || die "The \"ip\" command (iproute2 package) was not found."

    echo "${C_B}=== ${PROG} ${VERSION} ===${C_RST}"
    info "System: $(os_version)"
    is_debian_like || warn "This distribution is not officially supported yet (only Debian is): results are not guaranteed."

    local ifc backend addr_pfx ip p gw dns_str dns=()
    ifc=$(choose_iface) || exit 1
    info "Interface: $ifc (current address: $(current_addr "$ifc" || true))"

    if [[ -n $OPT_BACKEND ]]; then
        case $OPT_BACKEND in
            networkmanager|nm) backend=networkmanager ;;
            ifupdown|interfaces) backend=ifupdown ;;
            networkd|systemd-networkd) backend=networkd ;;
            *) die "Unknown backend: $OPT_BACKEND" ;;
        esac
    else
        backend=$(detect_backend "$ifc")
    fi
    [[ $backend == none ]] && die "No network manager found (NetworkManager, ifupdown or systemd-networkd)."
    info "Detected manager: $(backend_label "$backend")"
    if [[ $backend == networkmanager ]] && ! nm_active; then
        die "NetworkManager is not running on this machine."
    fi

    local mode
    mode=$(choose_mode "$(current_mode "$ifc")") || exit 1

    if [[ $mode == static ]]; then
        addr_pfx=$(read_address "$(current_addr "$ifc")") || exit 1
        read -r ip p <<<"$addr_pfx"
        gw=$(read_gateway "$ip" "$p" "$ifc") || exit 1
        dns_str=$(read_dns) || exit 1
        read -r -a dns <<<"$dns_str"
    else
        ip=""; p=""; gw=""; dns_str=""
    fi

    echo
    echo "${C_B}Summary${C_RST}"
    printf '  Interface : %s\n' "$ifc"
    if [[ $mode == static ]]; then
        printf '  Mode      : static IP\n'
        printf '  Address   : %s/%s  (mask %s)\n' "$ip" "$p" "$(int_to_ip "$(prefix_to_int "$p")")"
        printf '  Gateway   : %s\n' "${gw:-none}"
        printf '  DNS       : %s\n' "${dns_str:-none}"
    else
        printf '  Mode      : DHCP (automatic address, gateway and DNS)\n'
    fi
    printf '  Manager   : %s\n' "$(backend_label "$backend")"
    echo
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        if [[ $mode == static ]]; then
            warn "You are connected over SSH: if the address changes, reconnect to ${ip}."
        else
            warn "You are connected over SSH: the new DHCP address is not known in advance (check the console or the DHCP server)."
        fi
    fi
    confirm "Apply now?" || { info "Cancelled, nothing was changed."; exit 0; }

    if (( ! DRY_RUN )); then
        # Survive an SSH disconnect while applying, and log everything
        trap '' HUP PIPE
        BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        exec > >(tee -a "$LOG_FILE") 2>&1
        if [[ $mode == static ]]; then
            echo "----- $(date '+%F %T') : $ifc -> $ip/$p gw=${gw:-none} dns=${dns_str:-none} ($backend)"
        else
            echo "----- $(date '+%F %T') : $ifc -> DHCP ($backend)"
        fi
        info "Backup: $BACKUP_DIR"
    fi

    local cidr=""
    [[ $mode == static ]] && cidr="$ip/$p"
    case $backend in
        networkmanager) apply_networkmanager "$ifc" "$cidr" "$gw" "${dns[@]}" ;;
        ifupdown)       apply_ifupdown       "$ifc" "$cidr" "$gw" "${dns[@]}" ;;
        networkd)       apply_networkd       "$ifc" "$cidr" "$gw" "${dns[@]}" ;;
    esac

    if [[ $mode == static ]]; then
        verify "$ifc" "$ip" "$gw" "${dns[0]:-}"
    else
        verify_dhcp "$ifc"
    fi
    echo
    if (( DRY_RUN )); then
        ok "Dry run finished, nothing was changed."
    else
        ok "Configuration applied and persistent across reboots."
        info "Log: $LOG_FILE — Backup: $BACKUP_DIR"
    fi
}

main "$@"
