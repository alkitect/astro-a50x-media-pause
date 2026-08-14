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
# Prefer sibling lib when running from repo; optional installed lib dir; else inlined fallback.
if [[ -f "${SCRIPT_DIR}/lib/classify-remove-intent.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/classify-remove-intent.sh"
elif [[ -f "${SCRIPT_DIR}/a50x-spotify-pause-lib/classify-remove-intent.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/a50x-spotify-pause-lib/classify-remove-intent.sh"
elif [[ -f "${HOME}/.local/bin/a50x-spotify-pause-lib/classify-remove-intent.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.local/bin/a50x-spotify-pause-lib/classify-remove-intent.sh"
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

list_eligible_players() {
  if [[ "${PLAYER_MODE}" == "all" ]]; then
    playerctl -l 2>/dev/null || true
  else
    if [[ -n "${PLAYER}" && "${PLAYER}" != "REPLACE_ME_FROM_DISCOVER" ]]; then
      printf '%s\n' "${PLAYER}"
    fi
  fi
}

player_status_of() {
  playerctl -p "$1" status 2>/dev/null || echo "Gone"
}

player_status() {
  if [[ "${PLAYER_MODE}" == "all" ]]; then
    aggregate_player_status
  else
    player_status_of "${PLAYER}"
  fi
}

# Prefer Playing if any eligible is Playing; else Paused/Stopped/Gone.
aggregate_player_status() {
  local p st any_paused=0 any_stopped=0 count=0
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    count=$((count + 1))
    st="$(player_status_of "${p}")"
    case "${st}" in
      Playing)
        printf '%s\n' "Playing"
        return 0
        ;;
      Paused) any_paused=1 ;;
      Stopped) any_stopped=1 ;;
    esac
  done < <(list_eligible_players)
  if ((count == 0)); then
    printf '%s\n' "Gone"
    return 0
  fi
  if ((any_paused)); then
    printf '%s\n' "Paused"
    return 0
  fi
  if ((any_stopped)); then
    printf '%s\n' "Stopped"
    return 0
  fi
  printf '%s\n' "Gone"
}

any_playing() {
  local p
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    if [[ "$(player_status_of "${p}")" == "Playing" ]]; then
      return 0
    fi
  done < <(list_eligible_players)
  return 1
}

we_paused_csv() {
  if [[ -z "${we_paused_players}" ]]; then
    printf '%s' ""
    return 0
  fi
  printf '%s' "${we_paused_players}" | paste -sd, -
}

we_paused_sync() {
  if [[ -n "${we_paused_players}" ]]; then
    we_paused_it=1
  else
    we_paused_it=0
  fi
}

we_paused_has() {
  local p="$1"
  [[ -n "${we_paused_players}" ]] || return 1
  printf '%s\n' "${we_paused_players}" | grep -qxF "${p}"
}

we_paused_add() {
  local p="$1"
  [[ -n "${p}" ]] || return 0
  if we_paused_has "${p}"; then
    return 0
  fi
  if [[ -z "${we_paused_players}" ]]; then
    we_paused_players="${p}"
  else
    we_paused_players+=$'\n'"${p}"
  fi
  we_paused_sync
}

any_we_paused_playing() {
  local p
  [[ -n "${we_paused_players}" ]] || return 1
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    if [[ "$(player_status_of "${p}")" == "Playing" ]]; then
      return 0
    fi
  done <<<"${we_paused_players}"
  return 1
}

eligible_for_pause_gate() {
  if any_playing; then
    return 0
  fi
  if [[ "${PLAYER_MODE}" == "single" ]] && spotify_uncorked; then
    return 0
  fi
  return 1
}

spotify_cork_state() {
  pactl list sink-inputs 2>/dev/null | awk -v p="${PLAYER}" '
    BEGIN { IGNORECASE=1 }
    /^Sink Input #/ {
      if (keep && cork != "") { print cork; exit }
      keep=0; cork=""
    }
    /^[[:space:]]*Corked:[[:space:]]+/ { cork=$2 }
    /application\.(name|process\.binary) = "/ {
      if (index($0, "\"" p "\"") || index(tolower($0), "\"" tolower(p) "\"")) keep=1
    }
    END { if (keep && cork != "") print cork; else if (!keep) print "none" }
  '
}

spotify_uncorked() {
  [[ "${PLAYER_MODE}" == "single" ]] || return 1
  [[ "$(spotify_cork_state)" == "no" ]]
}

note_playing_activity() {
  if any_playing || { [[ "${PLAYER_MODE}" == "single" ]] && spotify_uncorked; }; then
    last_playing_at="${SECONDS}"
    latched_playing=1
  fi
}

recent_playing() {
  (( last_playing_at > 0 && SECONDS - last_playing_at < 45 ))
}

classify_event() {
  local line="$1"
  if [[ "${line}" =~ on\ sink-input\ #[0-9]+ ]]; then
    last_event_kind=sink-input
    return 0
  fi
  if [[ "${line}" =~ on\ sink\ #[0-9]+ ]]; then
    last_event_kind=sink
    return 0
  fi
  if [[ "${line}" =~ on\ card\ #[0-9]+ ]]; then
    last_event_kind=card
    return 0
  fi
  return 1
}

ms_to_sec() {
  awk -v ms="${1}" 'BEGIN { printf "%.3f", ms/1000 }'
}

disable_latch_armed() {
  (( SECONDS < disable_latch_until ))
}

arm_disable_latch() {
  local st="$1"
  disable_latch_until=$((SECONDS + DISABLE_LATCH_SEC))
  if [[ "${st}" == "Playing" ]]; then
    latched_playing=1
  fi
  log "armed disable_latch until=t+${DISABLE_LATCH_SEC}s latched_playing=${latched_playing} status=${st} intent=disable"
}

clear_disable_latch() {
  disable_latch_until=0
}

clear_we_paused() {
  we_paused_players=""
  we_paused_it=0
  post_pause_skip=0
  hid_paused_at=0
  pw_paused_at=0
  hid_soft_off_episode=0
}

# User pressed Play (or media resumed for user) — never fight them.
user_play_override() {
  local why="${1:-user_play}"
  if [[ "${our_resume_in_progress}" == "1" ]]; then
    return 0
  fi
  if ! disable_latch_armed && [[ "${we_paused_it}" != "1" ]]; then
    return 0
  fi
  log "override=${why} clear latch+we_paused players=$(we_paused_csv)"
  clear_disable_latch
  clear_we_paused
  latched_playing=1
}

maybe_clear_while_off_match() {
  [[ "${CLEAR_ON_USER_PAUSE}" == "1" ]] || return 0
  [[ "${we_paused_it}" == "1" ]] || return 0
  if [[ "${post_pause_skip}" == "1" ]]; then
    post_pause_skip=0
    return 0
  fi
  if any_we_paused_playing; then
    user_play_override "user_play_off_match"
    return 0
  fi
  local st
  st="$(aggregate_player_status)"
  case "${st}" in
    Stopped)
      log "clear we_paused_it (status=${st} while off match sink)"
      clear_we_paused
      clear_disable_latch
      ;;
    Gone)
      if ! disable_latch_armed; then
        log "clear we_paused_it (status=Gone while off match; latch expired)"
        clear_we_paused
      fi
      ;;
  esac
}

should_pause_now() {
  local force="${1:-0}"
  if any_playing; then
    return 0
  fi
  if [[ "${PLAYER_MODE}" == "single" ]] && spotify_uncorked; then
    return 0
  fi
  if [[ "${force}" == "1" ]]; then
    return 0
  fi
  local st
  st="$(aggregate_player_status)"
  if [[ "${st}" == "Paused" || "${st}" == "Stopped" ]]; then
    log "skip pause action=skipped status=${st} (already stopped)"
    return 1
  fi
  log "skip pause action=skipped status=${st}"
  return 1
}

do_pause() {
  local reason="${1:-unknown}"
  local force="${2:-0}"
  local signal="${3:-pw}"
  local p st targets="" paused_any=0

  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    if we_paused_has "${p}"; then
      continue
    fi
    st="$(player_status_of "${p}")"
    if [[ "${st}" == "Playing" ]]; then
      targets+="${p}"$'\n'
    elif [[ "${PLAYER_MODE}" == "single" && "${p}" == "${PLAYER}" ]] && spotify_uncorked; then
      targets+="${p}"$'\n'
    elif [[ "${force}" == "1" && "${st}" == "Gone" && "${PLAYER_MODE}" == "single" ]]; then
      targets+="${p}"$'\n'
    fi
  done < <(list_eligible_players)

  if [[ -z "${targets}" ]]; then
    if [[ -n "${we_paused_players}" ]]; then
      log "coalesce skip duplicate pause reason=${reason} signal=${signal} players=$(we_paused_csv)"
      return 0
    fi
    log "skip pause action=skipped no Playing eligible reason=${reason} signal=${signal}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    while IFS= read -r p; do
      [[ -z "${p}" ]] && continue
      we_paused_add "${p}"
    done <<<"${targets}"
    log "DRY_RUN would-pause players=$(we_paused_csv) reason=${reason} signal=${signal} action=paused"
    post_pause_skip=1
    paused_at="${SECONDS}"
    [[ "${signal}" == "hid" ]] && hid_paused_at="${SECONDS}" || pw_paused_at="${SECONDS}"
    return 0
  fi

  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    local attempt=1
    while ((attempt <= 3)); do
      if playerctl -p "${p}" pause 2>/dev/null; then
        st="$(player_status_of "${p}")"
        if [[ "${st}" == "Paused" || "${st}" == "Stopped" ]]; then
          we_paused_add "${p}"
          paused_any=1
          break
        fi
      else
        st="$(player_status_of "${p}")"
        if [[ "${st}" == "Gone" && "${force}" != "1" ]]; then
          break
        fi
      fi
      attempt=$((attempt + 1))
      sleep 0.05
    done
    st="$(player_status_of "${p}")"
    if [[ "${st}" == "Paused" || "${st}" == "Stopped" ]]; then
      we_paused_add "${p}"
      paused_any=1
    elif [[ "${force}" == "1" ]]; then
      we_paused_add "${p}"
      paused_any=1
    fi
  done <<<"${targets}"

  if [[ "${paused_any}" == "1" || -n "${we_paused_players}" ]]; then
    log "paused players=$(we_paused_csv) reason=${reason} signal=${signal} action=paused"
    post_pause_skip=1
    paused_at="${SECONDS}"
    [[ "${signal}" == "hid" ]] && hid_paused_at="${SECONDS}" || pw_paused_at="${SECONDS}"
  else
    log "pause incomplete players= reason=${reason} signal=${signal}"
  fi
}

do_play() {
  local reason="${1:-unknown}"
  local p st csv
  our_resume_in_progress=1
  sleep "$(ms_to_sec "${RESUME_DELAY_MS}")"
  csv="$(we_paused_csv)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN would-play players=${csv} reason=${reason}"
    clear_we_paused
    clear_disable_latch
    our_resume_in_progress=0
    return 0
  fi
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    st="$(player_status_of "${p}")"
    if [[ "${st}" == "Paused" || "${st}" == "Stopped" ]]; then
      if playerctl -p "${p}" play 2>/dev/null; then
        :
      else
        log "play failed player=${p}"
      fi
    fi
  done <<<"${we_paused_players}"
  log "resumed players=${csv} reason=${reason}"
  clear_we_paused
  clear_disable_latch
  our_resume_in_progress=0
}

try_resume() {
  local reason="$1"
  local p st can=0
  [[ "${ENABLED}" == "1" ]] || return 0
  [[ "${AUTO_RESUME}" == "1" ]] || return 0
  [[ "${we_paused_it}" == "1" ]] || return 0
  if any_we_paused_playing; then
    user_play_override "already_playing"
    return 0
  fi
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    st="$(player_status_of "${p}")"
    if [[ "${st}" == "Paused" || "${st}" == "Stopped" ]]; then
      can=1
      break
    fi
  done <<<"${we_paused_players}"
  if [[ "${can}" != "1" ]]; then
    log_edge "skip resume (no Paused/Stopped in we_paused_players)"
    return 0
  fi
  do_play "${reason}"
}

try_pause_off_match() {
  local reason="$1"
  local force_gone="${2:-0}"
  local signal="${3:-pw}"
  [[ "${ENABLED}" == "1" ]] || {
    log "probe skip action=skipped ENABLED=0 reason=${reason}"
    return 0
  }
  if should_pause_now "${force_gone}"; then
    do_pause "${reason}" "${force_gone}" "${signal}"
  fi
}

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
