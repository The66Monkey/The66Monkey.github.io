#!/usr/bin/env bash
# WiFiScan — Passive Wi-Fi reconnaissance.
# RUN IT BY USING: sudo /path/to/WiFiScan --active (optional)
# WATCH IT RUN: tail -f ~/wifi-logs/wifiscan.out
# STOP the logs after closing by using: sudo kill $(cat ~/wifi-logs/wifiscan.pid)


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
IFACE="wlan1"                      # USB adapter (RTL8812AU) — put into monitor mode
MANAGED_IFACE="wlan0"              # internal adapter — stays managed for connectivity
SSID_FILE="$HOME/Open-Nets.csv"    # pre-configured list of trusted open SSIDs to auto-join
LOG_DIR="$SCRIPT_DIR"              # log to the same folder the script was launched from
SHARED_DIR=""
DWELL=10                           # seconds airodump-ng listens per channel
BAND="both"
GPS_ENABLED=true
QUIET=false
AUTO_CONNECT_OPEN=true
RUN_ACTIVE_RECON=false             # passive-only by default; use --active to enable active recon
AGGRESSIVE_SCAN_INTERVAL=300       # seconds between full nmap port scans on connected network
LOOP_SLEEP=10
FULL_RESCAN_EVERY=10               # full channel sweep every N loops to catch new networks
VENDOR_DB_FILE="$SCRIPT_DIR/mac-vendors.json"
PASSIVE_NOTICE_SHOWN=false
declare -A CH_HITS=()              # AP count per channel; drives adaptive skip
declare -A VENDOR_CACHE=()         # cache OUI/vendor lookups to avoid repeated disk scans
LAST_AGGR_SCAN_TS=0
LAST_AGGR_GW=""
SSL_WARNING_COUNT=0   # incremented per gateway with SSL/TLS issues found
SNMP_WARNING_COUNT=0  # incremented per gateway responding to public SNMP

usage() {
    cat <<EOF
WiFiScan - passive-first Wi-Fi reconnaissance helper

Usage:
  sudo $0 [options]

Options:
  -i IFACE                 Monitor-mode interface (default: $IFACE)
  -m IFACE                 Managed interface for connectivity checks (default: $MANAGED_IFACE)
  -b BAND                  Scan band: 2, 5, both (default: $BAND)
  -d SECONDS               Dwell time per channel (default: $DWELL)
  -l SECONDS               Loop sleep between sweeps (default: $LOOP_SLEEP)
  --active                 Enable active recon on connected network (nmap/arp/snmp/dns)
  --passive                Disable active recon
  --aggressive-interval S  Seconds between aggressive nmap scans (default: $AGGRESSIVE_SCAN_INTERVAL)
  --vendor-db PATH         Path to MAC vendor JSON (default: $VENDOR_DB_FILE)
  --no-autoconnect         Disable auto-connect to discovered open networks
  --no-gps                 Disable GPS logging
  -q, --quiet              Reduce terminal output
  -h, --help               Show this help
EOF
}

USER_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)
            IFACE="$2"; shift 2 ;;
        -m)
            MANAGED_IFACE="$2"; shift 2 ;;
        -b)
            BAND="$2"; shift 2 ;;
        -d)
            DWELL="$2"; shift 2 ;;
        -l)
            LOOP_SLEEP="$2"; shift 2 ;;
        --active)
            RUN_ACTIVE_RECON=true; shift ;;
        --passive)
            RUN_ACTIVE_RECON=false; shift ;;
        --aggressive-interval)
            AGGRESSIVE_SCAN_INTERVAL="$2"; shift 2 ;;
        --vendor-db)
            VENDOR_DB_FILE="$2"; shift 2 ;;
        --no-autoconnect)
            AUTO_CONNECT_OPEN=false; shift ;;
        --no-gps)
            GPS_ENABLED=false; shift ;;
        -q|--quiet)
            QUIET=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1 ;;
    esac
done

### ─── SELF-DAEMONIZE ────────────────────────────────────────────── ###
# Re-exec with nohup+redirect when run directly; WIFISCAN_DAEMON guards against recursion.
if [[ -z "${WIFISCAN_DAEMON:-}" ]]; then
    mkdir -p "$LOG_DIR"
    LOGFILE="$LOG_DIR/wifiscan.out"
    PIDFILE="$LOG_DIR/wifiscan.pid"
    export WIFISCAN_DAEMON=1
    nohup "$0" "${USER_ARGS[@]}" >> "$LOGFILE" 2>&1 &
    disown
    echo $! > "$PIDFILE"
    ok  "WiFiScan started in background  (PID $(cat "$PIDFILE"))"
    info "Log : $LOGFILE"
    info "Stop: kill \$(cat $PIDFILE)"
    trap 'tput cnorm 2>/dev/null; echo; info "Stopped watching (scan still running in background)."; exit 0' INT
    spinner "$(cat "$PIDFILE")"
    exit 0
fi

### ─── CHANNEL LISTS ─────────────────────────────────────────────── ###
CH_2G="1 6 11 2 3 4 5 7 8 9 10 12 13"
CH_5G="36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 149 153 157 161 165"
case "$BAND" in
    2)    CHANNELS="$CH_2G" ;;
    5)    CHANNELS="$CH_5G" ;;
    both) CHANNELS="$CH_2G $CH_5G" ;;
    *)    err "Invalid band '$BAND'. Use 2, 5, or both."; exit 1 ;;
esac

### ─── PREFLIGHT CHECKS ──────────────────────────────────────────── ###
[[ $EUID -ne 0 ]] && { err "Must be run as root (use sudo)."; exit 1; }

# binary → apt package (required tools)
declare -A REQ_PKGS=(
    [iw]="iw"
    [ip]="iproute2"
    [airodump-ng]="aircrack-ng"
    [gpspipe]="gpsd-clients"
    [awk]="gawk"
    [flock]="util-linux"
    [nmcli]="network-manager"
    [nmap]="nmap"
    [timeout]="coreutils"
    [paste]="coreutils"
)

# binary → apt package (optional tools — missing ones are skipped, not fatal)
declare -A OPT_PKGS=(
    [arp-scan]="arp-scan"
    [nbtscan]="nbtscan"
    [snmpwalk]="snmp"
    [dnsrecon]="dnsrecon"
    [wash]="reaver"
    [jq]="jq"
)

