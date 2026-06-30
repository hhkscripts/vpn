#!/usr/bin/env python3
"""
Raspberry Pi Hotspot Manager - Smart Monitoring
"""

import argparse
import html
import re
import subprocess
import sys
import time
from datetime import datetime
from typing import Optional, Sequence, TypedDict


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

GITHUB_ROUTE_SCRIPT = "/usr/local/bin/github-vpn-routes.sh"


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
    ok, out, _ = run_args(["systemctl", "is-active", service])
    return ok and out == "active"


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
    ok, _, _ = run_args(["ping", "-c", "2", "-W", "3", CONFIG["ping_target"]])
    return ok


def check_dns() -> bool:
    ok, _, _ = run_args(["nslookup", "google.com", CONFIG["hotspot_ip"]])
    return ok


def check_ping(target: Optional[str] = None) -> PingStatus:
    target = target or CONFIG["ping_target"]
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
        refresh_github_routes()
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
        refresh_github_routes()
    return ok


def refresh_github_routes() -> None:
    ok, _, err = run_args(["test", "-x", GITHUB_ROUTE_SCRIPT])
    if not ok:
        return

    ok, _, err = run_args(["sudo", GITHUB_ROUTE_SCRIPT])
    if not ok:
        detail = f": {err}" if err else ""
        log(f"GitHub route refresh failed{detail}", "WARN")


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


