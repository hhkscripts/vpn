# Raspberry Pi VPN Hotspot

GoodWifi is a Raspberry Pi Wi-Fi hotspot that routes connected device traffic through an OpenVPN tunnel. The Pi host itself, Docker, and local server processes keep using normal Ethernet unless you explicitly route them through the VPN.

## Current Design

Traffic is intentionally split:

- GoodWifi clients: `10.42.0.0/24 -> tun0 -> VPN/VPS`
- Pi host services: `eth0 -> <LAN gateway> -> ISP router`
- Docker workloads: not forced through VPN by default
- DNS for GoodWifi clients: `10.42.0.1:53` handled by dnsmasq with upstream DNS to Google (8.8.8.8, 8.8.4.4)
- DHCP for GoodWifi clients: handled by dnsmasq on `wlan0`

Do not install scripts that run:

```bash
ip route del default
ip route add default dev tun0
```

That makes the Pi itself use the VPN and can break Docker networking, DNS, SSH, and deployments.

## Components

- `hostapd`: broadcasts `GoodWifi` on `wlan0`
- `dnsmasq`: DHCP and DNS for clients, gives IPs from `10.42.0.10` to `10.42.0.100`, upstream DNS to Google (8.8.8.8, 8.8.4.4)
- `NetworkManager`: manages Ethernet and OpenVPN connection `pi`
- `configs/90-hotspot-vpn-policy`: keeps host traffic on `eth0` and routes hotspot clients through `tun0` using project-owned firewall chains
- `scripts/vpn-routing.sh`: editable mirror of the installed dispatcher policy
- `scripts/hotspot-manager.py`: status/fix CLI used by aliases and Telegram Bot
- `telegrambot/`: Telegram Bot for remote hotspot control via Docker

## Prerequisites

- Raspberry Pi with Wi-Fi AP support on `wlan0`
- Raspberry Pi OS Bookworm or Bullseye
- Ethernet upstream on `eth0`
- A NetworkManager-compatible OpenVPN `.ovpn` client file
- Internet access during first install so `apt` can install packages

`setup.sh` installs the required packages: `hostapd`, `dnsmasq`, `ipset`, `ipset-persistent`, `iptables-persistent`, `netfilter-persistent`, `python3`, `python3-pip`, `curl`, and `wget`.

## Quick Start

From a fresh Pi:

```bash
sudo apt update
sudo apt install -y git network-manager network-manager-openvpn
git clone <this-repo-url>
cd vpn
sudo nmcli connection import type openvpn file /path/to/client.ovpn
sudo nmcli connection modify "<imported-name>" connection.id pi
sudo nmcli connection modify pi connection.autoconnect yes ipv4.never-default yes ipv6.never-default yes
sudo nmcli connection up pi
chmod +x setup.sh uninstall.sh scripts/hotspot-manager.py
./setup.sh
```

During setup, enter a hotspot SSID and password when prompted. Leaving the prompts blank keeps the currently installed values from `/etc/hostapd/hostapd.conf`, or the template values from `configs/hostapd.conf` on a first install. For unattended installs, set `HOTSPOT_SSID` and `HOTSPOT_PASSWORD` before running `./setup.sh`.

## Important Files

```text
vpn/
├── README.md
├── setup.sh
├── configs/
│   ├── hostapd.conf
│   ├── hostapd-override.conf
│   ├── dnsmasq.conf
│   ├── NetworkManager.conf
│   ├── dhcpcd.conf
│   ├── 20-hotspot-manager
│   └── 90-hotspot-vpn-policy
├── scripts/
│   ├── hotspot-manager.py
│   └── vpn-routing.sh
└── telegrambot/
    ├── bot.py
    ├── Dockerfile
    ├── docker-compose.yml
    ├── requirements.txt
    ├── .env.example
    └── README.md
```

Installed live files:

```text
/etc/hostapd/hostapd.conf
/etc/systemd/system/hostapd.service.d/override.conf
/etc/dnsmasq.conf
/etc/NetworkManager/dispatcher.d/20-hotspot-manager
/etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy
/usr/local/bin/hotspot-manager.py
```

## OpenVPN Setup

The hotspot expects a NetworkManager OpenVPN connection named `pi`. It should create interface `tun0` when connected.

If you have an `.ovpn` file, import it on the Pi:

```bash
sudo nmcli connection import type openvpn file /path/to/client.ovpn
```

Rename the imported connection to `pi` if needed:

```bash
nmcli connection show
sudo nmcli connection modify "<imported-name>" connection.id pi
```

