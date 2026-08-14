#!/usr/bin/env bash
# Read-only status for astro-a50x-spotify-pause (no pause/play side effects).
set -euo pipefail

CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/astro-a50x-spotify-pause"
CFG_FILE="${CFG_DIR}/config"
SYSTEMD_USER="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
UNIT="${SYSTEMD_USER}/a50x-spotify-pause.service"
BIN="${HOME}/.local/bin/a50x-spotify-pause"

ENABLED=0
DRY_RUN=1
SINK_MATCH=""
PLAYER=""
AUTO_RESUME=1

rc=0
warn() { echo "WARN: $*"; }
fail() { echo "FAIL: $*"; rc=1; }
ok() { echo "OK: $*"; }

echo "=== astro-a50x-spotify-pause verify ==="

if command -v pactl >/dev/null 2>&1; then
  ok "pactl present"
else
  fail "pactl missing"
fi
if command -v playerctl >/dev/null 2>&1; then
  ok "playerctl present"
else
  fail "playerctl missing"
fi

if systemctl --user is-active pipewire-pulse >/dev/null 2>&1; then
  ok "pipewire-pulse active"
else
  warn "pipewire-pulse not active"
fi
if pactl info >/dev/null 2>&1; then
  ok "pactl info"
else
  fail "pactl info failed"
fi

if [[ -f "${CFG_FILE}" ]]; then
  ok "config ${CFG_FILE}"
  # shellcheck disable=SC1090
  source "${CFG_FILE}"
else
  fail "config missing: ${CFG_FILE}"
fi

echo "ENABLED=${ENABLED} DRY_RUN=${DRY_RUN} AUTO_RESUME=${AUTO_RESUME}"
echo "SINK_MATCH=${SINK_MATCH}"
echo "PLAYER=${PLAYER}"
echo "PLAYER_MODE=${PLAYER_MODE:-single}"

if command -v playerctl >/dev/null 2>&1; then
  echo "playerctl -l:"
  playerctl -l 2>/dev/null || echo "(none)"
fi

if [[ "${ENABLED}" == "1" && "${DRY_RUN}" == "1" ]]; then
  fail "ENABLED=1 but DRY_RUN=1 — watcher will not actually pause (set DRY_RUN=0)"
fi

PLAYER_MODE="${PLAYER_MODE:-single}"
HID_ENABLE="${HID_ENABLE:-0}"
HID_MATCH_HEX="${HID_MATCH_HEX:-}"
HID_SOFT_OFF_PREFIX="${HID_SOFT_OFF_PREFIX:-}"
HID_SOFT_ON_PREFIX="${HID_SOFT_ON_PREFIX:-}"
if [[ "${HID_ENABLE}" == "1" ]]; then
  if ! command -v xxd >/dev/null 2>&1; then
    fail "HID_ENABLE=1 but xxd missing (apt install xxd)"
  else
    ok "xxd present"
  fi
  if [[ -n "${HID_MATCH_HEX}" ]]; then
    warn "HID_MATCH_HEX is set but deprecated (F3c uses battery GET + soft-off/on prefixes); watcher ignores it"
  fi
  if [[ -z "${HID_SOFT_OFF_PREFIX}" ]]; then
    ok "HID_SOFT_OFF_PREFIX empty → default 020c04000a0006 (F2e/F3b soft-off)"
  else
    ok "HID_SOFT_OFF_PREFIX=${HID_SOFT_OFF_PREFIX}"
  fi
  if [[ -z "${HID_SOFT_ON_PREFIX}" ]]; then
    ok "HID_SOFT_ON_PREFIX empty → default 020c0400130000 (F2e/F3c soft-on)"
  else
    ok "HID_SOFT_ON_PREFIX=${HID_SOFT_ON_PREFIX}"
  fi
  if [[ -r /etc/udev/rules.d/99-logitech-a50x-hid.rules ]] || [[ -r /lib/udev/rules.d/99-logitech-a50x-hid.rules ]]; then
    ok "HID udev rule present"
  else
    fail "HID_ENABLE=1 but udev rule 99-logitech-a50x-hid.rules not installed"
  fi
  hidraw_ok=0
  for hr in /sys/class/hidraw/hidraw*; do
    [[ -e "${hr}/device/uevent" ]] || continue
    if grep -qi '046D:.*0B0B\|046D:00000B0B' "${hr}/device/uevent" 2>/dev/null; then
      dev="/dev/$(basename "${hr}")"
      if [[ -r "${dev}" && -w "${dev}" ]]; then
        ok "hidraw read+write: ${dev}"
        hidraw_ok=1
        break
      elif [[ -r "${dev}" ]]; then
        warn "hidraw readable but not writable: ${dev}"
      fi
    fi
  done
  if [[ "${hidraw_ok}" -eq 0 ]]; then
    fail "HID_ENABLE=1 but no rw A50 X hidraw (install udev + replug / re-login)"
  fi
