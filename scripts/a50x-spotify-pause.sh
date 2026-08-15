#!/usr/bin/env bash
# Pause MPRIS media on confirmed A50X disable_intent (off-match after remove / HID).
# PLAYER_MODE=single (default): one PLAYER (typically Spotify).
# PLAYER_MODE=all: all Playing players from playerctl -l.
# Never re-pause after user Play. Resume only if this watcher paused it.
# F0: remove-while-still-on-A50 is log-only (retired ambiguous disable_soft).
# Usage: a50x-spotify-pause  (long-running; intended as user systemd service)
set -euo pipefail

WATCHER_VERSION=f4-mpris-multi-1

CFG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/astro-a50x-spotify-pause"
CFG_FILE="${CFG_DIR}/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_a50x_lib() {
  local name="$1"
  if [[ -f "${SCRIPT_DIR}/lib/${name}" ]]; then
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/lib/${name}"
  elif [[ -f "${SCRIPT_DIR}/a50x-spotify-pause-lib/${name}" ]]; then
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/a50x-spotify-pause-lib/${name}"
  elif [[ -f "${HOME}/.local/bin/a50x-spotify-pause-lib/${name}" ]]; then
    # shellcheck disable=SC1090
    source "${HOME}/.local/bin/a50x-spotify-pause-lib/${name}"
  else
    return 1
  fi
  return 0
}

# Prefer sibling lib when running from repo; optional installed lib dir; else inlined classifier fallback.
if source_a50x_lib classify-remove-intent.sh; then
  :
fi
# Fallback if lib missing (inlined copy of classifier).
if ! declare -F classify_remove_intent >/dev/null 2>&1; then
  classify_remove_intent() {
    local was_on_match="$1" on_match="$2" pending_new="$3" status="$4"
    if [[ "${was_on_match}" != "1" ]]; then
      printf '%s\n' "none"; return 0
    fi
    if [[ "${on_match}" == "0" ]]; then
      printf '%s\n' "disable"; return 0
    fi
    if [[ "${pending_new}" == "1" ]]; then
      printf '%s\n' "churn"; return 0
    fi
    case "${status}" in
      Playing) printf '%s\n' "ambiguous_on_match" ;;
      *) printf '%s\n' "churn" ;;
    esac
  }
fi

ENABLED=0
DRY_RUN=1
SINK_MATCH=REPLACE_ME_FROM_DISCOVER
PLAYER=REPLACE_ME_FROM_DISCOVER
# single = one PLAYER; all = every Playing MPRIS player from playerctl -l.
PLAYER_MODE=single
DEBOUNCE_MS=200
RESUME_DELAY_MS=400
REQUIRE_PLAYING=1
AUTO_RESUME=1
CLEAR_ON_USER_PAUSE=1
LOG_EDGE_EVENTS=0
POLL_SEC=1
# TTL for disable_intent bookkeeping (not a re-pause weapon). Default 15; do not auto-bump higher on migrate.
DISABLE_LATCH_SEC=15
HID_ENABLE=0
HID_MATCH_HEX=""
HID_DEVICE=""
# Empty = use F2e PASS defaults below (after config source).
HID_SOFT_OFF_PREFIX=""
HID_SOFT_ON_PREFIX=""

if [[ -f "${CFG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CFG_FILE}"
fi

PLAYER_MODE="${PLAYER_MODE:-single}"
case "${PLAYER_MODE}" in
  single | all) ;;
  *)
    echo "a50x-spotify-pause: invalid PLAYER_MODE=${PLAYER_MODE}; using single" >&2
    PLAYER_MODE=single
    ;;
esac

# F2e PASS (r3): first soft-disable / power-on interrupt prefixes (14 hex chars).
HID_SOFT_OFF_PREFIX_DEFAULT=020c04000a0006
HID_SOFT_ON_PREFIX_DEFAULT=020c0400130000
if [[ -z "${HID_SOFT_OFF_PREFIX}" ]]; then
  HID_SOFT_OFF_PREFIX="${HID_SOFT_OFF_PREFIX_DEFAULT}"
fi
if [[ -z "${HID_SOFT_ON_PREFIX}" ]]; then
  HID_SOFT_ON_PREFIX="${HID_SOFT_ON_PREFIX_DEFAULT}"
