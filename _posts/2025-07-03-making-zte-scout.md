---
layout: post
title: "ZTE_Scout: Field Recon from a Locked Core"
date: 2025-07-03
categories: [projects, tools, hardware, termux, security]
tags: [ZTE_Scout, Axon7, automation, hardware, scripting, wifi]
---

## Introduction

Mapping Wi-Fi networks on a non-rooted Android device can feel like a dead end—until you discover Termux.
Introdusing the **ZTE_Scout**, a low-profile recon asset built on a locked-down ZTE Axon 7.
In this post we’ll unpack two companion scripts, **wifi-map.sh** and **wifi-scout.sh**, that turn a ZTE Axon 7 into a portable scout device and Wi-Fi reconnaissance toolkit. You’ll learn how each script works, how they collect GPS‐tagged scans and network data, and how to deploy them over ADB on a stock (but debloated) device.

---

## 🧰 Base Platform

- **Device**: ZTE Axon 7
- **Bootloader**: Locked, no root or custom recovery (fuck you very much ZTE!)  
- **OS**: Stock Android 8.0
- **Access**: ADB over USB  

---
## Prerequisites

Before you begin, ensure the following are in place:

- A ZTE Axon 7 running Android with Termux, Termux:API and Termux:Widget installed 
- USB debugging enabled and ADB accessible on your Debian host  
- Termux packages:  
  - `termux-wifi-scaninfo` / `termux-wifi-connectioninfo`  
  - `termux-location`  
  - `jq`, `timeout`, `ip`, `arp`, `awk`, `grep`, `cut`  
- (Optional) `nmap` installed in Termux for subnet ARP scanning  
- A writable directory on shared storage (e.g. `/sdcard/logs`)  

---

## Script 1: wifi-map.sh  

### Purpose  
Passive “warwalking” scan: tag every beacon frame with GPS coordinates and log SSID, BSSID, channel and encryption.

### Key Sections  

1. **Dependency Check**  
   ```bash
   for cmd in termux-wifi-scaninfo jq timeout termux-location; do
     command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
   done
   ```  
2. **Log Initialization**  
   - Creates `/sdcard/logs`  
   - Filename includes timestamp: `wifi-map-YYYYMMDD_HHMMSS.log`  
3. **Frequency→Channel Helper**  
   Converts 2.4 GHz & 5 GHz frequencies into channel numbers.  
4. **GPS Snapshot**  
   Requests one‐off GPS fix (5 s timeout). If available, extracts latitude, longitude and accuracy via `jq`.  
5. **Passive Scan**  
   - Runs `termux-wifi-scaninfo` (10 s timeout)  
   - Parses JSON with `jq` into TSV lines  
   - For each network:  
     - Derives channel  
     - Extracts encryption (WPA3/WPA2/WPA/WEP) or marks as OPEN  
     - Formats output into a nicely aligned string  

### Sample Output Line  
```
MyNetworkSSID               12:34:56:78:9A:BC CH:11 RSSI:-67  WPA2/WPA3
```

---

## Script 2: wifi-scout.sh  

### Purpose  
Active reconnaissance on the currently connected AP: GPS tag + connection details + local host and subnet discovery.

### Key Sections  

1. **Dependency Check**  
   Includes `termux-wifi-connectioninfo`, `ip`, `arp`, `nmap` (optional), etc.  
2. **Report Header & GPS**  
   Similar 10 s GPS snapshot block as in wifi-map.sh.  
3. **Connection Info**  
   Uses `termux-wifi-connectioninfo` to capture SSID, BSSID, IP, link speed, frequency and RSSI.  
4. **DNS Servers**  
   Extracts DNS entries via `getprop | grep dns`.  
5. **ARP Cache**  
   Dumps `ip neigh show` to list local neighbors.  
6. **Subnet Sweep—Ping Scan**  
   - Derives subnet from IP’s first three octets  
   - Fires simultaneous 1 s pings to `.1–.254` and logs “X.X.X.Y is up”  
7. **Subnet Sweep—Nmap**  
   If `nmap` is present, runs an ARP‐ping scan on `X.X.X.0/24` with a 45 s timeout.  
8. **MAC Vendor Lookup**  
   Reads `/proc/net/arp`, extracts each MAC, finds OUI vendor in `~/storage/shared/oui.txt`.

---

## Deploying

Just push the files to the device with something like

