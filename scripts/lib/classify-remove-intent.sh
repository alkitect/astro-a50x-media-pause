#!/usr/bin/env bash
# Pure remove-intent classifier for A50X watcher (F0).
# Usage: classify_remove_intent <was_on_match> <on_match> <pending_new> <status>
# Prints: none|disable|churn|ambiguous_on_match
# Exit 0 always when args valid; exit 2 on usage error.
set -euo pipefail

classify_remove_intent() {
  local was_on_match="$1"
  local on_match="$2"
  local pending_new="$3"
  local status="$4"

  if [[ "${was_on_match}" != "1" ]]; then
    printf '%s\n' "none"
    return 0
  fi
  if [[ "${on_match}" == "0" ]]; then
    printf '%s\n' "disable"
    return 0
  fi
  if [[ "${pending_new}" == "1" ]]; then
    printf '%s\n' "churn"
    return 0
  fi
  case "${status}" in
    Playing)
      # Retired disable_soft: still on A50 after remove is ambiguous (churn vs soft-disable).
      printf '%s\n' "ambiguous_on_match"
      ;;
    *)
      printf '%s\n' "churn"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${#}" -ne 4 ]]; then
    echo "Usage: $0 <was_on_match:0|1> <on_match:0|1> <pending_new:0|1> <status>" >&2
    exit 2
  fi
  classify_remove_intent "$@"
fi
