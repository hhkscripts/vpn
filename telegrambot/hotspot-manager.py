#!/usr/bin/env python3
"""
Raspberry Pi Hotspot Manager - Smart Monitoring
"""

import argparse
import re
import subprocess
import sys
import time
from datetime import datetime
from typing import Optional, Sequence, TypedDict, List


class Config(TypedDict):
    services: list[str]
    vpn_name: str
    default_hotspot_ssid: str
    hostapd_conf: str
    hotspot_ip: str
    interface_wlan: str
    log_file: str
    ping_target: str


class PingStatus(TypedDict):
    ok: bool
    target: str
    summary: str
    rtt: str
    loss: str
    avg_ms: str


class VpnStatus(TypedDict):
    connected: bool
    ip: Optional[str]
    external_ip: Optional[str]
    external_ok: bool


class HotspotInfo(TypedDict):
    broadcasting: bool
    clients: int


class HotspotStatus(TypedDict):
    services: dict[str, bool]
    vpn: VpnStatus
    hotspot: HotspotInfo
    dns_working: bool
    internet: bool
    ping: PingStatus


CONFIG: Config = {
    "services": ["hostapd", "dnsmasq"],
    "vpn_name": "pi",
    "default_hotspot_ssid": "GoodWifi",
    "hostapd_conf": "/etc/hostapd/hostapd.conf",
    "hotspot_ip": "10.42.0.1",
    "interface_wlan": "wlan0",
    "log_file": "/var/log/hotspot-manager.log",
    "ping_target": "8.8.8.8",
}

CUSTOM_EMOJIS = {
    "signal": '<tg-emoji emoji-id="6127157759872868272">📡</tg-emoji>',      # 📡 အစား
    "tools": '<tg-emoji emoji-id="6141134446742478627">🔧</tg-emoji>',       # 🔧 အစား
    "check": '<tg-emoji emoji-id="6114156013399579882">✅</tg-emoji>',       # ✅ အစား
    "lock": '<tg-emoji emoji-id="6059947491695008618">🔒</tg-emoji>',        # 🔒 အစား
    "stats": '<tg-emoji emoji-id="6143449494244563627">📶</tg-emoji>',       # 📶 အစား (📊)
    "globe": '<tg-emoji emoji-id="6057443049020071219">🌐</tg-emoji>',       # 🌐 အစား
    "cross": '<tg-emoji emoji-id="6111658378247806635">❌</tg-emoji>'        # ❌ အစား
}

# အဆင်ပြေအောင် Short variable names ထပ်သတ်မှတ်နိုင်ပါတယ် (Optional)
EMOJI_SIGNAL = CUSTOM_EMOJIS["signal"]
EMOJI_TOOLS = CUSTOM_EMOJIS["tools"]
EMOJI_CHECK = CUSTOM_EMOJIS["check"]
EMOJI_LOCK = CUSTOM_EMOJIS["lock"]
EMOJI_STATS = CUSTOM_EMOJIS["stats"]
EMOJI_GLOBE = CUSTOM_EMOJIS["globe"]
EMOJI_CROSS = CUSTOM_EMOJIS["cross"]

class Colors:
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    BOLD = "\033[1m"
    RESET = "\033[0m"


def log(msg: str, level: str = "INFO") -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(CONFIG["log_file"], "a") as f:
            f.write(f"[{timestamp}] [{level}] {msg}\n")
    except Exception:
        pass
    print(msg)


def run_args(cmd: Sequence[str]) -> tuple[bool, str, str]:
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, check=False
        )
        return result.returncode == 0, result.stdout.strip(), result.stderr.strip()
    except Exception:
        return False, "", ""


def check_service(service: str) -> bool:
    # Try systemctl first (works on host, fails in Docker chroot)
    ok, out, _ = run_args(["systemctl", "is-active", service])
    if ok and out == "active":
        return True
    
    # Fallback: Check if process is running using pgrep (works in Docker with host PID)
    ok, out, _ = run_args(["pgrep", "-x", service])
    if ok and out.strip():
        return True
    
    # Additional fallback for dnsmasq (might run as dnsmasq not exact match)
    if service == "dnsmasq":
        ok, out, _ = run_args(["pgrep", "-f", "dnsmasq"])
        if ok and out.strip():
            return True
    
    # Additional fallback for hostapd
    if service == "hostapd":
        ok, out, _ = run_args(["pgrep", "-f", "hostapd"])
        if ok and out.strip():
            return True
    
    return False


