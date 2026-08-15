#!/usr/bin/env bash
# Release gate for astro-a50x-media-pause (local + CI).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Patterns encoded so this file is not a false positive.
_p1='Python/'
_p2='Linux'
_p3='.cursor/plans'
_p4='topics/astro-a50x-spotify-pause'
FORBIDDEN_RE="${_p1}${_p2}|${_p3}|${_p4}"

hits="$(grep -rE "${FORBIDDEN_RE}" \
  --include='*.sh' --include='*.md' --include='*.rules' --include='*.py' . \
  --exclude-dir=.git --exclude-dir=__pycache__ \
  --exclude='ci-check.sh' 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  echo "ci-check: forbidden path refs found:" >&2
  echo "${hits}" >&2
  exit 1
fi

if grep -qF "${_p1}${_p2}" scripts/verify-a50x-spotify-pause.sh; then
  echo "ci-check: verify still references ${_p1}${_p2}" >&2
  exit 1
fi

grep -q 'WATCHER_VERSION=f4-mpris-multi-1' scripts/a50x-spotify-pause.sh
grep -qE '^ENABLED=0' config/example.config
grep -qE '^DRY_RUN=1' config/example.config
grep -qE '^PLAYER_MODE=single' config/example.config

find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
./scripts/test/run-intent-fixtures.sh

tmp="$(mktemp -d)"
cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT
HOME="${tmp}" "${ROOT}/scripts/install-to-local.sh"
test -x "${tmp}/.local/bin/a50x-spotify-pause"
grep -q 'WATCHER_VERSION=f4-mpris-multi-1' "${tmp}/.local/bin/a50x-spotify-pause"
for lib in classify-remove-intent.sh hid.sh mpris.sh; do
  test -f "${tmp}/.local/bin/a50x-spotify-pause-lib/${lib}"
done
for tool in a50x-hid-probe a50x-hid-battery-probe score-a50x-hid-batt-bytes score-a50x-hid-passive-power; do
  test ! -e "${tmp}/.local/bin/${tool}"
done

HOME="${tmp}" "${ROOT}/scripts/install-to-local.sh" --with-tools
test -x "${tmp}/.local/bin/a50x-hid-probe"

# Versioning gate (alkitect public extracts)
if [[ -f docs/PUBLISH.md ]] && grep -qF 'RC-BEFORE-1.0' docs/PUBLISH.md; then
  :
else
  if [[ -f CHANGELOG.md ]] && grep -qE '^## 0\.9\.0' CHANGELOG.md; then
    echo "ci-check: CHANGELOG ## 0.9.0 is not the default first tag; add RC-BEFORE-1.0 to docs/PUBLISH.md or use 0.1.0+" >&2
    exit 1
  fi
  for _vf in docs/PUBLISH.md README.md; do
    if [[ -f "${_vf}" ]] && grep -qE 'v0\.9\.0' "${_vf}"; then
      echo "ci-check: ${_vf} mentions v0.9.0 without RC-BEFORE-1.0" >&2
      exit 1
    fi
  done
fi
if grep -rE '/home/alex' --include='*.md' . --exclude-dir=.git >/dev/null 2>&1; then
  echo "ci-check: public markdown must not contain /home/alex host paths" >&2
  grep -rE '/home/alex' --include='*.md' . --exclude-dir=.git >&2 || true
  exit 1
fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git describe --tags --abbrev=0 >/dev/null 2>&1; then
  _tag="$(git describe --tags --abbrev=0)"
  _tag="${_tag#v}"
  _first="$(awk '/^## [0-9]+\.[0-9]+\.[0-9]+/{ sub(/^## /,""); sub(/ .*/,""); print; exit }' CHANGELOG.md)"
  if [[ -n "${_first}" && "${_first}" != "${_tag}" ]]; then
    echo "ci-check: CHANGELOG first dated section ${_first} != git describe ${_tag}" >&2
    exit 1
  fi
fi

echo "ci-check: OK"