_apt_updated=0
_install_pkg() {
    local bin="$1" pkg="$2"
    if [[ $_apt_updated -eq 0 ]]; then
        info "Running apt-get update before installing missing tools..."
        apt-get update -qq 2>/dev/null
        _apt_updated=1
    fi
    info "Installing $pkg (provides $bin)..."
    if apt-get install -y -qq "$pkg" 2>/dev/null; then
        ok "$pkg installed."
    else
        err "Failed to install $pkg — check apt sources."
        return 1
    fi
}

missing_required=0
for bin in "${!REQ_PKGS[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
        _install_pkg "$bin" "${REQ_PKGS[$bin]}" || missing_required=1
    fi
done
[[ $missing_required -ne 0 ]] && { err "One or more required tools could not be installed. Aborting."; exit 1; }

for bin in "${!OPT_PKGS[@]}"; do
    if ! command -v "$bin" &>/dev/null; then
        _install_pkg "$bin" "${OPT_PKGS[$bin]}" \
            || warn "Optional tool '$bin' unavailable — related analysis will be skipped."
    fi
done

iw dev "$IFACE" info &>/dev/null || { err "Interface '$IFACE' not found. Use -i to specify one."; exit 1; }
iw dev "$MANAGED_IFACE" info &>/dev/null || { err "Managed interface '$MANAGED_IFACE' not found. Use -m to specify one."; exit 1; }

### ─── LOG SETUP ─────────────────────────────────────────────────── ###
mkdir -p "$LOG_DIR"
if [[ -z "$SHARED_DIR" ]]; then
    SHARED_DIR="$LOG_DIR/shared"
fi
mkdir -p "$SHARED_DIR"
chmod 755 "$LOG_DIR" "$SHARED_DIR"  # ensure normal users can read logs without sudo
TS=$(date +%Y%m%d_%H%M%S)
LOG_PREFIX="$LOG_DIR/scan-$TS"
SCAN_CSV="$LOG_DIR/.scan_tmp_$$"   # temp dir for per-channel airodump output

# Per-run timestamped files sit under LOG_PREFIX; persistent cross-run files go in LOG_DIR.
SECURITY_LOG="$LOG_PREFIX-security.log"
WPS_LOG="$LOG_PREFIX-wps.log"
HEATMAP_LOG="$LOG_PREFIX-heatmap.csv"
FINGERPRINT_LOG="$LOG_PREFIX-fingerprints.log"
SUMMARY_LOG="$LOG_PREFIX-summary.txt"
VULN_REPORT="$LOG_PREFIX-vuln-report.txt"
SEEN_BSSIDS="${TMPDIR:-/tmp}/wifiscan_seen_$$"
OPEN_SSIDS_LIVE="${TMPDIR:-/tmp}/wifiscan_open_ssids_$$"  # live-discovered open SSIDs for auto-connect
SHARED_EVENTS_FILE="$SHARED_DIR/events.csv"
SHARED_AP_FEED_FILE="$SHARED_DIR/ap-feed.csv"
SHARED_LOCK_FILE="$SHARED_DIR/.lock"
NETWORK_CSV="$LOG_DIR/network-log.csv"
NETWORK_RAW="$LOG_DIR/network-raw.log"
OPEN_NETS_FILE="$LOG_DIR/Open-Nets.csv"

mkdir -p "$SCAN_CSV"
touch "$WPS_LOG" "$FINGERPRINT_LOG" "$SEEN_BSSIDS" "$OPEN_SSIDS_LIVE"

if [ ! -f "$SHARED_EVENTS_FILE" ]; then
    echo "timestamp,source,mode,ssid,bssid,channel,rssi,encryption,vendor,router_model,extra" > "$SHARED_EVENTS_FILE"
fi

if [ ! -f "$SHARED_AP_FEED_FILE" ]; then
    echo "timestamp,source,iface,ssid,bssid,channel,rssi,encryption,vendor" > "$SHARED_AP_FEED_FILE"
fi

if [ ! -f "$NETWORK_CSV" ]; then
    echo "timestamp,mode,ssid,bssid,channel,rssi,encryption,vendor,router_model,extra" > "$NETWORK_CSV"
fi

if [ ! -f "$OPEN_NETS_FILE" ]; then
    echo "timestamp,ssid,bssid,channel,signal_dbm,encryption,security,hidden,vendor,source" > "$OPEN_NETS_FILE"
fi

# CSV headers
echo "BSSID,ESSID,Channel,Signal_dBm,Encryption,Cipher,Auth,Security,Hidden,WPS,Vendor" > "$SECURITY_LOG"
echo "BSSID,ESSID,WPS_Version,WPS_Manufacturer,WPS_Model" > "$WPS_LOG"
echo "Lat,Lon,ESSID,BSSID,Channel,Signal_dBm" > "$HEATMAP_LOG"

### ─── CLEANUP / TRAP ────────────────────────────────────────────── ###
GPS_PID=""
AIRODUMP_PID=""
_CLEANUP_DONE=0
cleanup() {
    [[ $_CLEANUP_DONE -eq 1 ]] && return
    _CLEANUP_DONE=1
    echo ""
    warn "Shutting down..."
    [[ -n "${AIRODUMP_PID:-}" ]] && kill "$AIRODUMP_PID" 2>/dev/null; wait "$AIRODUMP_PID" 2>/dev/null || true
    [[ -n "$GPS_PID" ]] && kill "$GPS_PID" 2>/dev/null && info "GPS logging stopped."
    ip link set "$IFACE" down 2>/dev/null
    iw "$IFACE" set type managed 2>/dev/null
    ip link set "$IFACE" up 2>/dev/null
    ok "Interface $IFACE restored to managed mode."
    rm -rf "$SCAN_CSV" "$SEEN_BSSIDS" "$OPEN_SSIDS_LIVE" "$VENDOR_MAP_TSV"
    generate_summary
    generate_vuln_report
    info "All logs saved under: $LOG_DIR"
}
trap cleanup EXIT INT TERM HUP

### ─── HELPERS ───────────────────────────────────────────────────── ###
VENDOR_MAP_TSV="${TMPDIR:-/tmp}/wifiscan_vendor_map_$$.csv"
VENDOR_SOURCE="system-oui"

# Build a fast local OUI map from mac-vendors.json when available.
init_vendor_db() {
    if [[ ! -s "$VENDOR_DB_FILE" ]]; then
        warn "Vendor DB not found at $VENDOR_DB_FILE; using system OUI fallback."
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq not available; cannot parse $VENDOR_DB_FILE. Using system OUI fallback."
        return 0
    fi

    if jq -r '.[] | select(.macPrefix and .vendorName) | "\(.macPrefix|ascii_upcase|gsub(":";"")),\(.vendorName)"' "$VENDOR_DB_FILE" > "$VENDOR_MAP_TSV" 2>/dev/null; then
        sort -u -o "$VENDOR_MAP_TSV" "$VENDOR_MAP_TSV"
        VENDOR_SOURCE="local-json"
        ok "Loaded local MAC vendor DB: $VENDOR_DB_FILE"
    else
        rm -f "$VENDOR_MAP_TSV"
        warn "Failed to parse $VENDOR_DB_FILE; using system OUI fallback."
    fi
}