Enable autoconnect:

```bash
sudo nmcli connection modify pi connection.autoconnect yes
```

Keep the VPN from becoming the Pi host default route:

```bash
sudo nmcli connection modify pi ipv4.never-default yes ipv6.never-default yes
```

Connect it if it is not already active:

```bash
sudo nmcli connection up pi
```

Verify:

```bash
nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active
ip addr show tun0
curl -4 -s --max-time 8 --interface tun0 https://ifconfig.me
```

The public VPN exit IP can vary by provider, account, or server pool. Treat the `curl --interface tun0` result as the current active exit IP, not as a value that must match this README.

Apply the hotspot routing policy after `tun0` has an IPv4 address:

```bash
sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy tun0 up
```

Private OpenVPN files must not be committed. This repo ignores `backup/`, `*.ovpn`, `*.key`, `*.pem`, and `*.crt`.

## Changing Wi-Fi Name And Password

Template values:

- SSID: `GoodWifi`
- Password: `ChangeMeDuringSetup`

For normal installs, run setup and enter new values when prompted:

```bash
./setup.sh
```

For unattended installs:

```bash
HOTSPOT_SSID="MyWifi" HOTSPOT_PASSWORD="change-this-password" ./setup.sh
```

`setup.sh` renders the installed `/etc/hostapd/hostapd.conf` with your chosen values. The repository config stays as a reusable template.


For a live-only quick test, edit `/etc/hostapd/hostapd.conf` and restart:

```bash
sudo systemctl restart hostapd dnsmasq
```

Source files are preferred so the next setup run preserves your changes.

## Aliases

These are in `~/.bashrc`:

```bash
alias hotspot="sudo /usr/local/bin/hotspot-manager.py"
alias hs="sudo /usr/local/bin/hotspot-manager.py --status"
alias hf="sudo /usr/local/bin/hotspot-manager.py --fix"
```

Reload aliases after changing `.bashrc`:

```bash
source ~/.bashrc
```

## Daily Commands

Check status:

```bash
hotspot --status
hs
```

Expected healthy output includes:

```text
SERVICES:
  ✅ hostapd      Running
  ✅ dnsmasq      Running

VPN:
  ✅ Connected: True
    Tunnel IP: 10.8.0.2
    VPN Exit IP: <public VPN IP>

HOTSPOT:
  ✅ SSID: GoodWifi
    Clients: <number>

NETWORK:
  ✅ DNS: Working
  ✅ Internet: Available
  ✅ Ping 8.8.8.8: 3 packets transmitted, 3 received, 0% packet loss, time ...ms
```

The `NETWORK` section is a Pi host check. Client VPN routing is verified separately with the commands in "Routing Verification" below.

### Telegram Bot Control

Control your hotspot remotely via Telegram Bot. The bot runs in Docker and uses the same `hotspot-manager.py` commands internally.

#### Setup Instructions

1. **Get a Bot Token**:
   - Open Telegram and search for `@BotFather`
   - Send `/newbot` command and follow instructions
   - Copy the API token provided

2. **Configure Environment**:
   ```bash
   cd telegrambot
   cp .env.example .env
   nano .env
   ```
   Add your bot token:
   ```
   TELEGRAM_BOT_TOKEN=your_bot_token_here
   TELEGRAM_ALLOWED_USERS=your_telegram_user_id (optional)
   ```

3. **Run with Docker**:
   ```bash
   docker-compose up -d --build
   ```

4. **Verify**:
   - Send `/start` to your bot in Telegram to test

#### Available Commands

| Command | Description |
|---------|-------------|
| `/start` | Start the bot and see welcome message |
| `/status` | Check hotspot status with refresh button (updates existing message) |
| `/restart` | Restart all hotspot services |
| `/restart_vpn` | Restart VPN connection only |
| `/fix` | Auto-fix common hotspot issues |
| `/clients` | Show connected clients count |
| `/help` | Display help message |

#### Features

- **Message Updates**: Status messages update in-place instead of creating new messages
- **User Authorization**: Optional whitelist via `TELEGRAM_ALLOWED_USERS`
- **Docker Isolation**: Runs in isolated container for security
- **Auto-Reconnect**: Automatically reconnects to Telegram if connection is lost

#### GitHub Secrets Integration

For automated deployments, store your bot token in GitHub Secrets:

1. Go to **Repository Settings** → **Secrets and variables** → **Actions**
2. Add new secrets:
   - `TELEGRAM_BOT_TOKEN`: Your bot token from BotFather
   - `TELEGRAM_ALLOWED_USERS`: (Optional) Your Telegram user ID

