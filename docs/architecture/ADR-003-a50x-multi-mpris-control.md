# ADR-003: A50X multi-MPRIS pause/resume control plane

## Status

Accepted — 2026-08-14

## Context

ADR-002 defines **HID triggers** (dock `dock_chg`, soft-off/on prefixes) for the Astro A50X watcher. The control plane paused a single MPRIS player (`PLAYER`, typically Spotify snap). Product need: on the same HID edges, pause/resume **all Playing MPRIS players** (browser video/music, VLC, etc.) without changing HID semantics or broadening the ambiguous PipeWire remove path.

## Decision

1. **`PLAYER_MODE=single|all`** (default `single`) — existing installs unchanged; `all` is opt-in.
2. **`PLAYER`** required only in `single`; optional in `all`.
3. **A50 gate:** `single` → name-filtered `player_on_match_sink`; `all` → `any_on_match_sink` (any sink-input on `SINK_MATCH`).
4. **Pause scope in `all`:** when the A50 gate fires and eligible players are Playing, pause **all Playing MPRIS names from `playerctl -l`** (global MPRIS set), not only streams routed to A50.
5. **Resume set:** `we_paused_players` (newline-separated); `we_paused_it` derived non-empty; resume only that set; soft-on still requires `hid_soft_off_episode` (ADR-002).
6. **Cork heuristics** only in `single`. **Do not** broaden PW `sink-input remove` soft-pause; browser soft-off relies on HID (`HID_ENABLE=1`).
7. **HID plane unchanged** — ADR-002 remains SSOT for prefixes, GET `06`, episode latch.

## Consequences

### Positive

- One deployable covers Spotify-default and multi-media opt-in.
- True pause via MPRIS (video freezes) rather than mute-only.
- ADR-002 validation ladder remains valid for `PLAYER_MODE=single`.

### Negative / tradeoffs

- `all` may pause MPRIS players whose audio is not on A50 if any other stream is on A50 when HID fires.
- Non-MPRIS apps (many games) are out of scope.
- Browser soft-off without HID stays uncovered (same as Spotify soft-off without HID).

## Related

- [ADR-002](ADR-002-a50x-hid-dock-and-soft-power.md) (HID triggers)
- [a50x-spotify-pause.md](a50x-spotify-pause.md) (C1–C3)
- [README.md](../../README.md)
- [IMPLEMENTATION.md](../IMPLEMENTATION.md)
