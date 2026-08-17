#!/usr/bin/env bash
# Install Logitech Astro A50 X Spotify pause/resume watcher.
# Usage: install-to-local.sh [--with-tools] [--enable-automation]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${HOME}/.local/bin"
CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/astro-a50x-spotify-pause"
SYSTEMD_USER="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
ENABLE_AUTOMATION=0
WITH_TOOLS=0

for arg in "$@"; do
  case "${arg}" in
    --enable-automation) ENABLE_AUTOMATION=1 ;;
    --with-tools) WITH_TOOLS=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--with-tools] [--enable-automation]"
      echo "  Installs watcher + libs + unit + fixtures. Does not start Spotify or pause playback."
      echo "  --with-tools also installs HID probes + scorers (research / matrix)."
      echo "  --enable-automation requires ENABLED=1 DRY_RUN=0 and pactl+playerctl."
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

mkdir -p "${BIN}" "${CFG_DIR}" "${SYSTEMD_USER}"

install -m0755 "${ROOT}/scripts/a50x-spotify-pause.sh" "${BIN}/a50x-spotify-pause"
install -m0755 "${ROOT}/scripts/discover-a50x-sink.sh" "${BIN}/discover-a50x-sink"
install -m0755 "${ROOT}/scripts/verify-a50x-spotify-pause.sh" "${BIN}/verify-a50x-spotify-pause"
install -m0755 "${ROOT}/scripts/test/run-intent-fixtures.sh" "${BIN}/a50x-intent-fixtures"
mkdir -p "${BIN}/a50x-spotify-pause-lib"
for lib in "${ROOT}/scripts/lib/"*.sh; do
  install -m0644 "${lib}" "${BIN}/a50x-spotify-pause-lib/$(basename "${lib}")"
done

if [[ "${WITH_TOOLS}" -eq 1 ]]; then
  install -m0755 "${ROOT}/scripts/tools/a50x-hid-probe.sh" "${BIN}/a50x-hid-probe"
  install -m0755 "${ROOT}/scripts/tools/a50x-hid-battery-probe.sh" "${BIN}/a50x-hid-battery-probe"
  install -m0755 "${ROOT}/scripts/tools/score-a50x-hid-batt-bytes.py" "${BIN}/score-a50x-hid-batt-bytes"
  install -m0755 "${ROOT}/scripts/tools/score-a50x-hid-passive-power.py" "${BIN}/score-a50x-hid-passive-power"
fi

migrate_config() {
  local cfg="$1"
  local tmp
  tmp="$(mktemp)"
  # Drop dead knobs only — do NOT auto-bump DISABLE_LATCH_SEC (H02).
  grep -vE '^[[:space:]]*(RESUME_SOFT_SEC|REASSERT_SEC)=' "${cfg}" >"${tmp}" || true
  mv "${tmp}" "${cfg}"
  for key in HID_ENABLE HID_MATCH_HEX HID_DEVICE DISABLE_LATCH_SEC HID_SOFT_OFF_PREFIX HID_SOFT_ON_PREFIX PLAYER_MODE; do
    if ! grep -qE "^[[:space:]]*${key}=" "${cfg}" 2>/dev/null; then
      if grep -qE "^${key}=" "${ROOT}/config/example.config" 2>/dev/null; then
        grep -E "^${key}=" "${ROOT}/config/example.config" >>"${cfg}" || true
        echo "  appended ${key} from example.config"
      fi
    fi
  done
}

if [[ ! -f "${CFG_DIR}/config" ]]; then
  install -m0644 "${ROOT}/config/example.config" "${CFG_DIR}/config"
  echo "Seeded ${CFG_DIR}/config (ENABLED=0 DRY_RUN=1)"
else
  echo "Migrating existing ${CFG_DIR}/config"
  migrate_config "${CFG_DIR}/config"
fi

install -m0644 "${ROOT}/systemd/user/a50x-spotify-pause.service.example" \
  "${SYSTEMD_USER}/a50x-spotify-pause.service"
