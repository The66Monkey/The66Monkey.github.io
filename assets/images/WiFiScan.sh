#!/data/data/com.termux/files/usr/bin/bash
# WiFiScan — On-device Wi-Fi + subnet recon for a rooted Android phone in Termux.
#
# Target: rooted Pixel 9a / LineageOS (Android 16), but works on any rooted
# Termux install. There is NO monitor-mode capture — verified on-device that
# the Broadcom Wi-Fi firmware refuses it ("Monitor mode is not enabled in FW
# cap"), so scanning goes through Android's WifiManager APIs (Termux:API)
# plus nmap/arp-scan/nbtscan/snmpwalk/dnsrecon for active recon, instead of
# airodump-ng/aircrack-ng.
#
# QUICK START (one-time setup in Termux):
#   pkg install jq nmap termux-api arp-scan nbtscan net-snmp
#   Also sideload the Termux:API *app* (F-Droid/GitHub build matching your
#   Termux app — NOT Play Store) and grant it Location access, or
#   termux-wifi-scaninfo/termux-location will be no-ops.
#   (dnsrecon isn't packaged for Termux; the script tries 'pip install
#   dnsrecon' on first run and just skips that check if it fails.)
#
# RUN:   bash WiFiScan.sh [-q] [-p]
#   -q   quiet    — suppress the per-AP scan lines, keep loop/summary output
#   -p   passive  — Wi-Fi scanning only; skip all active subnet/gateway recon
#                    (arp-scan/nbtscan/snmpwalk/dnsrecon/nmap). Use this if you
#                    only have authorization to observe, not to probe hosts.
#   -h   help     — print this usage and exit
#
# WATCH IT RUN:  tail -f wifiscan.out   (in the folder you launched from)
# STOP THE SCAN: kill $(cat wifiscan.pid)
# LOGS:          written to the folder you launched the script from

### ─── COLORS ────────────────────────────────────────────────────── ###
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
info() { echo -e "${CYN}[*]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
err()  { echo -e "${RED}[-]${RST} $*" >&2; }
ok()   { echo -e "${GRN}[+]${RST} $*"; }

# Resolve the directory the script was launched from, regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Animated "still working" indicator shown in the launching terminal while the
# daemonized scan runs in the background; watches PID, exits when it dies.
spinner() {
    local pid="$1"
    local frames=("🐇      " " 🐇     " "  🐇    " "   🐇   " "    🐇  " "     🐇 " "      🐇" "     🐇 " "    🐇  " "   🐇   " "  🐇    " " 🐇     ")
    local i=0
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYN}[running]${RST} %s  (PID %s — Ctrl+C stops watching, not the scan)" "${frames[i]}" "$pid"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.15
    done
    tput cnorm 2>/dev/null
    printf "\r%-70s\r" " "
}

### ─── DEFAULTS ──────────────────────────────────────────────────── ###
LOG_DIR="$SCRIPT_DIR"               # log to the same folder the script was launched from
WIFI_IFACE="${WIFI_IFACE:-wlan0}"   # used by arp-scan; override with WIFI_IFACE=wlan1 env var
DWELL=15                            # seconds between passive Wi-Fi scans
GPS_ENABLED=true
GPS_EVERY=3                         # only take a fresh GPS fix every N loops (battery)
QUIET=false
AGGRESSIVE_SCAN=true                # do active subnet/gateway recon when connected
AGGRESSIVE_SCAN_INTERVAL=300        # seconds between full active-recon passes
LOOP_SLEEP=10
LAST_AGGR_SCAN_TS=0
LAST_GPS="0,0,?"
SCAN_COUNT=0
SSL_WARNING_COUNT=0
SNMP_WARNING_COUNT=0
NOTIFY=false                        # set true if termux-notification is available

### ─── ARGUMENTS (locked down to two flags for easy use) ────────── ###
usage() { grep '^#   -' "$0" | sed 's/^# //'; }
while getopts "qph" opt; do
    case "$opt" in
        q) QUIET=true ;;
        p) AGGRESSIVE_SCAN=false ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

### ─── ROOT DETECTION ────────────────────────────────────────────── ###
ROOT=false
if command -v su &>/dev/null && su -c 'id -u' 2>/dev/null | grep -qx 0; then
    ROOT=true
fi

# Run a command as root when available, otherwise run it unprivileged.
as_root() {
    if $ROOT; then su -c "$*" 2>/dev/null; else "$@" 2>/dev/null; fi
}

