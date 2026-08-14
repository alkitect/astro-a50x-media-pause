#!/usr/bin/env bash
# Deterministic intent fixtures for F0 (no live PipeWire / playerctl required).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${HERE}/lib/classify-remove-intent.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HERE}/lib/classify-remove-intent.sh"
elif [[ -f "${HERE}/a50x-spotify-pause-lib/classify-remove-intent.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HERE}/a50x-spotify-pause-lib/classify-remove-intent.sh"
elif [[ -f "${HOME}/.local/bin/a50x-spotify-pause-lib/classify-remove-intent.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.local/bin/a50x-spotify-pause-lib/classify-remove-intent.sh"
elif [[ -f "${HERE}/../scripts/lib/classify-remove-intent.sh" ]]; then
  # shellcheck disable=SC1091
  source "${HERE}/../scripts/lib/classify-remove-intent.sh"
else
  echo "Cannot find classify-remove-intent.sh" >&2
  exit 1
fi

rc=0
pass=0
fail=0

check() {
  local name="$1"
  local was="$2" on="$3" new="$4" st="$5"
  local want="$6"
  local got
  got="$(classify_remove_intent "${was}" "${on}" "${new}" "${st}")"
  if [[ "${got}" == "${want}" ]]; then
    echo "PASS ${name} -> ${got}"
    pass=$((pass + 1))
  else
    echo "FAIL ${name}: want=${want} got=${got}" >&2
    fail=$((fail + 1))
    rc=1
  fi
}

echo "=== a50x remove-intent fixtures ==="

check "remove_new_during_settle" 1 1 1 Playing churn
check "remove_new_gone" 1 1 1 Gone churn
check "no_new_on_match_playing" 1 1 0 Playing ambiguous_on_match
check "no_new_on_match_paused" 1 1 0 Paused churn
check "offmatch_playing" 1 0 0 Playing disable
check "offmatch_gone" 1 0 0 Gone disable
check "never_on_match" 0 1 0 Playing none
check "never_on_match_off" 0 0 0 Playing none
check "offmatch_with_new_flag" 1 0 1 Playing disable

echo "=== summary pass=${pass} fail=${fail} ==="
exit "${rc}"