# Resolve OUI prefix to vendor name using local JSON map first, then system ieee-data.
lookup_vendor() {
    local mac="$1" prefix vendor oui="/usr/share/ieee-data/oui.txt"
    prefix=$(echo "$mac" | cut -d: -f1-3 | tr '[:lower:]' '[:upper:]' | tr -d ':')
    [[ -z "$prefix" ]] && echo "Unknown" && return

    if [[ -n "${VENDOR_CACHE[$prefix]:-}" ]]; then
        echo "${VENDOR_CACHE[$prefix]}"
        return
    fi

    if [[ -f "$VENDOR_MAP_TSV" ]]; then
        vendor=$(grep -m1 "^${prefix}," "$VENDOR_MAP_TSV" | cut -d, -f2-)
    fi

    if [[ -z "${vendor:-}" && -f "$oui" ]]; then
        vendor=$(grep -i "^$prefix" "$oui" | head -1 | cut -f3- | xargs 2>/dev/null)
    fi

    [[ -z "${vendor:-}" ]] && vendor="Unknown"
    VENDOR_CACHE[$prefix]="$vendor"
    echo "$vendor"
}

# Map Privacy/Cipher fields to a human-readable risk tier.
classify_security() {
    local enc="$1" cipher="$2"
    [[ "$enc" == "OPN"     ]] && echo "OPEN"         && return
    [[ "$enc" == *"WEP"*   ]] && echo "WEAK-WEP"     && return
    [[ "$enc" == *"WPA3"*  ]] && echo "STRONG-WPA3"  && return
    [[ "$enc" == *"WPA2"* && "$cipher" == *"CCMP"* ]] && echo "GOOD-WPA2" && return
    [[ "$enc" == *"WPA2"* && "$cipher" == *"TKIP"* ]] && echo "WEAK-TKIP" && return
    [[ "$enc" == *"WPA"*   ]] && echo "WEAK-WPA"     && return
    echo "UNKNOWN"
}

# Label 2.4 GHz channel overlap quality; 5 GHz channels pass through.
rate_channel() {
    case "$1" in
        1|6|11)             echo "NON-OVERLAPPING" ;;
        2|3|4|5|7|8|9|10)  echo "OVERLAPPING-2G"  ;;
        *)                  echo "5GHz"            ;;
    esac
}

# Return YES if the SSID is blank or an airodump length placeholder.
is_hidden() {
    local e="$1"
    [[ -z "${e// }" || "$e" == "<length:"* ]] && echo "YES" || echo "NO"
}

# Extract the most recent lat,lon fix from the running gpspipe JSONL log.
get_gps_coords() {
    local gps_file="$LOG_PREFIX-gps.jsonl"
    [[ ! -s "$gps_file" ]] && echo "0,0" && return
    local lat lon
    lat=$(grep -o '"lat":[0-9.-]*' "$gps_file" | tail -1 | cut -d: -f2)
    lon=$(grep -o '"lon":[0-9.-]*' "$gps_file" | tail -1 | cut -d: -f2)
    echo "${lat:-0},${lon:-0}"
}

