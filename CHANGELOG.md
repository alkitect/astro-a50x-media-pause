# Changelog

## Unreleased

## 0.7.3 — 2026-09-14

- Install: restore user units from `automation.wanted` or prior enablement; uninstall keeps the marker unless `--purge-config`.
- Helper: vendored `scripts/lib/automation-wanted.sh`.

## 0.7.2 — 2026-09-14

- Docs: portal README (Quick start H3s, tip-vs-tag Releases surface, Issues help line, flag table).

## 0.7.1 — 2026-09-11

- Fix dual A50 pro-audio sinks: keep `SINK_MATCH` broad for pause gates; add optional `ROUTE_SINK_MATCH` for preferred Game/Pro 1 routing (`WATCHER_VERSION=f5-route-2`).
- Log HID soft-off skips when not on A50; defer `user_play_override` for a short post-pause grace (Spotify/PipeWire Playing flap).

## 0.7.0 — 2026-09-11

- Optional PipeWire default-sink routing (`ROUTE_ENABLE`, `WATCHER_VERSION=f5-route-1`, ADR-004): undock / soft-on edges + guarded startup; `switch-to-a50x-sink` helper; `DRY_RUN` logs `would-route` only; route-helper fixtures + ci-check / verify ladder.

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
