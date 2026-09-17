#!/bin/sh
# Keep Pi host traffic on eth0 while routing hotspot clients through the VPN.

# Load optional config override if present
# shellcheck source=/dev/null
[ -f /etc/goodwifi/goodwifi.conf ] && . /etc/goodwifi/goodwifi.conf
VPN_BACKEND="${VPN_BACKEND:-auto}"

HOTSPOT_IF="${HOTSPOT_IF:-wlan0}"
HOTSPOT_SUBNET="${HOTSPOT_SUBNET:-10.42.0.0/24}"
HOTSPOT_IP="${HOTSPOT_IP:-10.42.0.1}"
LAN_IF="${LAN_IF:-eth0}"
LAN_GW_OVERRIDE="${LAN_GW:-}"
TABLE_ID="${TABLE_ID:-100}"
RULE_PRIORITY="${RULE_PRIORITY:-1000}"
HOST_RULE_PRIORITY="${HOST_RULE_PRIORITY:-999}"
BYPASS_RULE_PRIORITY="${BYPASS_RULE_PRIORITY:-998}"
MANAGEMENT_RULE_PRIORITY="${MANAGEMENT_RULE_PRIORITY:-997}"
FWMARK="${FWMARK:-100}"
BYPASS_FWMARK="${BYPASS_FWMARK:-101}"
VPN_IPSET="${VPN_IPSET:-vpn_domains}"
VPN_ROUTES_IPSET="${VPN_ROUTES_IPSET:-${GITHUB_IPSET:-vpn_routes}}"
LOCAL_ROUTES_IPSET="${LOCAL_ROUTES_IPSET:-${LOCAL_BYPASS_IPSET:-local_routes}}"
GITHUB_IPSET="$VPN_ROUTES_IPSET"
LOCAL_BYPASS_IPSET="$LOCAL_ROUTES_IPSET"
LEGACY_GITHUB_IPSET="github_vpn_routes"
LEGACY_LOCAL_IPSET="local_bypass_domains"
IPTABLES_CHAIN="${IPTABLES_CHAIN:-GOODWIFI_FORWARD}"
IP6TABLES_CHAIN="${IP6TABLES_CHAIN:-GOODWIFI6_FORWARD}"
MANAGEMENT_SUBNETS="${MANAGEMENT_SUBNETS:-10.8.0.0/24 192.168.100.0/24 192.168.1.0/24}"
IPV6_LEAK_PROTECTION="${IPV6_LEAK_PROTECTION:-drop}"

# Determine VPN_IF dynamically or from argument
if [ -n "$1" ] && [ "$1" != "apply" ] && [ "$1" != "cleanup" ] && [ "$1" != "up" ] && [ "$1" != "down" ] && [ "$1" != "vpn-up" ] && [ "$1" != "vpn-down" ] && [ "$1" != "connectivity-change" ]; then
    VPN_IF="$1"
elif [ "$VPN_BACKEND" = "awg0" ]; then
    VPN_IF="awg0"
elif [ "$VPN_BACKEND" = "wg0" ]; then
    VPN_IF="wg0"
elif [ "$VPN_BACKEND" = "tun0" ]; then
    VPN_IF="tun0"
else
    # auto mode: prioritize active interfaces with an IPv4 address
    if ip -4 addr show awg0 2>/dev/null | grep -q "inet "; then
        VPN_IF="awg0"
    elif ip -4 addr show wg0 2>/dev/null | grep -q "inet "; then
        VPN_IF="wg0"
    elif ip -4 addr show tun0 2>/dev/null | grep -q "inet "; then
        VPN_IF="tun0"
    elif ip link show awg0 >/dev/null 2>&1; then
        VPN_IF="awg0"
    elif ip link show wg0 >/dev/null 2>&1; then
        VPN_IF="wg0"
    else
        VPN_IF="tun0"
    fi
fi

VPN_MTU="${VPN_MTU:-1400}"

mkdir -p /run/lock
exec 9>/run/lock/goodwifi-vpn-policy.lock
if ! flock -w 60 9; then
    echo "Timed out waiting for the GoodWifi VPN policy lock" >&2
    exit 1
fi

remove_rule() {
    table="$1"
    shift

    if [ "$table" = "filter" ]; then
        while iptables -C "$@" 2>/dev/null; do
            iptables -D "$@"
        done
    else
        while iptables -t "$table" -C "$@" 2>/dev/null; do
            iptables -t "$table" -D "$@"
        done
    fi
}

remove_ip6_rule() {
    while ip6tables -C "$@" 2>/dev/null; do
        ip6tables -D "$@"
    done
}

