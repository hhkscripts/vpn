# Raspberry Pi VPN Hotspot

GoodWifi is a Raspberry Pi Wi-Fi hotspot that sends connected client traffic through an OpenVPN tunnel while keeping the Pi host, Docker workloads, and local services on the normal Ethernet route.

## Routing Design

Traffic is intentionally split:

- GoodWifi clients: `10.42.0.0/24 -> wlan0 -> tun0 -> VPN/VPS`
- Pi host traffic: `eth0 -> <LAN gateway> -> ISP router`
- Docker workloads: normal host/Docker routes, not forced through the hotspot VPN
- GitHub host traffic: selected GitHub IPv4 ranges can be marked into the VPN when the ISP blocks GitHub
- Binance client traffic: Binance DNS answers are placed in `local_bypass_domains` and routed through `eth0`, so Binance P2P sees the normal Myanmar ISP public IP instead of the VPN exit IP
- DNS for GoodWifi clients: `10.42.0.1:53` handled by Pi-hole
- DHCP for GoodWifi clients: `dnsmasq` on `wlan0`, assigning `10.42.0.10` to `10.42.0.100`

## Do Not Force The Host Default Route

Do not install dispatcher scripts or manual fixes that run:

```bash
ip route del default
ip route add default dev tun0
```

Those commands replace the Pi's main default route with the VPN tunnel. That is the wrong model for this project.

The Pi must keep its main route on `eth0` so SSH, Docker, Pi-hole, GitHub deployment tooling, and local management keep working. GoodWifi clients are routed through the VPN with policy routing instead:

```text
from 10.42.0.0/24 lookup table 100
table 100 default dev tun0
```

On systems with a route-table name configured, table `100` may display as `github_vpn` in `ip rule show`.

Targeted exceptions then use marks and ipsets:

- `github_vpn_routes` + mark `100`: send selected Pi host GitHub traffic through `tun0`
- `local_bypass_domains` + mark `101`: send selected hotspot client destinations, currently Binance, through `eth0`

If an old script forces the main default route to `tun0`, the Pi may lose stable DNS, Docker networking, SSH reachability, and deployment access.

## Components

- `hostapd`: broadcasts the Wi-Fi AP on `wlan0`
- `dnsmasq`: DHCP only; advertises Pi-hole as DNS
- `Pi-hole`: DNS and ipset population for GoodWifi clients
- `NetworkManager`: manages Ethernet and the OpenVPN connection named `pi`
- `configs/90-hotspot-vpn-policy`: installed dispatcher policy
- `scripts/vpn-routing.sh`: editable mirror of the dispatcher policy
- `scripts/github-vpn-routes.sh`: loads GitHub IPv4 ranges into `github_vpn_routes`
- `scripts/hotspot-manager.py`: status, restart, and fix CLI
- `telegrambot/`: optional Telegram remote control

## Prerequisites

- Raspberry Pi with AP-capable Wi-Fi on `wlan0`
- Raspberry Pi OS Bookworm or Bullseye
- Ethernet upstream on `eth0`
- NetworkManager OpenVPN profile
- Docker Compose for Pi-hole and the optional Telegram bot

## Quick Start

Install base packages and import the OpenVPN profile:

```bash
sudo apt update
sudo apt install -y git network-manager network-manager-openvpn docker.io docker-compose-plugin
git clone <this-repo-url>
cd vpn
sudo nmcli connection import type openvpn file /path/to/client.ovpn
sudo nmcli connection modify "<imported-name>" connection.id pi
sudo nmcli connection modify pi connection.autoconnect yes ipv4.never-default yes ipv6.never-default yes
sudo nmcli connection up pi
```

Install and apply GoodWifi:

```bash
chmod +x setup.sh uninstall.sh scripts/hotspot-manager.py scripts/github-vpn-routes.sh
./setup.sh
```

Start Pi-hole:

```bash
cd pihole
cp .env.example .env
nano .env
docker compose up -d
cd ..
```

