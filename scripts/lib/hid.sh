#!/usr/bin/env bash
# HID F3/F3b/F3c: battery GET dock_chg + passive soft-off/on (sourced by a50x-spotify-pause).
# Functions only — no top-level executable code.
# shellcheck shell=bash

# --- HID F3/F3b/F3c: battery GET dock_chg + passive soft-off/on; HID_MATCH_HEX deprecated ---

# Gen5 battery GET frame: 02 0c 03 00 06 0c + zero pad to 64 bytes
HID_BATTERY_GET_HEX="020c0300060c$(printf '00%.0s' {1..58})"
HID_READ_ATTEMPTS=8
HID_READ_TIMEOUT_SEC=0.1
HID_DRAIN_ATTEMPTS=4

find_a50_hidraw() {
  local hr uevent dev
  if [[ -n "${HID_DEVICE}" ]]; then
    if [[ -r "${HID_DEVICE}" && -w "${HID_DEVICE}" ]]; then
      printf '%s\n' "${HID_DEVICE}"
      return 0
    fi
    return 1
  fi
  for hr in /sys/class/hidraw/hidraw*; do
    [[ -e "${hr}/device/uevent" ]] || continue
    uevent="$(cat "${hr}/device/uevent" 2>/dev/null || true)"
    if grep -qi 'HID_ID=.*046D:.*0B0B' <<<"${uevent}" || grep -qi '046D:00000B0B' <<<"${uevent}"; then
      dev="/dev/$(basename "${hr}")"
      if [[ -r "${dev}" && -w "${dev}" ]]; then
        printf '%s\n' "${dev}"
        return 0
      fi
    fi
  done
  return 1
}

hid_close_fd() {
  if [[ "${hid_fd_open}" == "1" ]]; then
    exec 9>&- 2>/dev/null || true
    hid_fd_open=0
  fi
}

hid_open_fd() {
  local dev
  if [[ "${hid_fd_open}" == "1" ]]; then
    return 0
  fi
  dev="$(find_a50_hidraw 2>/dev/null || true)"
  [[ -n "${dev}" ]] || return 1
  exec 9<>"${dev}" || return 1
  hid_fd_open=1
  hid_open_dev="${dev}"
  return 0
}

