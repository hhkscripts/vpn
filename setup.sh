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
  "$SCRIPT_DIR/github-vpn-routes.sh"
  "$SCRIPT_DIR/openvpn-replay-wrapper"
  "$SCRIPT_DIR/openvpn-diversion.sh"
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
  if [ -d "$dest" ] && [ ! -L "$dest" ]; then
    log_warn "Replacing unexpected directory at $dest with file from $src"
    sudo rm -rf "$dest"
  fi
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

get_active_vpn_if() {
  for cand in awg0 wg0 tun0; do
    if ip -4 addr show "$cand" 2>/dev/null | grep -q "inet "; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

vpn_has_ipv4() {
  get_active_vpn_if >/dev/null 2>&1
}

detect_nm_vpn_connection() {
  local conn="${VPN_UUID:-}"
  if [ -n "$conn" ] && nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$conn"; then
    echo "$conn"
    return 0
  fi

  local active
  active="$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="vpn" || $2=="wireguard" {print $1; exit}')"
  if [ -n "$active" ]; then
    echo "$active"
    return 0
  fi

  nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="vpn" || $2=="wireguard" {print $1; exit}'
}

connect_vpn_if_available() {
  local vpn_conn
  vpn_conn="$(detect_nm_vpn_connection)"

  if [ -z "$vpn_conn" ]; then
    log_warn "No NetworkManager VPN connection found."
    return
  fi

  if nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$vpn_conn"; then
    log_info "VPN connection '$vpn_conn' is already active"
    sleep 3
    return
  fi

  log_info "Connecting VPN connection: $vpn_conn"
  if ! sudo nmcli connection up "$vpn_conn"; then
    log_warn "Could not activate VPN connection '$vpn_conn'. Check the VPN profile and credentials."
  fi
  sleep 3
}

stop_legacy_pihole_if_running() {
  if ! command -v docker >/dev/null 2>&1; then
    return
  fi

  if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'pihole'; then
    log_info "Stopping legacy Pi-hole container before starting AdGuard Home"
    sudo docker stop pihole >/dev/null 2>&1 || true
  fi
}

restart_adguard_if_configured() {
  local compose_dir="$PROJECT_DIR/adguard"

  if [ ! -f "$compose_dir/docker-compose.yml" ]; then
    return
  fi

  if [ ! -f "$compose_dir/.env" ]; then
    log_warn "AdGuard Home .env not found. Start it later with: cd adguard && cp .env.example .env && docker compose up -d"
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_warn "Docker not found; skipping AdGuard Home restart"
    return
  fi

  stop_legacy_pihole_if_running

  # Migrate legacy local_bypass_domains to local_routes in existing AdGuard configuration
  if [ -f "$compose_dir/conf/AdGuardHome.yaml" ]; then
    if sudo grep -q "local_bypass_domains" "$compose_dir/conf/AdGuardHome.yaml" 2>/dev/null; then
      log_info "Migrating AdGuard Home ipset rule from local_bypass_domains to local_routes"
      sudo sed -i 's#/local_bypass_domains#/local_routes#g' "$compose_dir/conf/AdGuardHome.yaml"
    fi
  fi

  log_info "Starting/restarting AdGuard Home DNS service"
  if ! (cd "$compose_dir" && sudo docker compose up -d); then
    log_warn "Could not start AdGuard Home. Retry with: cd adguard && docker compose up -d"
  fi
}

render_hostapd_conf() {
  local ssid="$1"
  local password="$2"
  local iface="${HOTSPOT_IF:-wlan0}"

  awk -v ssid="$ssid" -v password="$password" -v iface="$iface" '
    $0 ~ "^interface=" {
      print "interface=" iface
      next
    }
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

log_info "Validating and installing the OpenVPN replay-window wrapper"
sudo "$SCRIPT_DIR/openvpn-diversion.sh" check "$SCRIPT_DIR/openvpn-replay-wrapper"
sudo "$SCRIPT_DIR/openvpn-diversion.sh" install "$SCRIPT_DIR/openvpn-replay-wrapper"

configure_hotspot_credentials

log_info "Installing required packages"
sudo apt update
sudo apt install -y hostapd dnsmasq ipset ipset-persistent iptables-persistent netfilter-persistent python3 python3-pip curl wget util-linux

log_info "Cleaning up legacy ipsets if migrating"
for legacy_set in github_vpn_routes local_bypass_domains; do
  if sudo ipset list "$legacy_set" >/dev/null 2>&1; then
    sudo ipset flush "$legacy_set" 2>/dev/null || true
    sudo ipset destroy "$legacy_set" 2>/dev/null || true
  fi
done

log_info "Configuring GoodWifi default configuration"
backup_file /etc/goodwifi/goodwifi.conf
sudo mkdir -p /etc/goodwifi
if [ ! -f /etc/goodwifi/goodwifi.conf ]; then
  copy_file "$CONFIG_DIR/goodwifi.conf" /etc/goodwifi/goodwifi.conf 0644
fi
copy_file "$CONFIG_DIR/github-ipv4-ranges.txt" /etc/goodwifi/github-ipv4-ranges.txt 0644

# Load settings from goodwifi.conf
# shellcheck source=/dev/null
[ -f /etc/goodwifi/goodwifi.conf ] && . /etc/goodwifi/goodwifi.conf
HOTSPOT_IF="${HOTSPOT_IF:-wlan0}"
HOTSPOT_IP="${HOTSPOT_IP:-10.42.0.1}"
HOTSPOT_SUBNET="${HOTSPOT_SUBNET:-10.42.0.0/24}"

log_info "Installing config files from configs/ for interface $HOTSPOT_IF"
render_hostapd_conf "$ssid" "$password"
copy_file "$GENERATED_HOSTAPD_CONF" /etc/hostapd/hostapd.conf 0644

tmp_hostapd_override="$(mktemp)"
sed "s/wlan0/$HOTSPOT_IF/g" "$CONFIG_DIR/hostapd-override.conf" > "$tmp_hostapd_override"
copy_file "$tmp_hostapd_override" /etc/systemd/system/hostapd.service.d/override.conf 0644
rm -f "$tmp_hostapd_override"

tmp_dnsmasq="$(mktemp)"
sed -e "s/interface=wlan0/interface=$HOTSPOT_IF/g"     -e "s/10\.42\.0\.1/$HOTSPOT_IP/g"     -e "s/10\.42\.0\./${HOTSPOT_IP%.*\.}./g"     "$CONFIG_DIR/dnsmasq.conf" > "$tmp_dnsmasq"
copy_file "$tmp_dnsmasq" /etc/dnsmasq.conf 0644
rm -f "$tmp_dnsmasq"

tmp_nm="$(mktemp)"
sed "s/wlan0/$HOTSPOT_IF/g" "$CONFIG_DIR/NetworkManager.conf" > "$tmp_nm"
copy_file "$tmp_nm" /etc/NetworkManager/NetworkManager.conf 0644
rm -f "$tmp_nm"

copy_file "$CONFIG_DIR/20-hotspot-manager" /etc/NetworkManager/dispatcher.d/20-hotspot-manager 0755
copy_file "$CONFIG_DIR/90-hotspot-vpn-policy" /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy 0755

log_info "Configuring dhcpcd $HOTSPOT_IF block"
backup_file /etc/dhcpcd.conf
sudo sed -i '/^# Access Point configuration for /d; /^interface wlan/d; /^static ip_address=10\.42\./d; /^    nohook wpa_supplicant$/d' /etc/dhcpcd.conf 2>/dev/null || true
tmp_dhcpcd="$(mktemp)"
cat <<DHCPCD_EOF > "$tmp_dhcpcd"
interface $HOTSPOT_IF
    static ip_address=$HOTSPOT_IP/24
    nohook wpa_supplicant
DHCPCD_EOF
ensure_managed_block /etc/dhcpcd.conf "# BEGIN GoodWifi managed block" "# END GoodWifi managed block" "$tmp_dhcpcd"
rm -f "$tmp_dhcpcd"

backup_file /etc/default/hostapd
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee /etc/default/hostapd >/dev/null

log_info "Installing manager script from scripts/"
copy_file "$SCRIPT_DIR/hotspot-manager.py" /usr/local/bin/hotspot-manager.py 0755
copy_file "$SCRIPT_DIR/github-vpn-routes.sh" /usr/local/bin/github-vpn-routes.sh 0755

log_info "Installing shell aliases"
install_aliases_for() {
  local target_home="$1"
  local rc_file="$target_home/.bashrc"
  [ -f "$rc_file" ] || return 0
  sed -i '/^alias hotspot=/d; /^alias hs=/d; /^alias hf=/d' "$rc_file"
  {
    echo 'alias hotspot="sudo /usr/local/bin/hotspot-manager.py"'
    echo 'alias hs="sudo /usr/local/bin/hotspot-manager.py --status"'
    echo 'alias hf="sudo /usr/local/bin/hotspot-manager.py --fix"'
  } >> "$rc_file"
}

install_aliases_for "$HOME"
if [ -n "${SUDO_USER:-}" ] && [ -d "/home/$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
  install_aliases_for "/home/$SUDO_USER"
fi

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
target_vpn="$(get_active_vpn_if 2>/dev/null || echo "tun0")"
sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy "$target_vpn" apply
sudo netfilter-persistent save

log_info "Configuring $HOTSPOT_IF address"
sudo systemctl stop hostapd dnsmasq 2>/dev/null || true
sudo ip link set "$HOTSPOT_IF" down || true
sudo ip addr flush dev "$HOTSPOT_IF" || true
sudo ip link set "$HOTSPOT_IF" up
sudo /sbin/iw dev "$HOTSPOT_IF" set power_save off 2>/dev/null || true
sudo ip addr add "$HOTSPOT_IP/24" dev "$HOTSPOT_IF" 2>/dev/null || true

log_info "Restarting NetworkManager and hotspot services"
sudo systemctl daemon-reload
sudo systemctl restart NetworkManager
sudo systemctl unmask hostapd 2>/dev/null || true
sudo systemctl enable hostapd dnsmasq 2>/dev/null || true
sudo systemctl restart hostapd dnsmasq 2>/dev/null || true
restart_adguard_if_configured

if ! vpn_has_ipv4; then
  connect_vpn_if_available
fi

if vpn_has_ipv4; then
  active_vpn="$(get_active_vpn_if)"
  log_info "VPN interface $active_vpn is active and has an IPv4 address"
  sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy "$active_vpn" up
  log_info "Refreshing GitHub host routes through $active_vpn"
  if ! sudo /usr/local/bin/github-vpn-routes.sh; then
    log_warn "Could not refresh GitHub host routes. You can retry with: sudo github-vpn-routes.sh"
  fi
else
  log_warn "No active VPN interface (awg0, wg0, tun0) with an IPv4 address found."
  log_warn "If using OpenVPN ('pi'), confirm it creates tun0. If using AmneziaWG, check awg0."
  log_warn "After the VPN is healthy, reapply hotspot routing with: hotspot --restart-vpn"
  log_warn "Then refresh GitHub host routes with: sudo github-vpn-routes.sh"
fi

log_info "SETUP/APPLY COMPLETE"
log_info "Backups for overwritten system files: $BACKUP_DIR"
sudo /usr/local/bin/hotspot-manager.py --status