### ─── DEPENDENCY CHECK ──────────────────────────────────────────── ###
declare -A REQ_PKGS=( [jq]="jq" )
declare -A OPT_PKGS=(
    [nmap]="nmap" [termux-wifi-scaninfo]="termux-api" [termux-location]="termux-api"
    [termux-wake-lock]="termux-tools" [arp-scan]="arp-scan" [nbtscan]="nbtscan" [snmpwalk]="net-snmp"
)

missing_required=0
for bin in "${!REQ_PKGS[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
        info "Installing ${REQ_PKGS[$bin]} (provides $bin)..."
        pkg install -y "${REQ_PKGS[$bin]}" &>/dev/null || missing_required=1
    fi
done
[[ $missing_required -ne 0 ]] && { err "Could not install required package(s). Run 'pkg install jq' manually."; exit 1; }

for bin in "${!OPT_PKGS[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
        info "Installing ${OPT_PKGS[$bin]} (provides $bin)..."
        pkg install -y "${OPT_PKGS[$bin]}" &>/dev/null \
            || warn "Optional tool '$bin' unavailable — related feature will be skipped."
    fi
done

command -v nmap &>/dev/null && HAVE_NMAP=true || HAVE_NMAP=false
command -v arp-scan &>/dev/null && HAVE_ARPSCAN=true || HAVE_ARPSCAN=false
command -v nbtscan &>/dev/null && HAVE_NBTSCAN=true || HAVE_NBTSCAN=false
command -v snmpwalk &>/dev/null && HAVE_SNMPWALK=true || HAVE_SNMPWALK=false
command -v termux-notification &>/dev/null && NOTIFY=true

# dnsrecon isn't in Termux's apt repo — try pip as a fallback, skip if that fails too.
HAVE_DNSRECON=false
if command -v dnsrecon &>/dev/null; then
    HAVE_DNSRECON=true
else
    command -v pip &>/dev/null || pkg install -y python &>/dev/null
    if command -v pip &>/dev/null; then
        info "Installing dnsrecon via pip (not packaged in Termux)..."
        pip install --quiet dnsrecon &>/dev/null && command -v dnsrecon &>/dev/null && HAVE_DNSRECON=true
    fi
fi
$HAVE_DNSRECON || warn "dnsrecon unavailable — reverse-PTR recon will be skipped."

if ! command -v termux-wifi-scaninfo &>/dev/null; then
    err "termux-wifi-scaninfo missing. Install the Termux:API app (F-Droid/GitHub build) and grant it Location access."
    exit 1
fi
if ! termux-wifi-connectioninfo &>/dev/null; then
    warn "termux-wifi-connectioninfo failed — is the Termux:API app installed and running?"
fi

$ROOT && ok "Root available — using it to lift the Wi-Fi scan throttle and for deeper nmap scans." \
      || warn "No root detected — scans limited to Android's default throttle (~1 per 30s)."

if $ROOT; then
    su -c 'settings put global wifi_scan_throttle_enabled 0' 2>/dev/null
    su -c 'cmd wifi set-scan-always-available true' 2>/dev/null
fi

command -v termux-wake-lock &>/dev/null && termux-wake-lock

# Load the local IEEE OUI dump (same folder as the script) into memory once,
# keyed by uppercase "XX:XX:XX" prefix, instead of re-parsing JSON per lookup.
MAC_VENDORS_FILE="$SCRIPT_DIR/mac-vendors.json"
declare -A VENDOR_MAP=()
if [[ -f "$MAC_VENDORS_FILE" ]] && command -v jq &>/dev/null; then
    while IFS=$'\t' read -r prefix vendor; do
        VENDOR_MAP["$prefix"]="$vendor"
    done < <(jq -r '.[] | "\(.macPrefix)\t\(.vendorName)"' "$MAC_VENDORS_FILE" 2>/dev/null)
    ok "Loaded ${#VENDOR_MAP[@]} MAC vendor prefixes from mac-vendors.json"
else
    warn "mac-vendors.json not found next to the script — vendor lookups will show 'Unknown'."
fi

### ─── SELF-DAEMONIZE ────────────────────────────────────────────── ###
if [[ -z "${WIFISCAN_DAEMON:-}" ]]; then
    mkdir -p "$LOG_DIR"
    LOGFILE="$LOG_DIR/wifiscan.out"
    PIDFILE="$LOG_DIR/wifiscan.pid"
    export WIFISCAN_DAEMON=1
    nohup "$0" "$@" >> "$LOGFILE" 2>&1 &
    disown
    echo $! > "$PIDFILE"
    ok  "WiFiScan started in background  (PID $(cat "$PIDFILE"))"
    info "Log : $LOGFILE"
    info "Stop: kill \$(cat $PIDFILE)"
    trap 'tput cnorm 2>/dev/null; echo; info "Stopped watching (scan still running in background)."; exit 0' INT
    spinner "$(cat "$PIDFILE")"
    exit 0
