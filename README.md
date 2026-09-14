# Logitech Astro A50 X media pause

Pause and resume desktop media when a Logitech Astro A50 X headset docks, undocks, or soft power-cycles, without hunting for the right player window.

[Quick start](#quick-start) · [acceptance matrix](docs/acceptance-matrix.md) · [Releases](https://github.com/alkitect/astro-a50x-media-pause/releases) · [License](#license)

Latest release notes: [CHANGELOG.md](CHANGELOG.md) and [GitHub Releases](https://github.com/alkitect/astro-a50x-media-pause/releases). A plain `git clone` follows the default branch tip unless you check out a tag; prefer a tagged release for day-to-day use.

## What this does

Docking or soft-powering a Logitech Astro A50 X should pause what is playing and resume when you come back. Doing that by hand is easy to miss mid-game or mid-call.

This watcher listens to HID events on the Logitech USB cradle (`046d:0b0b`) and drives media apps that speak MPRIS (a standard Linux media-control interface) via `playerctl`, typically Spotify, and optionally other players.

Optional seamless output: with `ROUTE_ENABLE=1`, undock / soft-on (and a guarded startup) set the PipeWire default sink to your A50 match and move active streams, so audio works without opening Sound Settings.

Safe by default: the watcher stays off and dry-run (`ENABLED=0`, `DRY_RUN=1`, `HID_ENABLE=0`, `ROUTE_ENABLE=0`) until you opt in. Install, wire udev, and verify before real pause/play or live routing.

## Who this is for

This is for a Logitech Astro A50 X USB cradle `046d:0b0b` on a Linux desktop with user systemd, PipeWire or PulseAudio (`pactl`), plus `playerctl`, `xxd`, and bash.

It is not for generic headsets, or apps that do not speak MPRIS (many games).

## Quick start

Install puts a user service and config on your account. The unit and binary keep the legacy name `a50x-spotify-pause` even though this GitHub repo is `astro-a50x-media-pause`. You still copy a udev rule (sudo), discover sink/player strings, then opt into HID and live pause with the flags below.

Then: [Install](#install) → [Wire udev](#wire-udev) → [Discover and seed config](#discover-and-seed-config) → [Dry-run soak](#dry-run-soak) → [Optional route](#optional-route) → [Restart and journal](#restart-and-journal).

### Install

Needs: matching A50 X cradle, user session with Pulse/PipeWire, `playerctl`, `xxd`, bash, and `systemd --user`.

Stable path: clone or download a release tag from [Releases](https://github.com/alkitect/astro-a50x-media-pause/releases), then run the install script. Tip of the default branch is fine for contributors.

```bash
git clone https://github.com/alkitect/astro-a50x-media-pause.git
cd astro-a50x-media-pause
# optional: git checkout vX.Y.Z   # pin to a release tag
./scripts/install-to-local.sh          # add --with-tools for HID probes/scorers
```

Config lands at `~/.config/astro-a50x-spotify-pause/config`. Leave `ENABLED=0` until after discover and a dry-run soak.

### Wire udev

```bash
sudo cp udev/99-logitech-a50x-hid.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger -c add -s hidraw
```

### Discover and seed config

```bash
./scripts/discover-a50x-sink.sh   # helps set SINK_MATCH / PLAYER in config
```

Set `SINK_MATCH` (and `PLAYER` if `PLAYER_MODE=single`). Defaults stay `PLAYER_MODE=single` (one player, typically Spotify). Deeper player-mode tradeoffs: [docs/acceptance-matrix.md](docs/acceptance-matrix.md).

### Dry-run soak

| Flag           | Safe default | Meaning                          |
| -------------- | ------------ | -------------------------------- |
| `ENABLED`      | `0`          | Watcher inactive until `1`       |
| `DRY_RUN`      | `1`          | Journal only; no real pause/play |
| `HID_ENABLE`   | `0`          | Ignore cradle edges until `1`    |
| `ROUTE_ENABLE` | `0`          | No sink moves until `1`          |

Keep the safe defaults until discover looks right. Then set `ENABLED=1` and `HID_ENABLE=1` with `DRY_RUN=1` for a journal-only soak. Set `DRY_RUN=0` only when you want real pause/play.

### Optional route

After discover, you can set `ROUTE_ENABLE=1` with `HID_ENABLE=1` and `DRY_RUN=0` for live sink moves. With `DRY_RUN=1`, routing only logs `would-route` (not a sink-move soak). `ROUTE_ENABLE=0` later stops future claims; it does not restore the prior default sink.

### Restart and journal

```bash
systemctl --user restart a50x-spotify-pause.service
journalctl --user -t a50x-spotify-pause -f
```

Dock or soft-power the headset. In dry-run you should see journal lines that match those edges without unwanted pauses.

## Check it works

Success is journal lines that match dock / soft-power events (in dry-run, without unwanted pauses). If HID never fires, confirm udev and the USB ID. If the wrong app pauses, stay on `PLAYER_MODE=single` until you are ready to try `all`.

<details>
<summary>Optional confirmation scripts</summary>

```bash
A50X_TOPIC_ROOT="$PWD" ./scripts/verify-a50x-spotify-pause.sh
journalctl --user -t a50x-spotify-pause -n 50
```

Maintainers: `find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n` · `./scripts/test/run-intent-fixtures.sh` · `./scripts/test/run-route-helper-fixtures.sh` · `./scripts/ci-check.sh`.

</details>

Questions or a stuck install: open a GitHub [Issue](https://github.com/alkitect/astro-a50x-media-pause/issues) or see [CONTRIBUTING.md](CONTRIBUTING.md).

## Support my work

Tip jar for the next desktop fix. Or a coffee so the next script stays boring on purpose.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true)

## Uninstall

```bash
./scripts/uninstall-from-local.sh
```

Also remove the udev rule if you copied it:

```bash
sudo rm -f /etc/udev/rules.d/99-logitech-a50x-hid.rules
sudo udevadm control --reload
```

## Configure

- `PLAYER_MODE=single` (default) vs `all` (pauses all Playing MPRIS players: browser, VLC, and so on). See [docs/acceptance-matrix.md](docs/acceptance-matrix.md).
- Soft-off/on hex may need `HID_SOFT_*_PREFIX` override per firmware; browser soft-off needs `HID_ENABLE=1`.
- Seamless output: `ROUTE_ENABLE=1` routes on undock / soft-on via `ROUTE_SINK_MATCH` (or `SINK_MATCH` if unset); needs `HID_ENABLE=1` for those edges. On dual A50 Pro sinks keep `SINK_MATCH` broad for pause and set `ROUTE_SINK_MATCH` to Pro 1. Startup skips if the default is already a Bluetooth A2DP sink.
- Rollback routing: set `ROUTE_ENABLE=0` and restart. Restore the prior sink manually with `pactl set-default-sink <name>`.

## How it works

The user service watches HID on the cradle, maps dock/undock and soft-power edges, then asks `playerctl` to pause or resume MPRIS players. Optional routing claims the matching PipeWire/Pulse sink on undock / soft-on.

Product CLIs live under `scripts/`; libs in `scripts/lib/`; fixtures in `scripts/test/`; research probes in `scripts/tools/` (install with `--with-tools`).

Architecture: [docs/architecture/](docs/architecture/) · [ADR-002](docs/architecture/ADR-002-a50x-hid-dock-and-soft-power.md) · [ADR-003](docs/architecture/ADR-003-a50x-multi-mpris-control.md) · [ADR-004](docs/architecture/ADR-004-a50x-default-sink-routing.md).

## Limits & safety

This can pause and resume media players, and optionally change the default audio sink.

- Platform: Logitech Astro A50 X USB `046d:0b0b` only, not generic headsets.
- `PLAYER_MODE=all` may pause MPRIS players whose audio is not on the A50 if any stream is on A50 when HID fires.
- Non-MPRIS apps are out of scope; soft-off hex may need per-firmware overrides; `ROUTE_ENABLE=0` does not restore the previous default sink.
- Kill-switch: `systemctl --user stop a50x-spotify-pause.service`
- Defaults: `ENABLED=0`, `DRY_RUN=1`, `HID_ENABLE=0`, `ROUTE_ENABLE=0` until you opt in. `PLAYER_MODE=all` remains experimental until v1.0.
- This GitHub repo is the release source for tagged releases and public docs. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

Optional tip jar: [ko-fi.com/alkitect](https://ko-fi.com/alkitect/?hidefeed=true&widget=true&embed=true)