fi
HID_SOFT_OFF_PREFIX="$(printf '%s' "${HID_SOFT_OFF_PREFIX}" | tr 'A-F' 'a-f')"
HID_SOFT_ON_PREFIX="$(printf '%s' "${HID_SOFT_ON_PREFIX}" | tr 'A-F' 'a-f')"

log() {
  local msg="$*"
  logger -t a50x-spotify-pause -- "${msg}" 2>/dev/null || true
  echo "a50x-spotify-pause: ${msg}" >&2
}

log_edge() {
  if [[ "${LOG_EDGE_EVENTS}" == "1" ]]; then
    log "$@"
  fi
}

require_cmds() {
  local missing=0
  command -v pactl >/dev/null 2>&1 || { log "missing pactl"; missing=1; }
  command -v playerctl >/dev/null 2>&1 || { log "missing playerctl (apt install playerctl)"; missing=1; }
  return "${missing}"
}

sinks_match() {
  local lines
  lines="$(pactl list short sinks 2>/dev/null || true)"
  [[ -n "${lines}" ]] || return 1
  grep -qiE "${SINK_MATCH}" <<<"${lines}"
}

player_on_match_sink() {
  local short inputs idxs idx name
  short="$(pactl list short sinks 2>/dev/null || true)"
  inputs="$(pactl list sink-inputs 2>/dev/null || true)"
  [[ -n "${inputs}" ]] || return 1

  idxs="$(
    printf '%s\n' "${inputs}" | awk -v p="${PLAYER}" '
      BEGIN { IGNORECASE=1 }
      /^Sink Input #/ {
        if (keep && sink != "") print sink
        keep=0; sink=""
      }
      /^[[:space:]]*Sink:[[:space:]]+/ { sink=$2 }
      /application\.(name|process\.binary) = "/ {
        if (index($0, "\"" p "\"") || index(tolower($0), "\"" tolower(p) "\"")) keep=1
      }
      END { if (keep && sink != "") print sink }
    '
  )"
  [[ -n "${idxs}" ]] || return 1

  while IFS= read -r idx; do
    [[ -z "${idx}" ]] && continue
    name="$(awk -v i="${idx}" '$1 == i { print $2; exit }' <<<"${short}")"
    if [[ -n "${name}" ]] && grep -qiE "${SINK_MATCH}" <<<"${name}"; then
      return 0
    fi
  done <<<"${idxs}"
  return 1
}

# Any sink-input whose sink matches SINK_MATCH (PLAYER_MODE=all A50 gate).
any_on_match_sink() {
  local short inputs sink_idxs idx name
  short="$(pactl list short sinks 2>/dev/null || true)"
  inputs="$(pactl list sink-inputs 2>/dev/null || true)"
  [[ -n "${inputs}" ]] || return 1
  sink_idxs="$(
    printf '%s\n' "${inputs}" | awk '
      /^Sink Input #/ {
        if (sink != "") print sink
        sink=""
      }
      /^[[:space:]]*Sink:[[:space:]]+/ { sink=$2 }
      END { if (sink != "") print sink }
    '
  )"
  [[ -n "${sink_idxs}" ]] || return 1
  while IFS= read -r idx; do
    [[ -z "${idx}" ]] && continue
    name="$(awk -v i="${idx}" '$1 == i { print $2; exit }' <<<"${short}")"
    if [[ -n "${name}" ]] && grep -qiE "${SINK_MATCH}" <<<"${name}"; then
      return 0
    fi
  done <<<"${sink_idxs}"
  return 1
}

on_match_gate() {
  if [[ "${PLAYER_MODE}" == "all" ]]; then
    any_on_match_sink
  else
    player_on_match_sink
  fi
}


# MPRIS + HID libs (after on_match_gate; HID needs do_pause / arm_disable_latch from mpris).
if ! source_a50x_lib mpris.sh; then
  echo "a50x-spotify-pause: missing lib/mpris.sh" >&2
  exit 1
fi
if ! source_a50x_lib hid.sh; then
  echo "a50x-spotify-pause: missing lib/hid.sh" >&2
  exit 1
