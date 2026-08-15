#!/usr/bin/env bash
# Log A50 X hidraw interrupt reports (passive — no battery GET).
# Schema (CSV): ts,t0_ms,hex,phase,cmd
#   cmd = hex chars 4-5 (byte2); 05 ≈ heartbeat noise for F2e.
# Usage:
#   a50x-hid-probe.sh                    # PHASE=play
#   PHASE=dock a50x-hid-probe.sh
#   PHASE=power-off a50x-hid-probe.sh    # soft-disable edge (F2e)
#   PHASE=power-on a50x-hid-probe.sh     # power-on edge (F2e)
#   PHASE=power a50x-hid-probe.sh        # alias of power-off
#   a50x-hid-probe.sh /dev/hidrawN
#
# F2e: do NOT run a50x-hid-battery-probe concurrently (GET injects 06 frames).
set -euo pipefail

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
  power) phase="power-off" ;;
esac
case "${phase}" in
  play|dock|power-off|power-on) ;;
  *)
    echo "PHASE must be play, dock, power-off, power-on, or power (got: ${PHASE:-})" >&2
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

if [[ ! -r "${DEV}" ]]; then
  echo "Cannot read ${DEV} (permissions?). Install udev rule or run as user with access." >&2
  exit 1
fi

if ! command -v xxd >/dev/null 2>&1; then
  echo "xxd required (apt install xxd / vim-common)" >&2
  exit 1
fi

echo "# a50x-hid-probe device=${DEV} phase=${phase}" >&2
echo "# CSV: ts,t0_ms,hex,phase,cmd — Ctrl-C to stop" >&2
echo "# F2e: cmd=05 is heartbeat; candidates are non-05. No concurrent battery GET." >&2
case "${phase}" in
  power-off)
    echo "# Start undocked+ON; after first rows power OFF; leave off ≥10 s." >&2
    ;;
  power-on)
    echo "# Start undocked+OFF; after first rows power ON; keep ≥10 s." >&2
    ;;
  play)
    echo "# Play/listen soak ≥60 s; expect mostly cmd=05." >&2
    ;;
  dock)
    echo "# Dock samples; compare vs PHASE=play." >&2
    ;;
esac
echo "ts,t0_ms,hex,phase,cmd"

trap 'exit 0' INT TERM

start_ms="$(now_ms)"

# Blocking read with short timeout: A50 X only emits interrupt reports
# occasionally; nonblock dd returns empty and looks like "wrong device".
while true; do
  hex="$(timeout 1.0 dd if="${DEV}" bs=64 count=1 status=none 2>/dev/null | xxd -p -c 256 | tr -d '\n' || true)"
  if [[ -n "${hex}" ]]; then
    loop_ms="$(now_ms)"
    t0_ms=$((loop_ms - start_ms))
    [[ "${t0_ms}" -ge 0 ]] || t0_ms=0
    if [[ ${#hex} -ge 6 ]]; then
      cmd="${hex:4:2}"
    else
      cmd=""
    fi
    printf '%s,%s,%s,%s,%s\n' "$(iso_ts)" "${t0_ms}" "${hex}" "${phase}" "${cmd}"
  fi
done