echo "Installed ${SYSTEMD_USER}/a50x-spotify-pause.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  if systemctl --user is-active a50x-spotify-pause.service >/dev/null 2>&1; then
    systemctl --user restart a50x-spotify-pause.service
    echo "Restarted a50x-spotify-pause.service"
  fi
fi

echo ""
echo "Installed:"
echo "  ${BIN}/a50x-spotify-pause"
echo "  ${BIN}/discover-a50x-sink"
echo "  ${BIN}/verify-a50x-spotify-pause"
echo "  ${BIN}/a50x-intent-fixtures"
echo "  ${BIN}/a50x-spotify-pause-lib/*.sh"
if [[ "${WITH_TOOLS}" -eq 1 ]]; then
  echo "  ${BIN}/a50x-hid-probe"
  echo "  ${BIN}/a50x-hid-battery-probe"
  echo "  ${BIN}/score-a50x-hid-batt-bytes"
  echo "  ${BIN}/score-a50x-hid-passive-power"
else
  echo "  (research tools skipped — pass --with-tools to install)"
fi
echo "  ${CFG_DIR}/config"
echo "  ${SYSTEMD_USER}/a50x-spotify-pause.service"
echo ""
echo "F4-multi ladder (multi-MPRIS after F4c):"
echo "  1. install-to-local.sh; systemctl --user restart a50x-spotify-pause.service"
echo "  2. Confirm journal version=f4-mpris-multi-1 PLAYER_MODE=single (default)"
echo "  3. Optional: PLAYER_MODE=all DRY_RUN=1 soak → DRY_RUN=0 → docs/acceptance-matrix.md F4-multi"
echo "  4. STOP on first false pause/resume"
echo "Expect: reason=hid-soft-off / hid-soft-on / hid-dock-chg-rise|fall; players=…"
echo "Log: journalctl --user -t a50x-spotify-pause -f"

if [[ "${ENABLE_AUTOMATION}" -eq 1 ]]; then
  if ! command -v pactl >/dev/null 2>&1 || ! command -v playerctl >/dev/null 2>&1; then
    echo "" >&2
    echo "Refusing --enable-automation: need pactl and playerctl in PATH" >&2
    exit 1
  fi
  if ! grep -qE '^[[:space:]]*ENABLED=1' "${CFG_DIR}/config" 2>/dev/null; then
    echo "" >&2
    echo "Refusing --enable-automation: ENABLED is not 1 in ${CFG_DIR}/config" >&2
    exit 1
  fi
  if ! grep -qE '^[[:space:]]*DRY_RUN=0' "${CFG_DIR}/config" 2>/dev/null; then
    echo "" >&2
    echo "Refusing --enable-automation: DRY_RUN must be 0 in ${CFG_DIR}/config" >&2
    exit 1
  fi
  if grep -qE '^[[:space:]]*SINK_MATCH=REPLACE_ME_FROM_DISCOVER' "${CFG_DIR}/config" 2>/dev/null; then
    echo "" >&2
    echo "Refusing --enable-automation: SINK_MATCH still REPLACE_ME_FROM_DISCOVER" >&2
    exit 1
  fi
  if grep -qE '^[[:space:]]*PLAYER=REPLACE_ME_FROM_DISCOVER' "${CFG_DIR}/config" 2>/dev/null; then
    if ! grep -qE '^[[:space:]]*PLAYER_MODE=all' "${CFG_DIR}/config" 2>/dev/null; then
      echo "" >&2
      echo "Refusing --enable-automation: PLAYER still REPLACE_ME_FROM_DISCOVER (or set PLAYER_MODE=all)" >&2
      exit 1
    fi
  fi
  echo ""
  echo "Running verify before enable..."
  if ! "${BIN}/verify-a50x-spotify-pause"; then
    echo "Refusing --enable-automation: verify failed" >&2
    exit 1
  fi
  echo "Enabling a50x-spotify-pause.service (--enable-automation)..."
  systemctl --user enable --now a50x-spotify-pause.service
  echo "Service enabled."
fi