fi


# Latch no longer re-pauses Playing. Off-match: one first pause if needed; Playing → override.
discharge_disable_latch() {
  disable_latch_armed || return 0
  local on=0
  on_match_gate && on=1
  local st
  st="$(aggregate_player_status)"
  if any_playing || any_we_paused_playing; then
    user_play_override "play_while_latch"
    return 0
  fi
  if [[ "${on}" == "0" && "${we_paused_it}" != "1" ]]; then
    if [[ "${st}" == "Gone" && "${latched_playing}" == "1" ]]; then
      log "latch first-pause Gone while latched_playing"
      try_pause_off_match "disable-latch-gone" 1 "pw"
    elif [[ "${st}" != "Paused" && "${st}" != "Stopped" ]]; then
      log "latch first-pause on_match=0 status=${st}"
      try_pause_off_match "disable-latch" 1 "pw"
    fi
  fi
}

apply_on_match_state() {
  local reason="$1"
  local edge_was_on_match="${was_on_match}"
  local on=0
  if on_match_gate; then
    on=1
  fi
  local st
  st="$(aggregate_player_status)"
  log "probe on_match=${on} was_on_match=${edge_was_on_match} status=${st} reason=${reason} latch=$(disable_latch_armed && echo 1 || echo 0) intent=${last_intent} PLAYER_MODE=${PLAYER_MODE}"

  if [[ "${on}" == "0" ]]; then
    maybe_clear_while_off_match
    local force=0
    if disable_latch_armed && [[ "${latched_playing}" == "1" || "${edge_was_on_match}" == "1" ]]; then
      force=1
    fi
    # H03b: only falling edge or latch first-pause — never bare Playing while off-match.
    if [[ "${edge_was_on_match}" == "1" ]] || [[ "${force}" == "1" ]]; then
      try_pause_off_match "${reason}" "${force}" "pw"
    else
      log "probe action=skipped on_match=0 status=${st} reason=${reason}"
    fi
    was_on_match=0
  else
    if any_playing || any_we_paused_playing; then
      user_play_override "play_on_match"
    fi
    if [[ "${edge_was_on_match}" == "0" ]]; then
      try_resume "on-match-returned"
    fi
    was_on_match=1
    if any_playing; then
      latched_playing=1
    fi
  fi
}

evaluate_edge() {
  local edge_was_on_match="${was_on_match}"
  local edge_was_sinks="${was_sinks}"
  local new_on=0 new_sinks=0
  if on_match_gate; then
    new_on=1
  fi
  if sinks_match; then
    new_sinks=1
  fi

  if [[ "${new_on}" == "0" ]]; then
    maybe_clear_while_off_match
    local force=0
    if disable_latch_armed && [[ "${latched_playing}" == "1" ]]; then
      force=1
    fi
    if [[ "${ENABLED}" == "1" ]]; then
      if [[ "${edge_was_on_match}" == "1" ]] || [[ "${force}" == "1" ]]; then
        last_intent=disable
        log_edge "falling edge (off match sink) event=${last_event_kind}"
        arm_disable_latch "$(aggregate_player_status)"
        try_pause_off_match "off-match-sink" "${force}" "pw"
      fi
    fi
  else
    if any_playing || any_we_paused_playing; then
      user_play_override "play_on_match_edge"
    fi
  fi

  # H03c: sinks-gone is log-only (dual A50 outputs / PW churn). Hard unplug still hits off-match edge.
  if [[ "${edge_was_sinks}" == "1" && "${new_sinks}" == "0" ]]; then
    log "intent=sinks-gone action=skipped (retired pause path)"
  fi

  if [[ "${edge_was_sinks}" == "0" && "${new_sinks}" == "1" ]]; then
    try_resume "sinks-returned"
  fi

  if [[ "${edge_was_on_match}" == "0" && "${new_on}" == "1" ]]; then
    try_resume "on-match-returned"
  fi

  was_on_match="${new_on}"
  was_sinks="${new_sinks}"
  if [[ "${new_on}" == "1" ]] && any_playing; then
    latched_playing=1
  fi
}

