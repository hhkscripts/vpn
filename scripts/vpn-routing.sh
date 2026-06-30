#!/bin/sh
# Keep Pi host traffic on eth0 while routing hotspot clients through the VPN.

HOTSPOT_SUBNET="10.42.0.0/24"
VPN_IF="tun0"
LAN_IF="eth0"
LAN_GW_OVERRIDE="${LAN_GW:-}"
TABLE_ID="100"
RULE_PRIORITY="1000"
HOST_RULE_PRIORITY="999"
FWMARK="100"
VPN_IPSET="vpn_domains"
GITHUB_IPSET="github_vpn_routes"
IPTABLES_CHAIN="GOODWIFI_FORWARD"
IP6TABLES_CHAIN="GOODWIFI6_FORWARD"

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

    echo 1 > /proc/sys/net/ipv4/ip_forward
    ipset create "$VPN_IPSET" hash:ip 2>/dev/null || true
    ipset create "$GITHUB_IPSET" hash:net family inet 2>/dev/null || true
    ensure_filter_chain "$IPTABLES_CHAIN"
    ensure_ip6_filter_chain "$IP6TABLES_CHAIN"

    remove_rule mangle OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle OUTPUT -m set --match-set "$GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule filter FORWARD -i wlan0 -o "$VPN_IF" -s "$HOTSPOT_SUBNET" -j ACCEPT
    remove_rule filter FORWARD -i "$VPN_IF" -o wlan0 -d "$HOTSPOT_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_rule filter FORWARD -i wlan0 -o "$LAN_IF" -j ACCEPT
    remove_rule filter FORWARD -i "$LAN_IF" -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_ip6_rule FORWARD -i wlan0 -j DROP

    ip route del default dev "$VPN_IF" table main metric 100 2>/dev/null || \
        ip route del default dev "$VPN_IF" table main 2>/dev/null || true
    if [ -n "$LAN_GW" ]; then
        ip route add default via "$LAN_GW" dev "$LAN_IF" metric 100 2>/dev/null || \
            ip route replace default via "$LAN_GW" dev "$LAN_IF" metric 100 2>/dev/null || true
    fi
    ip route replace "$HOTSPOT_SUBNET" dev wlan0 table "$TABLE_ID" 2>/dev/null || true
    ip route replace default dev "$VPN_IF" table "$TABLE_ID" 2>/dev/null || true

    ip rule del from "$HOTSPOT_SUBNET" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    ip rule add from "$HOTSPOT_SUBNET" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    ip rule del fwmark "$FWMARK" table "$TABLE_ID" priority "$HOST_RULE_PRIORITY" 2>/dev/null || true
    ip rule add fwmark "$FWMARK" table "$TABLE_ID" priority "$HOST_RULE_PRIORITY" 2>/dev/null || true

    iptables -t nat -C POSTROUTING -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -j MASQUERADE
    iptables -t mangle -C OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK" 2>/dev/null || \
        iptables -t mangle -A OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK"
    iptables -t mangle -C OUTPUT -m set --match-set "$GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK" 2>/dev/null || \
        iptables -t mangle -A OUTPUT -m set --match-set "$GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK"
    iptables -A "$IPTABLES_CHAIN" -i wlan0 -o "$VPN_IF" -s "$HOTSPOT_SUBNET" -j ACCEPT
    iptables -A "$IPTABLES_CHAIN" -i "$VPN_IF" -o wlan0 -d "$HOTSPOT_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    iptables -C INPUT -i wlan0 -p udp --dport 67:68 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i wlan0 -p udp --dport 67:68 -j ACCEPT
    iptables -C INPUT -i wlan0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i wlan0 -p tcp --dport 53 -j ACCEPT
    iptables -C INPUT -i wlan0 -p udp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i wlan0 -p udp --dport 53 -j ACCEPT

    ip6tables -A "$IP6TABLES_CHAIN" -i wlan0 -j DROP
}

cleanup_policy() {
    remove_rule nat POSTROUTING -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -j MASQUERADE
    remove_rule mangle OUTPUT -m set --match-set "$VPN_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle OUTPUT -m set --match-set "$GITHUB_IPSET" dst -j MARK --set-mark "$FWMARK"
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    remove_rule mangle FORWARD -s "$HOTSPOT_SUBNET" -o "$VPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    remove_rule filter FORWARD -i wlan0 -o "$VPN_IF" -s "$HOTSPOT_SUBNET" -j ACCEPT
    remove_rule filter FORWARD -i "$VPN_IF" -o wlan0 -d "$HOTSPOT_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_rule filter FORWARD -i wlan0 -o "$LAN_IF" -j ACCEPT
    remove_rule filter FORWARD -i "$LAN_IF" -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    remove_ip6_rule FORWARD -i wlan0 -j DROP
    remove_filter_chain "$IPTABLES_CHAIN"
    remove_ip6_filter_chain "$IP6TABLES_CHAIN"
    remove_rule filter INPUT -i wlan0 -p udp --dport 67:68 -j ACCEPT
    remove_rule filter INPUT -i wlan0 -p tcp --dport 53 -j ACCEPT
    remove_rule filter INPUT -i wlan0 -p udp --dport 53 -j ACCEPT
    ip rule del from "$HOTSPOT_SUBNET" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    ip rule del fwmark "$FWMARK" table "$TABLE_ID" priority "$HOST_RULE_PRIORITY" 2>/dev/null || true
    ip route flush table "$TABLE_ID" 2>/dev/null || true
}

case "$2" in
    apply)
        apply_policy
        ;;
    cleanup|down|vpn-down)
        cleanup_policy
        ;;
    up|vpn-up|connectivity-change)
        if ip link show "$VPN_IF" >/dev/null 2>&1; then
            apply_policy
            ( sleep 5; apply_policy ) &
            ( sleep 15; apply_policy ) &
        fi
        ;;
esac
