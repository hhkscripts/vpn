# Raspberry Pi VPN Hotspot (GoodWifi)

GoodWifi is a resilient Raspberry Pi Wi-Fi hotspot designed to defeat censorship and DPI (Deep Packet Inspection). It automatically routes connected Wi-Fi clients through an encrypted VPN tunnel (**AmneziaWG**, **WireGuard**, or **OpenVPN**) while keeping the Pi host, Docker workloads, and local services on the normal Ethernet route.

---

## Key Features

- **Multi-Backend VPN**: Native support for **AmneziaWG (`awg0`)** (obfuscated anti-DPI WireGuard), **WireGuard (`wg0`)**, and **OpenVPN (`tun0`)**, with automatic health checking and failover.
- **Selective Policy Routing**: Hotspot client traffic goes through the active VPN; Raspberry Pi host services, SSH, and Docker containers remain reachable on Ethernet (`eth0`).
- **Selective GitHub Routing**: Routes GitHub API, Git, and GitHub Actions runner traffic through the VPN to bypass local censorship while keeping the rest of host traffic on local LAN.
- **Selective Local Bypass (Binance / P2P)**: Automatically routes specific services (such as Binance) through the local Myanmar ISP gateway via DNS ipsets (`local_bypass_domains`) to avoid VPN geo-blocking.
- **AdGuard Home DNS Filtering**: Blocks ads and trackers network-wide while dynamically populating policy routing ipsets.
- **Telegram Bot Remote Control**: Manage VPN backends, inspect connected clients, and monitor system health with interactive inline buttons and Telegram Premium status emojis.

---

## Routing Architecture

Traffic is split dynamically using Linux policy routing, packet marks, and ipsets:

| Source / Destination | Interface | Routing Mechanism | Purpose |
| :--- | :--- | :--- | :--- |
| **Hotspot Clients** (`10.42.0.0/24`) | Active VPN (`awg0` / `wg0` / `tun0`) | Policy `table 100` (`github_vpn`) | Encrypted, secure Internet for all Wi-Fi clients |
| **Binance / Local Bypass** | `eth0` (Local ISP) | `fwmark 0x65` -> `table main` | Bypasses VPN so P2P exchanges see local Myanmar IP |
| **GoodWifi Management Subnets** | `eth0` / Local LAN | `priority 997` -> `table main` | Clients can access Pi services (`10.42.0.1`, LAN IPs, VPN IPs) |
| **Raspberry Pi Host Traffic** | `eth0` (Local ISP) | Default route (`table main`) | Fast, unaffected host networking, SSH, and Docker |
| **Selected GitHub Host Traffic** | Active VPN (`awg0` / `tun0`) | `fwmark 0x64` (`github_vpn_routes`) | Ensures Git, GitHub Actions Runner, and APIs never timeout |

### Policy Routing Tables

```text
# ip rule show
997:  from 10.42.0.0/24 to 10.8.0.0/24 lookup main
997:  from 10.42.0.0/24 to 192.168.100.0/24 lookup main
998:  from all fwmark 0x65 lookup main              # local_bypass_domains (Binance)
999:  from all fwmark 0x64 lookup 100               # github_vpn_routes
1000: from 10.42.0.0/24 lookup 100                  # all other client traffic
```

> [!IMPORTANT]
> **Do NOT force the host default route to VPN.**
> Never replace the host default gateway (`ip route replace default dev tun0/awg0`). Keeping host traffic on `eth0` preserves Docker containers, local SSH management, and stable DNS.

---

## Components

- `hostapd`: Broadcasts the Wi-Fi AP on `wlan0` (`10.42.0.1/24`).
- `dnsmasq`: Lightweight DHCP server assigning IP leases (`10.42.0.10`–`10.42.0.100`) and advertising AdGuard Home as DNS (`10.42.0.1:53`).
- `AdGuard Home`: Dockerized DNS filter on host network; blocks ads and assigns resolved domains into policy ipsets.
- `NetworkManager` & `awg-quick`: Manages Ethernet, Wi-Fi AP, AmneziaWG, and OpenVPN connections.
- `configs/90-hotspot-vpn-policy`: Core firewall and policy routing dispatcher script (mirrored at `scripts/vpn-routing.sh`).
- `configs/20-hotspot-manager`: NetworkManager dispatcher script ensuring VPN policy on network change.
- `scripts/hotspot-manager.py`: Complete CLI management tool for status, switching backends, and self-healing.
- `scripts/github-vpn-routes.sh`: Fetches published GitHub IPv4 CIDRs and loads them into `github_vpn_routes`.
- `telegrambot/`: Python Telegram Bot with interactive inline keyboards, real-time alerts, and VPN switcher.

---

## Configuration (`/etc/goodwifi/goodwifi.conf`)

Create or modify `/etc/goodwifi/goodwifi.conf` to set project-wide preferences:

