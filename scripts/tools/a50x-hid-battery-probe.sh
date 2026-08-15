#!/usr/bin/env bash
# F2b/F2c: active Gen5-style battery GET on A50 X hidraw (046d:0b0b).
# Poll CMD 0x06 every 250 ms; emit CSV edges for dock/charging or offline.
# Probe/matrix only — does not change watcher pause logic.
#
# Schema (CSV): ts,phase,t0_ms,level,dock_chg,online,edge,raw_hex
# Usage:
#   a50x-hid-battery-probe.sh                         # PHASE=play
#   PHASE=play a50x-hid-battery-probe.sh > /tmp/a50x-hid-batt-play.csv
#   PHASE=dock-t0 a50x-hid-battery-probe.sh > /tmp/a50x-hid-batt-dock1.csv
#     (start this at cradle contact; t0_ms=0 is process start)
#   PHASE=power a50x-hid-battery-probe.sh > /tmp/a50x-hid-batt-power1.csv
#     (undocked + powered on; power off after online=1 rows; edge=online_fall)
#   a50x-hid-battery-probe.sh /dev/hidrawN
set -euo pipefail

POLL_MS="${POLL_MS:-250}"
READ_ATTEMPTS="${READ_ATTEMPTS:-8}"
READ_TIMEOUT_SEC="${READ_TIMEOUT_SEC:-0.1}"
OFFLINE_MISS_THRESHOLD="${OFFLINE_MISS_THRESHOLD:-3}"

# Gen5 battery GET: 02 0c 03 00 06 0c + zero pad to 64 bytes
GET_HEX="020c0300060c$(printf '00%.0s' {1..58})"

find_a50_hidraw() {
  local hr uevent
  for hr in /sys/class/hidraw/hidraw*; do
    [[ -e "${hr}/device/uevent" ]] || continue
    uevent="$(cat "${hr}/device/uevent" 2>/dev/null || true)"
    if grep -qi 'HID_ID=.*046D:.*0B0B' <<<"${uevent}" || grep -qi '046D:00000B0B' <<<"${uevent}"; then
      printf '/dev/%s\n' "$(basename "${hr}")"
      return 0
    fi
  done
  return 1
}

now_ms() {
  date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))'
}

iso_ts() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ
}

DEV="${1:-}"
phase="${PHASE:-play}"
case "${phase}" in
  play|dock|dock-t0|power) ;;
  *)
    echo "PHASE must be play, dock, dock-t0, or power (got: ${phase})" >&2
    exit 2
    ;;
esac

if [[ -z "${DEV}" ]]; then
  DEV="$(find_a50_hidraw)" || {
    echo "No readable A50 X hidraw (046d:0b0b). Install udev rule and replug / re-login." >&2
    echo "  sudo cp udev/99-logitech-a50x-hid.rules /etc/udev/rules.d/" >&2
    echo "  sudo udevadm control --reload && sudo udevadm trigger -c add -s hidraw" >&2
    exit 1
  }
fi

if [[ ! -r "${DEV}" || ! -w "${DEV}" ]]; then
  echo "Need read+write on ${DEV} (permissions?). Install udev rule or fix group/uaccess." >&2
  exit 1
fi

if ! command -v xxd >/dev/null 2>&1; then
  echo "xxd required (apt install xxd / vim-common)" >&2
  exit 1
fi

exec 3<>"${DEV}"

send_battery_get() {
  printf '%s' "${GET_HEX}" | xxd -r -p >&3
}

# Print matching battery reply hex to stdout; return 1 if none.
read_battery_reply() {
  local attempt hex b0 b1 b4
  for ((attempt = 1; attempt <= READ_ATTEMPTS; attempt++)); do
    hex="$(timeout "${READ_TIMEOUT_SEC}" dd bs=64 count=1 status=none <&3 2>/dev/null | xxd -p -c 256 | tr -d '\n' || true)"
    [[ -n "${hex}" && ${#hex} -ge 18 ]] || continue
    b0="${hex:0:2}"
    b1="${hex:2:2}"
    b4="${hex:8:2}"
    if [[ "${b0}" == "02" && "${b1}" == "0c" && "${b4}" == "06" ]]; then
      printf '%s\n' "${hex}"
      return 0
    fi
  done
  return 1
}

echo "# a50x-hid-battery-probe device=${DEV} phase=${phase} poll_ms=${POLL_MS}" >&2
echo "# CSV: ts,phase,t0_ms,level,dock_chg,online,edge,raw_hex — Ctrl-C to stop" >&2
if [[ "${phase}" == "dock-t0" ]]; then
  echo "# T0 = now (start at cradle contact). Edge must appear with t0_ms<=2000." >&2
elif [[ "${phase}" == "power" ]]; then
  echo "# F2c soft-disable: start undocked + powered on (online=1, dock_chg=0)." >&2
  echo "# Power off headset after online=1 rows appear; keep running ≥5 s after online_fall." >&2
  echo "# Score detect_lag = last online=1 row → online_fall (must be ≤2000 ms)." >&2
fi
echo "ts,phase,t0_ms,level,dock_chg,online,edge,raw_hex"

trap 'exec 3>&-; exit 0' INT TERM

start_ms="$(now_ms)"
prev_dock_chg=""
prev_online=""
misses=0
had_good=0

while true; do
  loop_start_ms="$(now_ms)"
  t0_ms=$((loop_start_ms - start_ms))
  [[ "${t0_ms}" -ge 0 ]] || t0_ms=0

  send_battery_get || true
  hex=""
  level=""
  dock_chg=0
  online=0
  edge="none"
  raw_hex=""

  if hex="$(read_battery_reply)"; then
    had_good=1
    misses=0
    online=1
    level="$((16#${hex:12:2}))"
    dock_byte="$((16#${hex:16:2}))"
    if [[ "${dock_byte}" -ne 0 ]]; then
      dock_chg=1
    fi
    raw_hex="${hex}"
  else
    misses=$((misses + 1))
    raw_hex=""
    if [[ "${had_good}" -eq 1 && "${misses}" -ge "${OFFLINE_MISS_THRESHOLD}" ]]; then
      online=0
      level=""
      dock_chg=0
    elif [[ "${had_good}" -eq 0 ]]; then
      online=0
      level=""
      dock_chg=0
    else
      # Transient miss while still considered online (below threshold)
      online=1
      level=""
      dock_chg="${prev_dock_chg:-0}"
    fi
  fi

  if [[ -n "${prev_dock_chg}" && "${prev_dock_chg}" == "0" && "${dock_chg}" == "1" ]]; then
    edge="dock_chg_rise"
  elif [[ -n "${prev_online}" && "${prev_online}" == "1" && "${online}" == "0" ]]; then
    edge="online_fall"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(iso_ts)" "${phase}" "${t0_ms}" "${level}" "${dock_chg}" "${online}" "${edge}" "${raw_hex}"

  prev_dock_chg="${dock_chg}"
  prev_online="${online}"

  elapsed=$(( $(now_ms) - loop_start_ms ))
  sleep_ms=$((POLL_MS - elapsed))
  if [[ "${sleep_ms}" -gt 0 ]]; then
    # bash sleep accepts fractional seconds
    sleep "$(awk -v ms="${sleep_ms}" 'BEGIN { printf "%.3f", ms/1000 }')"
  fi
done