def check_vpn() -> bool:
    ok, out, _ = run_args(["ip", "-4", "addr", "show", "tun0"])
    if ok and "inet " in out:
        return True

    ok, out, _ = run_args(
        [
            "nmcli",
            "-t",
            "-f",
            "TYPE,STATE",
            "connection",
            "show",
            "--active",
        ]
    )
    if ok and "vpn:activated" in out.lower():
        return True

    return False


def check_vpn_ip() -> tuple[bool, str]:
    ok, out, _ = run_args(["ip", "-4", "-o", "addr", "show", "tun0"])
    if ok:
        for line in out.splitlines():
            parts = line.split()
            if "inet" in parts:
                cidr = parts[parts.index("inet") + 1]
                return True, cidr.split("/", 1)[0]
    return False, "None"


def check_vpn_external_ip() -> tuple[bool, str]:
    ok, out, _ = run_args(
        [
            "curl",
            "-4",
            "-s",
            "--max-time",
            "8",
            "--interface",
            "tun0",
            "https://ifconfig.me",
        ]
    )
    if ok and out:
        return True, out
    return False, "None"


def check_internet() -> bool:
    # Try multiple targets and interfaces to ensure robustness in Docker
    targets = [CONFIG["ping_target"], "1.1.1.1", "8.8.4.4"]
    for target in targets:
        # Use -I tun0 if VPN is active, otherwise let kernel route
        vpn_ok, _, _ = run_args(["ip", "-4", "addr", "show", "tun0"])
        if vpn_ok:
            ok, _, _ = run_args(["ping", "-c", "2", "-W", "3", "-I", "tun0", target])
        else:
            ok, _, _ = run_args(["ping", "-c", "2", "-W", "3", target])
        
        if ok:
            return True
    return False


def check_dns() -> bool:
    ok, _, _ = run_args(["nslookup", "google.com", CONFIG["hotspot_ip"]])
    return ok


def check_ping(target: Optional[str] = None) -> PingStatus:
    target = target or CONFIG["ping_target"]
    
    # Try with tun0 interface first if VPN is active, then fallback to default routing
    vpn_ok, _, _ = run_args(["ip", "-4", "addr", "show", "tun0"])
    
    if vpn_ok:
        ok, out, _ = run_args(["ping", "-c", "3", "-W", "2", "-I", "tun0", target])
        if not ok:
            # Fallback to default routing if tun0 ping fails
            ok, out, _ = run_args(["ping", "-c", "3", "-W", "2", target])
    else:
        ok, out, _ = run_args(["ping", "-c", "3", "-W", "2", target])
    
    packet_line = "No ping result"
    rtt_line = ""
    for line in out.splitlines():
        if "packets transmitted" in line:
            packet_line = line.strip()
        elif line.startswith("rtt "):
            rtt_line = line.strip()

    loss_match = re.search(r"(\d+(?:\.\d+)?)% packet loss", packet_line)
    loss = loss_match.group(1) if loss_match else "?"
    avg_match = re.search(r"= ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms", rtt_line)
    avg = avg_match.group(2) if avg_match else "?"
    return {
        "ok": ok,
        "target": target,
        "summary": packet_line,
        "rtt": rtt_line,
        "loss": loss,
        "avg_ms": avg,
    }


def check_clients() -> int:
    wlan = CONFIG["interface_wlan"]
    ok, out, _ = run_args(["iw", "dev", wlan, "station", "dump"])
    if ok:
        return sum(1 for line in out.splitlines() if line.startswith("Station "))
    return 0


def check_hotspot() -> bool:
    ok, out, _ = run_args(["iw", "dev", CONFIG["interface_wlan"], "info"])
    return ok and any(line.strip() == "type AP" for line in out.splitlines())