```bash
# Preferred VPN backend: "auto", "awg0", "wg0", or "tun0"
VPN_BACKEND="auto"

# VPN MTU (default: 1280 for AmneziaWG/WireGuard, 1400 for OpenVPN)
VPN_MTU="1280"

# OpenVPN NetworkManager connection profile name
VPN_UUID="pi"
```

---

## Multi-Backend VPN Support

GoodWifi dynamically adapts to whichever VPN backend is running:

- **AmneziaWG (`awg0`)**: Recommended for heavily censored environments. Obfuscates WireGuard packet headers (`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1`-`H4`) to bypass DPI blocks.
- **WireGuard (`wg0`)**: Standard WireGuard protocol for high-speed, low-latency tunneling.
- **OpenVPN (`tun0`)**: Traditional OpenVPN protocol managed by NetworkManager. Includes automatic `--replay-window 8192 60` diversion wrapper for unstable mobile UDP paths.

### AmneziaWG / WireGuard Configuration

Ensure `Table = off` is configured in `/etc/amnezia/amneziawg/awg0.conf` or `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.8.0.2/24
PrivateKey = <private_key>
DNS = 1.1.1.1
Table = off          # Prevents hijacking Pi host default routes
MTU = 1280
...
```

### Switching VPN Backends via CLI

```bash
# Check current active backend, external IP, and client count
hotspot --status

# Switch active backend to AmneziaWG
hotspot --switch-vpn awg0

# Switch active backend to OpenVPN
hotspot --switch-vpn tun0

# Set to auto-failover (prefers awg0, falls back to tun0/wg0)
hotspot --switch-vpn auto
```

### Switching via Telegram Bot

The Telegram bot includes interactive **Inline Keyboard Buttons** under `/status`:
- When running on `awg0`: displays a `[ 🔄 Switch to OpenVPN (tun0) ]` button.
- When running on `tun0`: displays a `[ ⚡ Switch to AmneziaWG (awg0) ]` button.
- You can also send `/switch_vpn awg0` or `/switch_vpn tun0` directly as text commands.

---

## Daily Management Commands

Convenience aliases installed by `setup.sh`:

```bash
alias hotspot="sudo /usr/local/bin/hotspot-manager.py"
alias hs="sudo /usr/local/bin/hotspot-manager.py --status"
alias hf="sudo /usr/local/bin/hotspot-manager.py --fix"
```

Useful commands:

```bash
hotspot --status       # View current status, VPN backend, IP, and clients
hotspot --clients      # List connected client devices and IP/MAC mappings
hotspot --restart-vpn  # Reconnect active VPN and refresh routes
hotspot --restart      # Restart hotspot services and reapply firewall policy
hf                     # Run automated self-healing fix
```

---

## AdGuard Home & DNS Policy

GoodWifi clients query `10.42.0.1:53` for DNS. AdGuard Home performs ad-blocking, anti-tracking, and routes specific domains into kernel ipsets:

- `github.com` & subdomains -> `vpn_domains`
- `binance.com`, `binance.info`, `bnbstatic.com` -> `local_bypass_domains`

### Verifying DNS & Ipsets

```bash
# Test DNS resolution
dig @10.42.0.1 binance.com

# Verify that Binance IPs were added to bypass set
sudo ipset list local_bypass_domains

# Verify GitHub set
sudo ipset list vpn_domains
```

> [!TIP]
> **Ad Blocking on Client Devices:**
> If ads appear on specific client devices:
> 1. Check if the device has **Private DNS** or **DNS-over-HTTPS (DoH)** enabled. Private DNS ignores local Wi-Fi DNS and queries public resolvers directly. Set Android Private DNS to "Off" when on GoodWifi.
> 2. Video in-stream ads (such as YouTube or Facebook video ads) are served from the same CDNs as media streams and cannot be blocked via DNS alone without breaking video playback.

---

## GitHub Actions Self-Hosted Runner

The Pi can run a self-hosted GitHub Actions runner (`actions.runner.hhkscripts.RaspberryPi.service`) for automated deployment of containers and code updates.

- GitHub connections automatically route through the active VPN via `github_vpn_routes` and `table 100`.
- Git SSH operations automatically bind to the active VPN interface (`awg0` or `tun0`) via `~/.ssh/config`.
- TCP MSS is clamped to PMTU on outbound packets, ensuring TLS handshakes and large payloads never timeout.

---

## Quick Start & Installation

```bash
git clone https://github.com/hhkscripts/vpn.git
cd vpn
chmod +x setup.sh uninstall.sh scripts/*.sh scripts/hotspot-manager.py
sudo ./setup.sh
```

To uninstall and clean up all firewall rules, configs, and services:

```bash
sudo ./uninstall.sh
```

---

## License

This project is licensed under the MIT License.
