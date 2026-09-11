#!/usr/bin/env bash
# Make the first PipeWire/Pulse sink matching a regex the default and move streams onto it.
# Idempotent: no-op when already routed. No card-profile changes (avoids sink recreation stutter).
# Usage: switch-to-a50x-sink.sh --match REGEX [--volume PCT] [--quiet]
# Exit: 0 success/no-op; 1 no sink after retry; 2 bad args
set -euo pipefail

MATCH="${A50X_SINK_MATCH:-}"
VOLUME=""
QUIET=0
RETRY_SEC="${A50X_SWITCH_RETRY_SEC:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --match) MATCH="${2:?}"; shift 2 ;;
    --volume) VOLUME="${2:?}"; shift 2 ;;
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${MATCH}" ]]; then
  echo "switch-to-a50x-sink: --match REGEX required (or A50X_SINK_MATCH)" >&2
  exit 2
fi

log() { [[ "$QUIET" -eq 1 ]] || echo "$*"; }

find_match() {
  pactl list short sinks 2>/dev/null | awk -v re="$MATCH" 'BEGIN{IGNORECASE=1} $2 ~ re { print $1, $2 }'
}

sink=""
sink_idx=""
deadline=$((SECONDS + RETRY_SEC))
while true; do
  matches="$(find_match || true)"
  count="$(grep -c . <<<"${matches}" 2>/dev/null || true)"
  if [[ -n "${matches}" ]]; then
    if [[ "${count}" -gt 1 ]]; then
      log "WARN: ${count} sinks match /${MATCH}/; using first (narrow SINK_MATCH)"
    fi
    read -r sink_idx sink <<<"$(head -n1 <<<"${matches}")"
    break
  fi
  if (( SECONDS >= deadline )); then
    break
  fi
  sleep 0.25
done

if [[ -z "${sink}" || -z "${sink_idx}" ]]; then
  log "No sink matching /${MATCH}/ after ${RETRY_SEC}s." >&2
  exit 1
fi

def="$(pactl get-default-sink 2>/dev/null || true)"
need_default=0
[[ "$def" == "$sink" ]] || need_default=1

# sink-inputs column 2 is numeric sink index, not name.
need_move=0
while read -r id ssink_idx; do
  [[ -z "$id" ]] && continue
  if [[ "$ssink_idx" != "$sink_idx" ]]; then
    need_move=1
    break
  fi
done < <(pactl list short sink-inputs 2>/dev/null | awk '{print $1, $2}')

if [[ "$need_default" -eq 0 && "$need_move" -eq 0 && -z "$VOLUME" ]]; then
  log "Already on ${sink} — no-op"
  exit 0
fi

if [[ "$need_default" -eq 1 ]]; then
  pactl set-default-sink "$sink"
fi
if [[ -n "$VOLUME" ]]; then
  pactl set-sink-volume "$sink" "${VOLUME}%" >/dev/null 2>&1 || true
fi

moved=0
while read -r id ssink_idx; do
  [[ -z "$id" ]] && continue
  [[ "$ssink_idx" == "$sink_idx" ]] && continue
  if pactl move-sink-input "$id" "$sink" >/dev/null 2>&1; then
    moved=$((moved + 1))
  fi
done < <(pactl list short sink-inputs 2>/dev/null | awk '{print $1, $2}')

log "Default sink → ${sink} (moved ${moved} stream(s))"
exit 0