flush_subscribe_backlog() {
  local line
  pending_sink_input_remove=0
  pending_sink_input_new=0
  while IFS= read -t 0.05 -r line; do
    if [[ "${line}" == *"remove' on sink-input"* ]]; then
      pending_sink_input_remove=1
    fi
    if [[ "${line}" == *"new' on sink-input"* ]]; then
      pending_sink_input_new=1
    fi
    classify_event "${line}" || true
  done || true
}

# Soft-disable often keeps on_match=1; remove alone is ambiguous with stream churn.
# Pause only on confirmed off-match (or HID later). Never re-pause after user Play.
# PW remove path stays single-PLAYER shaped for cork; in all mode uses aggregate status
# but does not broaden soft-pause while still on A50.
handle_sink_input_remove() {
  local st on=0 settle_ms intent
  local edge_was_on_match="${was_on_match}"
  st="$(aggregate_player_status)"
  note_playing_activity
  log "sink-input remove seen was_on_match=${edge_was_on_match} status=${st}"

  if [[ "${we_paused_it}" == "1" ]]; then
    log "coalesce sink-input-remove (already paused this episode) players=$(we_paused_csv)"
    sleep 0.05
    flush_subscribe_backlog
    pending_sink_input_remove=0
    apply_on_match_state "sink-input-remove-coalesce"
    return 0
  fi

  pending_sink_input_new=0
  settle_ms="${DEBOUNCE_MS}"
  if (( settle_ms < 600 )); then
    settle_ms=600
  fi
  sleep "$(ms_to_sec "${settle_ms}")"
  flush_subscribe_backlog
  pending_sink_input_remove=0

  if on_match_gate; then
    on=1
  fi
  st="$(aggregate_player_status)"
  intent="$(classify_remove_intent "${edge_was_on_match}" "${on}" "${pending_sink_input_new}" "${st}")"
  last_intent="${intent}"

  case "${intent}" in
    disable)
      arm_disable_latch "${st}"
      if [[ "${st}" != "Playing" ]] && recent_playing; then
        latched_playing=1
      fi
      if [[ "${ENABLED}" == "1" ]]; then
        if [[ "${st}" == "Playing" ]] || { [[ "${PLAYER_MODE}" == "single" ]] && spotify_uncorked; }; then
          do_pause "sink-input-remove-offmatch" 0 "pw"
        elif [[ "${st}" == "Gone" ]]; then
          do_pause "sink-input-remove-gone" 1 "pw"
        fi
      fi
      ;;
    churn)
      log "intent=churn action=skipped on_match=${on} status=${st} pending_new=${pending_sink_input_new}"
      ;;
    ambiguous_on_match)
      # F0: retired disable_soft — do not pause while still on A50.
      log "intent=ambiguous_on_match action=skipped on_match=1 status=${st} (retired disable_soft; wait off-match or HID)"
      ;;
    none)
      log "intent=none action=skipped was_on_match=${edge_was_on_match} on_match=${on}"
      ;;
  esac

  apply_on_match_state "sink-input-remove"
  discharge_disable_latch
}

debounce_and_evaluate() {
  local edge_was_on_match="${was_on_match}"
  sleep "$(ms_to_sec "${DEBOUNCE_MS}")"
  flush_subscribe_backlog
  if [[ "${pending_sink_input_remove}" == "1" ]]; then
    pending_sink_input_remove=0
    was_on_match="${edge_was_on_match}"
    handle_sink_input_remove
    maybe_poll
    return 0
  fi
  was_on_match="${edge_was_on_match}"
  evaluate_edge
  maybe_poll
}

maybe_poll() {
  if (( SECONDS - last_poll_at >= POLL_SEC )); then
    last_poll_at="${SECONDS}"
    poll_off_match_playing
    discharge_disable_latch
    maybe_hid_poll
  fi
}

