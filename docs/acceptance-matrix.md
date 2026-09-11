# Acceptance matrix (template)

Human checklist for Logitech Astro A50 X media pause. **Do not** commit host `/tmp` capture paths, usernames, or raw journal timestamps from a private machine.

Upstream host validated dock / soft-off / soft-on for `PLAYER_MODE=single` before the public extract. Re-run locally after install if you change firmware or distro.

## F4 — dock / soft power (`PLAYER_MODE=single`) — example row format

| Case | Expect | Result |
|------|--------|--------|
| Spotify Playing on A50 → dock | ≤2 s pause; undock resume if watcher paused | (your result) |
| Soft-off / soft-on | `hid-soft-off` / episode-gated `hid-soft-on` | (your result) |
| Listen ≥5 min | 0 false pauses | (your result) |

```bash
journalctl --user -t a50x-spotify-pause --since "10 min ago" \
  | grep -E 'action=paused|resumed|HID dock|HID soft'
```

## F4-multi — multi-MPRIS (`PLAYER_MODE=all`) — human (release gate for v1.0)

Watcher: `WATCHER_VERSION=f5-route-1`. Browser soft-off requires **`HID_ENABLE=1`**.

**Enable ladder:** working `single` → set `PLAYER_MODE=all` with `DRY_RUN=1` soak ≥5 min → `DRY_RUN=0` → matrix below.

| Case | Expect | Result |
|------|--------|--------|
| Install shows `f5-route-1` + `PLAYER_MODE=` in start log | pending |
| Spotify Playing on A50 → dock | ≤2 s pause; undock resume | pending |
| Browser HTML5 on A50, `HID_ENABLE=1` | soft-off pause; soft-on resume | pending |
| Spotify + browser both Playing | both in `players=`; both resume only if watcher paused | pending |
| Manual pause then dock/power | no auto-resume | pending |
| User Play after auto-pause | no re-pause | pending |
| `PLAYER_MODE=single` soak unchanged | pending |
| Listen ≥5 min on `all` | 0 false pauses | pending |

```bash
journalctl --user -t a50x-spotify-pause --since "10 min ago" \
  | grep -E 'action=paused|resumed|players=|PLAYER_MODE=|version=f5-route|route reason='
```

## F5 — seamless output (`ROUTE_ENABLE=1`) — human

**Enable ladder:** `discover-a50x-sink` → unique `SINK_MATCH` → `ROUTE_ENABLE=1` `HID_ENABLE=1` `DRY_RUN=0` → verify PASS → matrix.

| Case | Expect | Result |
|------|--------|--------|
| Undock or soft-on with default on speakers/HDMI | ≤2 s `pactl get-default-sink` matches A50; journal `route reason=… rc=0` | pending |
| `ENABLED=0` route-only undock | still routes | pending |
| `DRY_RUN=1` soak | `would-route` only; default unchanged | pending |
| Twins Elite A2DP connect then A50 undock | Twins claims; A50 reclaim on undock | pending |
| Restart watcher while Twins is default | startup does **not** steal | pending |
| `ROUTE_ENABLE=0` + restart | no further claims; manual `pactl set-default-sink` restore | pending |
| Pause SLO regression with HID | ≤2 s pause/resume | pending |

**v1.0.0** requires this section’s F4-multi rows marked PASS in **this** public file (release SSOT).
