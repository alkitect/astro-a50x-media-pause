# Astro A50X media pause

Pause and resume desktop media when an **Astro A50 X** headset docks, undocks, or soft power-cycles — via HID on the Logitech USB cradle (`046d:0b0b`) and MPRIS (`playerctl`).

**Repo name:** `astro-a50x-media-pause`. **Installed names stay** `a50x-spotify-pause` (binary, systemd user unit, XDG config dir).

## What this does

Docking or soft-powering an Astro A50 X should pause what’s playing and resume when you come back — without hunting for the right media window. This watcher listens to the cradle’s HID events and drives MPRIS players via `playerctl`.

Shipped defaults keep the watcher **off** and **dry-run** (`ENABLED=0`, `DRY_RUN=1`, `HID_ENABLE=0`) until you opt in.

## Who this is for

- Astro A50 X / Logitech USB cradle `046d:0b0b` on a Linux desktop with user systemd
- PipeWire or PulseAudio (`pactl`), `playerctl`, `xxd`, bash

**Not for:** generic headsets, or apps that don’t speak MPRIS (many games).

## Quick start

```bash
git clone https://github.com/alkitect/astro-a50x-media-pause.git
cd astro-a50x-media-pause
./scripts/install-to-local.sh          # add --with-tools for HID probes/scorers
sudo cp udev/99-logitech-a50x-hid.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger -c add -s hidraw
./scripts/discover-a50x-sink.sh   # set SINK_MATCH / PLAYER in config
```

Config: `~/.config/astro-a50x-spotify-pause/config`

1. Set `SINK_MATCH` (and `PLAYER` if `PLAYER_MODE=single`).
2. Keep `ENABLED=0` `DRY_RUN=1` `HID_ENABLE=0` until ready; then `ENABLED=1` `HID_ENABLE=1` with `DRY_RUN=1` for a journal-only soak.
3. `DRY_RUN=0` when ready for real pause/play.
4. Optional: `PLAYER_MODE=all` after another dry-run soak — see [docs/acceptance-matrix.md](docs/acceptance-matrix.md).

Primary safety defaults: `ENABLED=0`, `DRY_RUN=1`, `HID_ENABLE=0` until you opt in. Default player mode is `PLAYER_MODE=single` (one `PLAYER`, typically Spotify).

```bash
systemctl --user restart a50x-spotify-pause.service
A50X_TOPIC_ROOT="$PWD" ./scripts/verify-a50x-spotify-pause.sh
journalctl --user -t a50x-spotify-pause -f
```

## Check it works

```bash
A50X_TOPIC_ROOT="$PWD" ./scripts/verify-a50x-spotify-pause.sh
find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
./scripts/test/run-intent-fixtures.sh
./scripts/ci-check.sh
```

## Uninstall

```bash
./scripts/uninstall-from-local.sh
```

## Configure

- `PLAYER_MODE=single` (default) vs `all` (pauses all Playing MPRIS players — browser, VLC, …).
- Soft-off/on hex may need `HID_SOFT_*_PREFIX` override per firmware; browser soft-off needs `HID_ENABLE=1`.

## How it works

Layout: product CLIs under `scripts/`; libs in `scripts/lib/`; fixtures in `scripts/test/`; research probes/scorers in `scripts/tools/` (install with `--with-tools`).

Current watcher: `WATCHER_VERSION=f4-mpris-multi-1` · release tag **v0.6.0** (`PLAYER_MODE=all` experimental until v1.0).

Architecture: [docs/architecture/](docs/architecture/) · [ADR-002](docs/architecture/ADR-002-a50x-hid-dock-and-soft-power.md) · [ADR-003](docs/architecture/ADR-003-a50x-multi-mpris-control.md).

See also [docs/PUBLISH.md](docs/PUBLISH.md).

## Limits & safety

- **Product class:** Astro A50X / Logitech USB `046d:0b0b` — not generic headsets.
- **`all` tradeoff:** may pause MPRIS players whose audio is not on the A50 if any stream is on A50 when HID fires.
- **Limits:** non-MPRIS apps out of scope; soft-off hex may need per-firmware overrides.
- **Kill-switch:** `systemctl --user stop a50x-spotify-pause.service`
- **Validated on:** Ubuntu 22.04 + PipeWire + Spotify snap (not required). `PLAYER_MODE=all` remains experimental until v1.0.
- This GitHub repo is the **release source** for tagged releases and public docs. A private Linux customization tree may be a daily driver — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