hid_hex_is_soft_off() {
  local hex="$1"
  local pref="${HID_SOFT_OFF_PREFIX}"
  local n=${#pref}
  [[ -n "${pref}" && ${#hex} -ge n && "${hex:0:n}" == "${pref}" ]]
}

hid_hex_is_soft_on() {
  local hex="$1"
  local pref="${HID_SOFT_ON_PREFIX}"
  local n=${#pref}
  [[ -n "${pref}" && ${#hex} -ge n && "${hex:0:n}" == "${pref}" ]]
}

# Classify one hex frame into soft-off / soft-on flags (never match GET cmd=06).
hid_note_passive_hex() {
  local hex="$1"
  if hid_hex_is_soft_off "${hex}"; then
    HID_SOFT_OFF_SEEN=1
  elif hid_hex_is_soft_on "${hex}"; then
    HID_SOFT_ON_SEEN=1
  fi
}

# Drain pending interrupts; return 0 if soft-off or soft-on seen.
hid_drain_passive() {
  local attempt hex
  HID_SOFT_OFF_SEEN=0
  HID_SOFT_ON_SEEN=0
  if ! hid_open_fd; then
    return 1
  fi
  for ((attempt = 1; attempt <= HID_DRAIN_ATTEMPTS; attempt++)); do
    hex="$(timeout "${HID_READ_TIMEOUT_SEC}" dd bs=64 count=1 status=none <&9 2>/dev/null | xxd -p -c 256 | tr -d '\n' || true)"
    [[ -n "${hex}" ]] || {
      if [[ "${HID_SOFT_OFF_SEEN}" == "1" || "${HID_SOFT_ON_SEEN}" == "1" ]]; then
        return 0
      fi
      return 1
    }
    hex="$(printf '%s' "${hex}" | tr 'A-F' 'a-f')"
    hid_note_passive_hex "${hex}"
    if [[ "${HID_SOFT_OFF_SEEN}" == "1" || "${HID_SOFT_ON_SEEN}" == "1" ]]; then
      return 0
    fi
  done
  return 1
}

# Pause on soft-off if gates pass. Sets hid_soft_off_episode on successful pause path.
hid_try_pause_soft_off() {
  local st
  last_intent=disable
  st="$(aggregate_player_status)"
  if ! on_match_gate; then
    log_edge "HID soft-off skipped (not on A50 sink)"
    return 0
  fi
  if ! eligible_for_pause_gate; then
    log_edge "HID soft-off skipped status=${st}"
    return 0
  fi
  if [[ -n "${we_paused_players}" ]] && ! any_playing; then
    log "coalesce HID soft-off (already paused) players=$(we_paused_csv)"
    return 0
  fi
  log "HID soft-off device=${hid_open_dev:-unknown} prefix=${HID_SOFT_OFF_PREFIX}"
  hid_soft_off_episode=1
  arm_disable_latch "${st}"
  do_pause "hid-soft-off" 0 "hid"
  if [[ -z "${we_paused_players}" ]]; then
    hid_soft_off_episode=0
  fi
  return 0
}

# Resume on soft-on only after a soft-off pause episode.
hid_try_resume_soft_on() {
  if [[ "${hid_soft_off_episode}" != "1" ]]; then
    log_edge "HID soft-on skipped (no soft-off episode)"
    return 0
  fi
  log "HID soft-on device=${hid_open_dev:-unknown} prefix=${HID_SOFT_ON_PREFIX}"
  try_resume "hid-soft-on"
  return 0
}

hid_handle_passive_edges() {
  if [[ "${HID_SOFT_OFF_SEEN}" == "1" ]]; then
    hid_try_pause_soft_off
  fi
  if [[ "${HID_SOFT_ON_SEEN}" == "1" ]]; then
    hid_try_resume_soft_on
  fi
}

# On success: sets HID_DOCK_CHG_RESULT=0|1. Miss/error → return 1 (keep last dock_chg).
# May set HID_SOFT_OFF_SEEN / HID_SOFT_ON_SEEN if passive edges arrive mid-GET wait.
# Must not run in command substitution — open fd / hid_open_dev must persist in parent.
hid_battery_get_dock_chg() {
  local attempt hex b0 b1 b4 dock_byte
  HID_DOCK_CHG_RESULT=""
  if ! hid_open_fd; then
    return 1
  fi
  if ! printf '%s' "${HID_BATTERY_GET_HEX}" | xxd -r -p >&9 2>/dev/null; then
    hid_close_fd
    return 1
  fi
  for ((attempt = 1; attempt <= HID_READ_ATTEMPTS; attempt++)); do
    hex="$(timeout "${HID_READ_TIMEOUT_SEC}" dd bs=64 count=1 status=none <&9 2>/dev/null | xxd -p -c 256 | tr -d '\n' || true)"
    [[ -n "${hex}" && ${#hex} -ge 18 ]] || continue
    hex="$(printf '%s' "${hex}" | tr 'A-F' 'a-f')"
    b0="${hex:0:2}"
    b1="${hex:2:2}"
    b4="${hex:8:2}"
    if [[ "${b0}" == "02" && "${b1}" == "0c" && "${b4}" == "06" ]]; then
      dock_byte="$((16#${hex:16:2}))"
      if [[ "${dock_byte}" -ne 0 ]]; then
        HID_DOCK_CHG_RESULT=1
      else
        HID_DOCK_CHG_RESULT=0
      fi
      return 0
    fi
    # Never treat GET cmd=06 as soft-on; only non-06 passive frames.
    hid_note_passive_hex "${hex}"
  done
  return 1
}

maybe_hid_poll() {
  [[ "${HID_ENABLE}" == "1" ]] || return 0
  [[ "${ENABLED}" == "1" ]] || return 0
  if ! command -v xxd >/dev/null 2>&1; then
    if [[ "${hid_warned_xxd}" != "1" ]]; then
      log "HID_ENABLE=1 but xxd missing; skipping HID"
      hid_warned_xxd=1
    fi
    return 0
  fi

  local dock_chg st
  HID_SOFT_OFF_SEEN=0
  HID_SOFT_ON_SEEN=0

  # Drain pending interrupts before GET (non-06 frames were previously dropped).
  if hid_drain_passive; then
    hid_handle_passive_edges
  fi

  if ! hid_battery_get_dock_chg; then
    if [[ "${HID_SOFT_OFF_SEEN}" == "1" || "${HID_SOFT_ON_SEEN}" == "1" ]]; then
      hid_handle_passive_edges
      hid_warned_device=0
      return 0
    fi
    if [[ "${hid_warned_device}" != "1" ]]; then
      log "HID battery GET miss/unavailable (will retry; no edge)"
      hid_warned_device=1
    fi
    return 0
  fi
  hid_warned_device=0

  if [[ "${HID_SOFT_OFF_SEEN}" == "1" || "${HID_SOFT_ON_SEEN}" == "1" ]]; then
    hid_handle_passive_edges
  fi

  dock_chg="${HID_DOCK_CHG_RESULT}"

  if [[ "${hid_dock_chg_seeded}" != "1" ]]; then
    hid_dock_chg="${dock_chg}"
    hid_dock_chg_seeded=1
    log "HID battery seed dock_chg=${hid_dock_chg} device=${hid_open_dev:-unknown} (no edge)"
    return 0
  fi

  if [[ "${hid_dock_chg}" == "0" && "${dock_chg}" == "1" ]]; then
    hid_dock_chg=1
    last_intent=disable
    st="$(aggregate_player_status)"
    if ! on_match_gate; then
      log_edge "HID dock_chg_rise skipped (not on A50 sink)"
      return 0
    fi
    if ! eligible_for_pause_gate; then
      log_edge "HID dock_chg_rise skipped status=${st}"
      return 0
    fi
    if [[ -n "${we_paused_players}" ]] && ! any_playing; then
      log "coalesce HID dock_chg_rise (already paused) players=$(we_paused_csv)"
      return 0
    fi
    log "HID dock_chg_rise device=${hid_open_dev:-unknown}"
    arm_disable_latch "${st}"
    do_pause "hid-dock-chg-rise" 0 "hid"
    return 0
  fi

  if [[ "${hid_dock_chg}" == "1" && "${dock_chg}" == "0" ]]; then
    hid_dock_chg=0
    log "HID dock_chg_fall device=${hid_open_dev:-unknown}"
    try_resume "hid-dock-chg-fall"
    return 0
  fi

  hid_dock_chg="${dock_chg}"
}
