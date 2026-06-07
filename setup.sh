#!/bin/bash
# Raspberry Pi Hotspot - installer/apply wrapper
# Source of truth lives in configs/ and scripts/.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CONFIG_DIR="$PROJECT_DIR/configs"
SCRIPT_DIR="$PROJECT_DIR/scripts"
HOSTAPD_CONF="$CONFIG_DIR/hostapd.conf"
GENERATED_HOSTAPD_CONF=""
BACKUP_DIR="$PROJECT_DIR/backup/system-$(date +%Y%m%d_%H%M%S)"
trap 'rm -f "${GENERATED_HOSTAPD_CONF:-}"' EXIT

required_files=(
  "$HOSTAPD_CONF"
  "$CONFIG_DIR/hostapd-override.conf"
  "$CONFIG_DIR/dnsmasq.conf"
  "$CONFIG_DIR/NetworkManager.conf"
  "$CONFIG_DIR/dhcpcd.conf"
  "$CONFIG_DIR/20-hotspot-manager"
  "$CONFIG_DIR/90-hotspot-vpn-policy"
  "$SCRIPT_DIR/hotspot-manager.py"
)

backup_file() {
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    sudo mkdir -p "$BACKUP_DIR$(dirname "$path")"
    sudo cp -a "$path" "$BACKUP_DIR$path"
  fi
}

copy_file() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  backup_file "$dest"
  sudo mkdir -p "$(dirname "$dest")"
  sudo cp "$src" "$dest"
  sudo chmod "$mode" "$dest"
}

ensure_line() {
  local line="$1"
  local file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" | sudo tee -a "$file" >/dev/null
}

ensure_managed_block() {
  local file="$1"
  local begin="$2"
  local end="$3"
  local block_file="$4"

  sudo touch "$file"
  sudo sed -i "\|$begin|,\|$end|d" "$file"
  {
    echo "$begin"
    cat "$block_file"
    echo "$end"
  } | sudo tee -a "$file" >/dev/null
}

vpn_has_ipv4() {
  ip -4 addr show tun0 2>/dev/null | grep -q "inet "
}

vpn_profile_exists() {
  nmcli -t -f NAME connection show 2>/dev/null | grep -qx 'pi'
}

vpn_profile_active() {
  nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep -qx 'pi:vpn'
}

connect_vpn_if_available() {
  if ! vpn_profile_exists; then
    log_warn "NetworkManager VPN connection 'pi' was not found."
    return
  fi

  if vpn_profile_active; then
    log_info "VPN connection 'pi' is already active"
    sleep 3
    return
  fi

  log_info "Connecting VPN connection: pi"
  if ! sudo nmcli connection up pi; then
    log_warn "Could not activate VPN connection 'pi'. Check the OpenVPN profile and credentials."
  fi
  sleep 3
}

render_hostapd_conf() {
  local ssid="$1"
  local password="$2"
  GENERATED_HOSTAPD_CONF="$(mktemp)"
  awk -v ssid="$ssid" -v password="$password" '
    $0 ~ "^ssid=" {
      print "ssid=" ssid
      next
    }
    $0 ~ "^wpa_passphrase=" {
      print "wpa_passphrase=" password
      next
    }
    { print }
  ' "$HOSTAPD_CONF" > "$GENERATED_HOSTAPD_CONF"
}

configure_hotspot_credentials() {
  local current_ssid current_password ssid password entered_ssid entered_password
  local current_conf="$HOSTAPD_CONF"
  if [ -r /etc/hostapd/hostapd.conf ]; then
    current_conf=/etc/hostapd/hostapd.conf
  fi

  current_ssid="$(awk -F= '$1 == "ssid" {print $2; exit}' "$current_conf")"
  current_password="$(awk -F= '$1 == "wpa_passphrase" {print $2; exit}' "$current_conf")"
  ssid="${HOTSPOT_SSID:-$current_ssid}"
  password="${HOTSPOT_PASSWORD:-$current_password}"

  if [ -t 0 ]; then
    read -r -p "Hotspot SSID [$ssid]: " entered_ssid
    ssid="${entered_ssid:-$ssid}"
    read -r -s -p "Hotspot password (8+ chars, blank keeps current): " entered_password
    echo
    password="${entered_password:-$password}"
  fi

  if [ "${#password}" -lt 8 ]; then
    echo "Hotspot password must be at least 8 characters." >&2
    exit 1
  fi

  render_hostapd_conf "$ssid" "$password"
}

log_info "Starting Raspberry Pi Hotspot setup/apply"
log_info "Project dir: $PROJECT_DIR"

for file in "${required_files[@]}"; do
  if [ ! -f "$file" ]; then
    echo "Missing required file: $file" >&2
    exit 1
  fi
done

configure_hotspot_credentials

