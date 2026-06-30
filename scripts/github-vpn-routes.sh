#!/bin/bash
# Seed GitHub's published IPv4 ranges into the GoodWifi host-VPN ipset.
#
# The dispatcher policy marks this ipset and routes marked Pi-host traffic
# through table 100/tun0. This avoids adding one iptables rule per GitHub CIDR.

set -euo pipefail

VPN_IF="${VPN_IF:-tun0}"
GITHUB_IPSET="${GITHUB_IPSET:-github_vpn_routes}"
POLICY_SCRIPT="${POLICY_SCRIPT:-/etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy}"
META_URL="${GITHUB_META_URL:-https://api.github.com/meta}"

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

if ! ip link show "$VPN_IF" >/dev/null 2>&1; then
    log "Interface '$VPN_IF' is not available. Connect VPN first."
    exit 1
fi

if [ -x "$POLICY_SCRIPT" ]; then
    "$POLICY_SCRIPT" "$VPN_IF" up
fi

tmp_json="$(mktemp)"
tmp_ranges="$(mktemp)"
trap 'rm -f "$tmp_json" "$tmp_ranges"' EXIT

log "Fetching GitHub meta ranges through $VPN_IF..."
curl -fsS --interface "$VPN_IF" --max-time 20 "$META_URL" -o "$tmp_json"

python3 - "$tmp_json" > "$tmp_ranges" <<'PY'
import ipaddress
import json
import sys

with open(sys.argv[1], encoding="utf-8") as meta_file:
    meta = json.load(meta_file)

keys = ("hooks", "web", "api", "git", "packages")
ranges = set()
for key in keys:
    for value in meta.get(key, []):
        try:
            network = ipaddress.ip_network(value, strict=False)
        except ValueError:
            continue
        if network.version == 4:
            ranges.add(str(network))

for value in sorted(ranges, key=lambda item: ipaddress.ip_network(item)):
    print(value)
PY

if [ ! -s "$tmp_ranges" ]; then
    log "No GitHub IPv4 ranges found in meta response."
    exit 1
fi

ipset create "$GITHUB_IPSET" hash:net family inet 2>/dev/null || true
ipset flush "$GITHUB_IPSET"

added_count=0
while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    ipset add "$GITHUB_IPSET" "$cidr" -exist
    added_count=$((added_count + 1))
done < "$tmp_ranges"

log "Loaded $added_count GitHub IPv4 ranges into ipset '$GITHUB_IPSET'."

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    log "Saved netfilter state."
else
    log "netfilter-persistent not found; rules are active until reboot."
fi

log "Verify:"
log "  sudo ipset list $GITHUB_IPSET"
log "  ip route get 140.82.112.4 mark 100"