poll_off_match_playing() {
  [[ "${ENABLED}" == "1" ]] || return 0
  local on=0
  if on_match_gate; then
    on=1
  fi
  local st
  st="$(aggregate_player_status)"
  note_playing_activity
  if [[ "${on}" == "1" ]]; then
    # H03c: never poll-latch-replaying. Playing on match → user owns playback.
    if any_playing || any_we_paused_playing; then
      user_play_override "play_on_match_poll"
    fi
    if [[ "${was_on_match}" == "0" ]]; then
      try_resume "poll-on-match"
    fi
    was_on_match=1
    if any_playing; then
      latched_playing=1
    fi
    return 0
  fi
  # H03b: off-match poll only on falling edge memory or latch first-pause — not bare Playing.
  local force=0
  if disable_latch_armed && [[ "${latched_playing}" == "1" ]]; then
    force=1
  fi
  if [[ "${was_on_match}" == "1" ]] || [[ "${force}" == "1" ]]; then
    if [[ "${was_on_match}" == "1" ]]; then
      last_intent=disable
      arm_disable_latch "${st}"
    fi
    try_pause_off_match "poll-off-match" "${force}" "pw"
  fi
  was_on_match=0
}


run_subscribe_loop() {
  local line rc
  while true; do
    maybe_poll
    rc=0
    IFS= read -t "${POLL_SEC}" -r line || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      if ! classify_event "${line}"; then
        continue
      fi
      if [[ "${line}" == *"remove' on sink-input"* ]]; then
        handle_sink_input_remove
        maybe_poll
        continue
      fi
      debounce_and_evaluate
    elif [[ "${rc}" -gt 128 ]]; then
      maybe_poll
    else
      log "pactl subscribe EOF (rc=${rc})"
      break
    fi
  done < <(pactl subscribe 2>/dev/null)
}

we_paused_it=0
we_paused_players=""
post_pause_skip=0
was_on_match=0
was_sinks=0
last_event_kind=none
paused_at=0
pending_sink_input_remove=0
pending_sink_input_new=0
disable_latch_until=0
latched_playing=0
last_poll_at=0
last_playing_at=0
hid_paused_at=0
pw_paused_at=0
last_hid_match_at=0
our_resume_in_progress=0
last_intent=none
hid_fd_open=0
hid_open_dev=""
hid_dock_chg_seeded=0
hid_dock_chg=0
hid_warned_xxd=0
hid_warned_device=0
hid_warned_match_hex=0
HID_SOFT_OFF_SEEN=0
HID_SOFT_ON_SEEN=0
hid_soft_off_episode=0

if ! require_cmds; then
  exit 1
fi

if [[ "${SINK_MATCH}" == "REPLACE_ME_FROM_DISCOVER" || -z "${SINK_MATCH}" ]]; then
  log "SINK_MATCH not configured; run discover-a50x-sink.sh"
  exit 1
fi
if [[ "${PLAYER_MODE}" == "single" ]]; then
  if [[ "${PLAYER}" == "REPLACE_ME_FROM_DISCOVER" || -z "${PLAYER}" ]]; then
    log "PLAYER not configured; run discover-a50x-sink.sh / playerctl -l"
    exit 1
  fi
fi

if [[ -n "${HID_MATCH_HEX}" && "${hid_warned_match_hex}" != "1" ]]; then
  log "HID_MATCH_HEX is set but deprecated (F3c uses battery GET + soft-off/on prefixes); ignoring"
  hid_warned_match_hex=1
fi

if on_match_gate; then
  was_on_match=1
else
  was_on_match=0
fi
if sinks_match; then
  was_sinks=1
else
  was_sinks=0
fi
last_poll_at="${SECONDS}"
note_playing_activity

log "start on_match=${was_on_match} sinks=${was_sinks} ENABLED=${ENABLED} DRY_RUN=${DRY_RUN} SINK_MATCH=${SINK_MATCH} PLAYER=${PLAYER} PLAYER_MODE=${PLAYER_MODE} POLL_SEC=${POLL_SEC} DISABLE_LATCH_SEC=${DISABLE_LATCH_SEC} HID_ENABLE=${HID_ENABLE} hid_mode=battery_get+soft_off_on soft_off_prefix=${HID_SOFT_OFF_PREFIX} soft_on_prefix=${HID_SOFT_ON_PREFIX} version=${WATCHER_VERSION}"

trap 'hid_close_fd; exit 0' INT TERM

while true; do
  run_subscribe_loop
  hid_close_fd
  log "pactl subscribe ended; reconnecting in 2s"
  sleep 2
done