log_info "Installing required packages"
sudo apt update
sudo apt install -y hostapd dnsmasq ipset ipset-persistent iptables-persistent netfilter-persistent python3 python3-pip curl wget

log_info "Installing config files from configs/"
copy_file "$GENERATED_HOSTAPD_CONF" /etc/hostapd/hostapd.conf 0644
copy_file "$CONFIG_DIR/hostapd-override.conf" /etc/systemd/system/hostapd.service.d/override.conf 0644
copy_file "$CONFIG_DIR/dnsmasq.conf" /etc/dnsmasq.conf 0644
copy_file "$CONFIG_DIR/NetworkManager.conf" /etc/NetworkManager/NetworkManager.conf 0644
copy_file "$CONFIG_DIR/20-hotspot-manager" /etc/NetworkManager/dispatcher.d/20-hotspot-manager 0755
copy_file "$CONFIG_DIR/90-hotspot-vpn-policy" /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy 0755

log_info "Configuring dhcpcd wlan0 block"
backup_file /etc/dhcpcd.conf
sudo sed -i '/^# Access Point configuration for wlan0$/,/^    nohook wpa_supplicant$/d' /etc/dhcpcd.conf 2>/dev/null || true
ensure_managed_block /etc/dhcpcd.conf "# BEGIN GoodWifi managed block" "# END GoodWifi managed block" "$CONFIG_DIR/dhcpcd.conf"

backup_file /etc/default/hostapd
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee /etc/default/hostapd >/dev/null

log_info "Installing AdGuardHome when missing"
# AdGuardHome removed per user request - DNS handled directly by dnsmasq
# if ! command -v AdGuardHome >/dev/null 2>&1 && [ ! -x /opt/AdGuardHome/AdGuardHome ]; then
#   agh_installer="$(mktemp /tmp/adguardhome-install.XXXXXX.sh)"
#   curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh -o "$agh_installer"
#   chmod 0755 "$agh_installer"
#   sudo sh "$agh_installer"
#   rm -f "$agh_installer"
# fi

log_info "Installing manager script from scripts/"
copy_file "$SCRIPT_DIR/hotspot-manager.py" /usr/local/bin/hotspot-manager.py 0755

log_info "Installing shell aliases"
sed -i '/^alias hotspot=/d; /^alias hs=/d; /^alias hf=/d' "$HOME/.bashrc"
{
  echo 'alias hotspot="sudo /usr/local/bin/hotspot-manager.py"'
  echo 'alias hs="sudo /usr/local/bin/hotspot-manager.py --status"'
  echo 'alias hf="sudo /usr/local/bin/hotspot-manager.py --fix"'
} >> "$HOME/.bashrc"

log_info "Configuring system forwarding and wlan0 ownership"
sudo sysctl -w net.ipv4.ip_forward=1
ensure_line 'net.ipv4.ip_forward=1' /etc/sysctl.conf
sudo systemctl stop wpa_supplicant 2>/dev/null || true
sudo systemctl disable wpa_supplicant 2>/dev/null || true
sudo rfkill unblock wifi 2>/dev/null || true

log_info "Disabling old route scripts that force host default via VPN"
sudo chmod -x /etc/NetworkManager/dispatcher.d/10-vpn-routing 2>/dev/null || true
sudo chmod -x /etc/NetworkManager/dispatcher.d/50-vpn-route 2>/dev/null || true
sudo chmod -x /etc/NetworkManager/dispatcher.d/99-vpn-routing 2>/dev/null || true

log_info "Applying hotspot routing/firewall policy"
sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy tun0 apply
sudo netfilter-persistent save

log_info "Configuring wlan0 address"
sudo systemctl stop hostapd dnsmasq 2>/dev/null || true
sudo ip link set wlan0 down || true
sudo ip addr flush dev wlan0 || true
sudo ip link set wlan0 up
sudo /sbin/iw dev wlan0 set power_save off 2>/dev/null || true
sudo ip addr add 10.42.0.1/24 dev wlan0 2>/dev/null || true

log_info "Restarting NetworkManager and hotspot services"
sudo systemctl daemon-reload
sudo systemctl restart NetworkManager
sudo systemctl unmask hostapd 2>/dev/null || true
sudo systemctl enable hostapd dnsmasq 2>/dev/null || true
sudo systemctl restart hostapd dnsmasq 2>/dev/null || true

if ! vpn_has_ipv4; then
  connect_vpn_if_available
fi

if vpn_has_ipv4; then
  log_info "tun0 is active and has an IPv4 address"
  sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy tun0 up
else
  log_warn "tun0 has no IPv4 address yet. If VPN 'pi' is active, confirm it creates tun0."
  log_warn "After the VPN is healthy, reapply hotspot routing with: hotspot --restart-vpn"
fi

log_info "SETUP/APPLY COMPLETE"
log_info "Backups for overwritten system files: $BACKUP_DIR"
sudo /usr/local/bin/hotspot-manager.py --status
