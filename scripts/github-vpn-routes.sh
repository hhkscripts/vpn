#!/bin/bash
# Seed GitHub's published IPv4 ranges into the GoodWifi host-VPN ipset.
#
# The dispatcher policy marks this ipset and routes marked Pi-host traffic
# through table 100/tun0. This avoids adding one iptables rule per GitHub CIDR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load optional config override
# shellcheck source=/dev/null
[ -f /etc/goodwifi/goodwifi.conf ] && . /etc/goodwifi/goodwifi.conf
VPN_BACKEND="${VPN_BACKEND:-auto}"

if [ -z "${VPN_IF:-}" ]; then
    if [ "$VPN_BACKEND" = "awg0" ]; then
        VPN_IF="awg0"
    elif [ "$VPN_BACKEND" = "wg0" ]; then
        VPN_IF="wg0"
    elif [ "$VPN_BACKEND" = "tun0" ]; then
        VPN_IF="tun0"
    elif ip -4 addr show awg0 2>/dev/null | grep -q "inet "; then
        VPN_IF="awg0"
    elif ip -4 addr show wg0 2>/dev/null | grep -q "inet "; then
        VPN_IF="wg0"
    else
        VPN_IF="tun0"
    fi
fi
VPN_ROUTES_IPSET="${VPN_ROUTES_IPSET:-${GITHUB_IPSET:-vpn_routes}}"
GITHUB_IPSET="$VPN_ROUTES_IPSET"
META_URL="${GITHUB_META_URL:-https://api.github.com/meta}"
FORCE_REFRESH="${GITHUB_ROUTES_FORCE_REFRESH:-0}"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