For an existing checkout after pulling source changes:

```bash
cd ~/Projects/vpn
git pull --ff-only
./setup.sh
cd pihole
docker compose restart
cd ..
sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy tun0 apply
```

## Wi-Fi Name And Password

Default template values:

- SSID: `GoodWifi`
- Password: `ChangeMeDuringSetup`

Run setup and enter new values when prompted:

```bash
./setup.sh
```

For unattended setup:

```bash
HOTSPOT_SSID="MyWifi" HOTSPOT_PASSWORD="change-this-password" ./setup.sh
```

## Daily Commands

Aliases installed by `setup.sh`:

```bash
alias hotspot="sudo /usr/local/bin/hotspot-manager.py"
alias hs="sudo /usr/local/bin/hotspot-manager.py --status"
alias hf="sudo /usr/local/bin/hotspot-manager.py --fix"
```

Common operations:

```bash
hotspot --status
hotspot --restart
hotspot --restart-vpn
hotspot --clients
hf
```

`hotspot --restart-vpn` also refreshes GitHub host routes when `/usr/local/bin/github-vpn-routes.sh` is installed.

## Pi-hole DNS And Ipsets

GoodWifi clients receive `10.42.0.1` as DNS. Pi-hole runs on the host network and loads dnsmasq ipset rules from:

```text
pihole/etc-dnsmasq.d/99-goodwifi-ipset.conf
```

Current DNS-to-ipset mappings:

- GitHub domains -> `vpn_domains`
- Binance domains -> `local_bypass_domains`

Restart Pi-hole after changing that file:

```bash
cd ~/Projects/vpn/pihole
docker compose restart
```

Verify DNS:

```bash
nslookup google.com 10.42.0.1
docker logs --tail=80 pihole
```

## GitHub Through VPN

Some ISPs block GitHub on the normal Ethernet path. This project keeps the Pi host default route on `eth0`, then handles GitHub as a targeted exception.

Refresh GitHub routes:

```bash
sudo nmcli connection up pi
sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy tun0 up
sudo github-vpn-routes.sh
```

`github-vpn-routes.sh` fetches `https://api.github.com/meta` through `tun0`, extracts GitHub IPv4 ranges, loads them into `github_vpn_routes`, and saves netfilter state. The dispatcher marks matching host traffic with fwmark `100`, then sends it to table `100`, whose default route is `tun0`.

Verify:

```bash
sudo ipset list github_vpn_routes
sudo iptables -t mangle -S OUTPUT | grep github_vpn_routes
ip route get 140.82.112.4 mark 100
```

Expected:

```text
140.82.112.4 dev tun0 table 100
```

## Binance Through Myanmar ISP

Binance P2P can reject VPN exit IPs. GoodWifi keeps normal client traffic on the VPN but sends Binance destinations through the Pi's Ethernet route:

```text
GoodWifi client -> wlan0 -> eth0 -> Myanmar ISP
```

This depends on clients using Pi-hole DNS (`10.42.0.1`). Android Private DNS, browser DNS-over-HTTPS, another VPN app, or a proxy can bypass Pi-hole and prevent Binance IPs from entering `local_bypass_domains`.

Verify:

```bash
nslookup www.binance.com 10.42.0.1
sudo ipset list local_bypass_domains
```

Pick one IP from `local_bypass_domains`:

```bash
ip route get <binance-ip> from 10.42.0.83 iif wlan0 mark 101
```

Expected:

```text
<binance-ip> from 10.42.0.83 via <LAN gateway> dev eth0 mark 0x65
```

Normal non-Binance client traffic should still use the VPN:

```bash
ip route get 1.1.1.1 from 10.42.0.83 iif wlan0
```

Expected:

```text
1.1.1.1 from 10.42.0.83 dev tun0 table 100
```

## Routing Verification

Host/Pi traffic should use Ethernet:

```bash
ip route get 1.1.1.1
```

Expected:

```text
1.1.1.1 via <LAN gateway> dev eth0
```

