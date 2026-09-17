#!/usr/bin/env python3
"""
Raspberry Pi Hotspot Manager - Smart Monitoring
"""

import argparse
import html
import re
import subprocess
import os
import sys
import time
from datetime import datetime
from typing import Optional, Sequence, TypedDict


class Config(TypedDict, total=False):
    services: list[str]
    vpn_name: str
    default_hotspot_ssid: str
    hostapd_conf: str
    hotspot_ip: str
    interface_wlan: str
    log_file: str
    ping_target: str
    hotspot_subnet: str
    adguard_container: str
    telegram_container: str
    adguard_enabled: bool


class PingStatus(TypedDict):
    ok: bool
    target: str
    summary: str
    rtt: str
    loss: str
    avg_ms: str


class VpnStatus(TypedDict):
    connected: bool
    interface: str
    backend: str
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
    ipv6_protection: str


CONFIG: Config = {
    "services": ["hostapd", "dnsmasq"],
    "vpn_name": "",
    "default_hotspot_ssid": "GoodWifi",
    "hostapd_conf": "/etc/hostapd/hostapd.conf",
    "hotspot_ip": "10.42.0.1",
    "interface_wlan": "wlan0",
    "log_file": "/var/log/hotspot-manager.log",
    "ping_target": "8.8.8.8",
    "hotspot_subnet": "10.42.0.0/24",
    "adguard_container": "adguardhome",
    "telegram_container": "mpxraspberrypibot",
    "adguard_enabled": True,
}

GITHUB_ROUTE_SCRIPT = "/usr/local/bin/github-vpn-routes.sh"
POLICY_SCRIPT = "/etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy"

CUSTOM_EMOJIS = {
    "signal": '<tg-emoji emoji-id="6127157759872868272">📡</tg-emoji>',
    "tools": '<tg-emoji emoji-id="6141134446742478627">🔧</tg-emoji>',
    "check": '<tg-emoji emoji-id="6114156013399579882">✅</tg-emoji>',
    "lock": '<tg-emoji emoji-id="6059947491695008618">🔒</tg-emoji>',
    "stats": '<tg-emoji emoji-id="6143449494244563627">📶</tg-emoji>',
    "globe": '<tg-emoji emoji-id="6057443049020071219">🌐</tg-emoji>',
    "cross": '<tg-emoji emoji-id="6111658378247806635">❌</tg-emoji>',
    "ping": '<tg-emoji emoji-id="6060045064762039982">⏲</tg-emoji>',
}

EMOJI_SIGNAL = CUSTOM_EMOJIS["signal"]
EMOJI_TOOLS = CUSTOM_EMOJIS["tools"]
EMOJI_CHECK = CUSTOM_EMOJIS["check"]
EMOJI_LOCK = CUSTOM_EMOJIS["lock"]
EMOJI_STATS = CUSTOM_EMOJIS["stats"]
EMOJI_GLOBE = CUSTOM_EMOJIS["globe"]
EMOJI_CROSS = CUSTOM_EMOJIS["cross"]
EMOJI_PING = CUSTOM_EMOJIS["ping"]
GOODWIFI_CONF = "/etc/goodwifi/goodwifi.conf"

def get_host_path(path: str) -> str:
    if not os.path.exists(path) and os.path.exists(f"/host{path}"):
        return f"/host{path}"
    return path


