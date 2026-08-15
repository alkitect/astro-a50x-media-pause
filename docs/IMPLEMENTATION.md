# Astro A50X media pause/resume — implementation notes

Semantics for [a50x-spotify-pause.sh](../scripts/a50x-spotify-pause.sh) after **F4-multi** (`PLAYER_MODE`) on top of **F3c** HID soft-on.

## Host truth

Soft-disable/dock does **not** remove A50 USB sinks. `sink-input remove` also fires during normal stream churn while still on A50. Remove alone is **not** disable intent. **Dock** via HID battery `dock_chg` (F2b/F3). **Soft-disable** via `020c04000a0006` (F2e/F3b); **power-on resume** via `020c0400130000` (F2e/F3c), episode-gated. Never match battery GET `cmd=06` for resume. F2c+F2d GET soft-disable paths retired.

## Semantics

| Symbol | Meaning |
|--------|---------|
| `PLAYER_MODE` | `single` (default) = one `PLAYER`; `all` = every Playing name from `playerctl -l` |
| `we_paused_players` | Newline-separated MPRIS names this watcher paused; survives until clear/override |
| `we_paused_it` | Derived: 1 iff `we_paused_players` non-empty |
| `on_match_gate` | `single` → `player_on_match_sink`; `all` → `any_on_match_sink` |
| `any_on_match_sink` | Any sink-input whose sink matches `SINK_MATCH` |
| `disable_intent` (PW) | Remove + post-settle `on_match=0` or off-match falling edge |
| `intent=churn` | Remove + still on A50 with replacement `new` (or not Playing) → **no pause** |
| `intent=ambiguous_on_match` | Remove + still on A50 + Playing + no `new` → **no pause** |
| HID `dock_chg` rise | Battery GET byte8 0→1 → pause (`reason=hid-dock-chg-rise`) |
| HID `dock_chg` fall | 1→0 → resume if `we_paused_players` (`reason=hid-dock-chg-fall`) |
| HID soft-off | Prefix `HID_SOFT_OFF_PREFIX` (default `020c04000a0006`) → pause; sets `hid_soft_off_episode` if pause recorded |
| HID soft-on | Prefix `HID_SOFT_ON_PREFIX` (default `020c0400130000`) → `try_resume hid-soft-on` only if episode set |
| `disable_latch` | Bookkeeping TTL after real disable — does **not** re-pause Playing |
| `override=user_play` | User Playing while we_paused/latch → clear latch + set |
| Coalesce | Skip players already in `we_paused_players`; still pause newly Playing eligible |
| Cork | `spotify_uncorked` only when `PLAYER_MODE=single` |
| `WATCHER_VERSION` | `f4-mpris-multi-1` |
| `HID_MATCH_HEX` | Deprecated — ignored |

Layout: watcher entry [a50x-spotify-pause.sh](../scripts/a50x-spotify-pause.sh) sources [lib/mpris.sh](../scripts/lib/mpris.sh) (MPRIS + shared pause orchestration) and [lib/hid.sh](../scripts/lib/hid.sh) (ADR-002 triggers). Classifier: [lib/classify-remove-intent.sh](../scripts/lib/classify-remove-intent.sh). Fixtures: [test/run-intent-fixtures.sh](../scripts/test/run-intent-fixtures.sh). Research tools: [scripts/tools/](../scripts/tools/) (`install-to-local.sh --with-tools`). Structure-only split — no new ADR.

Architecture: [a50x-spotify-pause.md](architecture/a50x-spotify-pause.md) · [ADR-002](architecture/ADR-002-a50x-hid-dock-and-soft-power.md) · [ADR-003](architecture/ADR-003-a50x-multi-mpris-control.md).

## Journal

```
paused … players=spotify,firefox.instance… reason=hid-soft-off signal=hid action=paused
resumed … players=spotify,firefox.instance… reason=hid-soft-on
```

## Latency

| Path | Expectation |
|------|-------------|
| HID battery GET (F2b/F3) | Dock pause/resume ≤~1–2 s; **F4 PASS** |
| HID soft-off (F3b) | Pause ≤~1–2 s; **F4b PASS** |
| HID soft-on (F3c) | Resume ≤~1–2 s after power-on; **F4c PASS** 2026-08-14 |
| Multi-MPRIS (`PLAYER_MODE=all`) | Same HID SLO; human **F4-multi** |

## Kill-switch

```bash
systemctl --user stop a50x-spotify-pause.service
# or HID_ENABLE=0 / PLAYER_MODE=single / ENABLED=0 in config
```

## Rollback

`uninstall-from-local.sh` removes unit/binaries and udev (sudo). Drop `HID_*` / `PLAYER_MODE` from config if keeping the file.
