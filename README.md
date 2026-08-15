# Astro A50X media pause

Pause and resume desktop media when an **Astro A50 X** headset docks, undocks, or soft power-cycles — via HID on the Logitech USB cradle (`046d:0b0b`) and MPRIS (`playerctl`).

**Repo name:** `astro-a50x-media-pause`. **Installed names stay** `a50x-spotify-pause` (binary, systemd user unit, XDG config dir).

## Scope (read first)

1. **Product class:** Astro A50X / Logitech USB `046d:0b0b` — not generic headsets.
2. **Default:** `PLAYER_MODE=single` (one `PLAYER`, typically Spotify). **Opt-in:** `PLAYER_MODE=all` pauses all Playing MPRIS players (browser, VLC, …).
3. **`all` tradeoff:** may pause MPRIS players whose audio is not on the A50 if any stream is on A50 when HID fires.
4. **Limits:** non-MPRIS apps (many games) out of scope; browser soft-off needs `HID_ENABLE=1`; soft-off/on hex may need `HID_SOFT_*_PREFIX` override per firmware.
5. **Safety defaults:** `ENABLED=0`, `DRY_RUN=1`, `HID_ENABLE=0` until you opt in.
6. **Validated upstream:** Ubuntu 22.04 + PipeWire + Spotify snap (not required). **F4-multi** (`PLAYER_MODE=all`) is open until v1.0.
7. **Kill-switch:** `systemctl --user stop a50x-spotify-pause.service`
8. **SSOT:** this repo is canonical for **releases** and public docs. A private Linux customization tree may be a daily driver — see [CONTRIBUTING.md](CONTRIBUTING.md).

Architecture: [docs/architecture/](docs/architecture/) · [ADR-002](docs/architecture/ADR-002-a50x-hid-dock-and-soft-power.md) · [ADR-003](docs/architecture/ADR-003-a50x-multi-mpris-control.md).

Clone: [github.com/alkitect/astro-a50x-media-pause](https://github.com/alkitect/astro-a50x-media-pause). See [docs/PUBLISH.md](docs/PUBLISH.md).

## Requirements

- Linux desktop with user systemd, PipeWire or PulseAudio (`pactl`)
- `playerctl`, `xxd`, bash
- Astro A50 X base (USB ID above)

## Install

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
2. `ENABLED=1` `DRY_RUN=1` `HID_ENABLE=1` → soak (journal only).
3. `DRY_RUN=0` when ready for real pause/play.
4. Optional: `PLAYER_MODE=all` after another dry-run soak — see [docs/acceptance-matrix.md](docs/acceptance-matrix.md).

```bash
systemctl --user restart a50x-spotify-pause.service
A50X_TOPIC_ROOT="$PWD" ./scripts/verify-a50x-spotify-pause.sh
journalctl --user -t a50x-spotify-pause -f
```

## Uninstall

```bash
./scripts/uninstall-from-local.sh
```

## Develop / CI

```bash
find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
./scripts/test/run-intent-fixtures.sh
./scripts/ci-check.sh
```

Layout: product CLIs under `scripts/`; libs in `scripts/lib/`; fixtures in `scripts/test/`; research probes/scorers in `scripts/tools/` (install with `--with-tools`).

## Version

Current watcher: `WATCHER_VERSION=f4-mpris-multi-1` · release tag **v0.6.0** (`PLAYER_MODE=all` experimental until v1.0).