3. Use in GitHub Actions workflow:
   ```yaml
   - name: Deploy Telegram Bot
     run: |
       cd telegrambot
       echo "TELEGRAM_BOT_TOKEN=${{ secrets.TELEGRAM_BOT_TOKEN }}" > .env
       docker-compose up -d --build
   ```

#### Troubleshooting

- Check logs: `docker-compose logs -f`
- Verify token is correct in `.env`
- Ensure Docker is running: `systemctl status docker`
- Check bot status: Send `/status` command in Telegram

Restart hotspot services and reapply routing policy:

```bash
hotspot -r
hotspot --restart
```

Auto-fix common runtime issues:

```bash
hf
hotspot --fix
```

Reconnect/apply VPN policy only:

```bash
hotspot --restart-vpn
```

Show connected client count:

```bash
hotspot --clients
```

## Setup / Reinstall

Use setup only when source config changed or after a fresh OS install. Do not use setup as the first fix for a temporary client issue.

```bash
cd /path/to/vpn
chmod +x setup.sh
./setup.sh
```

`setup.sh` is an apply wrapper. It does not regenerate project files. It installs/copies the existing files from `configs/` and `scripts/`, sets aliases, enables forwarding, installs the status manager, disables old bad VPN route scripts, applies hotspot-only VPN routing, and restarts services.

`uninstall.sh` removes the installed system files, aliases, and runtime firewall/policy-route rules. It does not delete this project directory or rewrite files in `configs/` or `scripts/`.

## Docker Setup Notes

Docker services on the Pi should normally keep using the host Ethernet route, not the GoodWifi VPN route.

Recommended pattern for Docker apps that need stable DNS:

```yaml
services:
  app:
    image: your-image
    dns:
      - 1.1.1.1
      - 8.8.8.8
```

Check Docker apps after hotspot changes:

```bash
docker ps
docker compose ps
```

Confirm host routing still uses Ethernet:

```bash
ip route get 1.1.1.1
```

Expected:

```text
1.1.1.1 via <LAN gateway> dev eth0
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

The LAN gateway is detected dynamically from `eth0`. It may be `192.168.1.1`, `192.168.0.1`, or another gateway assigned by the upstream router. Set `LAN_GW=<gateway>` only when you need to override detection manually.

Hotspot client traffic should use VPN table 100:

```bash
ip route get 1.1.1.1 from 10.42.0.83 iif wlan0
```

Expected:

```text
1.1.1.1 from 10.42.0.83 dev tun0 table 100
```

NAT should only masquerade hotspot subnet to VPN:

```bash
sudo iptables -t nat -S POSTROUTING | grep -E 'tun0|eth0|10.42'
```

Expected:

```text
-A POSTROUTING -s 10.42.0.0/24 -o tun0 -j MASQUERADE
```

Forward rules should jump through the project-owned chain:

```bash
sudo iptables -S FORWARD
sudo iptables -S GOODWIFI_FORWARD
```

Expected:

```text
-A FORWARD -j GOODWIFI_FORWARD
-A GOODWIFI_FORWARD -s 10.42.0.0/24 -i wlan0 -o tun0 -j ACCEPT
-A GOODWIFI_FORWARD -d 10.42.0.0/24 -i tun0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

IPv6 forwarding from hotspot clients is blocked to prevent VPN leaks:

```bash
sudo ip6tables -S FORWARD
sudo ip6tables -S GOODWIFI6_FORWARD
```

Expected:

```text
-A FORWARD -j GOODWIFI6_FORWARD
-A GOODWIFI6_FORWARD -i wlan0 -j DROP
```

## Why Devices Show "Connected / No Internet Access"

Phones and laptops do not simply check whether Wi-Fi is connected. They run a captive-portal or internet validation check after joining Wi-Fi.

Examples:

- Android checks URLs such as `connectivitycheck.gstatic.com/generate_204`
- Google checks `www.google.com/generate_204`
- Some devices also require DNS and Private DNS to work
- Some devices cache a previous failed result until Wi-Fi is reconnected

So this message can appear even while the Pi status looks healthy.

Common causes:

1. Device has stale DHCP/captive-portal state after hotspot restart.
2. Device uses strict Private DNS and cannot reach its configured DNS-over-TLS provider.
3. Device kept an old lease but route/NAT changed under it.
4. VPN was briefly down while the device performed its internet check.
5. dnsmasq upstream DNS temporarily failed.
6. Client is listed in old DHCP leases but is not actually associated to `hostapd` anymore.
7. AP compatibility settings are wrong for the device. Current `hostapd.conf` keeps WMM and 802.11n enabled for Android compatibility.