fi

### ─── LOG SETUP ─────────────────────────────────────────────────── ###
mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d_%H%M%S)
LOG_PREFIX="$LOG_DIR/scan-$TS"
SECURITY_LOG="$LOG_PREFIX-security.csv"
HEATMAP_LOG="$LOG_PREFIX-heatmap.csv"
SUMMARY_LOG="$LOG_PREFIX-summary.txt"
VULN_REPORT="$LOG_PREFIX-vuln-report.txt"
NETWORK_CSV="$LOG_DIR/network-log.csv"
NETWORK_RAW="$LOG_DIR/network-raw.log"
SEEN_BSSIDS="$LOG_DIR/.wifiscan_seen_$$"
touch "$SEEN_BSSIDS"

echo "timestamp,ssid,bssid,channel,freq,rssi,security,wps,hidden,vendor,ch_rating" > "$SECURITY_LOG"
echo "lat,lon,accuracy,ssid,bssid,channel,rssi,vendor" > "$HEATMAP_LOG"
[[ -f "$NETWORK_CSV" ]] || echo "timestamp,mode,ssid,bssid,detail" > "$NETWORK_CSV"

### ─── CLEANUP / TRAP ────────────────────────────────────────────── ###
_CLEANUP_DONE=0
cleanup() {
    [[ $_CLEANUP_DONE -eq 1 ]] && return
    _CLEANUP_DONE=1
    warn "Shutting down..."
    command -v termux-wake-unlock &>/dev/null && termux-wake-unlock
    $NOTIFY && termux-notification-remove wifiscan 2>/dev/null
    rm -f "$SEEN_BSSIDS"
    generate_summary
    generate_vuln_report
    info "All logs saved under: $LOG_DIR"
}
trap cleanup EXIT INT TERM HUP

### ─── HELPERS ───────────────────────────────────────────────────── ###
csv_escape() {
    local s="${1:-}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

# Resolve a BSSID's OUI prefix to a vendor name via the in-memory VENDOR_MAP.
lookup_vendor() {
    local prefix
    prefix=$(echo "$1" | cut -d: -f1-3 | tr '[:lower:]' '[:upper:]')
    echo "${VENDOR_MAP[$prefix]:-Unknown}"
}

# Convert a Wi-Fi scan frequency (MHz) to its channel number.
freq_to_channel() {
    local f="$1"
    if   [[ "$f" -ge 2412 && "$f" -le 2484 ]]; then echo $(( (f - 2407) / 5 ))
    elif [[ "$f" -ge 5170 && "$f" -le 5825 ]]; then echo $(( (f - 5000) / 5 ))
    elif [[ "$f" -ge 5925 && "$f" -le 7125 ]]; then echo $(( (f - 5950) / 5 + 1 ))  # 6 GHz (Wi-Fi 6E)
    else echo "?"
    fi
}

# Classify an Android scan-result "capabilities" string into a risk tier.
classify_security() {
    local caps="$1"
    [[ "$caps" == *"WPA3"* ]] && echo "STRONG-WPA3" && return
    if [[ "$caps" == *"WPA2"* ]]; then
        [[ "$caps" == *"TKIP"* && "$caps" != *"CCMP"* ]] && echo "WEAK-TKIP" && return
        echo "GOOD-WPA2" && return
    fi
    [[ "$caps" == *"WPA"* ]] && echo "WEAK-WPA" && return
    [[ "$caps" == *"WEP"* ]] && echo "WEAK-WEP" && return
    echo "OPEN"
}

# Label 2.4 GHz channel overlap quality; 5/6 GHz channels pass through.
rate_channel() {
    case "$1" in
        1|6|11)            echo "NON-OVERLAPPING" ;;
        2|3|4|5|7|8|9|10)  echo "OVERLAPPING-2G"  ;;
        '?')               echo "?"               ;;
        *)                 echo "5-6GHz"           ;;
    esac
}

# Tally CSV-quoted security/wps/hidden counts from $SECURITY_LOG in one pass.
# Fields are wrapped in "..." by csv_escape, so split on the '","' separator.
security_counts() {
    awk -F'","' 'NR>1 {
        open += ($7=="OPEN"); weak += ($7 ~ /^WEAK-/); strong += ($7 ~ /^(STRONG|GOOD)-/);
        wps += ($8=="YES"); hidden += ($9=="YES")
    } END { print open+0, weak+0, strong+0, wps+0, hidden+0 }' "$SECURITY_LOG" 2>/dev/null
}

