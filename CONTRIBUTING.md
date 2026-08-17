# Contributing

## README conventions

Public README required H2s (exact strings; enforced by `./scripts/ci-check.sh`):

```text
## What this does
## Who this is for
## Quick start
## Check it works
## Uninstall
## Limits & safety
## License
```

Put the beginner path (install / verify / uninstall) above limits. Do not put private monorepo paths or the token `SSOT` in README prose — say “release source” instead.

Also enforced by `./scripts/ci-check.sh`:

- `.github/FUNDING.yml` with `ko_fi: alkitect`
- README Ko-fi GitHub button (`githubbutton_sm.svg` → `ko-fi.com/alkitect`) under the tagline
- README soft tip containing `ko-fi.com/alkitect` (after License)
- README must not link Patreon or Buy Me a Coffee

Gate: `./scripts/ci-check.sh`.

## Versioning

First public tag is recorded in `docs/PUBLISH.md` (`First public tag:`). Default is **0.1.0**. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in PUBLISH only for an intentional 0.9.x RC. After the first tag, bump from CHANGELOG Unreleased (`feat` → minor, `fix` → patch). Maintainers: `./scripts/ci-check.sh` must pass before tag.

## Bug / firmware reports

Please include:

- Distro and desktop (e.g. Ubuntu 22.04 GNOME)
- USB ID (`lsusb` — expect `046d:0b0b` for A50 X)
- Logitech / Astro firmware or G HUB version if known
- Soft-off / soft-on: whether defaults work or you needed `HID_SOFT_OFF_PREFIX` / `HID_SOFT_ON_PREFIX`
- Journal snippets: `journalctl --user -t a50x-spotify-pause --since "10 min ago"` (redact hostnames)

## Behavior changes

If you change pause/resume semantics, update:

- [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
- [docs/architecture/a50x-spotify-pause.md](docs/architecture/a50x-spotify-pause.md) and/or ADR-002 / ADR-003
- [docs/acceptance-matrix.md](docs/acceptance-matrix.md) rows if gates change

Run before PR:

```bash
find scripts -type f -name '*.sh' -print0 | xargs -0 -r bash -n
./scripts/test/run-intent-fixtures.sh
./scripts/ci-check.sh
```

## Sync policy (dual maintenance)

- **Release source:** this GitHub repository (tagged releases, public docs, release acceptance-matrix).
- **Daily driver:** a private Linux customization tree may develop first; before the next public tag, copy behavior changes (`scripts/`, `config/example.config`, `docs/IMPLEMENTATION.md`, `docs/architecture/*`) into this repo.
- After a public tag, optionally mirror those paths back into the private tree if it lagged.
- **Never** sync private Cursor plans, machine journals, or host-specific acceptance logs into this repo.
- **Conflicts:** a human maintainer chooses; no automatic overwrite.

## Naming

Headset (marketing): **Logitech Astro A50 X**. Short form in later mentions: **A50 X** (space before X). Do not write `Astro A50X`.

Repository slug: `astro-a50x-media-pause`. Installed binary / unit / XDG dir remain `a50x-spotify-pause` for compatibility. Env `A50X_TOPIC_ROOT` is an identifier — do not rename.
