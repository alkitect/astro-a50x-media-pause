# ADR-002: A50 X HID dock GET + passive soft power (pause triggers)

## Status

Accepted — 2026-08-14

## Context

Soft-disable and dock on Logitech Astro A50 X do **not** remove PipeWire A50 USB sinks. Media often stays `on_match=1`. Pausing on every `sink-input remove` false-positives on stream churn and is late (~12–19 s) for soft-disable. Product need: pause media within ≤2 s on dock and headset power-off; resume on undock and power-on when this watcher paused playback.

*Which* MPRIS players are paused is [ADR-003](ADR-003-a50x-multi-mpris-control.md). This ADR covers **HID trigger semantics only**.

Probes showed:

- Active Gen5 battery GET (`cmd=06` reply) exposes stable `dock_chg` (byte8) for cradle dock/undock (**F2b PASS**).
- Soft-disable does **not** stop GET answers (**F2c FAIL**) and does not flip a stable GET payload byte (**F2d FAIL**).
- Passive hidraw interrupts: `cmd=05` ≈ 10 s heartbeat; soft-off first frame prefix `020c04000a0006`; power-on first frame `020c0400130000` (**F2e PASS**). Unsolicited `cmd=06` also appears on power-on but collides with watcher battery GET replies.

## Decision

1. **Dock path:** Active battery GET each `POLL_SEC`; rising `dock_chg` → pause (`hid-dock-chg-rise`); falling → resume if `we_paused_it` (`hid-dock-chg-fall`).
2. **Soft-off path:** Drain pending HID reports before GET; match prefix `HID_SOFT_OFF_PREFIX` (default `020c04000a0006`) → pause (`hid-soft-off`); set `hid_soft_off_episode=1`.
3. **Soft-on path:** Match prefix `HID_SOFT_ON_PREFIX` (default `020c0400130000`) → `try_resume hid-soft-on` **only** if `hid_soft_off_episode=1` (and existing `AUTO_RESUME` / `we_paused_it`). Clear episode in `clear_we_paused`.
4. **Never** treat battery GET `cmd=06` replies as soft-on.
5. **PW off-match** remains a conservative secondary path; never pause on remove-while-still-on-A50 (`disable_soft` retired).
6. Gates: `ENABLED`, `DRY_RUN`, `HID_ENABLE`, on-A50 + Playing for pause; kill-switch via stop unit / `HID_ENABLE=0`.

## Consequences

### Positive

- Dock and soft-disable meet ≤2 s pause SLO when HID is enabled.
- Power-on resumes only after a soft-off pause episode (not after dock-only or manual pause).
- GET `06` collision avoided for resume.
- Single hidraw fd shared by drain + GET.

### Negative / tradeoffs

- Soft-on depends on seeing `020c0400130000` (rare captures saw only `06` first — may wait until next poll/cycle).
- `POLL_SEC=1` bounds worst-case latency ~1 s.
- Concurrent probe + watcher on same hidraw invalidates research captures (must stop unit / one reader).

## Alternatives considered

- **PW-only soft pause** — too late / false positives; retired.
- **GET `online_fall` or byte-diff for soft-disable** — F2c/F2d FAIL.
- **Resume on any `cmd=06`** — false resume every battery poll.
- **Revive `HID_MATCH_HEX` substring** — too loose; replaced by explicit F2e prefixes.

## Related

- [a50x-spotify-pause.md](a50x-spotify-pause.md) (C1–C3)
- [ADR-003](ADR-003-a50x-multi-mpris-control.md) (multi-MPRIS control plane; HID unchanged)
- [README.md](../../README.md)
- [IMPLEMENTATION.md](../IMPLEMENTATION.md)
