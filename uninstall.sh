#!/bin/bash
# Remove installed hotspot system files and runtime rules.
# Project source files in this repository are left intact.

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
POLICY_SCRIPT="$PROJECT_DIR/configs/90-hotspot-vpn-policy"
BACKUP_ROOT="$PROJECT_DIR/backup"

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}[WARNING] This removes installed hotspot services/config from the system.${NC}"
echo -e "${YELLOW}Project source files in this repository will not be deleted.${NC}"
read -r -p "Continue? (y/N): " reply
if [[ ! "$reply" =~ ^[Yy]$ ]]; then
  exit 1
fi

original_backup_dir() {
  if [ -d "$BACKUP_ROOT" ]; then
    find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'system-*' | sort | head -n 1
  fi
}

restore_or_remove() {
  local path="$1"
  local backup_dir="$2"
  local backup_path=""

  if [ -n "$backup_dir" ]; then
    backup_path="$backup_dir$path"
  fi

  if [ -n "$backup_path" ] && [ -e "$backup_path" ]; then
    sudo mkdir -p "$(dirname "$path")"
    sudo cp -a "$backup_path" "$path"
  else
    sudo rm -f "$path"
  fi
}

cleanup_dhcpcd_block() {
  if [ -e /etc/dhcpcd.conf ]; then
    sudo sed -i '/^# BEGIN GoodWifi managed block$/,/^# END GoodWifi managed block$/d' /etc/dhcpcd.conf
    sudo sed -i '/^# Access Point configuration for wlan0$/,/^    nohook wpa_supplicant$/d' /etc/dhcpcd.conf
  fi
}

BACKUP_DIR="$(original_backup_dir)"
if [ -n "$BACKUP_DIR" ]; then
  echo "Using original backup restore source: $BACKUP_DIR"
else
  echo "No backup/system-* directory found; removing managed files and blocks only."
fi

sudo systemctl stop hostapd dnsmasq 2>/dev/null || true
sudo systemctl disable hostapd dnsmasq 2>/dev/null || true
sudo systemctl stop wpa_supplicant 2>/dev/null || true

if [ -x "$POLICY_SCRIPT" ]; then
  sudo "$POLICY_SCRIPT" tun0 cleanup
elif [ -x /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy ]; then
  sudo /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy tun0 cleanup
fi
sudo netfilter-persistent save

restore_or_remove /etc/hostapd/hostapd.conf "$BACKUP_DIR"
restore_or_remove /etc/systemd/system/hostapd.service.d/override.conf "$BACKUP_DIR"
restore_or_remove /etc/dnsmasq.conf "$BACKUP_DIR"
restore_or_remove /etc/NetworkManager/NetworkManager.conf "$BACKUP_DIR"
restore_or_remove /etc/default/hostapd "$BACKUP_DIR"
restore_or_remove /etc/NetworkManager/dispatcher.d/20-hotspot-manager "$BACKUP_DIR"
restore_or_remove /etc/NetworkManager/dispatcher.d/90-hotspot-vpn-policy "$BACKUP_DIR"
restore_or_remove /usr/local/bin/hotspot-manager.py "$BACKUP_DIR"
restore_or_remove /usr/local/bin/github-vpn-routes.sh "$BACKUP_DIR"
if [ -n "$BACKUP_DIR" ] && [ -e "$BACKUP_DIR/etc/dhcpcd.conf" ]; then
  sudo cp -a "$BACKUP_DIR/etc/dhcpcd.conf" /etc/dhcpcd.conf
else
  cleanup_dhcpcd_block
fi
sudo systemctl daemon-reload

sudo ip addr flush dev wlan0 2>/dev/null || true

sed -i '/^alias hotspot=/d; /^alias hs=/d; /^alias hf=/d' "$HOME/.bashrc"

echo "Uninstall complete. Reboot if wlan0 or NetworkManager state needs a full reset."
