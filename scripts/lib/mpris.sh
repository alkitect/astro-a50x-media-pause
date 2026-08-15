#!/usr/bin/env bash
# MPRIS control + shared pause orchestration (sourced by a50x-spotify-pause).
# Functions only — no top-level executable code.
# shellcheck shell=bash

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