def load_goodwifi_conf() -> None:
    conf_path = GOODWIFI_CONF
    if not os.path.exists(conf_path) and os.path.exists(f"/host{GOODWIFI_CONF}"):
        conf_path = f"/host{GOODWIFI_CONF}"

    if os.path.exists(conf_path):
        try:
            with open(conf_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    if k == "HOTSPOT_IF" and v:
                        CONFIG["interface_wlan"] = v
                    elif k == "HOTSPOT_IP" and v:
                        CONFIG["hotspot_ip"] = v
                    elif k == "HOTSPOT_SUBNET" and v:
                        CONFIG["hotspot_subnet"] = v
                    elif k == "PING_TARGET" and v:
                        CONFIG["ping_target"] = v
                    elif k == "VPN_UUID" and v:
                        CONFIG["vpn_name"] = v
                    elif k == "ADGUARD_CONTAINER" and v:
                        CONFIG["adguard_container"] = v
                    elif k == "TELEGRAM_CONTAINER" and v:
                        CONFIG["telegram_container"] = v
                    elif k == "ADGUARD_ENABLED" and v:
                        CONFIG["adguard_enabled"] = v.lower() not in ["false", "0", "off", "no", "disable", "disabled"]
        except Exception:
            pass


load_goodwifi_conf()


def update_goodwifi_conf(key: str, value: str) -> bool:
    try:
        run_args(["sudo", "mkdir", "-p", os.path.dirname(GOODWIFI_CONF)])
        content = ""
        ok, out, _ = run_args(["cat", GOODWIFI_CONF])
        if ok and out:
            lines = out.splitlines()
            found = False
            new_lines = []
            for line in lines:
                if line.strip().startswith(f"{key}="):
                    new_lines.append(f'{key}="{value}"')
                    found = True
                else:
                    new_lines.append(line)
            if not found:
                new_lines.append(f'{key}="{value}"')
            content = "\n".join(new_lines) + "\n"
        else:
            content = f'{key}="{value}"\n'

        import tempfile

        with tempfile.NamedTemporaryFile(mode="w", delete=False) as tf:
            tf.write(content)
            temp_path = tf.name
        run_args(["sudo", "cp", temp_path, GOODWIFI_CONF])
        run_args(["sudo", "chmod", "0644", GOODWIFI_CONF])
        os.unlink(temp_path)
        return True
    except Exception as e:
        log(f"Could not update {GOODWIFI_CONF}: {e}", "WARN")
        return False


def get_configured_backend() -> str:
    if os.path.exists(GOODWIFI_CONF):
        try:
            with open(GOODWIFI_CONF, "r") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("VPN_BACKEND="):
                        val = line.split("=", 1)[1].strip().strip('"').strip("'")
                        if val in ["awg0", "tun0", "wg0", "auto"]:
                            return val
        except Exception:
            pass
    return "auto"


def get_configured_ipv6_mode() -> str:
    if os.path.exists(GOODWIFI_CONF):
        try:
            with open(GOODWIFI_CONF, "r") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("IPV6_LEAK_PROTECTION="):
                        val = (
                            line.split("=", 1)[1].strip().strip('"').strip("'").lower()
                        )
                        if val in ["drop", "reject", "off"]:
                            return val
        except Exception:
            pass
    return "drop"


def get_active_vpn_interface() -> tuple[str, str]:
    """Returns (interface_name, display_name)."""
    ok, out, _ = run_args(["ip", "route", "show", "table", "100"])
    if ok:
        for line in out.splitlines():
            if line.startswith("default dev "):
                parts = line.split()
                if len(parts) >= 3:
                    dev = parts[2]
                    if dev == "awg0":
                        return "awg0", "AmneziaWG"
                    elif dev == "wg0":
                        return "wg0", "WireGuard"
                    elif dev == "tun0":
                        return "tun0", "OpenVPN"

    configured = get_configured_backend()
    if configured in ["awg0", "wg0", "tun0"]:
        name = (
            "AmneziaWG"
            if configured == "awg0"
            else ("WireGuard" if configured == "wg0" else "OpenVPN")
        )
        return configured, name

    for iface, name in [
        ("awg0", "AmneziaWG"),
        ("wg0", "WireGuard"),
        ("tun0", "OpenVPN"),
    ]:
        ok, out, _ = run_args(["ip", "-4", "addr", "show", iface])
        if ok and "inet " in out:
            return iface, name

    ok, _, _ = run_args(["ip", "link", "show", "awg0"])
    if ok:
        return "awg0", "AmneziaWG"
    return "tun0", "OpenVPN"


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


def run_args(cmd: Sequence[str], timeout: int = 30) -> tuple[bool, str, str]:
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return result.returncode == 0, result.stdout.strip(), result.stderr.strip()
    except Exception as exc:
        return False, "", str(exc)


def check_service(service: str) -> bool:
    ok, out, _ = run_args(["systemctl", "is-active", service])
    return ok and out == "active"


def check_docker_container(container: str) -> Optional[bool]:
    """Check whether a Docker container is running.
    Returns True if running, False if stopped, or None if Docker/container
    is not available.
    """
    ok, out, _ = run_args(
        ["docker", "inspect", "-f", "{{.State.Running}}", container], timeout=5
    )
    if ok and out.lower() in ["true", "false"]:
        return out.lower() == "true"

    if (
        os.path.exists("/host/bin/docker")
        or os.path.exists("/host/usr/bin/docker")
        or os.path.exists("/host/var/run/docker.sock")
    ):
        ok, out, _ = run_args(
            [
                "chroot",
                "/host",
                "docker",
                "inspect",
                "-f",
                "{{.State.Running}}",
                container,
            ],
            timeout=5,
        )
        if ok and out.lower() in ["true", "false"]:
            return out.lower() == "true"

    return None


def check_vpn() -> bool:
    iface, _ = get_active_vpn_interface()
    ok, out, _ = run_args(["ip", "-4", "addr", "show", iface])
    if ok and "inet " in out:
        return True

    for fallback in ["awg0", "wg0", "tun0"]:
        ok, out, _ = run_args(["ip", "-4", "addr", "show", fallback])
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
    iface, _ = get_active_vpn_interface()
    for candidate in [iface, "awg0", "wg0", "tun0"]:
        ok, out, _ = run_args(["ip", "-4", "-o", "addr", "show", candidate])
        if ok:
            for line in out.splitlines():
                parts = line.split()
                if "inet" in parts:
                    cidr = parts[parts.index("inet") + 1]
                    return True, cidr.split("/", 1)[0]
    return False, "None"


def check_vpn_external_ip() -> tuple[bool, str]:
    iface, _ = get_active_vpn_interface()
    for candidate in [iface, "awg0", "wg0", "tun0"]:
        ok, out, _ = run_args(
            [
                "curl",
                "-4",
                "-s",
                "--max-time",
                "8",
                "--interface",
                candidate,
                "https://ifconfig.me",
            ]
        )
        if ok and out and out.strip():
            return True, out.strip()
    return False, "None"


def check_internet() -> bool:
    targets = [CONFIG["ping_target"], "1.1.1.1", "8.8.4.4"]
    active_if, _ = get_active_vpn_interface()
    vpn_ok, _, _ = run_args(["ip", "-4", "addr", "show", active_if])
    for target in targets:
        if vpn_ok:
            ok, _, _ = run_args(["ping", "-c", "2", "-W", "3", "-I", active_if, target])
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
    active_if, _ = get_active_vpn_interface()
    vpn_ok, _, _ = run_args(["ip", "-4", "addr", "show", active_if])
    if vpn_ok:
        ok, out, _ = run_args(["ping", "-c", "3", "-W", "2", "-I", active_if, target])
        if not ok:
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


def apply_vpn_policy(interface: Optional[str] = None) -> bool:
    if not interface or interface == "auto":
        interface, _ = get_active_vpn_interface()
    ok, out, err = run_args(["sudo", POLICY_SCRIPT, interface, "apply"])
    if not ok:
        detail = err or out or "unknown error"
        log(f"VPN policy apply failed: {detail}", "ERROR")
        return False

    route_ok, route_out, _ = run_args(["ip", "route", "show", "table", "100"])
    rule_ok, rule_out, _ = run_args(["ip", "rule", "show"])
    policy_ok = (
        route_ok
        and (f"default dev {interface}" in route_out or "default dev" in route_out)
        and rule_ok
        and (
            f"from {CONFIG.get('hotspot_subnet', '10.42.0.0/24')} lookup 100"
            in rule_out
            or f"from {CONFIG.get('hotspot_subnet', '10.42.0.0/24')} lookup github_vpn"
            in rule_out
            or "from 10.42.0.0/24 lookup 100" in rule_out
            or "from 10.42.0.0/24 lookup github_vpn" in rule_out
        )
    )
    if not policy_ok:
        log("VPN policy apply did not install GoodWifi table 100 routing", "ERROR")
        return False
    return True


def get_vpn_connection_name() -> str:
    """Return configured or auto-detected NetworkManager VPN connection name."""
    configured = CONFIG.get("vpn_name", "")
    ok, out, _ = run_args(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"])
    if not ok or not out:
        return configured or "pi"

    lines = out.splitlines()
    if configured:
        for line in lines:
            if line.split(":", 1)[0] == configured:
                return configured

    ok_act, out_act, _ = run_args(
        ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active"]
    )
    if ok_act and out_act:
        for line in out_act.splitlines():
            if ":" in line:
                name, ctype = line.split(":", 1)
                if ctype in ["vpn", "wireguard"] and name:
                    return name

    for line in lines:
        if ":" in line:
            name, ctype = line.split(":", 1)
            if ctype in ["vpn", "wireguard"] and name:
                return name

    return configured or "pi"


def switch_vpn(target: str) -> bool:
    target = target.lower()
    if target not in ["awg0", "tun0", "wg0", "auto"]:
        log(f"Invalid target: {target}. Choose from: awg0, tun0, wg0, auto", "ERROR")
        return False

    update_goodwifi_conf("VPN_BACKEND", target)

    log(f"Switching VPN backend to {target}...")
    vpn_name = get_vpn_connection_name()
    if target in ["awg0", "wg0"]:
        run_args(["sudo", "nmcli", "connection", "down", vpn_name], timeout=15)
        svc = "awg-quick@awg0" if target == "awg0" else "wg-quick@wg0"
        run_args(["sudo", "systemctl", "start", svc], timeout=30)
        wait_for_interface(target, timeout=10)
        ok = apply_vpn_policy(target)
        refresh_github_routes()
        return ok
    elif target == "tun0":
        run_args(
            ["sudo", "systemctl", "stop", "awg-quick@awg0", "wg-quick@wg0"], timeout=15
        )
        run_args(["sudo", "nmcli", "connection", "up", vpn_name], timeout=70)
        wait_for_interface("tun0", timeout=15)
        ok = apply_vpn_policy("tun0")
        refresh_github_routes()
        return ok
    else:  # auto
        iface, _ = get_active_vpn_interface()
        ok = apply_vpn_policy(iface)
        refresh_github_routes()
        return ok


def wait_for_interface(interface: str, timeout: int = 60) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        ok, _, _ = run_args(["ip", "link", "show", "dev", interface])
        if ok:
            return True
        time.sleep(1)
    return False


def restart_vpn() -> bool:
    target = get_configured_backend()
    if target == "awg0":
        log("Restarting AmneziaWG (awg0)...")
        run_args(["sudo", "systemctl", "restart", "awg-quick@awg0"], timeout=30)
        if wait_for_interface("awg0", timeout=10):
            log("AmneziaWG connected", "SUCCESS")
            policy_ok = apply_vpn_policy("awg0")
            refresh_github_routes()
            return policy_ok
        log("AmneziaWG restart failed", "ERROR")
        return False
    elif target == "wg0":
        log("Restarting WireGuard (wg0)...")
        run_args(["sudo", "systemctl", "restart", "wg-quick@wg0"], timeout=30)
        if wait_for_interface("wg0", timeout=10):
            log("WireGuard connected", "SUCCESS")
            policy_ok = apply_vpn_policy("wg0")
            refresh_github_routes()
            return policy_ok
        log("WireGuard restart failed", "ERROR")
        return False

    if check_vpn():
        log("Restarting OpenVPN connection...")
    else:
        log("VPN not connected, connecting...")
    vpn_name = get_vpn_connection_name()
    run_args(["sudo", "nmcli", "connection", "down", vpn_name], timeout=20)
    time.sleep(2)
    last_error = "unknown error"
    for attempt in range(1, 3):
        ok, out, err = run_args(
            ["sudo", "nmcli", "connection", "up", vpn_name],
            timeout=70,
        )
        if (ok or check_vpn()) and wait_for_interface("tun0", timeout=15):
            log("VPN connected", "SUCCESS")
            policy_ok = apply_vpn_policy()
            refresh_github_routes()
            return policy_ok

        last_error = err or out or "VPN interface did not become available"
        if attempt < 2:
            log(f"VPN activation attempt {attempt} failed; retrying...", "WARN")
            run_args(
                ["sudo", "nmcli", "connection", "down", vpn_name],
                timeout=20,
            )
            time.sleep(2)

    log(f"VPN activation failed: {last_error}", "ERROR")
    return False


def refresh_github_routes() -> None:
    ok, _, err = run_args(["test", "-x", GITHUB_ROUTE_SCRIPT])
    if not ok:
        return

    ok, _, err = run_args(["sudo", GITHUB_ROUTE_SCRIPT], timeout=120)
    if not ok:
        detail = f": {err}" if err else ""
        log(f"GitHub route refresh failed{detail}", "WARN")




def get_adguard_enabled() -> bool:
    conf_path = get_host_path(GOODWIFI_CONF)
    if os.path.exists(conf_path):
        try:
            with open(conf_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("ADGUARD_ENABLED="):
                        val = (
                            line.split("=", 1)[1].strip().strip('"').strip("'").lower()
                        )
                        if val in ["false", "0", "off", "no", "disable", "disabled"]:
                            return False
                        elif val in ["true", "1", "on", "yes", "enable", "enabled"]:
                            return True
        except Exception:
            pass
    st = check_docker_container(CONFIG.get("adguard_container", "adguardhome"))
    if st is False:
        return False
    return True


def configure_dnsmasq_fallback(enable_fallback: bool) -> bool:
    conf_path = get_host_path("/etc/dnsmasq.conf")
    if not os.path.exists(conf_path):
        return False
    try:
        with open(conf_path, "r", encoding="utf-8") as f:
            content = f.read()

        lines = content.splitlines()
        new_lines = []
        if enable_fallback:
            has_fallback_server = False
            for line in lines:
                stripped = line.strip()
                if stripped == "port=0":
                    new_lines.append("#port=0")
                    new_lines.append("server=1.1.1.1")
                    new_lines.append("server=8.8.8.8")
                    has_fallback_server = True
                elif stripped.startswith("server=1.1.1.1") or stripped.startswith(
                    "server=8.8.8.8"
                ):
                    has_fallback_server = True
                    new_lines.append(line)
                else:
                    new_lines.append(line)
            if not has_fallback_server:
                new_lines.append("server=1.1.1.1")
                new_lines.append("server=8.8.8.8")
        else:
            has_port_zero = False
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("server=1.1.1.1") or stripped.startswith(
                    "server=8.8.8.8"
                ):
                    continue
                if stripped == "#port=0":
                    new_lines.append("port=0")
                    has_port_zero = True
                else:
                    if stripped == "port=0":
                        has_port_zero = True
                    new_lines.append(line)
            if not has_port_zero:
                new_lines.insert(0, "port=0")

        new_content = "\n".join(new_lines) + "\n"
        import tempfile

        with tempfile.NamedTemporaryFile(mode="w", delete=False) as tf:
            tf.write(new_content)
            temp_path = tf.name
        run_args(["sudo", "cp", temp_path, conf_path])
        run_args(["sudo", "chmod", "0644", conf_path])
        os.unlink(temp_path)
        return True
    except Exception as e:
        log(f"Could not update dnsmasq config: {e}", "WARN")
        return False


def set_adguard_state(enable: bool) -> bool:
    container_name = CONFIG.get("adguard_container", "adguardhome")
    if enable:
        log("Enabling AdGuard Home DNS service...")
        update_goodwifi_conf("ADGUARD_ENABLED", "true")
        configure_dnsmasq_fallback(enable_fallback=False)
        run_args(["sudo", "systemctl", "restart", "dnsmasq"], timeout=30)
        ok, _, _ = run_args(["docker", "start", container_name], timeout=30)
        if not ok:
            project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            adguard_dir = os.path.join(project_dir, "adguard")
            compose_file = os.path.join(adguard_dir, "docker-compose.yml")
            if os.path.exists(compose_file):
                run_args(
                    [
                        "docker",
                        "compose",
                        "-f",
                        compose_file,
                        "up",
                        "-d",
                    ],
                    timeout=60,
                )
        time.sleep(2)
        running = check_docker_container(container_name)
        if running:
            log("AdGuard Home is now running and handling DNS.")
            return True
        else:
            log("Could not start AdGuard Home container.", "WARN")
            return False
    else:
        log("Disabling AdGuard Home DNS service (switching to fallback DNS)...")
        update_goodwifi_conf("ADGUARD_ENABLED", "false")
        run_args(["docker", "stop", container_name], timeout=30)
        configure_dnsmasq_fallback(enable_fallback=True)
        run_args(["sudo", "systemctl", "restart", "dnsmasq"], timeout=30)
        time.sleep(1)
        dns_ok = check_dns()
        if dns_ok:
            log("AdGuard Home disabled. Fallback DNS is active and working.")
        else:
            log("AdGuard Home disabled, but fallback DNS check failed.", "WARN")
        return True

def set_ipv6_mode(mode: str) -> bool:
    mode = mode.lower()
    if mode not in ["drop", "reject", "off"]:
        log(f"Invalid mode: {mode}. Choose from: drop, reject, off", "ERROR")
        return False
    update_goodwifi_conf("IPV6_LEAK_PROTECTION", mode)
    log(f"Set IPV6_LEAK_PROTECTION to {mode}")
    return apply_vpn_policy()


def fix_hotspot() -> bool:
    log("Restarting hotspot services...")
    run_args(["sudo", "systemctl", "restart", "hostapd", "dnsmasq"])
    time.sleep(2)
    vpn_ok = restart_vpn()
    policy_ok = apply_vpn_policy() if vpn_ok else False
    return vpn_ok and policy_ok


def get_status() -> HotspotStatus:
    clients = check_clients()
    vpn_connected = check_vpn()
    active_if, backend_name = get_active_vpn_interface()
    _vpn_ip_ok, vpn_ip = check_vpn_ip() if vpn_connected else (False, None)
    external_ok, external_ip = (
        check_vpn_external_ip() if vpn_connected else (False, None)
    )

    services_status = {s: check_service(s) for s in CONFIG["services"]}

    adguard_candidates = [
        CONFIG.get("adguard_container", "adguardhome"),
        "adguardhome",
        "adguard",
    ]
    for name in dict.fromkeys(adguard_candidates):
        st = check_docker_container(name)
        if st is not None:
            services_status["adguard"] = st
            break

    bot_candidates = [
        CONFIG.get("telegram_container", "mpxraspberrypibot"),
        "mpxraspberrypibot",
        "telegrambot",
    ]
    for name in dict.fromkeys(bot_candidates):
        st = check_docker_container(name)
        if st is not None:
            services_status["telegrambot"] = st
            break

    return {
        "services": services_status,
        "vpn": {
            "connected": vpn_connected,
            "interface": active_if,
            "backend": backend_name,
            "ip": vpn_ip,
            "external_ip": external_ip,
            "external_ok": external_ok,
        },
        "hotspot": {"broadcasting": check_hotspot(), "clients": clients},
        "dns_working": check_dns(),
        "internet": check_internet(),
        "ping": check_ping(),
        "ipv6_protection": get_configured_ipv6_mode(),
    }


def print_status(status: HotspotStatus, telegram_format: bool = False) -> str:
    if telegram_format:
        # HTML Formatting for Telegram with Premium Custom Emojis
        lines = []
        lines.append(f"<b>{EMOJI_SIGNAL} HOTSPOT STATUS</b>")
        lines.append("")

        # Services
        lines.append(f"<b>{EMOJI_TOOLS} SERVICES:</b>")
        adguard_enabled = get_adguard_enabled()
        for service, ok in status["services"].items():
            if service == "adguard" and not adguard_enabled:
                icon = "⏸️"
                state = "Disabled"
            else:
                icon = EMOJI_CHECK if ok else EMOJI_CROSS
                state = "Running" if ok else "Stopped"
            lines.append(f"{icon} <code>{service}</code>: {state}")
        lines.append("")

        # VPN
        lines.append(f"<b>{EMOJI_LOCK} VPN:</b>")
        vpn_connected = status["vpn"]["connected"]
        icon = EMOJI_CHECK if vpn_connected else EMOJI_CROSS
        backend = status["vpn"].get("backend", "VPN")
        iface = status["vpn"].get("interface", "unknown")
        conn_info = f"({backend} / <code>{iface}</code>)"
        lines.append(f"{icon} Connected: <code>{vpn_connected}</code> {conn_info}")
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
        lines.append(f"<b>{EMOJI_STATS} HOTSPOT:</b>")
        hotspot_active = status["hotspot"]["broadcasting"]
        icon = EMOJI_CHECK if hotspot_active else EMOJI_CROSS
        ssid = get_hotspot_ssid()
        lines.append(f"{icon} SSID: <code>{ssid}</code>")
        lines.append(f"• Clients: <code>{status['hotspot']['clients']}</code>")
        lines.append("")

        # Network
        lines.append(f"<b>{EMOJI_GLOBE} NETWORK:</b>")
        dns_ok = status["dns_working"]
        internet_ok = status["internet"]
        ping = status.get("ping", {})
        ping_result = ping.get("summary") if ping else None

        dns_status = "Working" if dns_ok else "Failed"
        dns_icon = EMOJI_CHECK if dns_ok else EMOJI_CROSS
        lines.append(f"{dns_icon} DNS: <code>{dns_status}</code>")
        net_status = "Available" if internet_ok else "Down"
        net_icon = EMOJI_CHECK if internet_ok else EMOJI_CROSS
        lines.append(f"{net_icon} Internet: <code>{net_status}</code>")
        ipv6_mode = status.get("ipv6_protection", "drop")
        lines.append(f"🛡 IPv6 Protection: <code>{ipv6_mode.upper()}</code>")

        ping_target = (
            ping.get("target", CONFIG["ping_target"]) if ping else CONFIG["ping_target"]
        )

        if ping_result and ping_result != "No ping result":
            safe_ping = html.escape(ping_result)
            lines.append(
                f"{EMOJI_PING} Ping <code>{ping_target}</code>: "
                f"<tg-spoiler><code>{safe_ping}</code></tg-spoiler>"
            )
            # Extract RTT if available
            if ping.get("avg_ms") and ping.get("avg_ms") != "?":
                loss = ping.get("loss", "?")
                lines.append(
                    f"  └─ <code>RTT avg: {ping['avg_ms']} ms | Loss: {loss}%</code>"
                )
        else:
            ping_icon = EMOJI_CHECK if internet_ok else EMOJI_CROSS
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
    adguard_enabled = get_adguard_enabled()
    for service, ok in status["services"].items():
        if service == "adguard" and not adguard_enabled:
            icon = "⏸️"
            state = "Disabled"
        else:
            icon = "✅" if ok else "❌"
            state = "Running" if ok else "Stopped"
        output.append(f"  {icon} {service:<12} {state}")

    output.append(f"\n{Colors.BOLD}VPN:{Colors.RESET}")
    icon = "✅" if status["vpn"]["connected"] else "❌"
    backend = status["vpn"].get("backend", "VPN")
    iface = status["vpn"].get("interface", "unknown")
    output.append(
        f"  {icon} Connected: {status['vpn']['connected']} ({backend} - {iface})"
    )
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
    ipv6_mode = status.get("ipv6_protection", "drop")
    output.append(f"  🛡 IPv6 Protection: {ipv6_mode.upper()}")

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
    parser.add_argument(
        "--switch-vpn",
        dest="switch_vpn",
        choices=["awg0", "tun0", "wg0", "auto"],
        help="Switch active VPN backend",
    )
    parser.add_argument(
        "--set-ipv6",
        "--ipv6",
        dest="set_ipv6",
        choices=["drop", "reject", "off"],
        help="Set IPv6 leak protection mode (drop, reject, off)",
    )
    parser.add_argument(
        "--adguard",
        dest="set_adguard",
        choices=["on", "off", "enable", "disable", "status", "restart"],
        help="Manage AdGuard Home service (on, off, status, restart)",
    )
    parser.add_argument("--clients", action="store_true")
    parser.add_argument(
        "--telegram", action="store_true", help="Output in HTML format for Telegram"
    )
    parser.add_argument(
        "--html", action="store_true", help="Output formatted as HTML for Telegram"
    )

    args = parser.parse_args()
    telegram_format = bool(args.telegram or args.html)

    if len(sys.argv) == 1:
        args.status = True

    if args.switch_vpn:
        success = switch_vpn(args.switch_vpn)
        output = print_status(get_status(), telegram_format=telegram_format)
        print(output)
        sys.exit(0 if success else 1)

    if args.set_ipv6:
        success = set_ipv6_mode(args.set_ipv6)
        output = print_status(get_status(), telegram_format=telegram_format)
        print(output)
        sys.exit(0 if success else 1)

    if args.set_adguard:
        if args.set_adguard in ["on", "enable"]:
            success = set_adguard_state(True)
        elif args.set_adguard in ["off", "disable"]:
            success = set_adguard_state(False)
        elif args.set_adguard == "restart":
            set_adguard_state(False)
            success = set_adguard_state(True)
        elif args.set_adguard == "status":
            enabled = get_adguard_enabled()
            st = check_docker_container(CONFIG.get("adguard_container", "adguardhome"))
            state_str = "Running" if st else "Stopped"
            config_str = "Enabled" if enabled else "Disabled"
            print(f"AdGuard Config: {config_str} | Container: {state_str}")
            sys.exit(0)
        output = print_status(get_status(), telegram_format=telegram_format)
        print(output)
        sys.exit(0 if success else 1)

    if args.status:
        output = print_status(get_status(), telegram_format=telegram_format)
        print(output)

    if args.clients:
        print(f"Clients: {check_clients()}")

    if args.restart_vpn:
        if not restart_vpn():
            sys.exit(1)

    if args.fix:
        if not fix_hotspot():
            sys.exit(1)
        output = print_status(get_status(), telegram_format=telegram_format)
        print(output)

    if args.restart:
        if not fix_hotspot():
            sys.exit(1)


if __name__ == "__main__":
    main()