GoodWifi client traffic should use VPN table 100:

```bash
ip route get 1.1.1.1 from 10.42.0.83 iif wlan0
```

Expected:

```text
1.1.1.1 from 10.42.0.83 dev tun0 table 100
```

Policy rules:

```bash
ip rule show
```

Expected entries:

```text
998: from all fwmark 0x65 lookup main
999: from all fwmark 0x64 lookup 100
1000: from 10.42.0.0/24 lookup 100
```

If table `100` is named locally, the last two lines may show `lookup github_vpn`.

NAT:

```bash
sudo iptables -t nat -S POSTROUTING | grep -E 'tun0|eth0|10.42'
```

Expected:

```text
-A POSTROUTING -s 10.42.0.0/24 -o tun0 -j MASQUERADE
-A POSTROUTING -s 10.42.0.0/24 -o eth0 -m set --match-set local_bypass_domains dst -j MASQUERADE
```

Forward rules:

```bash
sudo iptables -S GOODWIFI_FORWARD
```

Expected:

```text
-A GOODWIFI_FORWARD -s 10.42.0.0/24 -i wlan0 -o eth0 -m set --match-set local_bypass_domains dst -j ACCEPT
-A GOODWIFI_FORWARD -d 10.42.0.0/24 -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A GOODWIFI_FORWARD -s 10.42.0.0/24 -i wlan0 -o tun0 -j ACCEPT
-A GOODWIFI_FORWARD -d 10.42.0.0/24 -i tun0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

IPv6 forwarding from GoodWifi is blocked to prevent VPN leaks:

```bash
sudo ip6tables -S GOODWIFI6_FORWARD
```

Expected:

```text
-A GOODWIFI6_FORWARD -i wlan0 -j DROP
```

## Troubleshooting

Check overall status:

```bash
hotspot --status
```

Restart runtime services and reapply policy:

```bash
hotspot --restart
```

Reconnect only the VPN and refresh GitHub routes:

```bash
hotspot --restart-vpn
```

Run the manager's automatic fix path:

```bash
hf
```

Check connected clients:

```bash
sudo hostapd_cli all_sta
sudo iw dev wlan0 station dump
sudo cat /var/lib/misc/dnsmasq.leases
ip neigh show dev wlan0
```

`dnsmasq.leases` can include stale leases; `hostapd_cli`, `iw`, and reachable neighbor entries are better proof that a client is currently attached.

## Old Dispatcher Scripts

These old dispatcher scripts must stay non-executable or removed because they force the Pi host default route through the VPN:

```text
/etc/NetworkManager/dispatcher.d/10-vpn-routing
/etc/NetworkManager/dispatcher.d/50-vpn-route
/etc/NetworkManager/dispatcher.d/99-vpn-routing
```

Check:

```bash
ls -l /etc/NetworkManager/dispatcher.d/10-vpn-routing \
      /etc/NetworkManager/dispatcher.d/50-vpn-route \
      /etc/NetworkManager/dispatcher.d/99-vpn-routing
```

Expected permission starts with `-rw-`, not `-rwx`.

`setup.sh` disables these scripts when they exist.

## Important Files

```text
configs/90-hotspot-vpn-policy
scripts/vpn-routing.sh
scripts/github-vpn-routes.sh
scripts/hotspot-manager.py
pihole/docker-compose.yml
pihole/etc-dnsmasq.d/99-goodwifi-ipset.conf
telegrambot/README.md
```

Installed live files:

```text
/etc/hostapd/hostapd.conf
/etc/dnsmasq.conf
/etc/NetworkManager/dispatcher.d/20-hotspot-manager
/etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy
/usr/local/bin/hotspot-manager.py
/usr/local/bin/github-vpn-routes.sh
```

## Uninstall

```bash
./uninstall.sh
```

`uninstall.sh` removes installed system files, aliases, and runtime firewall/policy-route rules. It does not delete this project directory.

## License

This project is licensed under the MIT License. See `LICENSE`.