def get_hotspot_ssid() -> str:
    try:
        with open(CONFIG["hostapd_conf"]) as conf:
            for line in conf:
                if line.startswith("ssid="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return CONFIG["default_hotspot_ssid"]


def restart_vpn() -> bool:
    if check_vpn():
        log("VPN already connected")
        run_args(
            [
                "sudo",
                "/etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy",
                "tun0",
                "up",
            ]
        )
        return True
    log("VPN not connected, connecting...")
    run_args(["sudo", "nmcli", "connection", "down", CONFIG["vpn_name"]])
    time.sleep(2)
    ok, _, _ = run_args(["sudo", "nmcli", "connection", "up", CONFIG["vpn_name"]])
    if ok:
        log("VPN connected", "SUCCESS")
        time.sleep(3)
        run_args(
            [
                "sudo",
                "/etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy",
                "tun0",
                "up",
            ]
        )
    return ok


def fix_hotspot() -> bool:
    log("Restarting hotspot services...")
    run_args(["sudo", "systemctl", "restart", "hostapd", "dnsmasq"])
    time.sleep(2)
    vpn_ok = restart_vpn()
    run_args(
        ["sudo", "/etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy", "tun0", "up"]
    )
    return vpn_ok


def get_status() -> HotspotStatus:
    clients = check_clients()
    vpn_connected = check_vpn()
    _vpn_ip_ok, vpn_ip = check_vpn_ip() if vpn_connected else (False, None)
    external_ok, external_ip = (
        check_vpn_external_ip() if vpn_connected else (False, None)
    )

    return {
        "services": {s: check_service(s) for s in CONFIG["services"]},
        "vpn": {
            "connected": vpn_connected,
            "ip": vpn_ip,
            "external_ip": external_ip,
            "external_ok": external_ok,
        },
        "hotspot": {"broadcasting": check_hotspot(), "clients": clients},
        "dns_working": check_dns(),
        "internet": check_internet(),
        "ping": check_ping(),
    }


def print_status(status: HotspotStatus, telegram_format: bool = False, html_format: bool = False) -> None:
    # Helper to format text for telegram (code blocks + spoilers) or plain terminal
    def fmt_code(text: str) -> str:
        if html_format:
            return f"<code>{text}</code>"
        return f"`{text}`" if telegram_format else text

    def fmt_spoiler_code(text: str) -> str:
        # Telegram: ||`code`|| (spoiler containing code) for Markdown
        # HTML: <tg-spoiler><code>text</code></tg-spoiler>
        if html_format:
            return f"<tg-spoiler><code>{text}</code></tg-spoiler>"
        return f"||`{text}`||" if telegram_format else text

    def fmt_bold(text: str) -> str:
        if html_format:
            return f"<b>{text}</b>"
        return f"*{text}*" if telegram_format else text

    lines: List[str] = []

    # --- Emoji Selection Logic ---
    # Terminal mode မှာတော့ မူလ Unicode ကိုသုံးပြီး၊ Telegram/HTML မှာတော့ Custom Emoji ကိုသုံးမည်
    if telegram_format or html_format:
        ICON_OK = EMOJI_CHECK
        ICON_FAIL = EMOJI_CROSS
        ICON_SIGNAL = EMOJI_SIGNAL
        ICON_TOOLS = EMOJI_TOOLS
        ICON_LOCK = EMOJI_LOCK
        ICON_STATS = EMOJI_STATS
        ICON_GLOBE = EMOJI_GLOBE
    else:
        ICON_OK = "✅"
        ICON_FAIL = "❌"
        ICON_SIGNAL = "📡"
        ICON_TOOLS = "🔧"
        ICON_LOCK = "🔒"
        ICON_STATS = "📶"
        ICON_GLOBE = "🌐"
    # -----------------------------
    
    # Header - Clean UI without ASCII borders for Telegram
    if telegram_format or html_format:
        lines.append(fmt_bold(f"{ICON_SIGNAL} HOTSPOT STATUS"))
        lines.append("")
    else:
        lines.append("\n" + "=" * 55)
        lines.append(f"{Colors.BOLD}   HOTSPOT STATUS{Colors.RESET}")
        lines.append("=" * 55)

    # Services Section
    if telegram_format or html_format:
        lines.append(fmt_bold(f"{ICON_TOOLS} SERVICES:"))
    else:
        lines.append(f"\n{Colors.BOLD}SERVICES:{Colors.RESET}")

    for service, ok in status["services"].items():
        icon = ICON_OK if ok else ICON_FAIL
        state = "Running" if ok else "Stopped"
        if telegram_format or html_format:
            lines.append(f"{icon} {fmt_code(service)}: {state}")
        else:
            lines.append(f"  {icon} {service:<12} {state}")

    # VPN Section
    if telegram_format or html_format:
        lines.append("")
        lines.append(fmt_bold(f"{ICON_LOCK} VPN:"))
    else:
        lines.append(f"\n{Colors.BOLD}VPN:{Colors.RESET}")

    icon = ICON_OK if status["vpn"]["connected"] else ICON_FAIL
    if telegram_format or html_format:
        lines.append(f"{icon} Connected: {fmt_code(str(status['vpn']['connected']))}")
    else:
        lines.append(f"  {icon} Connected: {status['vpn']['connected']}")
        
    if status["vpn"].get("ip"):
        vpn_ip = status["vpn"]["ip"]
        if vpn_ip:
            ip_text = fmt_spoiler_code(vpn_ip)
            if telegram_format or html_format:
                lines.append(f"  • Tunnel IP: {ip_text}")
            else:
                lines.append(f"    Tunnel IP: {ip_text}")

    if status["vpn"].get("external_ip"):
        ext_ip = status["vpn"]["external_ip"]
        if ext_ip:
            exit_text = fmt_spoiler_code(ext_ip)
            if telegram_format or html_format:
                lines.append(f"  • VPN Exit IP: {exit_text}")
            else:
                lines.append(f"    VPN Exit IP: {exit_text}")

    # Hotspot Section
    if telegram_format or html_format:
        lines.append("")
        lines.append(fmt_bold(f"{ICON_STATS} HOTSPOT:"))
    else:
        lines.append(f"\n{Colors.BOLD}HOTSPOT:{Colors.RESET}")
        
    icon = ICON_OK if status["hotspot"]["broadcasting"] else ICON_FAIL
    ssid = get_hotspot_ssid()
    if telegram_format or html_format:
        lines.append(f"{icon} SSID: {fmt_code(ssid)}")
        lines.append(f"  • Clients: {fmt_code(str(status['hotspot']['clients']))}")
    else:
        lines.append(f"  {icon} SSID: {ssid}")
        lines.append(f"    Clients: {status['hotspot']['clients']}")

    # Network Section
    if telegram_format or html_format:
        lines.append("")
        lines.append(fmt_bold(f"{ICON_GLOBE} NETWORK:"))
    else:
        lines.append(f"\n{Colors.BOLD}NETWORK:{Colors.RESET}")
        
    dns_icon = ICON_OK if status["dns_working"] else ICON_FAIL
    dns_state = "Working" if status["dns_working"] else "Failed"
    if telegram_format or html_format:
        lines.append(f"{dns_icon} DNS: {fmt_code(dns_state)}")
    else:
        lines.append(f"  {dns_icon} DNS: {'Working' if status['dns_working'] else 'Failed'}")

    internet_icon = ICON_OK if status["internet"] else ICON_FAIL
    internet_state = "Available" if status["internet"] else "Down"
    if telegram_format or html_format:
        lines.append(f"{internet_icon} Internet: {fmt_code(internet_state)}")
    else:
        lines.append(f"  {internet_icon} Internet: {internet_state}")

    ping = status.get("ping", {})
    ping_icon = ICON_OK if ping.get("ok") else ICON_FAIL
    ping_target = ping.get("target", CONFIG["ping_target"])
    ping_summary = ping.get("summary", "No ping result")
    
    # Format ping target as code for Telegram/HTML
    if telegram_format or html_format:
        ping_target_display = fmt_code(ping_target)
    else:
        ping_target_display = ping_target
    
    # Format ping summary as code inside spoiler for Telegram
    if telegram_format or html_format:
        ping_display = fmt_spoiler_code(ping_summary)
        lines.append(f"{ping_icon} Ping {ping_target_display}: {ping_display}")
    else:
        ping_display = ping_summary
        lines.append(f"  {ping_icon} Ping {ping_target_display}: {ping_display}")
    
    if ping.get("avg_ms") and ping.get("avg_ms") != "?":
        rtt_loss = f"RTT avg: {ping['avg_ms']} ms | Loss: {ping.get('loss', '?')}%"
        if telegram_format or html_format:
            rtt_loss = fmt_code(rtt_loss)
            lines.append(f"  └─ {rtt_loss}")
        else:
            lines.append(f"    {rtt_loss}")

    if not telegram_format and not html_format:
        lines.append("=" * 55 + "\n")
    else:
        lines.append("")
    
    # Print to stdout
    for line in lines:
        print(line)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("-s", "--status", action="store_true")
    parser.add_argument("-r", "--restart", action="store_true")
    parser.add_argument("-rv", "--restart-vpn", action="store_true")
    parser.add_argument("-f", "--fix", action="store_true")
    parser.add_argument("--clients", action="store_true")
    parser.add_argument("--telegram", action="store_true", help="Output formatted for Telegram (spoilers/code)")
    parser.add_argument("--html", action="store_true", help="Output formatted as HTML for Telegram")

    args = parser.parse_args()

    if len(sys.argv) == 1:
        args.status = True

    if args.status:
        print_status(get_status(), telegram_format=args.telegram, html_format=args.html)

    if args.clients:
        print(f"Clients: {check_clients()}")

    if args.restart_vpn:
        restart_vpn()

    if args.fix:
        fix_hotspot()
        print_status(get_status())

    if args.restart:
        fix_hotspot()


if __name__ == "__main__":
    main()