def print_status(status: HotspotStatus, telegram_format: bool = False) -> str:
    if telegram_format:
        # HTML Formatting for Telegram
        lines = []
        lines.append("<b>📡 HOTSPOT STATUS</b>")
        lines.append("")

        # Services
        lines.append("<b>🔧 SERVICES:</b>")
        for service, ok in status["services"].items():
            icon = "✅" if ok else "❌"
            state = "Running" if ok else "Stopped"
            lines.append(f"{icon} <code>{service}</code>: {state}")
        lines.append("")

        # VPN
        lines.append("<b>🔒 VPN:</b>")
        vpn_connected = status["vpn"]["connected"]
        icon = "✅" if vpn_connected else "❌"
        lines.append(f"{icon} Connected: <code>{vpn_connected}</code>")
        if vpn_connected:
            if status["vpn"].get("ip"):
                ip = status["vpn"]["ip"]
                lines.append(f"• Tunnel IP: <tg-spoiler><code>{ip}</code></tg-spoiler>")
            if status["vpn"].get("external_ip"):
                ext_ip = status["vpn"]["external_ip"]
                lines.append(
                    f"• VPN Exit IP: <tg-spoiler><code>{ext_ip}</code></tg-spoiler>"
                )
        lines.append("")

        # Hotspot
        lines.append("<b>📶 HOTSPOT:</b>")
        hotspot_active = status["hotspot"]["broadcasting"]
        icon = "✅" if hotspot_active else "❌"
        ssid = get_hotspot_ssid()
        lines.append(f"{icon} SSID: <code>{ssid}</code>")
        lines.append(f"• Clients: <code>{status['hotspot']['clients']}</code>")
        lines.append("")

        # Network
        lines.append("<b>🌐 NETWORK:</b>")
        dns_ok = status["dns_working"]
        internet_ok = status["internet"]
        ping = status.get("ping", {})
        ping_result = ping.get("summary") if ping else None

        dns_status = "Working" if dns_ok else "Failed"
        lines.append(f"{'✅' if dns_ok else '❌'} DNS: <code>{dns_status}</code>")
        net_status = "Available" if internet_ok else "Down"
        lines.append(
            f"{'✅' if internet_ok else '❌'} Internet: <code>{net_status}</code>"
        )

        ping_target = (
            ping.get("target", CONFIG["ping_target"]) if ping else CONFIG["ping_target"]
        )

        if ping_result and ping_result != "No ping result":
            safe_ping = html.escape(ping_result)
            ping_icon = "✅" if internet_ok else "❌"
            lines.append(
                f"{ping_icon} Ping <code>{ping_target}</code>: "
                f"<tg-spoiler><code>{safe_ping}</code></tg-spoiler>"
            )
            # Extract RTT if available
            if ping.get("avg_ms") and ping.get("avg_ms") != "?":
                loss = ping.get("loss", "?")
                lines.append(
                    f"  └─ <code>RTT avg: {ping['avg_ms']} ms | Loss: {loss}%</code>"
                )
        else:
            ping_icon = "✅" if internet_ok else "❌"
            lines.append(
                f"{ping_icon} Ping <code>{ping_target}</code>: "
                f"<tg-spoiler><code>No ping result</code></tg-spoiler>"
            )

        return "\n".join(lines)

    # Terminal Formatting (Original)
    output = []
    output.append("\n" + "=" * 55)
    output.append(f"{Colors.BOLD}   HOTSPOT STATUS{Colors.RESET}")
    output.append("=" * 55)

    output.append(f"\n{Colors.BOLD}SERVICES:{Colors.RESET}")
    for service, ok in status["services"].items():
        icon = "✅" if ok else "❌"
        output.append(f"  {icon} {service:<12} {'Running' if ok else 'Stopped'}")

    output.append(f"\n{Colors.BOLD}VPN:{Colors.RESET}")
    icon = "✅" if status["vpn"]["connected"] else "❌"
    output.append(f"  {icon} Connected: {status['vpn']['connected']}")
    if status["vpn"].get("ip"):
        output.append(f"    Tunnel IP: {status['vpn']['ip']}")
    if status["vpn"].get("external_ip"):
        output.append(f"    VPN Exit IP: {status['vpn']['external_ip']}")

    output.append(f"\n{Colors.BOLD}HOTSPOT:{Colors.RESET}")
    icon = "✅" if status["hotspot"]["broadcasting"] else "❌"
    output.append(f"  {icon} SSID: {get_hotspot_ssid()}")
    output.append(f"    Clients: {status['hotspot']['clients']}")

    output.append(f"\n{Colors.BOLD}NETWORK:{Colors.RESET}")
    dns_icon = "✅" if status["dns_working"] else "❌"
    output.append(
        f"  {dns_icon} DNS: {'Working' if status['dns_working'] else 'Failed'}"
    )

    internet_icon = "✅" if status["internet"] else "❌"
    internet_state = "Available" if status["internet"] else "Down"
    output.append(f"  {internet_icon} Internet: {internet_state}")

    ping = status.get("ping", {})
    ping_icon = "✅" if ping.get("ok") else "❌"
    ping_target = ping.get("target", CONFIG["ping_target"])
    ping_summary = ping.get("summary", "No ping result")
    output.append(f"  {ping_icon} Ping {ping_target}: {ping_summary}")
    if ping.get("avg_ms") and ping.get("avg_ms") != "?":
        output.append(
            f"    RTT avg: {ping['avg_ms']} ms | Loss: {ping.get('loss', '?')}%"
        )

    output.append("=" * 55 + "\n")

    return "\n".join(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("-s", "--status", action="store_true")
    parser.add_argument("-r", "--restart", action="store_true")
    parser.add_argument("-rv", "--restart-vpn", action="store_true")
    parser.add_argument("-f", "--fix", action="store_true")
    parser.add_argument("--clients", action="store_true")
    parser.add_argument(
        "--telegram", action="store_true", help="Output in HTML format for Telegram"
    )

    args = parser.parse_args()

    if len(sys.argv) == 1:
        args.status = True

    if args.status:
        output = print_status(get_status(), telegram_format=args.telegram)
        print(output)

    if args.clients:
        print(f"Clients: {check_clients()}")

    if args.restart_vpn:
        restart_vpn()

    if args.fix:
        fix_hotspot()
        output = print_status(get_status(), telegram_format=args.telegram)
        print(output)

    if args.restart:
        fix_hotspot()


if __name__ == "__main__":
    main()