# Cache a GPS fix every GPS_EVERY loops; returns "lat,lon,accuracy".
get_gps() {
    ! $GPS_ENABLED && { echo "0,0,?"; return; }
    if (( SCAN_COUNT % GPS_EVERY != 1 )); then
        echo "$LAST_GPS"
        return
    fi
    local fix lat lon acc
    fix=$(timeout 10 termux-location -p gps -r once 2>/dev/null)
    if [[ -n "$fix" ]]; then
        lat=$(echo "$fix" | jq -r '.latitude // "0"')
        lon=$(echo "$fix" | jq -r '.longitude // "0"')
        acc=$(echo "$fix" | jq -r '.accuracy // "?"')
        LAST_GPS="$lat,$lon,$acc"
    fi
    echo "$LAST_GPS"
}

### ─── PASSIVE SCAN (termux-wifi-scaninfo) ───────────────────────── ###
passive_scan() {
    local scan_json new_count=0
    scan_json=$(timeout 15 termux-wifi-scaninfo 2>/dev/null)
    if [[ -z "$scan_json" || "$scan_json" == "[]" ]]; then
        warn "Wi-Fi scan returned no data (throttled, location off, or radio busy)."
        return
    fi

    local gps; gps=$(get_gps)
    local lat lon acc; IFS=',' read -r lat lon acc <<< "$gps"

    while IFS=$'\t' read -r ssid bssid freq level caps; do
        [[ -z "$bssid" ]] && continue
        grep -qxF "$bssid" "$SEEN_BSSIDS" 2>/dev/null && continue
        echo "$bssid" >> "$SEEN_BSSIDS"
        new_count=$((new_count + 1))

        local ch sec wps hidden vendor rating ts
        ch=$(freq_to_channel "$freq")
        sec=$(classify_security "$caps")
        [[ "$caps" == *"WPS"* ]] && wps="YES" || wps="NO"
        [[ -z "${ssid// }" ]] && hidden="YES" || hidden="NO"
        vendor=$(lookup_vendor "$bssid")
        rating=$(rate_channel "$ch")
        ts=$(date +%Y-%m-%dT%H:%M:%S)

        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "$(csv_escape "$ts")" "$(csv_escape "${ssid:-<hidden>}")" "$(csv_escape "$bssid")" \
            "$(csv_escape "$ch")" "$(csv_escape "$freq")" "$(csv_escape "$level")" \
            "$(csv_escape "$sec")" "$(csv_escape "$wps")" "$(csv_escape "$hidden")" "$(csv_escape "$vendor")" "$(csv_escape "$rating")" >> "$SECURITY_LOG"

        echo "$lat,$lon,$acc,$(csv_escape "${ssid:-<hidden>}"),$bssid,$ch,$level,$(csv_escape "$vendor")" >> "$HEATMAP_LOG"

        if ! $QUIET; then
            local label="${ssid:-[hidden]}"
            case "$sec" in
                OPEN)     echo -e "  ${RED}[OPEN]${RST}       $label ($bssid) CH:$ch ${level}dBm  $vendor" ;;
                WEAK*)    echo -e "  ${YEL}[$sec]${RST} $label ($bssid) CH:$ch ${level}dBm  $vendor" ;;
                STRONG*)  echo -e "  ${GRN}[$sec]${RST} $label ($bssid) CH:$ch ${level}dBm  $vendor" ;;
                GOOD*)    echo -e "  ${GRN}[$sec]${RST}   $label ($bssid) CH:$ch ${level}dBm  $vendor" ;;
                *)        echo -e "  ${CYN}[$sec]${RST}     $label ($bssid) CH:$ch ${level}dBm  $vendor" ;;
            esac
            [[ "$wps" == "YES" ]] && echo -e "    ${YEL}^ WPS enabled${RST}"
        fi
    done < <(echo "$scan_json" | jq -r '.[] | [.ssid, .bssid, (.frequency|tostring), (.level|tostring), .capabilities] | @tsv')

    info "Passive scan: $new_count new AP(s) this loop (seen so far: $(wc -l < "$SEEN_BSSIDS"))."
}

