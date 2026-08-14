#!/usr/bin/env bash
# Disable and remove A50X Spotify pause/resume user unit, binaries, and HID udev rule.
set -euo pipefail

BIN="${HOME}/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/astro-a50x-spotify-pause"
SYSTEMD_USER="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
UDEV_RULE="/etc/udev/rules.d/99-logitech-a50x-hid.rules"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now a50x-spotify-pause.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
fi

rm -f "${SYSTEMD_USER}/a50x-spotify-pause.service"
rm -f "${SYSTEMD_USER}/default.target.wants/a50x-spotify-pause.service"
rm -f "${BIN}/a50x-spotify-pause"
rm -f "${BIN}/discover-a50x-sink"
rm -f "${BIN}/verify-a50x-spotify-pause"
rm -f "${BIN}/a50x-hid-probe"
rm -f "${BIN}/a50x-hid-battery-probe"
rm -f "${BIN}/score-a50x-hid-batt-bytes"
rm -f "${BIN}/score-a50x-hid-passive-power"
rm -f "${BIN}/a50x-intent-fixtures"
rm -rf "${BIN}/a50x-spotify-pause-lib"

echo "Removed a50x-spotify-pause user unit and binaries."
echo "Config kept at ${CFG_DIR}/config (delete manually if unwanted)."
echo "Optional config keys to drop: HID_ENABLE HID_MATCH_HEX HID_DEVICE DISABLE_LATCH_SEC"

if [[ -f "${UDEV_RULE}" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    rm -f "${UDEV_RULE}"
    if command -v udevadm >/dev/null 2>&1; then
      udevadm control --reload
      udevadm trigger -c add -s hidraw 2>/dev/null || true
    fi
    echo "Removed ${UDEV_RULE} and reloaded udev."
  else
    echo ""
    echo "HID udev rule still present (needs sudo):"
    echo "  sudo rm -f ${UDEV_RULE}"
    echo "  sudo udevadm control --reload"
    echo "  sudo udevadm trigger -c add -s hidraw"
    if sudo -n true 2>/dev/null; then
      sudo rm -f "${UDEV_RULE}"
      sudo udevadm control --reload
      sudo udevadm trigger -c add -s hidraw 2>/dev/null || true
      echo "Removed ${UDEV_RULE} via passwordless sudo."
    fi
  fi
else
  echo "No ${UDEV_RULE} (already clean or never installed)."
fi
