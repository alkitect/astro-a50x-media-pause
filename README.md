# Logitech Astro A50 X media pause

Pause and resume desktop media when a **Logitech Astro A50 X** headset docks, undocks, or soft power-cycles — without hunting for the right player window.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/alkitect)

## What this does

Docking or soft-powering a Logitech Astro A50 X should pause what’s playing and resume when you come back. Doing that by hand is easy to miss mid-game or mid-call.

This watcher listens to **HID events on the Logitech USB cradle** (`046d:0b0b`) and drives media apps that speak **MPRIS** (a standard Linux media-control interface) via `playerctl` — typically Spotify, and optionally other players.

**Safe by default:** the watcher stays **off** and **dry-run** (`ENABLED=0`, `DRY_RUN=1`, `HID_ENABLE=0`) until you opt in. Install, wire udev, and verify before real pause/play.

## Who this is for

- **In:** Logitech Astro A50 X USB cradle `046d:0b0b` on a Linux desktop with **user systemd**.
- **In:** PipeWire or PulseAudio (`pactl`), plus `playerctl`, `xxd`, and bash.
- **Not for:** generic headsets, or apps that don’t speak MPRIS (many games).

## Quick start

```bash
git clone https://github.com/alkitect/astro-a50x-media-pause.git
cd astro-a50x-media-pause
./scripts/install-to-local.sh          # add --with-tools for HID probes/scorers
sudo cp udev/99-logitech-a50x-hid.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger -c add -s hidraw
./scripts/discover-a50x-sink.sh   # helps set SINK_MATCH / PLAYER in config
```

**What you installed:** user service `a50x-spotify-pause` (binary and config dir keep that name even though the GitHub repo is `astro-a50x-media-pause`). Config: `~/.config/astro-a50x-spotify-pause/config`.

**Stay safe before enabling:**

1. Set `SINK_MATCH` (and `PLAYER` if `PLAYER_MODE=single`).
2. Keep `ENABLED=0` `DRY_RUN=1` `HID_ENABLE=0` until ready; then `ENABLED=1` `HID_ENABLE=1` with `DRY_RUN=1` for a journal-only soak.
3. Set `DRY_RUN=0` when you want real pause/play.
4. Optional: `PLAYER_MODE=all` after another dry-run soak — see [docs/acceptance-matrix.md](docs/acceptance-matrix.md). Defaults stay `PLAYER_MODE=single` (one `PLAYER`, typically Spotify).

Then restart and watch:

```bash
systemctl --user restart a50x-spotify-pause.service
A50X_TOPIC_ROOT="$PWD" ./scripts/verify-a50x-spotify-pause.sh
journalctl --user -t a50x-spotify-pause -f
```

**Needs:** matching headset/cradle, user session with Pulse/PipeWire, and the packages above. Soft-off hex and player-mode tradeoffs: see **Configure** / **Limits & safety**.

## Check it works

You want verify to pass and (in dry-run) journal lines that match dock / soft-power events without unwanted pauses.

```bash
A50X_TOPIC_ROOT="$PWD" ./scripts/verify-a50x-spotify-pause.sh
journalctl --user -t a50x-spotify-pause -n 50
```

- If HID never fires: confirm udev rules are installed and `discover-a50x-sink.sh` / USB ID look right.
- If the wrong app pauses: stay on `PLAYER_MODE=single` until you’re ready to try `all`.

Maintainers: `find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n` · `./scripts/test/run-intent-fixtures.sh` · `./scripts/ci-check.sh`.

## Uninstall

```bash
./scripts/uninstall-from-local.sh
```

## Configure

- `PLAYER_MODE=single` (default) vs `all` (pauses all Playing MPRIS players — browser, VLC, …).
- Soft-off/on hex may need `HID_SOFT_*_PREFIX` override per firmware; browser soft-off needs `HID_ENABLE=1`.

## How it works

Layout: product CLIs under `scripts/`; libs in `scripts/lib/`; fixtures in `scripts/test/`; research probes/scorers in `scripts/tools/` (install with `--with-tools`).

Current watcher: `WATCHER_VERSION=f4-mpris-multi-1` · release tag **v0.6.1** (`PLAYER_MODE=all` experimental until v1.0).

Architecture: [docs/architecture/](docs/architecture/) · [ADR-002](docs/architecture/ADR-002-a50x-hid-dock-and-soft-power.md) · [ADR-003](docs/architecture/ADR-003-a50x-multi-mpris-control.md).

See also [docs/PUBLISH.md](docs/PUBLISH.md).

## Limits & safety

This can pause and resume media players. Hard stops and scope:

- **Platform:** Logitech Astro A50 X USB `046d:0b0b` — not generic headsets.
- **Tradeoffs:** `PLAYER_MODE=all` may pause MPRIS players whose audio is not on the A50 if any stream is on A50 when HID fires.
- **Limits:** non-MPRIS apps out of scope; soft-off hex may need per-firmware overrides.
- **Kill-switch:** `systemctl --user stop a50x-spotify-pause.service`
- **Defaults:** `ENABLED=0`, `DRY_RUN=1`, `HID_ENABLE=0` until you opt in. `PLAYER_MODE=all` remains experimental until v1.0.
- This GitHub repo is the **release source** for tagged releases and public docs — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

Optional tip jar: [ko-fi.com/alkitect](https://ko-fi.com/alkitect)
