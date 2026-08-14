#!/usr/bin/env bash
# Print sinks / default / playerctl hints for SINK_MATCH and PLAYER.
# Usage: discover-a50x-sink.sh [regex]
set -euo pipefail

CANDIDATE="${1:-A50|Astro|astro|Logitech}"

echo "=== pactl list short sinks ==="
pactl list short sinks 2>/dev/null || echo "(pactl failed)"
echo ""
echo "=== default sink ==="
pactl get-default-sink 2>/dev/null || true
echo ""
echo "=== lines matching /${CANDIDATE}/i ==="
matches="$(pactl list short sinks 2>/dev/null | grep -iE "${CANDIDATE}" || true)"
if [[ -z "${matches}" ]]; then
  echo "(none — put headset on, then re-run; or pass a custom regex)"
  echo "WARN: 0 matches"
else
  echo "${matches}"
  count="$(grep -c . <<<"${matches}" || true)"
  if [[ "${count}" -gt 1 ]]; then
    echo "WARN: ${count} matches — narrow SINK_MATCH to avoid HDMI/BT false positives"
  fi
  # Suggest last path component-ish token from first match column 2
  first_name="$(awk '{print $2; exit}' <<<"${matches}")"
  echo ""
  echo "Suggested SINK_MATCH (edit if needed):"
  echo "  SINK_MATCH=${first_name}"
  echo "Or a short unique substring regex, e.g. SINK_MATCH=A50_X|Astro"
fi
echo ""
echo "=== playerctl -l ==="
if command -v playerctl >/dev/null 2>&1; then
  players="$(playerctl -l 2>/dev/null || true)"
  if [[ -z "${players}" ]]; then
    echo "(none — start Spotify or browser media, then re-run)"
  else
    echo "${players}"
    echo ""
    echo "Suggested PLAYER (PLAYER_MODE=single — pick Spotify line):"
    if grep -qi '^spotify' <<<"${players}"; then
      echo "  PLAYER=$(grep -i '^spotify' <<<"${players}" | head -n1)"
    else
      echo "  PLAYER=<name from list above>"
    fi
    echo ""
    echo "Or pause all Playing MPRIS players:"
    echo "  PLAYER_MODE=all"
    echo "  # PLAYER optional when PLAYER_MODE=all"
  fi
else
  echo "playerctl not installed — sudo apt install playerctl"
fi
echo ""
echo "Optional: in another terminal, run: pactl subscribe"
echo "Then dock/disable the headset once and note 'on sink #' remove/change events."
echo ""
echo "Config: \${XDG_CONFIG_HOME:-\$HOME/.config}/astro-a50x-spotify-pause/config"
