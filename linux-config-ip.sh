#!/usr/bin/env bash
# =============================================================================
#  linux-config-ip — Configure l'adresse IPv4 d'une machine Linux (statique ou DHCP),
#  quel que soit le gestionnaire réseau utilisé par la machine :
#    - NetworkManager   (nmtui / nmcli)       -> installations avec bureau
#    - ifupdown         (/etc/network/interfaces) -> installations serveur
#    - systemd-networkd (/etc/systemd/network)    -> images cloud / minimales
#
#  Distributions prises en charge : Debian 11, 12 et 13.
#  (Ubuntu et autres distributions : à venir)
#  Licence : MIT
# =============================================================================

set -uo pipefail

VERSION="1.2.0"
PROG="linux-config-ip"
# Anciens noms du projet (pour reconnaître leurs marqueurs)
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
#  Affichage
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
err()  { printf '%s[ERREUR]%s %s\n' "$C_R" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<EOF
${PROG} ${VERSION} — IP statique ou DHCP sous Linux sans se prendre la tête

Usage : sudo ./${PROG}.sh [options]

Sans option, le script pose les questions une par une.

Options :
  -i, --interface IF     Interface à configurer (ex : ens18)
  -s, --static           Mode IP statique (implicite avec --address)
  -D, --dhcp             Repasser l'interface en DHCP
  -a, --address IP[/CIDR]
                         Adresse IP, avec ou sans masque (ex : 192.168.10.1/24)
  -m, --mask MASQUE      Masque si absent de --address (255.255.255.0 ou 24)
  -g, --gateway IP       Passerelle (chaîne vide "" = pas de passerelle)
  -d, --dns "IP IP"      Serveurs DNS séparés par des espaces ou des virgules
  -b, --backend NOM      Forcer : networkmanager | ifupdown | networkd
  -y, --yes              Ne pas demander de confirmation
  -n, --dry-run          Afficher ce qui serait fait, sans rien modifier
  -h, --help             Afficher cette aide
  -V, --version          Afficher la version

Exemples :
  sudo ./${PROG}.sh
  sudo ./${PROG}.sh -i ens18 -a 192.168.10.1/24 -g 192.168.10.254 -d "1.1.1.1 9.9.9.9" -y
  sudo ./${PROG}.sh -i ens18 --dhcp -y
EOF
}

# Lecture depuis le terminal (fonctionne aussi avec « curl ... | sudo bash »)
ask() {
    local prompt=$1 default=${2-} answer
    if [[ -n $default ]]; then
        prompt="${prompt} [${default}]"
    fi
    if ! read -r -p "${C_B}${prompt} : ${C_RST}" answer </dev/tty; then
        echo; die "Lecture impossible (pas de terminal). Utilisez les options, voir --help."
    fi
    answer=${answer#"${answer%%[![:space:]]*}"}
    answer=${answer%"${answer##*[![:space:]]}"}
    printf '%s' "${answer:-$default}"
}

confirm() {
    local a
    (( ASSUME_YES )) && return 0
    a=$(ask "$1 (O/n)" "O")
    [[ $a =~ ^([oOyY]|oui|OUI|Oui|yes)$ ]]
}

# --------------------------------------------------------------------------- #
#  Calculs IPv4
# --------------------------------------------------------------------------- #
valid_ip() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ $o =~ ^(0|[1-9][0-9]*)$ ]] || return 1   # pas de zéro en tête
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

# Accepte « 24 », « /24 » ou « 255.255.255.0 » ; renvoie le préfixe (1-32)
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
    (( (inv & (inv + 1)) == 0 )) || return 1      # masque non contigu
    while (( n & 0x80000000 )); do
        p=$((p + 1))
        n=$(( (n << 1) & 0xFFFFFFFF ))
    done
    (( p >= 1 )) || return 1
    echo "$p"
}