### ─── ACTIVE RECON ON CONNECTED NETWORK ─────────────────────────── ###
active_recon() {
    local now_epoch; now_epoch=$(date +%s)
    (( now_epoch - LAST_AGGR_SCAN_TS < AGGRESSIVE_SCAN_INTERVAL )) && return
    LAST_AGGR_SCAN_TS="$now_epoch"

    local info_json ssid bssid my_ip linkspeed freq rssi ts
    info_json=$(termux-wifi-connectioninfo 2>/dev/null)
    [[ -z "$info_json" ]] && return
    ssid=$(echo "$info_json" | jq -r '.ssid // empty' | tr -d '"')
    [[ -z "$ssid" || "$ssid" == "<unknown ssid>" ]] && return
    bssid=$(echo "$info_json" | jq -r '.bssid // empty')
    my_ip=$(echo "$info_json" | jq -r '.ip // empty')
    linkspeed=$(echo "$info_json" | jq -r '.link_speed // empty')
    freq=$(echo "$info_json" | jq -r '.frequency // empty')
    rssi=$(echo "$info_json" | jq -r '.rssi // empty')
    ts=$(date +%Y-%m-%dT%H:%M:%S)

    info "Active recon on '$ssid' ($bssid) — ip=$my_ip speed=${linkspeed}Mbps rssi=${rssi}dBm"
    printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "connection" "$(csv_escape "$ssid")" "$bssid" \
        "$(csv_escape "ip=$my_ip speed=${linkspeed}Mbps freq=$freq rssi=$rssi")" >> "$NETWORK_CSV"

    # DNS servers, as exposed by the platform's net.dns* properties.
    local dns; dns=$(getprop 2>/dev/null | grep -i '\[net\.dns' | sed -E 's/.*\]: \[(.*)\]/\1/' | paste -sd ';' -)
    [[ -n "$dns" ]] && printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "dns" "$(csv_escape "$ssid")" "" "$(csv_escape "$dns")" >> "$NETWORK_CSV"

    # ARP cache straight from the kernel table — no extra tools needed.
    awk 'NR>1 && $1 !~ /0x0/ {print $1, $4}' /proc/net/arp 2>/dev/null | while read -r ip mac; do
        [[ "$mac" == "00:00:00:00:00:00" ]] && continue
        printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "arp" "$(csv_escape "$ssid")" "$mac" "$(csv_escape "ip=$ip vendor=$(lookup_vendor "$mac")")" >> "$NETWORK_CSV"
    done

    [[ -z "$my_ip" ]] && return
    local subnet="${my_ip%.*}"

    # Fast local ping sweep — fires all 254 probes in parallel, 1s timeout each.
    info "Ping-sweeping ${subnet}.0/24..."
    for host in $(seq 1 254); do
        ( ping -c1 -W1 "${subnet}.${host}" &>/dev/null && echo "${subnet}.${host} is up" >> "$NETWORK_RAW" ) &
    done
    wait

    if $HAVE_NMAP; then
        # as_root runs nmap through 'su -c' when rooted, unlocking SYN scans
        # instead of slower/less accurate TCP-connect scans.
        info "nmap discovery sweep on ${subnet}.0/24..."
        as_root timeout 60 nmap -sn "${subnet}.0/24" >> "$NETWORK_RAW"

        local gw="${subnet}.1"
        if [[ -n "$bssid" ]]; then
            info "nmap deep fingerprint on gateway $gw..."
            local scan_out router_model
            scan_out=$(as_root timeout 120 nmap -Pn -sV --version-light \
                --script=vuln,http-title,http-server-header,upnp-info,ssl-cert,ssl-enum-ciphers \
                -p 53,80,443,1900,5000,8080,8443 "$gw")
            echo "$scan_out" >> "$NETWORK_RAW"

            router_model=$(echo "$scan_out" | awk '
                /upnp-info:/ {flag=1; next}
                flag && NF {gsub(/^[ \t]+/, "", $0); print; exit}
                /Service Info:/ {gsub(/^[ \t]+/, "", $0); print; exit}
                /http-title:/ {gsub(/^[ \t]+/, "", $0); print; exit}
            ')
            [[ -n "$router_model" ]] && printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "active" "$(csv_escape "$ssid")" "$bssid" "$(csv_escape "router_model=$router_model")" >> "$NETWORK_CSV"

            local ssl_issues
            ssl_issues=$(echo "$scan_out" | grep -E 'VULNERABLE|least strength: [BCDF]|TLSv1\.0|SSLv|RC4|DES|EXPORT|NULL|WEAK|expired|self-signed' | head -10 | tr '\n' '; ')
            if [[ -n "${ssl_issues// }" ]]; then
                warn "Gateway $gw: $ssl_issues"
                printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "active" "$(csv_escape "$ssid")" "$bssid" "$(csv_escape "SSL-WARNING:${ssl_issues}")" >> "$NETWORK_CSV"
                SSL_WARNING_COUNT=$((SSL_WARNING_COUNT + 1))
            fi
        fi

        # Full vuln/port scan on every host the ping sweep found — not just the gateway.
        local live_hosts
        live_hosts=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3} is up' "$NETWORK_RAW" | awk '{print $1}' | sort -u | tr '\n' ' ')
        if [[ -n "${live_hosts// }" ]]; then
            info "Full vuln/port scan on live hosts: $live_hosts"
            local nmap_open
            nmap_open=$(as_root timeout 300 nmap -T4 --max-retries 1 --open --reason --script vuln --top-ports 50 $live_hosts)
            echo "$nmap_open" >> "$NETWORK_RAW"
            echo "$nmap_open" | awk '
                /Nmap scan report/{ip=$NF}
                /^[0-9]+\/(tcp|udp)[[:space:]]+open/ {print ip "|" $1 " " $2 " " $3}
            ' | while IFS='|' read -r ip portinfo; do
                printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "active" "$(csv_escape "$ssid")" "" "$(csv_escape "NmapOpen:${ip} ${portinfo}")" >> "$NETWORK_CSV"
            done
        fi

        # ── arp-scan: fast ARP host discovery ─────────────────────
        if $HAVE_ARPSCAN; then
            info "arp-scan on $WIFI_IFACE..."
            local arp_out
            arp_out=$(as_root timeout 20 arp-scan -I "$WIFI_IFACE" --localnet --quiet)
            echo "$arp_out" >> "$NETWORK_RAW"
            echo "$arp_out" | awk '/^[0-9]/{print $1 "|" $2 "|" substr($0, index($0,$3))}' \
            | while IFS='|' read -r ip mac vend; do
                printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "arp-scan" "$(csv_escape "$ssid")" "$mac" "$(csv_escape "ip=$ip vendor=${vend:-$(lookup_vendor "$mac")}")" >> "$NETWORK_CSV"
            done
        fi

        # ── nbtscan: NetBIOS hostnames ─────────────────────────────
        if $HAVE_NBTSCAN; then
            info "nbtscan on ${subnet}.0/24..."
            local nbt_out
            nbt_out=$(timeout 25 nbtscan -r "${subnet}.0/24")
            echo "$nbt_out" >> "$NETWORK_RAW"
            echo "$nbt_out" | grep -v "^Doing\|^IP\|^-\|^$" \
            | awk 'NF>=2{print $1 "|" $2}' \
            | while IFS='|' read -r ip nbname; do
                printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "netbios" "$(csv_escape "$ssid")" "" "$(csv_escape "ip=$ip name=$nbname")" >> "$NETWORK_CSV"
            done
        fi

        # ── snmpwalk: check for public SNMP on the gateway ────────────
        if $HAVE_SNMPWALK; then
            local snmp_out
            snmp_out=$(timeout 10 snmpwalk -v1 -c public -OQ "$gw" system 2>/dev/null | head -20)
            if [[ -n "$snmp_out" ]]; then
                echo "=== SNMP $gw ===" >> "$NETWORK_RAW"
                echo "$snmp_out" >> "$NETWORK_RAW"
                warn "SNMP public community responding on $gw — potential info disclosure"
                printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "active" "$(csv_escape "$ssid")" "$bssid" "$(csv_escape "SNMP-public:$(echo "$snmp_out" | head -3 | tr '\n' ';')")" >> "$NETWORK_CSV"
                SNMP_WARNING_COUNT=$((SNMP_WARNING_COUNT + 1))
            fi
        fi

        # ── dnsrecon: reverse PTR + basic DNS recon ───────────────────
        if $HAVE_DNSRECON; then
            info "dnsrecon reverse PTR on ${subnet}.0/24..."
            local dns_out
            dns_out=$(timeout 30 dnsrecon -t rvl -r "${subnet}.0/24" 2>/dev/null)
            if [[ -n "$dns_out" ]]; then
                echo "=== dnsrecon ${subnet}.0/24 ===" >> "$NETWORK_RAW"
                echo "$dns_out" >> "$NETWORK_RAW"
                echo "$dns_out" | grep -oP '\[\+\].*' | while read -r line; do
                    printf "%s,%s,%s,%s,%s\n" "$(csv_escape "$ts")" "dnsrecon" "$(csv_escape "$ssid")" "" "$(csv_escape "$line")" >> "$NETWORK_CSV"
                done
            fi
        fi
    fi
}

