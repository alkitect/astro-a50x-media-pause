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

Watcher: `WATCHER_VERSION=f4-mpris-multi-1`. Browser soft-off requires **`HID_ENABLE=1`**.

**Enable ladder:** working `single` → set `PLAYER_MODE=all` with `DRY_RUN=1` soak ≥5 min → `DRY_RUN=0` → matrix below.

| Case | Expect | Result |
|------|--------|--------|
| Install shows `f4-mpris-multi-1` + `PLAYER_MODE=` in start log | pending |
| Spotify Playing on A50 → dock | ≤2 s pause; undock resume | pending |
| Browser HTML5 on A50, `HID_ENABLE=1` | soft-off pause; soft-on resume | pending |
| Spotify + browser both Playing | both in `players=`; both resume only if watcher paused | pending |
| Manual pause then dock/power | no auto-resume | pending |
| User Play after auto-pause | no re-pause | pending |
| `PLAYER_MODE=single` soak unchanged | pending |
| Listen ≥5 min on `all` | 0 false pauses | pending |

```bash
journalctl --user -t a50x-spotify-pause --since "10 min ago" \
  | grep -E 'action=paused|resumed|players=|PLAYER_MODE=|version=f4-mpris-multi'
```

**v1.0.0** requires this section’s F4-multi rows marked PASS in **this** public file (release SSOT).