## Fix Flow For "Connected / No Internet Access"

Start with the safe runtime fix:

```bash
hotspot -r
```

Then on the affected device:

1. Turn Wi-Fi off and on.
2. Reconnect to `GoodWifi`.
3. If still broken, Forget `GoodWifi` and join again.
4. On Android, set Private DNS to `Automatic` or `Off`.
5. Wait 10-20 seconds for the captive portal check to refresh.

Do not run `./setup.sh` first. `setup.sh` rewrites config and is for install/config updates, not normal client reconnect problems.

## Pi-Side Checks For Client Internet

Check manager status:

```bash
hotspot --status
```

Check Android captive portal endpoint using hotspot source address:

```bash
curl -4 -s -o /dev/null -w 'android204=%{http_code} time=%{time_total}\n' \
  --interface 10.42.0.1 --max-time 8 \
  http://connectivitycheck.gstatic.com/generate_204
```

Expected:

```text
android204=204
```

Check Google 204 endpoint:

```bash
curl -4 -s -o /dev/null -w 'google204=%{http_code} time=%{time_total}\n' \
  --interface 10.42.0.1 --max-time 8 \
  https://www.google.com/generate_204
```

Expected:

```text
google204=204
```

Check DNS through dnsmasq on the hotspot gateway:

```bash
nslookup connectivitycheck.gstatic.com 10.42.0.1
```

Check VPN egress IP:

```bash
curl -4 -s --max-time 8 --interface tun0 https://ifconfig.me
```

This prints the current public VPN exit IP for the active tunnel. It can change when the OpenVPN profile, provider server, or account changes.

```bash
nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active
ip -4 addr show tun0
```

Check active/reachable clients:

```bash
sudo hostapd_cli all_sta
sudo iw dev wlan0 station dump
sudo cat /var/lib/misc/dnsmasq.leases
ip neigh show dev wlan0
```

`hostapd_cli all_sta` and `iw station dump` show clients actually associated to the AP. `dnsmasq.leases` can contain stale lease records, so do not treat a lease entry by itself as proof that the device is connected. A neighbor entry with `REACHABLE` is currently visible. A neighbor entry with `FAILED` usually means stale lease or disconnected device.

## GoodWifi Is Connected But One Device Has No Internet

If only one device has the issue, the Pi is usually OK. Fix the device:

- Forget and reconnect `GoodWifi`
- Disable strict Private DNS
- Disable VPN/proxy apps on the device for testing
- Toggle airplane mode
- Reboot the device if it keeps cached "No internet" state

## All Devices Have No Internet

Run these in order:

```bash
hotspot --status
hotspot -r
hotspot --status
```

If still broken, verify route/NAT:

```bash
ip route get 1.1.1.1
ip route get 1.1.1.1 from 10.42.0.83 iif wlan0
sudo iptables -t nat -S POSTROUTING | grep -E 'tun0|eth0|10.42'
sudo iptables -S FORWARD
sudo iptables -S GOODWIFI_FORWARD
```

Only run setup after source config changed or if the installed files are damaged:

```bash
cd /path/to/vpn
./setup.sh
```

## Old Bad Scripts

These old dispatcher scripts must remain non-executable or removed because they force the Pi host default route through VPN:

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

## Docker Compatibility

Docker workloads must not be forced through the hotspot VPN unless you explicitly design them that way.

Expected default state:

- Docker containers keep using the Pi host/bridge route.
- Pi host traffic goes through `eth0`.
- GoodWifi client traffic goes through `tun0`.
- Docker apps that need stable resolver behavior can define `dns:` entries in their Compose files.

Generic Docker check:

```bash
docker ps
docker compose ps
ip route get 1.1.1.1
```

## Quick Decision Guide

- One device says No internet, others work: reconnect/forget Wi-Fi on that device.
- All devices say No internet, `hotspot --status` is healthy: run `hotspot -r`, then reconnect devices.
- VPN shows disconnected: run `hotspot --restart-vpn`.
- DNS failed: restart dnsmasq with `hotspot -r`.
- Route/NAT wrong: run `hf` or `hotspot --fix`.
- Source config changed: run `cd /path/to/vpn && ./setup.sh`.

## License

This project is licensed under the MIT License. See `LICENSE`.