ensure_filter_chain() {
    chain="$1"
    iptables -N "$chain" 2>/dev/null || true
    iptables -F "$chain"
    iptables -C FORWARD -j "$chain" 2>/dev/null || iptables -I FORWARD 1 -j "$chain"
}

remove_filter_chain() {
    chain="$1"
    remove_rule filter FORWARD -j "$chain"
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
}

ensure_ip6_filter_chain() {
    chain="$1"
    ip6tables -N "$chain" 2>/dev/null || true
    ip6tables -F "$chain"
    ip6tables -C FORWARD -j "$chain" 2>/dev/null || ip6tables -I FORWARD 1 -j "$chain"
}

remove_ip6_filter_chain() {
    chain="$1"
    remove_ip6_rule FORWARD -j "$chain"
    ip6tables -F "$chain" 2>/dev/null || true
    ip6tables -X "$chain" 2>/dev/null || true
}

detect_lan_gw() {
    if [ -n "$LAN_GW_OVERRIDE" ]; then
        printf '%s\n' "$LAN_GW_OVERRIDE"
        return
    fi

    ip -4 route show default dev "$LAN_IF" 2>/dev/null | awk '/ via / {print $3; exit}'
    nmcli -g IP4.GATEWAY device show "$LAN_IF" 2>/dev/null | awk 'NF {print; exit}'
    ip -4 route show dev "$LAN_IF" 2>/dev/null | awk '/ via / {print $3; exit}'
    ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '
        /inet / {
            split($2, addr, "/")
            split(addr[1], octet, ".")
            if (octet[1] && octet[2] && octet[3]) {
                print octet[1] "." octet[2] "." octet[3] ".1"
                exit
            }
        }
    '
}

