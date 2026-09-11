#!/usr/bin/env bash
# PATH-stubbed pactl fixtures for switch-to-a50x-sink.sh (no live PipeWire).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="${ROOT}/scripts/switch-to-a50x-sink.sh"
STUB_DIR="$(mktemp -d)"
cleanup() { rm -rf "${STUB_DIR}"; }
trap cleanup EXIT

fail=0
assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${label}: got=${got} want=${want}" >&2
    fail=1
  else
    echo "OK: ${label}"
  fi
}

# Stub: matched sink already default; no sink-inputs → no-op exit 0
cat >"${STUB_DIR}/pactl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list short sinks")
    echo -e "1\talsa_output.pci-0000_00_1f.3.analog-stereo\n42\talsa_output.usb-Logitech_A50_X.analog-stereo"
    ;;
  "get-default-sink")
    echo "alsa_output.usb-Logitech_A50_X.analog-stereo"
    ;;
  "list short sink-inputs")
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "${STUB_DIR}/pactl"
rc=0
PATH="${STUB_DIR}:${PATH}" bash "${HELPER}" --match 'A50_X|Astro' --quiet || rc=$?
assert_eq "${rc}" "0" "no-op when already default"

# Stub: no matching sink → exit 1 (retry quickly)
cat >"${STUB_DIR}/pactl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list short sinks")
    echo -e "1\talsa_output.pci-0000_00_1f.3.analog-stereo"
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${STUB_DIR}/pactl"
rc=0
A50X_SWITCH_RETRY_SEC=0 PATH="${STUB_DIR}:${PATH}" bash "${HELPER}" --match 'A50_X' --quiet || rc=$?
assert_eq "${rc}" "1" "missing sink exit 1"

# Bad args → exit 2
rc=0
bash "${HELPER}" --quiet || rc=$?
assert_eq "${rc}" "2" "missing --match exit 2"

# Stub: wrong default + one sink-input → set-default + move
cat >"${STUB_DIR}/pactl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list short sinks")
    echo -e "1\tspeakers\n7\talsa_output.usb-Logitech_A50_X.analog-stereo"
    ;;
  "get-default-sink")
    echo "speakers"
    ;;
  "list short sink-inputs")
    echo -e "99\t1\tprotocol-native.c\tapplication.name = \"spotify\""
    ;;
  "set-default-sink alsa_output.usb-Logitech_A50_X.analog-stereo")
    exit 0
    ;;
  "move-sink-input 99 alsa_output.usb-Logitech_A50_X.analog-stereo")
    exit 0
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "${STUB_DIR}/pactl"
rc=0
PATH="${STUB_DIR}:${PATH}" bash "${HELPER}" --match 'A50_X' --quiet || rc=$?
assert_eq "${rc}" "0" "switch + move exit 0"

if [[ "${fail}" -ne 0 ]]; then
  echo "run-route-helper-fixtures: FAILED" >&2
  exit 1
fi
echo "run-route-helper-fixtures: OK"