### ─── SUMMARY ───────────────────────────────────────────────────── ###
generate_summary() {
    local total_aps open_nets weak_nets strong_nets wps_nets hidden_nets
    total_aps=$(tail -n +2 "$SECURITY_LOG" 2>/dev/null | grep -c , || echo 0)
    read -r open_nets weak_nets strong_nets wps_nets hidden_nets <<< "$(security_counts)"

    {
        echo "═══════════════════════════════════════════"
        echo "  WiFiScan Summary  —  $TS"
        echo "═══════════════════════════════════════════"
        printf "  %-14s: %s\n" "Root"          "$ROOT"
        printf "  %-14s: %s\n" "Loops run"      "$SCAN_COUNT"
        printf "  %-14s: %s\n" "APs found"      "$total_aps"
        printf "  %-14s: %s\n" "Open nets"      "$open_nets"
        printf "  %-14s: %s\n" "Weak nets"      "$weak_nets"
        printf "  %-14s: %s\n" "Strong nets"    "$strong_nets"
        printf "  %-14s: %s\n" "WPS enabled"    "$wps_nets"
        printf "  %-14s: %s\n" "Hidden SSIDs"   "$hidden_nets"
        printf "  %-14s: %s\n" "SSL warnings"   "$SSL_WARNING_COUNT"
        printf "  %-14s: %s\n" "SNMP warnings"  "$SNMP_WARNING_COUNT"
        echo "═══════════════════════════════════════════"
    } | tee "$SUMMARY_LOG"
}