# Double-quote a value and escape internal quotes for safe CSV embedding.
csv_escape() {
    local s="${1:-}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

# flock-protected append so concurrent writes don't corrupt shared files.
shared_append_line() {
    local file="$1"
    local line="$2"
    (
        flock -x 9
        printf "%s\n" "$line" >> "$file"
    ) 9>"$SHARED_LOCK_FILE"
}

# Append one event row (AP or client) to the shared cross-tool events CSV.
log_shared_event() {
    local ts="$1" mode="$2" ssid="$3" bssid="$4" channel="$5" rssi="$6"
    local enc="$7" vendor="$8" router_model="$9" extra="${10}"
    local line
    line="$(csv_escape "$ts"),$(csv_escape "wifiscan"),$(csv_escape "$mode"),$(csv_escape "$ssid"),$(csv_escape "$bssid"),$(csv_escape "$channel"),$(csv_escape "$rssi"),$(csv_escape "$enc"),$(csv_escape "$vendor"),$(csv_escape "$router_model"),$(csv_escape "$extra")"
    shared_append_line "$SHARED_EVENTS_FILE" "$line"
}

# Append one AP row to the shared AP feed used by get_ap_hint_by_ssid.
log_shared_ap() {
    local ts="$1" iface="$2" ssid="$3" bssid="$4" channel="$5" rssi="$6" enc="$7" vendor="$8"
    local line
    line="$(csv_escape "$ts"),$(csv_escape "wifiscan"),$(csv_escape "$iface"),$(csv_escape "$ssid"),$(csv_escape "$bssid"),$(csv_escape "$channel"),$(csv_escape "$rssi"),$(csv_escape "$enc"),$(csv_escape "$vendor")"
    shared_append_line "$SHARED_AP_FEED_FILE" "$line"
}

# Return the SSID that MANAGED_IFACE is currently associated with.
current_ssid() {
    local out
    out="$(iw dev "$MANAGED_IFACE" link 2>/dev/null || true)"
    if echo "$out" | grep -q "Not connected"; then
        echo "<unknown ssid>"
        return
    fi
    echo "$out" | awk -F': ' '/SSID/ {print $2; exit}'
}

try_connect_open() {
    # Candidates: live-discovered open SSIDs first, then pre-configured SSID_FILE
    local -a candidates=()
    if [ -s "$OPEN_SSIDS_LIVE" ]; then
        mapfile -t _live < "$OPEN_SSIDS_LIVE"
        candidates+=("${_live[@]}")
    fi
    if [ -f "$SSID_FILE" ]; then
        mapfile -t _precfg < "$SSID_FILE"
        candidates+=("${_precfg[@]}")
    fi
    [ "${#candidates[@]}" -eq 0 ] && return 0

    nmcli dev wifi rescan ifname "$MANAGED_IFACE" >/dev/null 2>&1 || true
    local lines
    lines="$(timeout 15 nmcli -t --separator '|' -f SSID,SECURITY dev wifi list ifname "$MANAGED_IFACE" 2>/dev/null || true)"

    while IFS='|' read -r ssid sec; do
        [ -z "${ssid// }" ] && continue
        [ "$sec" = "--" ] || [ -z "$sec" ] || continue
        local c
        for c in "${candidates[@]}"; do
            [ "$c" = "$ssid" ] || continue
            nmcli dev disconnect "$MANAGED_IFACE" >/dev/null 2>&1 || true
            if nmcli dev wifi connect "$ssid" ifname "$MANAGED_IFACE" >/dev/null 2>&1; then
                sleep 3
                local now
                now="$(current_ssid)"
                if [ "$now" = "$ssid" ]; then
                    ok "Connected to open network: $ssid"
                    return 0
                fi
            fi
            break
        done
    done <<< "$lines"
    return 0
}

# Look up the strongest passive-scan AP entry matching the given SSID.
get_ap_hint_by_ssid() {
    local target_ssid="$1"
    [ -f "$SHARED_AP_FEED_FILE" ] || return 1

    awk -F',' -v target="$target_ssid" '
        function unq(v) {
            gsub(/^"|"$/, "", v)
            gsub(/""/, "\"", v)
            return v
        }
        NR == 1 { next }
        {
            ssid = unq($4)
            if (ssid != target) {
                next
            }
            bssid = unq($5)
            channel = unq($6)
            rssi = unq($7)
            enc = unq($8)
            vendor = unq($9)
            score = rssi + 0
            if (!found || score > best) {
                best = score
                out = bssid "|" channel "|" enc "|" vendor
                found = 1
            }
        }
        END {
            if (found) {
                print out
            }
        }
    ' "$SHARED_AP_FEED_FILE"
}

# Fingerprint the connected network: gateway, ARP table, nmap, arp-scan, nbtscan, SNMP, DNS.
active_map_connected() {
    local ts ssid my_cidr gw_ip dns_servers ap_hint hint_bssid hint_channel hint_enc hint_vendor
    ts="$(date +%Y-%m-%dT%H:%M:%S)"
    ssid="$(current_ssid)"
    [ -z "$ssid" ] && ssid="<unknown ssid>"
    [ "$ssid" = "<unknown ssid>" ] && return 0

    my_cidr="$(ip -o -4 addr show dev "$MANAGED_IFACE" | awk '{print $4; exit}')"
    gw_ip="$(ip route show default dev "$MANAGED_IFACE" | awk '{print $3; exit}')"
    dns_servers="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd ';' -)"
    ap_hint="$(get_ap_hint_by_ssid "$ssid" || true)"
    hint_bssid=""
    hint_channel=""
    hint_enc=""
    hint_vendor=""

    if [ -n "$ap_hint" ]; then
        IFS='|' read -r hint_bssid hint_channel hint_enc hint_vendor <<< "$ap_hint"
    fi

    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$(csv_escape "$ts")" \
        "$(csv_escape "active")" \
        "$(csv_escape "$ssid")" \
        "$(csv_escape "$hint_bssid")" \
        "$(csv_escape "$hint_channel")" \
        "$(csv_escape "")" \
        "$(csv_escape "$hint_enc")" \
        "$(csv_escape "$hint_vendor")" \
        "$(csv_escape "")" \
        "$(csv_escape "DNS:${dns_servers}")" >> "$NETWORK_CSV"
    log_shared_event "$ts" "active" "$ssid" "$hint_bssid" "$hint_channel" "" "$hint_enc" "$hint_vendor" "" "dns:${dns_servers}"

    if [ -n "${gw_ip:-}" ]; then
        local gw_mac gw_vendor router_fp router_model
        # Resolve gateway MAC/vendor and fingerprint its web/UPnP services.
        gw_mac="$(ip neigh show "$gw_ip" dev "$MANAGED_IFACE" 2>/dev/null | awk '{print $5; exit}')"
        gw_vendor="$(lookup_vendor "${gw_mac:-}")"
        [ -z "$gw_mac" ] && gw_mac="$hint_bssid"
        [ "$gw_vendor" = "Unknown" ] && [ -n "$hint_vendor" ] && gw_vendor="$hint_vendor"

        # vuln category covers Heartbleed, POODLE, EternalBlue etc; ssl-enum-ciphers is not in vuln category so kept explicitly.
        router_fp="$(timeout 120 nmap -Pn -sV --version-light \
            --script=vuln,http-title,http-server-header,upnp-info,ssl-cert,ssl-enum-ciphers \
            -p 53,80,443,1900,5000,8080,8443 "$gw_ip" 2>/dev/null || true)"
        echo "$router_fp" >> "$NETWORK_RAW"

        router_model="$(echo "$router_fp" | awk '
            /upnp-info:/ {flag=1; next}
            flag && NF {gsub(/^[ \t]+/, "", $0); print; exit}
            /Service Info:/ {gsub(/^[ \t]+/, "", $0); print; exit}
            /http-title:/ {gsub(/^[ \t]+/, "", $0); print; exit}
        ')"

        # Warn on anything ssl-enum-ciphers graded below A or flagged as vulnerable.
        local ssl_issues
        ssl_issues="$(echo "$router_fp" | grep -E \
            'VULNERABLE|least strength: [BCDF]|TLSv1\.0|SSLv|RC4|DES|EXPORT|NULL|WEAK|expired|self-signed' \
            | head -10 | tr '\n' '; ')"
        if [ -n "${ssl_issues// }" ]; then
            warn "SSL/TLS issue on gateway $gw_ip: $ssl_issues"
            log_shared_event "$ts" "active" "$ssid" "${gw_mac:-}" "" "" "" "${gw_vendor:-}" "${router_model:-}" "SSL-WARNING:${ssl_issues}"
            SSL_WARNING_COUNT=$((SSL_WARNING_COUNT + 1))
        fi

        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "$(csv_escape "$ts")" \
            "$(csv_escape "active")" \
            "$(csv_escape "$ssid")" \
            "$(csv_escape "${gw_mac:-}")" \
            "$(csv_escape "")" \
            "$(csv_escape "")" \
            "$(csv_escape "")" \
            "$(csv_escape "$gw_vendor")" \
            "$(csv_escape "${router_model:-Unknown}")" \
            "$(csv_escape "Gateway:${gw_ip}")" >> "$NETWORK_CSV"
        log_shared_event "$ts" "active" "$ssid" "$gw_mac" "$hint_channel" "" "$hint_enc" "$gw_vendor" "${router_model:-Unknown}" "gateway:${gw_ip}"
    fi

    # Harvest ARP table entries already visible to the kernel.
    ip neigh show dev "$MANAGED_IFACE" | awk '/..:..:..:..:..:../ {print $1,$5}' | while read -r ip_addr mac_addr; do
        local vendor
        vendor="$(lookup_vendor "$mac_addr")"
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "$(csv_escape "$ts")" \
            "$(csv_escape "active")" \
            "$(csv_escape "$ssid")" \
            "$(csv_escape "$mac_addr")" \
            "$(csv_escape "")" \
            "$(csv_escape "")" \
            "$(csv_escape "")" \
            "$(csv_escape "$vendor")" \
            "$(csv_escape "")" \
            "$(csv_escape "ARP:${ip_addr}")" >> "$NETWORK_CSV"
        log_shared_event "$ts" "active" "$ssid" "$mac_addr" "" "" "" "$vendor" "" "arp:${ip_addr}"
    done

    if [ -n "${my_cidr:-}" ]; then
        local nmap_ping nmap_open now_epoch
        # Ping sweep the subnet; run a full port scan only on interval to reduce noise.
        nmap_ping="$(timeout 30 nmap -sn "$my_cidr" 2>/dev/null || true)"
        echo "$nmap_ping" >> "$NETWORK_RAW"

        echo "$nmap_ping" | awk '
            /Nmap scan report/{ip=$NF}
            /MAC Address:/{mac=$3; sub(/^.*MAC Address: [^ ]+ /, "", $0); gsub(/^\(|\)$/, "", $0); vendor=$0; print ip "|" mac "|" vendor}
        ' | while IFS='|' read -r ip mac vendor; do
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                "$(csv_escape "$ts")" \
                "$(csv_escape "active")" \
                "$(csv_escape "$ssid")" \
                "$(csv_escape "$mac")" \
                "$(csv_escape "")" \
                "$(csv_escape "")" \
                "$(csv_escape "")" \
                "$(csv_escape "$vendor")" \
                "$(csv_escape "")" \
                "$(csv_escape "NmapPing:${ip}")" >> "$NETWORK_CSV"
            log_shared_event "$ts" "active" "$ssid" "$mac" "" "" "" "$vendor" "" "nmap-ping:${ip}"
        done

        now_epoch="$(date +%s)"
        if [ "$gw_ip" != "$LAST_AGGR_GW" ] || [ $((now_epoch - LAST_AGGR_SCAN_TS)) -ge "$AGGRESSIVE_SCAN_INTERVAL" ]; then
            # Scan only live hosts from the ping sweep — far faster than scanning the whole CIDR.
            local live_hosts
            live_hosts="$(echo "$nmap_ping" | awk '/Nmap scan report/{print $NF}' | tr '\n' ' ')"
            if [ -n "${live_hosts// }" ]; then
                # vuln scripts (EternalBlue, BlueKeep, etc.) run only against ports found open.
                nmap_open="$(timeout 300 nmap -T4 --max-retries 1 --open --reason \
                    --script vuln --top-ports 50 $live_hosts 2>/dev/null || true)"
            else
                nmap_open=""
            fi
            echo "$nmap_open" >> "$NETWORK_RAW"

            echo "$nmap_open" | awk '
                /Nmap scan report/{ip=$NF}
                /^[0-9]+\/(tcp|udp)[[:space:]]+open/ {print ip "|" $1 " " $2 " " $3}
            ' | while IFS='|' read -r ip info; do
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                    "$(csv_escape "$ts")" \
                    "$(csv_escape "active")" \
                    "$(csv_escape "$ssid")" \
                    "$(csv_escape "")" \
                    "$(csv_escape "")" \
                    "$(csv_escape "")" \
                    "$(csv_escape "")" \
                    "$(csv_escape "")" \
                    "$(csv_escape "")" \
                    "$(csv_escape "NmapOpen:${ip} ${info}")" >> "$NETWORK_CSV"
                log_shared_event "$ts" "active" "$ssid" "" "" "" "" "" "" "nmap-open:${ip} ${info}"
            done

            LAST_AGGR_SCAN_TS="$now_epoch"
            LAST_AGGR_GW="$gw_ip"
        fi

        # ── arp-scan: fast ARP host discovery ─────────────────────
        if command -v arp-scan &>/dev/null; then
            local arp_out
            arp_out="$(timeout 15 arp-scan -I "$MANAGED_IFACE" --localnet --quiet 2>/dev/null || true)"
            echo "$arp_out" >> "$NETWORK_RAW"
            echo "$arp_out" | awk '/^[0-9]/{print $1 "|" $2 "|" substr($0, index($0,$3))}' \
            | while IFS='|' read -r ip mac vendor; do
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                    "$(csv_escape "$ts")" "$(csv_escape "active")" "$(csv_escape "$ssid")" \
                    "$(csv_escape "$mac")" "$(csv_escape "")" "$(csv_escape "")" \
                    "$(csv_escape "")" "$(csv_escape "$vendor")" "$(csv_escape "")" \
                    "$(csv_escape "ArpScan:${ip}")" >> "$NETWORK_CSV"
                log_shared_event "$ts" "active" "$ssid" "$mac" "" "" "" "$vendor" "" "arp-scan:${ip}"
            done
        fi

        # ── nbtscan: NetBIOS hostnames ─────────────────────────────
        if command -v nbtscan &>/dev/null; then
            local nbts_out
            nbts_out="$(timeout 20 nbtscan -r "$my_cidr" 2>/dev/null || true)"
            echo "$nbts_out" >> "$NETWORK_RAW"
            echo "$nbts_out" | grep -v "^Doing\|^IP\|^-\|^$" \
            | awk 'NF>=2{print $1 "|" $2}' \
            | while IFS='|' read -r ip nbname; do
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                    "$(csv_escape "$ts")" "$(csv_escape "active")" "$(csv_escape "$ssid")" \
                    "$(csv_escape "")" "$(csv_escape "")" "$(csv_escape "")" \
                    "$(csv_escape "")" "$(csv_escape "")" "$(csv_escape "")" \
                    "$(csv_escape "NetBIOS:${ip} name=${nbname}")" >> "$NETWORK_CSV"
                log_shared_event "$ts" "active" "$ssid" "" "" "" "" "" "" "netbios:${ip} name=${nbname}"
            done
        fi
    fi

    # ── snmpwalk: check for public SNMP on the gateway ────────────
    if command -v snmpwalk &>/dev/null && [ -n "${gw_ip:-}" ]; then
        local snmp_out
        snmp_out="$(timeout 10 snmpwalk -v1 -c public -OQ "$gw_ip" system 2>/dev/null | head -20 || true)"
        if [ -n "$snmp_out" ]; then
            echo "=== SNMP $gw_ip ===" >> "$NETWORK_RAW"
            echo "$snmp_out" >> "$NETWORK_RAW"
            local snmp_summary
            snmp_summary="$(echo "$snmp_out" | head -3 | tr '\n' ';')"
            log_shared_event "$ts" "active" "$ssid" "${gw_mac:-}" "" "" "" "${gw_vendor:-}" "" "SNMP-public:${snmp_summary}"
            warn "SNMP public community responding on $gw_ip — potential info disclosure"
            SNMP_WARNING_COUNT=$((SNMP_WARNING_COUNT + 1))
        fi
    fi

    # ── dnsrecon: reverse PTR + basic DNS recon ───────────────────
    if command -v dnsrecon &>/dev/null && [ -n "${my_cidr:-}" ]; then
        local dns_out
        dns_out="$(timeout 30 dnsrecon -t rvl -r "$my_cidr" 2>/dev/null || true)"
        if [ -n "$dns_out" ]; then
            echo "=== dnsrecon $my_cidr ===" >> "$NETWORK_RAW"
            echo "$dns_out" >> "$NETWORK_RAW"
            echo "$dns_out" | grep -oP '\[\+\].*' | while read -r line; do
                log_shared_event "$ts" "active" "$ssid" "" "" "" "" "" "" "dnsrecon:${line}"
            done
        fi
    fi
}

### ─── CSV PROCESSOR ─────────────────────────────────────────────── ###
process_csv() {
    local csv_file="$1"
    [[ ! -f "$csv_file" ]] && return

    # AP section: lines before the "Station MAC" marker
    # airodump-ng CSV columns: BSSID,FirstSeen,LastSeen,channel,Speed,Privacy,Cipher,Auth,Power,Beacons,IV,LAN_IP,IDlen,ESSID,Key[,WPS,WPS_Mfr,WPS_Model...]
    while IFS=',' read -r BSSID _ _ CH _ ENC CIPHER AUTH PWR _ _ _ _ ESSID _ WPS WPS_MFR WPS_MODEL _; do
        BSSID=$(echo "$BSSID" | xargs 2>/dev/null); ESSID=$(echo "$ESSID" | xargs 2>/dev/null)
        ENC=$(echo "$ENC" | xargs 2>/dev/null);     CIPHER=$(echo "$CIPHER" | xargs 2>/dev/null)
        AUTH=$(echo "$AUTH" | xargs 2>/dev/null);   CH=$(echo "$CH" | xargs 2>/dev/null)
        PWR=$(echo "$PWR" | xargs 2>/dev/null);     WPS=$(echo "$WPS" | xargs 2>/dev/null)
        WPS_MFR=$(echo "$WPS_MFR" | xargs 2>/dev/null); WPS_MODEL=$(echo "$WPS_MODEL" | xargs 2>/dev/null)

        [[ -z "$BSSID" ]] && continue
        [[ ! "$BSSID" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && continue
        grep -qxF "$BSSID" "$SEEN_BSSIDS" && continue
        echo "$BSSID" >> "$SEEN_BSSIDS"

        local SEC HIDDEN VENDOR COORDS
        SEC=$(classify_security "$ENC" "$CIPHER")
        HIDDEN=$(is_hidden "$ESSID")
        VENDOR=$(lookup_vendor "$BSSID")
        NOW_TS=$(date +%Y-%m-%dT%H:%M:%S)

        echo "$BSSID,$ESSID,$CH,$PWR,$ENC,$CIPHER,$AUTH,$SEC,$HIDDEN,$WPS,$VENDOR" >> "$SECURITY_LOG"
        if [[ -n "$WPS" ]]; then
            echo "$BSSID,$ESSID,$WPS,$WPS_MFR,$WPS_MODEL" >> "$WPS_LOG"
            ! $QUIET && echo -e "  ${YEL}[WPS]${RST}          ${ESSID:-[hidden]} ($BSSID) WPS:$WPS $WPS_MFR $WPS_MODEL"
        fi
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "$(csv_escape "$NOW_TS")" \
            "$(csv_escape "passive")" \
            "$(csv_escape "${ESSID:-<hidden>}")" \
            "$(csv_escape "$BSSID")" \
            "$(csv_escape "$CH")" \
            "$(csv_escape "$PWR")" \
            "$(csv_escape "$SEC")" \
            "$(csv_escape "$VENDOR")" \
            "$(csv_escape "")" \
            "$(csv_escape "airdump-channel-scan")" >> "$NETWORK_CSV"

        if [ "$SEC" = "OPEN" ]; then
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                "$(csv_escape "$NOW_TS")" \
                "$(csv_escape "${ESSID:-<hidden>}")" \
                "$(csv_escape "$BSSID")" \
                "$(csv_escape "$CH")" \
                "$(csv_escape "$PWR")" \
                "$(csv_escape "$ENC")" \
                "$(csv_escape "$SEC")" \
                "$(csv_escape "$HIDDEN")" \
                "$(csv_escape "$VENDOR")" \
                "$(csv_escape "passive-airdump")" >> "$OPEN_NETS_FILE"
            # Feed discovered open SSID directly into auto-connect pool
            if [ -n "$ESSID" ] && ! grep -qxF "$ESSID" "$OPEN_SSIDS_LIVE" 2>/dev/null; then
                echo "$ESSID" >> "$OPEN_SSIDS_LIVE"
                info "Open network discovered and queued: $ESSID ($BSSID)"
            fi
        fi

        log_shared_ap "$NOW_TS" "$IFACE" "$ESSID" "$BSSID" "$CH" "$PWR" "$SEC" "$VENDOR"
        log_shared_event "$NOW_TS" "passive" "$ESSID" "$BSSID" "$CH" "$PWR" "$SEC" "$VENDOR" "" "airdump-channel-scan"

        if $GPS_ENABLED; then
            COORDS=$(get_gps_coords)
            echo "${COORDS},${ESSID},${BSSID},${CH},${PWR}" >> "$HEATMAP_LOG"
        fi

        if ! $QUIET; then
            local label="${ESSID:-[hidden]}"
            case "$SEC" in
                OPEN)        echo -e "  ${RED}[OPEN]${RST}         $label ($BSSID) CH:$CH ${PWR}dBm  $VENDOR" ;;
                WEAK*)       echo -e "  ${YEL}[$SEC]${RST} $label ($BSSID) CH:$CH ${PWR}dBm  $VENDOR" ;;
                STRONG*)     echo -e "  ${GRN}[$SEC]${RST} $label ($BSSID) CH:$CH ${PWR}dBm  $VENDOR" ;;
                GOOD*)       echo -e "  ${GRN}[$SEC]${RST}   $label ($BSSID) CH:$CH ${PWR}dBm  $VENDOR" ;;
                *)           echo -e "  ${CYN}[$SEC]${RST}     $label ($BSSID) CH:$CH ${PWR}dBm  $VENDOR" ;;
            esac
            [[ "$HIDDEN" == "YES" ]] && echo -e "    ${YEL}^ hidden SSID${RST}"
        fi

    done < <(awk '/^Station MAC/{exit} !/^[[:space:]]*(BSSID|$)/' "$csv_file")

    # Client/probe section: lines after the "Station MAC" header
    while IFS=',' read -r STATION _ _ PWR RATE LOST FRAMES PROBES _; do
        STATION=$(echo "$STATION" | xargs 2>/dev/null)
        [[ -z "$STATION" || "$STATION" == "Station MAC" ]] && continue
        [[ ! "$STATION" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && continue

        PROBES=$(echo "$PROBES" | xargs 2>/dev/null)
        # probes already captured in the line below; no separate probe log needed
        local V
        V=$(lookup_vendor "$STATION")
        echo "MAC=$STATION,VENDOR=$V,PWR=$PWR,RATE=$RATE,FRAMES=$FRAMES,PROBES=$PROBES" >> "$FINGERPRINT_LOG"
        log_shared_event "$(date +%Y-%m-%dT%H:%M:%S)" "passive-client" "$PROBES" "$STATION" "" "$PWR" "" "$V" "" "client-probe"
    done < <(awk '/^Station MAC/{found=1; next} found && !/^[[:space:]]*$/' "$csv_file")
}

### ─── VULNERABILITY REPORT ──────────────────────────────────────── ###
generate_vuln_report() {
    local score=0
    local -a findings=()
    local -a remediation=()

    # ── confirmed vulnerabilities from nmap vuln scripts ──────────
    local confirmed_vulns vuln_score
    confirmed_vulns="$(grep -c 'VULNERABLE:' "$NETWORK_RAW" 2>/dev/null || echo 0)"
    if [[ $confirmed_vulns -gt 0 ]]; then
        vuln_score=$((confirmed_vulns * 25))
        score=$((score + vuln_score))
        findings+=("CRITICAL | $confirmed_vulns confirmed vulnerability/vulnerabilities from nmap --script vuln (see network-raw.log)")
        # List the specific CVEs nmap confirmed.
        while IFS= read -r vuln_line; do
            findings+=("         \\_ $vuln_line")
        done < <(grep 'VULNERABLE:' "$NETWORK_RAW" 2>/dev/null | sed 's/^[[:space:]]*//' | sort -u | head -10)
        remediation+=("Review network-raw.log for confirmed CVEs and patch affected systems immediately.")
    fi

    # ── passive AP findings ────────────────────────────────────────
    local open_count wep_count wpa_count tkip_count wps_count hidden_count
    open_count=$(grep -c  ',OPEN,'       "$SECURITY_LOG" 2>/dev/null || echo 0)
    wep_count=$(grep  -c  ',WEAK-WEP,'  "$SECURITY_LOG" 2>/dev/null || echo 0)
    wpa_count=$(grep  -c  ',WEAK-WPA,'  "$SECURITY_LOG" 2>/dev/null || echo 0)
    tkip_count=$(grep -c  ',WEAK-TKIP,' "$SECURITY_LOG" 2>/dev/null || echo 0)
    wps_count=$(tail -n +2 "$WPS_LOG"   2>/dev/null | grep -c . || echo 0)
    hidden_count=$(grep -c ',YES,'      "$SECURITY_LOG" 2>/dev/null || echo 0)

    [[ $open_count  -gt 0 ]] && { score=$((score+25*open_count));
        findings+=("CRITICAL | $open_count unencrypted open network(s) — anyone can intercept traffic");
        remediation+=("Enable WPA2 or WPA3 on every access point immediately."); }

    [[ $wep_count   -gt 0 ]] && { score=$((score+20*wep_count));
        findings+=("CRITICAL | $wep_count network(s) using WEP — crackable in under 5 minutes");
        remediation+=("Replace WEP with WPA2-AES or WPA3 in each router's wireless settings."); }

    [[ $wpa_count   -gt 0 ]] && { score=$((score+15));
        findings+=("HIGH     | $wpa_count network(s) using WPA (TKIP-only) — deprecated since 2009");
        remediation+=("Upgrade WPA networks to WPA2-AES or WPA3."); }

    [[ $tkip_count  -gt 0 ]] && { score=$((score+10));
        findings+=("MEDIUM   | $tkip_count WPA2 network(s) still offering TKIP cipher — weaker than AES");
        remediation+=("Change cipher from TKIP to AES/CCMP in router wireless security settings."); }

    [[ $wps_count   -gt 0 ]] && { score=$((score+12*wps_count));
        findings+=("HIGH     | $wps_count network(s) have WPS enabled — PIN brute-force (CVE-2011-5053, CVSS 7.8)");
        remediation+=("Disable WPS (especially PIN mode) in each router's wireless settings."); }

    [[ $hidden_count -gt 0 ]] && { score=$((score+2));
        findings+=("LOW      | $hidden_count hidden SSID(s) — obscurity is not security"); }

    # ── active gateway findings ────────────────────────────────────
    [[ $SSL_WARNING_COUNT  -gt 0 ]] && { score=$((score+15));
        findings+=("HIGH     | Deprecated SSL/TLS ciphers or protocols on gateway (e.g. TLS 1.0, RC4, self-signed cert)");
        remediation+=("Update router firmware. If no update is available, consider replacing the router."); }

    [[ $SNMP_WARNING_COUNT -gt 0 ]] && { score=$((score+15));
        findings+=("HIGH     | Gateway responds to SNMP 'public' community — exposes device config info");
        remediation+=("Disable SNMP or change the community string from 'public' in router management."); }

    # ── sensitive open ports on subnet hosts ──────────────────────
    local telnet_count ftp_count rdp_count smb_count
    telnet_count=$(grep -c 'NmapOpen:.*23/' "$NETWORK_CSV" 2>/dev/null || echo 0)
    ftp_count=$(   grep -c 'NmapOpen:.*21/' "$NETWORK_CSV" 2>/dev/null || echo 0)
    rdp_count=$(   grep -c 'NmapOpen:.*3389/' "$NETWORK_CSV" 2>/dev/null || echo 0)
    smb_count=$(   grep -c 'NmapOpen:.*445/' "$NETWORK_CSV" 2>/dev/null || echo 0)

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

    # ── grade ──────────────────────────────────────────────────────
    local grade label
    if   [[ $score -eq 0   ]]; then grade="A"; label="Secure — no issues found"
    elif [[ $score -le 15  ]]; then grade="B"; label="Good — minor concerns"
    elif [[ $score -le 35  ]]; then grade="C"; label="Moderate risk — review recommended"
    elif [[ $score -le 60  ]]; then grade="D"; label="Significant risk — action needed soon"
    else                             grade="F"; label="Critical — immediate action required"
    fi

    # ── write report ───────────────────────────────────────────────
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

### ─── SUMMARY ───────────────────────────────────────────────────── ###
generate_summary() {
    local total_aps open_nets weak_nets strong_nets hidden_nets total_clients
    total_aps=$(tail -n +2 "$SECURITY_LOG" 2>/dev/null | grep -c , || echo 0)
    open_nets=$(grep -c ',OPEN,' "$SECURITY_LOG" 2>/dev/null || echo 0)
    weak_nets=$(grep -c ',WEAK' "$SECURITY_LOG" 2>/dev/null || echo 0)
    strong_nets=$(grep -cE ',(STRONG|GOOD)' "$SECURITY_LOG" 2>/dev/null || echo 0)
    hidden_nets=$(grep -c ',YES,' "$SECURITY_LOG" 2>/dev/null || echo 0)
    total_clients=$(grep -c 'MAC=' "$FINGERPRINT_LOG" 2>/dev/null || echo 0)

    {
        echo "═══════════════════════════════════════════"
        echo "  WiFiScan Summary  —  $TS"
        echo "═══════════════════════════════════════════"
        printf "  %-14s: %s\n" "Interface"   "$IFACE"
        printf "  %-14s: %s\n" "Band"        "$BAND"
        printf "  %-14s: ${DWELL}s per channel\n" "Dwell time"
        printf "  %-14s: %s\n" "GPS"         "$GPS_ENABLED"
        printf "  %-14s: %s\n" "Mode"        "$([ "$RUN_ACTIVE_RECON" = true ] && echo "active+passive" || echo "passive-only")"
        printf "  %-14s: %s\n" "Vendor DB"   "$VENDOR_SOURCE"
        echo "───────────────────────────────────────────"
        printf "  %-14s: %s\n" "APs found"   "$total_aps"
        printf "  %-14s: %s\n" "Clients seen" "$total_clients"
        printf "  %-14s: %s\n" "Open nets"   "$open_nets"
        printf "  %-14s: %s\n" "Weak nets"   "$weak_nets"
        printf "  %-14s: %s\n" "Strong nets" "$strong_nets"
        printf "  %-14s: %s\n" "Hidden SSIDs" "$hidden_nets"
        echo "═══════════════════════════════════════════"
    } | tee "$SUMMARY_LOG"
}

init_vendor_db

### ─── MONITOR MODE ──────────────────────────────────────────────── ###
info "Setting $IFACE to monitor mode..."
ip link set "$IFACE" down
iw "$IFACE" set monitor control
ip link set "$IFACE" up
ok "Monitor mode active on $IFACE"

### ─── GPS ───────────────────────────────────────────────────────── ###
GPS_JSON="$LOG_PREFIX-gps.jsonl"
if $GPS_ENABLED; then
    info "Checking GPS (gpsd)..."
    if pgrep gpsd >/dev/null 2>&1; then
        gpspipe -w > "$GPS_JSON" &
        GPS_PID=$!
        ok "GPS logging started (PID $GPS_PID)"
        sleep 1   # let gpspipe collect an initial fix
    else
        warn "gpsd not running — GPS disabled. Start with: gpsd /dev/ttyUSB0 -F /var/run/gpsd.sock"
        GPS_ENABLED=false
    fi
fi

### ─── SCAN LOOP ─────────────────────────────────────────────────── ###
SCAN_COUNT=0
info "Starting scan — band=$BAND, dwell=${DWELL}s/ch. Running in background."
echo ""

while true; do
    SCAN_COUNT=$((SCAN_COUNT + 1))
    TS_LOOP="$(date +%Y-%m-%dT%H:%M:%S)"

    if [ "$AUTO_CONNECT_OPEN" = true ]; then
        CUR_SSID="$(current_ssid)"
        # Attempt to join a known/discovered open network when unassociated.
        if [ "$CUR_SSID" = "<unknown ssid>" ]; then
            try_connect_open
        fi
    fi

    info "WiFiScan/Watcher loop #${SCAN_COUNT} @ ${TS_LOOP}"
    echo "=== Loop #${SCAN_COUNT} @ ${TS_LOOP} ===" >> "$NETWORK_RAW"

    for CH in $CHANNELS; do
        # Skip cold channels between full sweeps — focus dwell time where APs are found
        if [[ $SCAN_COUNT -gt 1 && $((SCAN_COUNT % FULL_RESCAN_EVERY)) -ne 0 && ${CH_HITS[$CH]:-0} -eq 0 ]]; then
            continue
        fi

        info "Channel $CH (hits: ${CH_HITS[$CH]:-0})..."
        iw dev "$IFACE" set channel "$CH" 2>/dev/null || { warn "Cannot set channel $CH — skipping."; continue; }

        rm -f "$SCAN_CSV/ch-${CH}"-* 2>/dev/null
        timeout "$DWELL" airodump-ng \
            --channel "$CH" \
            --write "$SCAN_CSV/ch-$CH" \
            --output-format csv \
            --write-interval 5 \
            --wps \
            "$IFACE" &>/dev/null &
        AIRODUMP_PID=$!
        wait "$AIRODUMP_PID" 2>/dev/null || true
        AIRODUMP_PID=""

        _before=$(wc -l < "$SEEN_BSSIDS")
        process_csv "$SCAN_CSV/ch-${CH}-01.csv"
        _after=$(wc -l < "$SEEN_BSSIDS")
        CH_HITS[$CH]=$(( ${CH_HITS[$CH]:-0} + _after - _before ))
    done

    if [ "$RUN_ACTIVE_RECON" = true ]; then
        active_map_connected
    elif [ "$PASSIVE_NOTICE_SHOWN" = false ]; then
        info "Passive-only mode enabled. Use --active to include network probing."
        PASSIVE_NOTICE_SHOWN=true
    fi

    sleep "$LOOP_SLEEP"
done