if [ -z "${GITHUB_PRESEEDED_RANGES:-}" ]; then
    if [ -f "$PROJECT_DIR/configs/github-ipv4-ranges.txt" ]; then
        PRESEEDED_RANGES="$PROJECT_DIR/configs/github-ipv4-ranges.txt"
    elif [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/configs/github-ipv4-ranges.txt" ]; then
        PRESEEDED_RANGES="$REPO_ROOT/configs/github-ipv4-ranges.txt"
    elif [ -f "/etc/goodwifi/github-ipv4-ranges.txt" ]; then
        PRESEEDED_RANGES="/etc/goodwifi/github-ipv4-ranges.txt"
    else
        PRESEEDED_RANGES=""
    fi
else
    PRESEEDED_RANGES="$GITHUB_PRESEEDED_RANGES"
fi

log() {
    printf '%s\n' "$1"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "Missing required command: $1"
        exit 1
    fi
}

require_cmd curl
require_cmd ip
require_cmd ipset
require_cmd python3

if [ "$(id -u)" -ne 0 ]; then
    log "Run as root: sudo $0"
    exit 1
fi

ipset create "$GITHUB_IPSET" hash:net family inet maxelem 131072 2>/dev/null || true
if [ "$GITHUB_IPSET" != "github_vpn_routes" ] && ipset list github_vpn_routes >/dev/null 2>&1; then
    ipset flush github_vpn_routes 2>/dev/null || true
    ipset destroy github_vpn_routes 2>/dev/null || true
fi

existing_count=0
if ipset list "$GITHUB_IPSET" >/dev/null 2>&1; then
    existing_count="$(ipset list "$GITHUB_IPSET" -terse | awk '/Number of entries:/ {print $4; exit}')"
    existing_count="${existing_count:-0}"
fi

# If ipset is currently empty, quickly load pre-seeded local ranges first
if [ "$existing_count" -eq 0 ] && [ -n "$PRESEEDED_RANGES" ] && [ -s "$PRESEEDED_RANGES" ]; then
    log "Loading pre-seeded GitHub IPv4 ranges from $PRESEEDED_RANGES..."
    sed -e "s|^|add $GITHUB_IPSET |" -e 's|$| -exist|' "$PRESEEDED_RANGES" | ipset restore
    existing_count="$(wc -l < "$PRESEEDED_RANGES" | tr -d ' ')" 
    log "Loaded $existing_count pre-seeded GitHub IPv4 ranges into '$GITHUB_IPSET'."
fi

if [ "$existing_count" -gt 0 ] && [ "$FORCE_REFRESH" != "1" ]; then
    log "Keeping existing GitHub IPv4 ranges ($existing_count entries)."
    log "Use GITHUB_ROUTES_FORCE_REFRESH=1 to download fresh ranges."
    if [ -x "$SCRIPT_DIR/apply-routes.sh" ]; then
        "$SCRIPT_DIR/apply-routes.sh"
    elif [ -x "/usr/local/bin/apply-routes.sh" ]; then
        /usr/local/bin/apply-routes.sh
    fi
    exit 0
fi

if ! ip link show "$VPN_IF" >/dev/null 2>&1; then
    if [ "$existing_count" -gt 0 ]; then
        log "Interface '$VPN_IF' not ready for refresh; keeping $existing_count existing ranges."
        if [ -x "$SCRIPT_DIR/apply-routes.sh" ]; then
            "$SCRIPT_DIR/apply-routes.sh"
        elif [ -x "/usr/local/bin/apply-routes.sh" ]; then
            /usr/local/bin/apply-routes.sh
        fi
        exit 0
    fi
    log "Interface '$VPN_IF' is not available. Connect VPN first."
    exit 1
fi

tmp_json="$(mktemp)"
tmp_ranges="$(mktemp)"
trap 'rm -f "$tmp_json" "$tmp_ranges"' EXIT

log "Fetching GitHub meta ranges through $VPN_IF..."
if ! curl -fsS --interface "$VPN_IF" --connect-timeout 10 --max-time 60 \
    --retry 3 --retry-delay 2 --retry-all-errors "$META_URL" -o "$tmp_json"; then
    if [ "$existing_count" -gt 0 ]; then
        log "Download failed, but keeping existing/pre-seeded $existing_count ranges."
        if [ -x "$SCRIPT_DIR/apply-routes.sh" ]; then
            "$SCRIPT_DIR/apply-routes.sh"
        elif [ -x "/usr/local/bin/apply-routes.sh" ]; then
            /usr/local/bin/apply-routes.sh
        fi
        exit 0
    fi
    log "Failed to download GitHub ranges and no local cache available."
    exit 1
fi

python3 - "$tmp_json" > "$tmp_ranges" <<'PY'
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as meta_file:
    meta = json.load(meta_file)

keys = ("hooks", "web", "api", "git", "packages", "actions")
ranges = set()
for key in keys:
    for value in meta.get(key, []):
        try:
            network = ipaddress.ip_network(value, strict=False)
        except ValueError:
            continue
        if network.version == 4:
            ranges.add(str(network))

# Debian / Fastly package mirror ranges to ensure apt update/upgrade bypasses local blocks
for extra in ("151.101.0.0/16", "199.232.0.0/16"):
    ranges.add(extra)

for value in sorted(ranges, key=lambda item: ipaddress.ip_network(item)):
    print(value)
PY

if [ ! -s "$tmp_ranges" ]; then
    log "No GitHub IPv4 ranges found in meta response."
    if [ "$existing_count" -gt 0 ]; then
        exit 0
    fi
    exit 1
fi

ipset flush "$GITHUB_IPSET"

sed -e "s|^|add $GITHUB_IPSET |" -e 's|$| -exist|' "$tmp_ranges" | ipset restore
added_count="$(wc -l < "$tmp_ranges" | tr -d ' ')" 

log "Loaded $added_count GitHub IPv4 ranges into ipset '$GITHUB_IPSET'."

# Save back to pre-seeded local file if writable
if [ -n "$PRESEEDED_RANGES" ] && [ -w "$PRESEEDED_RANGES" ]; then
    cp "$tmp_ranges" "$PRESEEDED_RANGES" 2>/dev/null || true
fi
if [ -f "$PROJECT_DIR/configs/github-ipv4-ranges.txt" ] && [ -w "$PROJECT_DIR/configs/github-ipv4-ranges.txt" ] && [ "$PRESEEDED_RANGES" != "$PROJECT_DIR/configs/github-ipv4-ranges.txt" ]; then
    cp "$tmp_ranges" "$PROJECT_DIR/configs/github-ipv4-ranges.txt" 2>/dev/null || true
elif [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/configs/github-ipv4-ranges.txt" ] && [ -w "$REPO_ROOT/configs/github-ipv4-ranges.txt" ] && [ "$PRESEEDED_RANGES" != "$REPO_ROOT/configs/github-ipv4-ranges.txt" ]; then
    cp "$tmp_ranges" "$REPO_ROOT/configs/github-ipv4-ranges.txt" 2>/dev/null || true
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    log "Saved netfilter state."
else
    log "netfilter-persistent not found; rules are active until reboot."
fi

# Apply modular route definitions (crypto, banking, streaming, Bybit, Debian mirrors)
if [ -x "$SCRIPT_DIR/apply-routes.sh" ]; then
    "$SCRIPT_DIR/apply-routes.sh"
elif [ -x "/usr/local/bin/apply-routes.sh" ]; then
    /usr/local/bin/apply-routes.sh
fi

log "Verify:"
log "  sudo ipset list $GITHUB_IPSET"
log "  ip route get 140.82.112.4 mark 100"