### ─── VULNERABILITY REPORT ──────────────────────────────────────── ###
generate_vuln_report() {
    local score=0
    local -a findings=()
    local -a remediation=()

    local open_nets weak_nets strong_nets wps_nets hidden_nets
    read -r open_nets weak_nets strong_nets wps_nets hidden_nets <<< "$(security_counts)"

    local confirmed_vulns
    confirmed_vulns=$(grep -c 'VULNERABLE:' "$NETWORK_RAW" 2>/dev/null || echo 0)
    if [[ $confirmed_vulns -gt 0 ]]; then
        score=$((score + confirmed_vulns * 25))
        findings+=("CRITICAL | $confirmed_vulns confirmed vulnerability/vulnerabilities from nmap --script vuln (see network-raw.log)")
        while IFS= read -r vuln_line; do
            findings+=("         \\_ $vuln_line")
        done < <(grep 'VULNERABLE:' "$NETWORK_RAW" 2>/dev/null | sed 's/^[[:space:]]*//' | sort -u | head -10)
        remediation+=("Review network-raw.log for confirmed CVEs and patch affected systems immediately.")
    fi

    [[ $open_nets   -gt 0 ]] && { score=$((score+25*open_nets));
        findings+=("CRITICAL | $open_nets unencrypted open network(s) — anyone can intercept traffic");
        remediation+=("Enable WPA2 or WPA3 on every access point immediately."); }

    [[ $weak_nets   -gt 0 ]] && { score=$((score+15*weak_nets));
        findings+=("HIGH     | $weak_nets network(s) using WEP/WPA/TKIP — crackable or deprecated");
        remediation+=("Upgrade weak networks to WPA2-AES or WPA3."); }

    [[ $wps_nets    -gt 0 ]] && { score=$((score+12*wps_nets));
        findings+=("HIGH     | $wps_nets network(s) have WPS enabled — PIN brute-force risk (CVE-2011-5053, CVSS 7.8)");
        remediation+=("Disable WPS (especially PIN mode) in each router's wireless settings."); }

    [[ $hidden_nets -gt 0 ]] && { score=$((score+2));
        findings+=("LOW      | $hidden_nets hidden SSID(s) — obscurity is not security"); }

    [[ $SSL_WARNING_COUNT  -gt 0 ]] && { score=$((score+15));
        findings+=("HIGH     | Deprecated SSL/TLS ciphers or protocols on a gateway (e.g. TLS 1.0, RC4, self-signed cert)");
        remediation+=("Update router firmware. If no update is available, consider replacing the router."); }

    [[ $SNMP_WARNING_COUNT -gt 0 ]] && { score=$((score+15));
        findings+=("HIGH     | Gateway responds to SNMP 'public' community — exposes device config info");
        remediation+=("Disable SNMP or change the community string from 'public' in router management."); }

    local telnet_count ftp_count rdp_count smb_count
    telnet_count=$(grep -c 'NmapOpen:.*23/'   "$NETWORK_CSV" 2>/dev/null || echo 0)
    ftp_count=$(   grep -c 'NmapOpen:.*21/'   "$NETWORK_CSV" 2>/dev/null || echo 0)
    rdp_count=$(   grep -c 'NmapOpen:.*3389/' "$NETWORK_CSV" 2>/dev/null || echo 0)
    smb_count=$(   grep -c 'NmapOpen:.*445/'  "$NETWORK_CSV" 2>/dev/null || echo 0)

    [[ $telnet_count -gt 0 ]] && { score=$((score+12));
        findings+=("HIGH     | Telnet (port 23) open on $telnet_count host(s) — credentials sent in plain text");
        remediation+=("Disable Telnet on all devices; use SSH instead."); }

    [[ $ftp_count    -gt 0 ]] && { score=$((score+8));
        findings+=("MEDIUM   | FTP (port 21) open on $ftp_count host(s) — transfers unencrypted");
        remediation+=("Replace FTP with SFTP or FTPS."); }

    [[ $rdp_count    -gt 0 ]] && { score=$((score+20));
        findings+=("HIGH     | RDP (port 3389) exposed on $rdp_count host(s) — brute-force target; BlueKeep class CVEs reach CVSS 9.8");
        remediation+=("Restrict RDP behind VPN or disable if unused. Patch all Windows hosts."); }

    [[ $smb_count    -gt 0 ]] && { score=$((score+20));
        findings+=("HIGH     | SMB (port 445) open on $smb_count host(s) — EternalBlue class CVEs reach CVSS 9.8");
        remediation+=("Apply all Windows/Samba patches. Block port 445 at the firewall for public-facing segments."); }

    local grade label
    if   [[ $score -eq 0   ]]; then grade="A"; label="Secure — no issues found"
    elif [[ $score -le 15  ]]; then grade="B"; label="Good — minor concerns"
    elif [[ $score -le 35  ]]; then grade="C"; label="Moderate risk — review recommended"
    elif [[ $score -le 60  ]]; then grade="D"; label="Significant risk — action needed soon"
    else                             grade="F"; label="Critical — immediate action required"
    fi

    {
        echo "╔══════════════════════════════════════════════════╗"
        echo "║          NETWORK VULNERABILITY REPORT            ║"
        echo "╚══════════════════════════════════════════════════╝"
        printf "  Scan date : %s\n" "$(date '+%Y-%m-%d %H:%M')"
        printf "  Log dir   : %s\n" "$LOG_DIR"
        echo   "──────────────────────────────────────────────────"
        printf "  Risk score: %s / 100+\n" "$score"
        printf "  Grade     : %s  (%s)\n"  "$grade" "$label"
        echo   "──────────────────────────────────────────────────"
        if [[ ${#findings[@]} -eq 0 ]]; then
            echo "  No vulnerabilities found."
        else
            echo "  Issues:"
            for f in "${findings[@]}"; do
                printf "    [%s]\n" "$f"
            done
        fi
        if [[ ${#remediation[@]} -gt 0 ]]; then
            echo ""
            echo "  Recommended actions (in priority order):"
            local i=1
            for r in "${remediation[@]}"; do
                printf "    %d. %s\n" "$i" "$r"
                i=$((i+1))
            done
        fi
        echo "══════════════════════════════════════════════════"
    } | tee "$VULN_REPORT"
}

### ─── SCAN LOOP ─────────────────────────────────────────────────── ###
info "Starting WiFiScan — dwell=${DWELL}s, GPS=$GPS_ENABLED, root=$ROOT, nmap=$HAVE_NMAP, arp-scan=$HAVE_ARPSCAN, nbtscan=$HAVE_NBTSCAN, snmpwalk=$HAVE_SNMPWALK, dnsrecon=$HAVE_DNSRECON"
echo ""

while true; do
    SCAN_COUNT=$((SCAN_COUNT + 1))
    TS_LOOP="$(date +%Y-%m-%dT%H:%M:%S)"
    info "Loop #${SCAN_COUNT} @ ${TS_LOOP}"
    echo "=== Loop #${SCAN_COUNT} @ ${TS_LOOP} ===" >> "$NETWORK_RAW"

    passive_scan
    $AGGRESSIVE_SCAN && active_recon

    if $NOTIFY; then
        termux-notification --id wifiscan --title "WiFiScan running" \
            --content "Loop #${SCAN_COUNT} — $(wc -l < "$SEEN_BSSIDS") APs seen" \
            --ongoing --priority low 2>/dev/null
    fi

    sleep "$LOOP_SLEEP"
    sleep "$DWELL"
done