# Vérifie qu'une IP est utilisable comme adresse d'hôte dans son réseau
check_host_ip() {
    local ip=$1 p=$2 i m net bc
    (( p >= 31 )) && return 0
    i=$(ip_to_int "$ip"); m=$(prefix_to_int "$p")
    net=$(( i & m )); bc=$(( net | (~m & 0xFFFFFFFF) ))
    if (( i == net )); then
        err "$ip est l'adresse du réseau $(int_to_ip "$net")/$p, pas une adresse d'hôte."
        return 1
    fi
    if (( i == bc )); then
        err "$ip est l'adresse de broadcast du réseau $(int_to_ip "$net")/$p."
        return 1
    fi
}

same_subnet() {
    local m
    m=$(prefix_to_int "$3")
    (( ($(ip_to_int "$1") & m) == ($(ip_to_int "$2") & m) ))
}

# --------------------------------------------------------------------------- #
#  Détection du système
# --------------------------------------------------------------------------- #
os_version() {
    local name="inconnu" ver=""
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

# Liste les fichiers ifupdown (principal + interfaces.d)
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

# Choisit le gestionnaire qui pilote RÉELLEMENT cette interface
detect_backend() {
    local ifc=$1 st
    # 1. NetworkManager gère l'interface (installations avec bureau)
    if nm_active; then
        st=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$ifc" '$1 == d {print $2; exit}')
        if [[ -n $st && $st != unmanaged* ]]; then
            echo networkmanager; return
        fi
    fi
    # 2. L'interface est déclarée dans /etc/network/interfaces
    #    (dans ce cas Debian indique à NetworkManager de l'ignorer)
    if iface_in_ifupdown "$ifc"; then
        echo ifupdown; return
    fi
    # 3. systemd-networkd gère l'interface (images cloud, installations minimales)
    if networkd_active && command -v networkctl >/dev/null 2>&1; then
        st=$(networkctl list --no-legend 2>/dev/null | awk -v d="$ifc" '$2 == d {print $5; exit}')
        if [[ -n $st && $st != unmanaged ]]; then
            echo networkd; return
        fi
    fi
    # 4. Rien ne gère l'interface : on prend le premier outil disponible
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
#  Outils d'écriture (respectent --dry-run)
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
            printf '%s[dry-run]%s sauvegarde de %s\n' "$C_Y" "$C_RST" "$f"
            continue
        fi
        mkdir -p "${BACKUP_DIR}$(dirname "$f")"
        cp -a "$f" "${BACKUP_DIR}${f}"
    done
}

restore_backup() {
    [[ -n $BACKUP_DIR && -d $BACKUP_DIR ]] || return 0
    warn "Restauration de la configuration précédente depuis $BACKUP_DIR"
    (cd "$BACKUP_DIR" && find . -type f -o -type l) | while IFS= read -r rel; do
        cp -a "${BACKUP_DIR}/${rel#./}" "/${rel#./}"
    done
}

# write_file CHEMIN MODE  (contenu lu sur l'entrée standard)
write_file() {
    local path=$1 mode=${2:-644} content
    content=$(cat)
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s contenu de %s :\n' "$C_Y" "$C_RST" "$path"
        printf '%s\n' "$content" | sed 's/^/    | /'
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    local tmp
    tmp=$(mktemp "${path}.XXXXXX") || return 1
    printf '%s\n' "$content" >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path"
}

# --------------------------------------------------------------------------- #
#  DNS (hors NetworkManager / networkd+resolved)
# --------------------------------------------------------------------------- #
# En DHCP : retirer les DNS forcés par ce script, le client DHCP reprend la main
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
# Généré par ${PROG} le $(date '+%F %T')
[Resolve]
DNS=${dns[*]}
EOF
        run systemctl restart systemd-resolved
        return
    fi

    if command -v resolvconf >/dev/null 2>&1 && [[ -L /etc/resolv.conf ]]; then
        # Le paquet resolvconf lit « dns-nameservers » dans /etc/network/interfaces
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
        echo "# Généré par ${PROG} le $(date '+%F %T')"
        [[ -n $keep ]] && echo "$keep"
        local d
        for d in "${dns[@]}"; do echo "nameserver $d"; done
    } | write_file /etc/resolv.conf 644 || warn "Impossible d'écrire /etc/resolv.conf."
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
        # Chercher un profil existant lié à cette interface
        uuid=$(nmcli -t -f UUID,DEVICE connection show 2>/dev/null | awk -F: -v d="$ifc" '$2 == d {print $1; exit}')
    fi
    if [[ -z $uuid ]]; then
        [[ $type == ethernet || -z $type ]] ||
            die "Aucun profil NetworkManager pour $ifc (type $type). Connectez-vous d'abord une fois avec nmtui."
        info "Création d'un profil NetworkManager « $ifc »"
        if (( DRY_RUN )); then
            run nmcli connection add type ethernet ifname "$ifc" con-name "$ifc"
            uuid="<nouveau-profil>"
        else
            nmcli connection add type ethernet ifname "$ifc" con-name "$ifc" >/dev/null ||
                die "Impossible de créer le profil NetworkManager."
            uuid=$(nmcli -g connection.uuid connection show "$ifc" | head -n1)
        fi
    fi

    local name
    name=$(nmcli -g connection.id connection show "$uuid" 2>/dev/null | head -n1)
    info "Profil NetworkManager modifié : ${name:-$uuid}"

    # Mémoriser l'ancienne config pour pouvoir revenir en arrière
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
            die "nmcli a refusé la configuration."
    else
        run nmcli connection modify "$uuid" \
            ipv4.method manual \
            ipv4.addresses "$addr" \
            ipv4.gateway "$gw" \
            ipv4.dns "$dns_csv" \
            ipv4.ignore-auto-dns yes \
            connection.autoconnect yes ||
            die "nmcli a refusé la configuration."
    fi

    if ! run nmcli connection up "$uuid"; then
        err "Activation impossible, retour à la configuration précédente."
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
# Réécrit un fichier ifupdown :
#  - supprime la déclaration IPv4 de l'interface et ses lignes auto/allow-*
#  - garde l'IPv6, les commentaires et les autres interfaces
#  - si NEW_BLOCK est défini (variable d'environnement), l'insère à la place
#    de l'ancienne déclaration IPv4
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
                if (index(line, "# " d " : configuré par " P[i]) == 1) return 1
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
                    pend = pend $0 "\n"; next      # peut appartenir au bloc suivant
                } else {
                    pend = ""; next                # option de l ancien bloc
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

# Premier fichier qui déclare « iface IF inet »
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
    command -v ifup >/dev/null 2>&1 || die "ifupdown n'est pas installé (apt install ifupdown)."

    local main=/etc/network/interfaces
    if [[ ! -f $main ]]; then
        printf 'source /etc/network/interfaces.d/*\n\nauto lo\niface lo inet loopback\n' | write_file "$main" 644
    fi

    local files=() owner
    while IFS= read -r f; do files+=("$f"); done < <(ifupdown_files)
    owner=$(ifupdown_owner "$ifc") || owner=$main
    backup "${files[@]}"

    # Nouveau bloc
    local block
    block="# $ifc : configuré par ${PROG} le $(date '+%F %T')"$'\n'"auto $ifc"$'\n'
    if [[ -z $addr ]]; then
        block+="iface $ifc inet dhcp"
    else
        block+="iface $ifc inet static"$'\n'"    address $addr"
        [[ -n $gw ]] && block+=$'\n'"    gateway $gw"
        (( ${#dns[@]} )) && block+=$'\n'"    dns-nameservers ${dns[*]}"
    fi

    # Libérer l'ancienne configuration (bail DHCP, etc.) avant de réécrire
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
        # Ne réécrire que si le fichier change réellement
        if [[ "$content" != "$(cat "$f")" ]]; then
            printf '%s\n' "$content" | write_file "$f" 644
        fi
    done

    if [[ -z $addr ]]; then
        reset_dns_generic
    else
        apply_dns_generic "$ifc" "${dns[@]}"
        # Arrêter un éventuel client DHCP resté actif sur l'interface
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
        err "ifup a échoué."
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

    # Désactiver les autres fichiers /etc qui ciblent cette interface
    local others=()
    for f in /etc/systemd/network/*.network; do
        [[ -f $f && $f != "$target" ]] || continue
        if grep -Eq "^[[:space:]]*Name=(.*[[:space:]])?${ifc}([[:space:]]|\$)" "$f"; then
            others+=("$f")
        fi
    done
    backup "$target" "${others[@]}"
    for f in "${others[@]}"; do
        info "Désactivation de $f"
        run mv -f "$f" "${f}.desactive-par-${PROG}"
    done

    {
        echo "# Généré par ${PROG} le $(date '+%F %T')"
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
        warn "Netplan est présent : ce fichier est prioritaire, mais pensez à nettoyer /etc/netplan."
    fi

    if [[ -z $addr ]]; then
        reset_dns_generic
    elif ! resolved_active; then
        apply_dns_generic "$ifc" "${dns[@]}"
    fi

    run ip -4 addr flush dev "$ifc"
    run networkctl reload
    if ! run networkctl reconfigure "$ifc"; then
        err "networkctl a échoué."
        if (( ! DRY_RUN )); then
            rm -f "$target"
            for f in "${others[@]}"; do mv -f "${f}.desactive-par-${PROG}" "$f"; done
            restore_backup
            networkctl reload; networkctl reconfigure "$ifc"
        fi
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
#  Programme principal
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
    (( ${#ifaces[@]} )) || die "Aucune interface réseau trouvée."
    def=$(default_iface)
    [[ -z $def ]] && def=${ifaces[0]}

    if [[ -n $OPT_IF ]]; then
        [[ -d /sys/class/net/$OPT_IF ]] || die "Interface introuvable : $OPT_IF"
        echo "$OPT_IF"; return
    fi
    if (( ${#ifaces[@]} == 1 )); then
        echo "${ifaces[0]}"; return
    fi

    {
        echo
        echo "${C_B}Interfaces disponibles :${C_RST}"
        n=1
        for i in "${ifaces[@]}"; do
            printf '  %d) %-12s %-18s %s\n' "$n" "$i" "$(current_addr "$i")" \
                "$([[ $i == "$def" ]] && echo '(route par défaut)')"
            n=$((n + 1))
        done
    } >&2
    while :; do
        choice=$(ask "Interface à configurer (numéro ou nom)" "$def")
        if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
            echo "${ifaces[choice - 1]}"; return
        fi
        [[ -d /sys/class/net/$choice ]] && { echo "$choice"; return; }
        err "Choix invalide : $choice"
    done
}

current_mode() {
    local ifc=$1
    if ip -4 -o addr show dev "$ifc" 2>/dev/null | grep -q ' dynamic '; then
        echo "DHCP"
    elif [[ -n $(current_addr "$ifc") ]]; then
        echo "statique"
    else
        echo "aucune adresse"
    fi
}

choose_mode() {
    local cur=$1 choice
    if [[ -n $OPT_MODE ]]; then echo "$OPT_MODE"; return; fi
    if [[ -n $OPT_ADDR ]]; then echo static; return; fi
    {
        echo
        echo "${C_B}Que voulez-vous faire ?${C_RST}  (mode actuel : $cur)"
        echo "  1) Adresse IP statique"
        echo "  2) Adresse automatique (DHCP)"
    } >&2
    while :; do
        choice=$(ask "Choix" "1")
        case ${choice,,} in
            1|s|statique|static) echo static; return ;;
            2|d|dhcp|auto)       echo dhcp; return ;;
        esac
        err "Choix invalide : $choice"
    done
}

# Renvoie « IP PREFIXE »
read_address() {
    local input ip mask p cur
    cur=$1
    while :; do
        if [[ -n $OPT_ADDR ]]; then
            input=$OPT_ADDR
        else
            echo >&2
            echo "Saisissez l'adresse ${C_B}avec son masque${C_RST} (ex : 192.168.10.1/24)" >&2
            echo "ou seulement l'adresse (ex : 192.168.10.1) : le masque sera demandé ensuite." >&2
            input=$(ask "Adresse IP" "$cur")
        fi
        input=${input// /}
        ip=${input%%/*}
        if ! valid_ip "$ip"; then
            err "Adresse IP invalide : $ip"
            [[ -n $OPT_ADDR ]] && exit 1
            continue
        fi
        if [[ $input == */* ]]; then
            mask=${input#*/}
        elif [[ -n $OPT_MASK ]]; then
            mask=$OPT_MASK
        else
            mask=$(ask "Masque (ex : 255.255.255.0 ou 24)" "255.255.255.0")
        fi
        if ! p=$(mask_to_prefix "$mask"); then
            err "Masque invalide : $mask"
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
            # Proposer la première adresse du réseau (ou la seconde si c'est l'IP choisie)
            local net
            net=$(( $(ip_to_int "$ip") & $(prefix_to_int "$p") ))
            def=$(int_to_ip $((net + 1)))
            [[ $def == "$ip" ]] && def=$(int_to_ip $((net + 2)))
            (( p >= 31 )) && def=""
        fi
        echo >&2
        gw=$(ask "Passerelle (tapez « aucune » pour ne pas en mettre)" "$def")
    fi
    case ${gw,,} in aucune|none|non|-) gw="" ;; esac
    while [[ -n $gw ]]; do
        if ! valid_ip "$gw"; then
            err "Passerelle invalide : $gw"
        elif [[ $gw == "$ip" ]]; then
            err "La passerelle ne peut pas être l'adresse de la machine."
        elif ! same_subnet "$gw" "$ip" "$p"; then
            err "La passerelle $gw n'est pas dans le réseau de $ip/$p."
        else
            break
        fi
        (( OPT_GW_SET )) && exit 1
        gw=$(ask "Passerelle" "")
        case ${gw,,} in aucune|none|non|-) gw="" ;; esac
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
        input=$(ask "Serveurs DNS (séparés par des espaces)" "$def")
    fi
    while :; do
        out=()
        local bad=0
        for d in ${input//,/ }; do
            if valid_ip "$d"; then out+=("$d"); else err "DNS invalide : $d"; bad=1; fi
        done
        (( bad == 0 )) && break
        [[ -n $OPT_DNS ]] && exit 1
        input=$(ask "Serveurs DNS" "1.1.1.1 9.9.9.9")
    done
    echo "${out[*]}"
}

verify_dhcp() {
    local ifc=$1 i a
    (( DRY_RUN )) && return 0
    echo
    info "Attente d'une adresse DHCP (30 s max)…"
    for (( i = 0; i < 30; i++ )); do
        a=$(current_addr "$ifc")
        [[ -n $a ]] && break
        sleep 1
    done
    ip -br -4 addr show dev "$ifc"
    ip -4 route show default 2>/dev/null | sed 's/^/    /'
    if [[ -n $a ]]; then
        ok "Adresse obtenue par DHCP : $a"
    else
        err "Aucune adresse reçue : vérifiez qu'un serveur DHCP est présent sur le réseau."
        return 1
    fi
}

verify() {
    local ifc=$1 ip=$2 gw=$3 dns1=$4 i
    (( DRY_RUN )) && return 0
    echo
    info "Vérification…"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ip -4 -o addr show dev "$ifc" | grep -q " ${ip}/" && break
        sleep 1
    done
    ip -br -4 addr show dev "$ifc"
    ip -4 route show default 2>/dev/null | sed 's/^/    /'
    if ip -4 -o addr show dev "$ifc" | grep -q " ${ip}/"; then
        ok "Adresse $ip présente sur $ifc."
    else
        err "L'adresse $ip n'apparaît pas sur $ifc."
        return 1
    fi
    if [[ -n $gw ]]; then
        if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then
            ok "Passerelle $gw joignable."
        else
            warn "La passerelle $gw ne répond pas au ping (pare-feu ou mauvaise adresse ?)."
        fi
    fi
    if [[ -n $dns1 ]] && command -v getent >/dev/null 2>&1; then
        if timeout 5 getent hosts deb.debian.org >/dev/null 2>&1; then
            ok "Résolution DNS fonctionnelle."
        else
            warn "La résolution DNS ne répond pas (pas d'accès Internet ?)."
        fi
    fi
}

main() {
    parse_args "$@"

    if (( EUID != 0 )) && (( ! DRY_RUN )); then
        die "Ce script doit être lancé en root : sudo $0  (ou « su - » puis relancer)"
    fi
    command -v ip >/dev/null 2>&1 || die "La commande « ip » (paquet iproute2) est introuvable."

    echo "${C_B}=== ${PROG} ${VERSION} ===${C_RST}"
    info "Système : $(os_version)"
    is_debian_like || warn "Distribution non encore prise en charge officiellement (seule Debian l'est) : le résultat n'est pas garanti."

    local ifc backend addr_pfx ip p gw dns_str dns=()
    ifc=$(choose_iface) || exit 1
    info "Interface : $ifc (adresse actuelle : $(current_addr "$ifc" || true))"

    if [[ -n $OPT_BACKEND ]]; then
        case $OPT_BACKEND in
            networkmanager|nm) backend=networkmanager ;;
            ifupdown|interfaces) backend=ifupdown ;;
            networkd|systemd-networkd) backend=networkd ;;
            *) die "Backend inconnu : $OPT_BACKEND" ;;
        esac
    else
        backend=$(detect_backend "$ifc")
    fi
    [[ $backend == none ]] && die "Aucun gestionnaire réseau trouvé (NetworkManager, ifupdown ou systemd-networkd)."
    info "Gestionnaire détecté : $(backend_label "$backend")"
    if [[ $backend == networkmanager ]] && ! nm_active; then
        die "NetworkManager n'est pas actif sur cette machine."
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
    echo "${C_B}Récapitulatif${C_RST}"
    printf '  Interface    : %s\n' "$ifc"
    if [[ $mode == static ]]; then
        printf '  Mode         : IP statique\n'
        printf '  Adresse      : %s/%s  (masque %s)\n' "$ip" "$p" "$(int_to_ip "$(prefix_to_int "$p")")"
        printf '  Passerelle   : %s\n' "${gw:-aucune}"
        printf '  DNS          : %s\n' "${dns_str:-aucun}"
    else
        printf '  Mode         : DHCP (adresse, passerelle et DNS automatiques)\n'
    fi
    printf '  Gestionnaire : %s\n' "$(backend_label "$backend")"
    echo
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        if [[ $mode == static ]]; then
            warn "Vous êtes connecté en SSH : si l'adresse change, reconnectez-vous sur ${ip}."
        else
            warn "Vous êtes connecté en SSH : la nouvelle adresse DHCP sera inconnue d'avance (voir la console ou le serveur DHCP)."
        fi
    fi
    confirm "Appliquer maintenant ?" || { info "Annulé, rien n'a été modifié."; exit 0; }

    if (( ! DRY_RUN )); then
        # Survivre à une coupure SSH pendant l'application et tout journaliser
        trap '' HUP PIPE
        BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        exec > >(tee -a "$LOG_FILE") 2>&1
        if [[ $mode == static ]]; then
            echo "----- $(date '+%F %T') : $ifc -> $ip/$p gw=${gw:-aucune} dns=${dns_str:-aucun} ($backend)"
        else
            echo "----- $(date '+%F %T') : $ifc -> DHCP ($backend)"
        fi
        info "Sauvegarde : $BACKUP_DIR"
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
        ok "Simulation terminée, rien n'a été modifié."
    else
        ok "Configuration appliquée et persistante au redémarrage."
        info "Journal : $LOG_FILE — Sauvegarde : $BACKUP_DIR"
    fi
}

main "$@"
