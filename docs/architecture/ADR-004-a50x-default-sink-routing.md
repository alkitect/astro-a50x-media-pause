# ADR-004: A50 X optional default-sink routing (undock / soft-on)

## Status

Accepted — 2026-09-11

## Context

GNOME/PipeWire often leave the session default sink on speakers, HDMI, or Bluetooth earbuds after the Logitech Astro A50 X is in use. Soft-disable and dock do **not** remove the A50 USB sink ([ADR-002](ADR-002-a50x-hid-dock-and-soft-power.md)), so a “sink appeared” autoswitch (Twins Elite pattern) does not fire on undock or power-on.

Operators want seamless output when putting the headset on, without a second hidraw reader (only one process may hold `046d:0b0b`). Pause/resume already owns that HID loop.

## Decision

1. **Same product / process:** Optional routing lives in `a50x-spotify-pause` via `ROUTE_ENABLE`. Helper `switch-to-a50x-sink` does pure `pactl` default + move-by-index (no card-profile thrash).
2. **Hook ownership:** Define `route_a50x_if_enabled` in the watcher **before** sourcing `hid.sh`. HID lib calls the hook only; no `pactl` inside `hid.sh`.
3. **Triggers:** HID undock (`dock_chg` fall) and soft-on **edge** (outside soft-off episode gate). Resume remains episode-gated ([ADR-002](ADR-002-a50x-hid-dock-and-soft-power.md)). Guarded startup one-shot unless default already matches `bluez_output.*a2dp`.
4. **Gate matrix:**
   - `ROUTE_ENABLE` independent of `ENABLED`.
   - HID edges require `HID_ENABLE=1`. When `ROUTE_ENABLE=1` and `HID_ENABLE=1`, run HID poll even if `ENABLED=0` (route-only).
   - `DRY_RUN=1` → log `would-route` only; no helper/`pactl` exec (same soak discipline as pause).
   - Live moves require `DRY_RUN=0`.
5. **Twins / other BT:** Last intentional event wins. No continuous prefer-A50 poll. Startup must not steal an active A2DP default.
6. **Multi-match:** If `SINK_MATCH` hits more than one sink, pick first and WARN; operators narrow via `discover-a50x-sink`.
7. **Rollback:** `ROUTE_ENABLE=0` + restart stops future claims; does **not** restore the prior default. Operator restores with `pactl set-default-sink …`.
8. **No shared lib** with private Twins Elite helpers (ponytail ceiling: duplicate small `pactl` switch scripts).

## Consequences

### Positive

- Seamless A50 output on undock/soft-on without a second systemd HID unit.
- Route-only mode works with pause disabled.
- DRY_RUN soak stays safe for both pause and route.
- Coexists with Twins Elite autoswitch via last-event + startup guard.

### Negative / tradeoffs

- Rapid Twins↔A50 events may flap the default once (no shared debounce bus).
- Multi-match WARN can pick the wrong sink if `SINK_MATCH` is too broad.
- Rollback is stop-claims only; restore is manual.

## Alternatives considered

- **Separate private topic / second hidraw watcher** — fights the single-reader constraint; rejected.
- **Continuous prefer-A50 poll** — thrash vs Twins; rejected.
- **Shared Twins+A50 routing library** — YAGNI; rejected for now.
- **Ignore DRY_RUN for routing** — surprises operators during soak; rejected.

## Related

- [a50x-spotify-pause.md](a50x-spotify-pause.md) (C1–C3)
- [ADR-002](ADR-002-a50x-hid-dock-and-soft-power.md) (HID edges; poll also serves routing)
- [ADR-003](ADR-003-a50x-multi-mpris-control.md) (MPRIS plane unchanged)
- [IMPLEMENTATION.md](../IMPLEMENTATION.md)
- [README.md](../../README.md) — Seamless output