fi

# Diagnostic: is media on a matching sink right now?
if [[ -n "${SINK_MATCH}" && "${SINK_MATCH}" != "REPLACE_ME_FROM_DISCOVER" ]]; then
  short="$(pactl list short sinks 2>/dev/null || true)"
  inputs="$(pactl list sink-inputs 2>/dev/null || true)"
  on_match=0
  if [[ "${PLAYER_MODE}" == "all" ]]; then
    if [[ -n "${inputs}" ]]; then
      sink_idxs="$(
        printf '%s\n' "${inputs}" | awk '
          /^Sink Input #/ { if (sink != "") print sink; sink="" }
          /^[[:space:]]*Sink:[[:space:]]+/ { sink=$2 }
          END { if (sink != "") print sink }
        '
      )"
      while IFS= read -r idx; do
        [[ -z "${idx}" ]] && continue
        name="$(awk -v i="${idx}" '$1 == i { print $2; exit }' <<<"${short}")"
        if [[ -n "${name}" ]] && grep -qiE "${SINK_MATCH}" <<<"${name}"; then
          on_match=1
          echo "on_match sink (any): ${name}"
          break
        fi
      done <<<"${sink_idxs}"
    fi
    if [[ "${on_match}" -eq 1 ]]; then
      ok "some sink-input currently on matching sink (PLAYER_MODE=all)"
    else
      warn "no sink-input on matching sink (paused or on another device)"
    fi
  elif [[ -n "${PLAYER}" && "${PLAYER}" != "REPLACE_ME_FROM_DISCOVER" ]]; then
    if [[ -n "${inputs}" ]]; then
      idxs="$(
        printf '%s\n' "${inputs}" | awk -v p="${PLAYER}" '
          BEGIN { IGNORECASE=1 }
          /^Sink Input #/ { if (keep && sink != "") print sink; keep=0; sink="" }
          /^[[:space:]]*Sink:[[:space:]]+/ { sink=$2 }
          /application\.(name|process\.binary) = "/ {
            if (index($0, "\"" p "\"") || index(tolower($0), "\"" tolower(p) "\"")) keep=1
          }
          END { if (keep && sink != "") print sink }
        '
      )"
      while IFS= read -r idx; do
        [[ -z "${idx}" ]] && continue
        name="$(awk -v i="${idx}" '$1 == i { print $2; exit }' <<<"${short}")"
        if [[ -n "${name}" ]] && grep -qiE "${SINK_MATCH}" <<<"${name}"; then
          on_match=1
          echo "on_match sink: ${name}"
          break
        fi
      done <<<"${idxs}"
    fi
    if [[ "${on_match}" -eq 1 ]]; then
      ok "PLAYER currently on matching sink"
    else
      warn "PLAYER not on matching sink (paused or on another device)"
    fi
  fi
fi

if [[ "${SINK_MATCH}" == "REPLACE_ME_FROM_DISCOVER" || -z "${SINK_MATCH}" ]]; then
  warn "SINK_MATCH not set from discover"
else
  match_count="$(pactl list short sinks 2>/dev/null | grep -ciE "${SINK_MATCH}" || true)"
  echo "sink match count: ${match_count}"
  if [[ "${match_count}" -eq 0 ]]; then
    warn "0 sinks match (headset docked/disabled?)"
  elif [[ "${match_count}" -gt 1 ]]; then
    warn "multiple sinks match — OK for dual A50 outputs if both are the headset"
  else
    ok "exactly one sink match"
  fi
fi

if [[ "${PLAYER_MODE}" == "all" ]]; then
  ok "PLAYER_MODE=all (PLAYER optional)"
  if [[ "${PLAYER}" == "REPLACE_ME_FROM_DISCOVER" || -z "${PLAYER}" ]]; then
    warn "PLAYER unset (OK for all mode)"
  fi
elif [[ "${PLAYER}" == "REPLACE_ME_FROM_DISCOVER" || -z "${PLAYER}" ]]; then
  warn "PLAYER not set"
  if [[ "${ENABLED}" == "1" ]]; then
    fail "ENABLED=1 but PLAYER unset (PLAYER_MODE=single)"
  fi