```bash
adb push wifi-map.sh /storage/scripts/wifi-map.sh

then copy from the scripts folder on the device with Termux to the Termux-Widget folder.
cp -f ./* ~/.shortcuts/

you might also have to make it executable
chmod +x (filename)
---

## Viewing Your Logs

All logs land in `/sdcard/logs`. You can pull them down for analysis:

```bash
adb pull /sdcard/logs ~/axonscout-logs
```

Open the `.log` files in your favorite editor or import into mapping software.

---

## Conclusion

With these scripts, your unrooted ZTE Axon 7 becomes a complete scouting and network-recon platform. You get:

- GPS-anchored passive scans  
- Live‐connection details and subnet exploration  
- Offline MAC vendor lookups  

Take this further by:

- Integrating log files into web maps (Leaflet, QGIS)  
- Automatically triggering scans on motion detection  
- Adding real‐time dashboard with Termux:API and a lightweight web server  

Every step is in Bash, so customize as you see fit. Happy scouting!


### wifi-map.sh
<pre><code>
#!/data/data/com.termux/files/usr/bin/bash

# wifi-map.sh — Passive scan with GPS tagging (for warwalking use)

# Dependencies check
for cmd in termux-wifi-scaninfo jq timeout termux-location; do
  command -v "$cmd" >/dev/null || {
    echo "Missing: $cmd" >&2
    exit 1
  }
done

# Log directory
LOG_DIR="/sdcard/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/wifi-map-$(date +%Y%m%d_%H%M%S).log"

# Channel helper
freq_to_channel() {
  local f=$1
  if [ "$f" -ge 2412 ] && [ "$f" -le 2484 ]; then echo $(( (f - 2407) / 5 ))
  elif [ "$f" -ge 5170 ] && [ "$f" -le 5825 ]; then echo $(( (f - 5000) / 5 ))
  else echo "?"; fi
}

# Get GPS snapshot
GPS=$(timeout 10 termux-location --provider gps --request once 2>/dev/null)
if [ -n "$GPS" ]; then
  LAT=$(echo "$GPS" | jq -r '.latitude')
  LON=$(echo "$GPS" | jq -r '.longitude')
  ACC=$(echo "$GPS" | jq -r '.accuracy')
  echo "GPS: lat=$LAT lon=$LON acc=${ACC}m" > "$LOG_FILE"
else
  echo "GPS: unavailable or timed out" > "$LOG_FILE"
fi

# Run scan with timeout
SCAN_JSON=$(timeout 10 termux-wifi-scaninfo 2>/dev/null)

# Handle timeout or empty result
if [ -z "$SCAN_JSON" ] || [ "$SCAN_JSON" = "[]" ]; then
  echo "Scan failed or returned no data. Check permissions or location services." >> "$LOG_FILE"
  exit 1
fi

# Parse and log results
echo "$SCAN_JSON" | jq -r '.[] | 
  {
    ssid: .SSID,
    bssid: .BSSID,
    freq: .frequency,
    level: .level,
    caps: .capabilities
  } | 
  [.ssid, .bssid, (.freq|tostring), (.level|tostring), .caps] | 
  @tsv' | while IFS=$'\t' read -r SSID BSSID FREQ RSSI CAPS; do
  CHAN=$(freq_to_channel "$FREQ")
  ENC=$(echo "$CAPS" | grep -Eo "WPA3|WPA2|WPA|WEP" | tr '\n' '/' | sed 's|/$||')
  [ -z "$ENC" ] && ENC="OPEN"
  printf "%-30s %-18s CH:%-2s RSSI:%-4s %s\n" "$SSID" "$BSSID" "$CHAN" "$RSSI" "$ENC"
done >> "$LOG_FILE"
</code></pre>

##  wifi-scout.sh
<pre><code>
#!/data/data/com.termux/files/usr/bin/bash

# wifi-map.sh — Passive scan with GPS tagging (for warwalking use)

# Dependencies check
for cmd in termux-wifi-scaninfo jq timeout termux-location; do
  command -v "$cmd" >/dev/null || {
    echo "Missing: $cmd" >&2
    exit 1
  }
done

# Log directory
LOG_DIR="/sdcard/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/wifi-map-$(date +%Y%m%d_%H%M%S).log"

# Channel helper
freq_to_channel() {
  local f=$1
  if [ "$f" -ge 2412 ] && [ "$f" -le 2484 ]; then echo $(( (f - 2407) / 5 ))
  elif [ "$f" -ge 5170 ] && [ "$f" -le 5825 ]; then echo $(( (f - 5000) / 5 ))
  else echo "?"; fi
}

# Get GPS snapshot
GPS=$(timeout 5 termux-location --provider gps --request once 2>/dev/null)
if [ -n "$GPS" ]; then
  LAT=$(echo "$GPS" | jq -r '.latitude')
  LON=$(echo "$GPS" | jq -r '.longitude')
  ACC=$(echo "$GPS" | jq -r '.accuracy')
  echo "GPS: lat=$LAT lon=$LON acc=${ACC}m" > "$LOG_FILE"
else
  echo "GPS: unavailable or timed out" > "$LOG_FILE"
fi

# Run scan with timeout
SCAN_JSON=$(timeout 10 termux-wifi-scaninfo 2>/dev/null)

# Handle timeout or empty result
if [ -z "$SCAN_JSON" ] || [ "$SCAN_JSON" = "[]" ]; then
  echo "Scan failed or returned no data. Check permissions or location services." >> "$LOG_FILE"
  exit 1
fi

# Parse and log results
echo "$SCAN_JSON" | jq -r '.[] | 
  {
    ssid: .SSID,
    bssid: .BSSID,
    freq: .frequency,
    level: .level,
    caps: .capabilities
  } | 
  [.ssid, .bssid, (.freq|tostring), (.level|tostring), .caps] | 
  @tsv' | while IFS=$'\t' read -r SSID BSSID FREQ RSSI CAPS; do
  CHAN=$(freq_to_channel "$FREQ")
  ENC=$(echo "$CAPS" | grep -Eo "WPA3|WPA2|WPA|WEP" | tr '\n' '/' | sed 's|/$||')
  [ -z "$ENC" ] && ENC="OPEN"
  printf "%-30s %-18s CH:%-2s RSSI:%-4s %s\n" "$SSID" "$BSSID" "$CHAN" "$RSSI" "$ENC"
done >> "$LOG_FILE"

</code></pre>