apply_policy() {
    LAN_GW="$(detect_lan_gw | awk 'NF {print; exit}')"

    # Purge any WireGuard / AmneziaWG auto-routing rules that conflict with policy routing
    while ip -4 rule show 2>/dev/null | grep -q "lookup 51820"; do
        ip -4 rule del table 51820 2>/dev/null || break
    done
    while ip -4 rule show 2>/dev/null | grep -q "from all lookup main suppress_prefixlength 0"; do
        ip -4 rule del table main suppress_prefixlength 0 2>/dev/null || break
    done
    ip -4 route flush table 51820 2>/dev/null || true

    echo 1 > /proc/sys/net/ipv4/ip_forward
    if ip link show "$VPN_IF" >/dev/null 2>&1; then
        if ! ip link set dev "$VPN_IF" mtu "$VPN_MTU"; then
            echo "Could not set $VPN_IF MTU to $VPN_MTU" >&2
            return 1
        fi
    fi
    ipset create "$VPN_IPSET" hash:ip 2>/dev/null || true
    ipset create "$VPN_ROUTES_IPSET" hash:net family inet 2>/dev/null || true
    ipset create "$LOCAL_ROUTES_IPSET" hash:ip 2>/dev/null || true
    if [ "$VPN_ROUTES_IPSET" != "$LEGACY_GITHUB_IPSET" ]; then
        remove_rule mangle OUTPUT -m set --match-set "$LEGACY_GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK"
        ipset destroy "$LEGACY_GITHUB_IPSET" 2>/dev/null || true
    fi
    if [ "$LOCAL_ROUTES_IPSET" != "$LEGACY_LOCAL_IPSET" ]; then
        remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -o "$LAN_IF" -j MASQUERADE
        remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -j MARK --set-mark "$BYPASS_FWMARK"
        remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -j MARK --set-mark 0
        remove_rule "$IPTABLES_CHAIN" -i "$HOTSPOT_IF" -o "$LAN_IF" -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -j ACCEPT
        ipset destroy "$LEGACY_LOCAL_IPSET" 2>/dev/null || true
    fi
    ensure_filter_chain "$IPTABLES_CHAIN"

    remove_rule mangle OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle OUTPUT -m set --match-set "$GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle OUTPUT -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    remove_rule mangle POSTROUTING -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    remove_rule nat POSTROUTING -o "$VPN_IF" -j MASQUERADE
    remove_rule filter FORWARD -i "$HOTSPOT_IF" -o "$VPN_IF" -s "$HOTSPOT_SUBNET" -j ACCEPT
    remove_rule filter FORWARD -i "$VPN_IF" -o "$HOTSPOT_IF" -d "$HOTSPOT_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_rule filter FORWARD -i "$HOTSPOT_IF" -o "$LAN_IF" -j ACCEPT
    remove_rule filter FORWARD -i "$LAN_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    for subnet in $MANAGEMENT_SUBNETS; do
        remove_rule filter FORWARD -i "$HOTSPOT_IF" -o "$LAN_IF" -s "$HOTSPOT_SUBNET" -d "$subnet" -j ACCEPT
        remove_rule filter FORWARD -i "$LAN_IF" -o "$HOTSPOT_IF" -d "$HOTSPOT_SUBNET" -s "$subnet" -m state --state RELATED,ESTABLISHED -j ACCEPT
        remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -d "$subnet" -o "$LAN_IF" -j MASQUERADE
    done
    remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_BYPASS_IPSET" dst -o "$LAN_IF" -j MASQUERADE
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_ROUTES_IPSET" dst -j MARK --set-mark "$BYPASS_FWMARK"
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_ROUTES_IPSET" dst -j MARK --set-mark 0
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -j MARK --set-mark "$BYPASS_FWMARK"
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -j MARK --set-mark 0
    remove_ip6_rule FORWARD -i "$HOTSPOT_IF" -j DROP
    remove_ip6_rule FORWARD -i "$HOTSPOT_IF" -j REJECT --reject-with icmp6-adm-prohibited

    ip route del default dev "$VPN_IF" table main metric 100 2>/dev/null || \
        ip route del default dev "$VPN_IF" table main 2>/dev/null || true
    if [ -n "$LAN_GW" ]; then
        ip route add default via "$LAN_GW" dev "$LAN_IF" metric 100 2>/dev/null || \
            ip route replace default via "$LAN_GW" dev "$LAN_IF" metric 100 2>/dev/null || true
    fi
    ip route replace "$HOTSPOT_SUBNET" dev "$HOTSPOT_IF" table "$TABLE_ID" 2>/dev/null || true
    ip route replace default dev "$VPN_IF" table "$TABLE_ID" 2>/dev/null || true

    ip rule del from "$HOTSPOT_SUBNET" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    ip rule add from "$HOTSPOT_SUBNET" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    ip rule del fwmark "$FWMARK" table "$TABLE_ID" priority "$HOST_RULE_PRIORITY" 2>/dev/null || true
    ip rule add fwmark "$FWMARK" table "$TABLE_ID" priority "$HOST_RULE_PRIORITY" 2>/dev/null || true
    ip rule del fwmark "$BYPASS_FWMARK" table main priority "$BYPASS_RULE_PRIORITY" 2>/dev/null || true
    ip rule add fwmark "$BYPASS_FWMARK" table main priority "$BYPASS_RULE_PRIORITY" 2>/dev/null || true
    for subnet in $MANAGEMENT_SUBNETS; do
        ip rule del from "$HOTSPOT_SUBNET" to "$subnet" table main priority "$MANAGEMENT_RULE_PRIORITY" 2>/dev/null || true
        ip rule add from "$HOTSPOT_SUBNET" to "$subnet" table main priority "$MANAGEMENT_RULE_PRIORITY" 2>/dev/null || true
    done

    iptables -t nat -C POSTROUTING -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -j MASQUERADE
    iptables -t nat -C POSTROUTING -o "$VPN_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$VPN_IF" -j MASQUERADE
    for subnet in $MANAGEMENT_SUBNETS; do
        target_dev="$(ip route get "${subnet%/*}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
        if [ "$target_dev" = "$VPN_IF" ] || [ "$subnet" = "10.8.0.0/24" ]; then
            continue
        fi
        iptables -t nat -C POSTROUTING -s "$HOTSPOT_SUBNET" -d "$subnet" -o "$LAN_IF" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$HOTSPOT_SUBNET" -d "$subnet" -o "$LAN_IF" -j MASQUERADE
    done
    iptables -t nat -C POSTROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_BYPASS_IPSET" dst -o "$LAN_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_BYPASS_IPSET" dst -o "$LAN_IF" -j MASQUERADE
    iptables -t mangle -C PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_BYPASS_IPSET" dst -j MARK --set-mark "$BYPASS_FWMARK" 2>/dev/null || \
        iptables -t mangle -I PREROUTING 1 -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_BYPASS_IPSET" dst -j MARK --set-mark "$BYPASS_FWMARK"
    iptables -t mangle -C OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK" 2>/dev/null || \
        iptables -t mangle -A OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK"
    iptables -t mangle -C OUTPUT -m set --match-set "$GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK" 2>/dev/null || \
        iptables -t mangle -A OUTPUT -m set --match-set "$GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK"
    iptables -t mangle -C OUTPUT -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || \
        iptables -t mangle -A OUTPUT -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    iptables -t mangle -C POSTROUTING -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A POSTROUTING -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -A "$IPTABLES_CHAIN" -i "$HOTSPOT_IF" -o "$LAN_IF" -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_BYPASS_IPSET" dst -j ACCEPT
    iptables -A "$IPTABLES_CHAIN" -i "$LAN_IF" -o "$HOTSPOT_IF" -d "$HOTSPOT_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
    for subnet in $MANAGEMENT_SUBNETS; do
        target_dev="$(ip route get "${subnet%/*}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
        if [ "$target_dev" = "$VPN_IF" ] || [ "$subnet" = "10.8.0.0/24" ]; then
            continue
        fi
        iptables -A "$IPTABLES_CHAIN" -i "$HOTSPOT_IF" -o "$LAN_IF" -s "$HOTSPOT_SUBNET" -d "$subnet" -j ACCEPT
        iptables -A "$IPTABLES_CHAIN" -i "$LAN_IF" -o "$HOTSPOT_IF" -d "$HOTSPOT_SUBNET" -s "$subnet" -m state --state RELATED,ESTABLISHED -j ACCEPT
    done
    iptables -A "$IPTABLES_CHAIN" -i "$HOTSPOT_IF" -o "$VPN_IF" -s "$HOTSPOT_SUBNET" -j ACCEPT
    iptables -A "$IPTABLES_CHAIN" -i "$VPN_IF" -o "$HOTSPOT_IF" -d "$HOTSPOT_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||         iptables -t mangle -A FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    iptables -C INPUT -i "$HOTSPOT_IF" -p udp --dport 67:68 -j ACCEPT 2>/dev/null ||         iptables -A INPUT -i "$HOTSPOT_IF" -p udp --dport 67:68 -j ACCEPT
    iptables -C INPUT -i "$HOTSPOT_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null ||         iptables -A INPUT -i "$HOTSPOT_IF" -p tcp --dport 53 -j ACCEPT
    iptables -C INPUT -i "$HOTSPOT_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null ||         iptables -A INPUT -i "$HOTSPOT_IF" -p udp --dport 53 -j ACCEPT

    # Force all client DNS (port 53) to AdGuard Home ($HOTSPOT_IP:53)
    iptables -t nat -C PREROUTING -i "$HOTSPOT_IF" -p udp --dport 53 ! -d "$HOTSPOT_IP" -j DNAT --to-destination "$HOTSPOT_IP:53" 2>/dev/null ||         iptables -t nat -A PREROUTING -i "$HOTSPOT_IF" -p udp --dport 53 ! -d "$HOTSPOT_IP" -j DNAT --to-destination "$HOTSPOT_IP:53"
    iptables -t nat -C PREROUTING -i "$HOTSPOT_IF" -p tcp --dport 53 ! -d "$HOTSPOT_IP" -j DNAT --to-destination "$HOTSPOT_IP:53" 2>/dev/null ||         iptables -t nat -A PREROUTING -i "$HOTSPOT_IF" -p tcp --dport 53 ! -d "$HOTSPOT_IP" -j DNAT --to-destination "$HOTSPOT_IP:53"

    # Reject DNS-over-TLS (port 853) so client devices fall back to standard DNS (AdGuard Home)
    iptables -C "$IPTABLES_CHAIN" -i "$HOTSPOT_IF" -p tcp --dport 853 -j REJECT 2>/dev/null ||         iptables -A "$IPTABLES_CHAIN" -i "$HOTSPOT_IF" -p tcp --dport 853 -j REJECT

    case "$IPV6_LEAK_PROTECTION" in
        drop|1|true|yes)
            ensure_ip6_filter_chain "$IP6TABLES_CHAIN"
            ip6tables -A "$IP6TABLES_CHAIN" -i "$HOTSPOT_IF" -j DROP
            ;;
        reject)
            ensure_ip6_filter_chain "$IP6TABLES_CHAIN"
            ip6tables -A "$IP6TABLES_CHAIN" -i "$HOTSPOT_IF" -j REJECT --reject-with icmp6-adm-prohibited
            ;;
        off|0|false|no)
            remove_ip6_filter_chain "$IP6TABLES_CHAIN"
            ;;
        *)
            ensure_ip6_filter_chain "$IP6TABLES_CHAIN"
            ip6tables -A "$IP6TABLES_CHAIN" -i "$HOTSPOT_IF" -j DROP
            ;;
    esac
}

cleanup_policy() {
    remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -j MASQUERADE
    remove_rule nat POSTROUTING -o "$VPN_IF" -j MASQUERADE
    remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_ROUTES_IPSET" dst -o "$LAN_IF" -j MASQUERADE
    remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -o "$LAN_IF" -j MASQUERADE
    remove_rule mangle OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle OUTPUT -m set --match-set "$VPN_ROUTES_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle OUTPUT -m set --match-set "$LEGACY_GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle OUTPUT -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    remove_rule mangle POSTROUTING -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_ROUTES_IPSET" dst -j MARK --set-mark "$BYPASS_FWMARK"
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LOCAL_ROUTES_IPSET" dst -j MARK --set-mark 0
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -j MARK --set-mark "$BYPASS_FWMARK"
    remove_rule mangle PREROUTING -s "$HOTSPOT_SUBNET" -m set --match-set "$LEGACY_LOCAL_IPSET" dst -j MARK --set-mark 0
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    remove_rule filter FORWARD -i "$HOTSPOT_IF" -o "$VPN_IF" -s "$HOTSPOT_SUBNET" -j ACCEPT
    remove_rule filter FORWARD -i "$VPN_IF" -o "$HOTSPOT_IF" -d "$HOTSPOT_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_rule filter FORWARD -i "$HOTSPOT_IF" -o "$LAN_IF" -j ACCEPT
    remove_rule filter FORWARD -i "$LAN_IF" -o "$HOTSPOT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    for subnet in $MANAGEMENT_SUBNETS; do
        remove_rule filter FORWARD -i "$HOTSPOT_IF" -o "$LAN_IF" -s "$HOTSPOT_SUBNET" -d "$subnet" -j ACCEPT
        remove_rule filter FORWARD -i "$LAN_IF" -o "$HOTSPOT_IF" -d "$HOTSPOT_SUBNET" -s "$subnet" -m state --state RELATED,ESTABLISHED -j ACCEPT
        remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -d "$subnet" -o "$LAN_IF" -j MASQUERADE
    done
    remove_ip6_rule FORWARD -i "$HOTSPOT_IF" -j DROP
    remove_ip6_rule FORWARD -i "$HOTSPOT_IF" -j REJECT --reject-with icmp6-adm-prohibited
    remove_filter_chain "$IPTABLES_CHAIN"
    remove_ip6_filter_chain "$IP6TABLES_CHAIN"
    remove_rule filter INPUT -i "$HOTSPOT_IF" -p udp --dport 67:68 -j ACCEPT
    remove_rule filter INPUT -i "$HOTSPOT_IF" -p tcp --dport 53 -j ACCEPT
    remove_rule filter INPUT -i "$HOTSPOT_IF" -p udp --dport 53 -j ACCEPT
    ip rule del from "$HOTSPOT_SUBNET" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    ip rule del fwmark "$FWMARK" table "$TABLE_ID" priority "$HOST_RULE_PRIORITY" 2>/dev/null || true
    ip rule del fwmark "$BYPASS_FWMARK" table main priority "$BYPASS_RULE_PRIORITY" 2>/dev/null || true
    for subnet in $MANAGEMENT_SUBNETS; do
        ip rule del from "$HOTSPOT_SUBNET" to "$subnet" table main priority "$MANAGEMENT_RULE_PRIORITY" 2>/dev/null || true
    done
    ip route flush table "$TABLE_ID" 2>/dev/null || true
}

case "$2" in
    apply)
        apply_policy
        ;;
    cleanup)
        cleanup_policy
        ;;
    down|vpn-down)
        if [ "$VPN_BACKEND" != "auto" ] && [ "$VPN_BACKEND" != "$1" ]; then
            if ip link show "$VPN_BACKEND" >/dev/null 2>&1; then
                VPN_IF="$VPN_BACKEND"
                apply_policy
                exit 0
            fi
        fi
        if [ "$VPN_BACKEND" = "auto" ]; then
            other_if=""
            for cand in awg0 wg0 tun0; do
                if [ "$cand" != "$1" ] && ip -4 addr show "$cand" 2>/dev/null | grep -q "inet "; then
                    other_if="$cand"
                    break
                fi
            done
            if [ -n "$other_if" ]; then
                VPN_IF="$other_if"
                apply_policy
                exit 0
            fi
        fi
        cleanup_policy
        ;;
    up|vpn-up|connectivity-change)
        if ip link show "$VPN_IF" >/dev/null 2>&1; then
            apply_policy
        fi
        ;;
esac