elif command -v playerctl >/dev/null 2>&1; then
  if playerctl -l 2>/dev/null | grep -qxF "${PLAYER}"; then
    ok "PLAYER=${PLAYER} in playerctl -l"
    echo "status: $(playerctl -p "${PLAYER}" status 2>/dev/null || echo Gone)"
  else
    if [[ "${ENABLED}" == "1" ]]; then
      fail "PLAYER=${PLAYER} not in playerctl -l (start Spotify?)"
    else
      warn "PLAYER=${PLAYER} not in playerctl -l (start Spotify or fix name)"
    fi
  fi
fi

if [[ -x "${BIN}" ]]; then
  ok "binary ${BIN}"
  TOPIC_ROOT="${A50X_TOPIC_ROOT:-}"
  if [[ -z "${TOPIC_ROOT}" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${HERE}/a50x-spotify-pause.sh" && -d "${HERE}/lib" ]]; then
      # Running from clone: scripts/verify-*.sh
      TOPIC_ROOT="$(cd "${HERE}/.." && pwd)"
    elif [[ -f "${HERE}/../scripts/a50x-spotify-pause.sh" ]]; then
      TOPIC_ROOT="$(cd "${HERE}/.." && pwd)"
    fi
  fi
  REPO_SCRIPT="${TOPIC_ROOT:+${TOPIC_ROOT}/scripts/a50x-spotify-pause.sh}"
  if [[ -n "${REPO_SCRIPT}" && -f "${REPO_SCRIPT}" ]]; then
    bin_hash="$(sha256sum "${BIN}" | awk '{print $1}')"
    repo_hash="$(sha256sum "${REPO_SCRIPT}" | awk '{print $1}')"
    if [[ "${bin_hash}" == "${repo_hash}" ]]; then
      ok "deployed binary matches repo (${bin_hash:0:12}…)"
    else
      fail "deployed binary != repo script (run install-to-local.sh)"
    fi
    if grep -q 'WATCHER_VERSION=f4-mpris-multi-1' "${BIN}"; then
      ok "WATCHER_VERSION=f4-mpris-multi-1"
    else
      fail "installed binary missing WATCHER_VERSION=f4-mpris-multi-1 (run install-to-local.sh)"
    fi
    if grep -qE 'do_pause "sink-input-remove-soft"' "${BIN}"; then
      fail "installed binary still pauses via sink-input-remove-soft"
    else
      ok "retired disable_soft pause path absent"
    fi
    if grep -q 'hid-dock-chg-rise' "${BIN}" && grep -q 'hid_mode=battery_get' "${BIN}"; then
      ok "F3 battery GET HID path present"
    else
      fail "installed binary missing F3 hid-dock-chg / battery_get path"
    fi
    if grep -q 'PLAYER_MODE' "${BIN}" && grep -q 'we_paused_players' "${BIN}"; then
      ok "multi-MPRIS PLAYER_MODE / we_paused_players present"
    else
      fail "installed binary missing PLAYER_MODE / we_paused_players"
    fi
  else
    fail "repo script not found for hash compare — set A50X_TOPIC_ROOT to the clone root (e.g. A50X_TOPIC_ROOT=\$PWD)"
  fi
else
  warn "binary missing: ${BIN}"
fi

if [[ -f "${UNIT}" ]]; then
  ok "unit installed"
  if grep -q 'WantedBy=default.target' "${UNIT}" && grep -q 'Wants=pipewire-pulse.service' "${UNIT}"; then
    ok "unit has WantedBy + Wants=pipewire-pulse"
  else
    fail "unit missing WantedBy or Wants=pipewire-pulse"
  fi
  if systemctl --user is-enabled a50x-spotify-pause.service >/dev/null 2>&1; then
    ok "unit enabled"
  else
    warn "unit not enabled"
  fi
  if systemctl --user is-active a50x-spotify-pause.service >/dev/null 2>&1; then
    ok "unit active"
    if [[ "${DRY_RUN}" == "1" ]]; then
      fail "unit active with DRY_RUN=1 — not a live pause setup (set DRY_RUN=0)"
    fi
  else
    warn "unit not active"
  fi
  nrestarts="$(systemctl --user show -p NRestarts --value a50x-spotify-pause.service 2>/dev/null || echo 0)"
  if [[ "${nrestarts}" =~ ^[0-9]+$ ]] && [[ "${nrestarts}" -gt 0 ]]; then
    warn "NRestarts=${nrestarts} (possible crash loop)"
  fi
else
  warn "unit not installed at ${UNIT}"
fi

if [[ "${ENABLED}" == "0" ]]; then
  warn "ENABLED=0 (safe; automation inactive until set to 1)"
fi

echo "=== done (exit ${rc}) ==="
exit "${rc}"
