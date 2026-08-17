# Changelog

## Unreleased

## 0.6.1 — 2026-08-15
- CI: isolate `XDG_CONFIG_HOME` / `XDG_STATE_HOME` under temp `HOME` in `ci-check.sh` (same Actions pitfall as graceful-shutdown); bump `actions/checkout` to v5.

## 0.6.0 — 2026-08-15
- Variant A layout: `scripts/lib/{hid,mpris}.sh`, `scripts/test/` fixtures, `scripts/tools/` research probes; `install-to-local.sh --with-tools` opt-in; lib-aware verify + ci-check install contract.

## 0.5.0 — 2026-08-14

- Initial public extract from private Linux customization work (`WATCHER_VERSION=f4-mpris-multi-1`).
- HID dock / soft-off / soft-on pause-resume for Logitech Astro A50 X (`046d:0b0b`).
- `PLAYER_MODE=single` (default) and opt-in `PLAYER_MODE=all` (experimental until v1.0 / F4-multi human PASS).
- Install via `scripts/install-to-local.sh`; CI: `bash -n`, intent fixtures, `scripts/ci-check.sh`.
- Claim: extract installable; single-mode behavior unchanged from upstream host validation. Full F4 soak not re-run for this tag. `PLAYER_MODE=all` not release-certified yet.
