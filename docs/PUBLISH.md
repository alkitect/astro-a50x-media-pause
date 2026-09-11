# Publish notes

Before tag: README must pass `./scripts/ci-check.sh` (required H2s + README ban tokens + Ko-fi `FUNDING.yml` / tip link). See [CONTRIBUTING.md](../CONTRIBUTING.md) § README conventions.

README variant: A

First public tag: v0.6.1

Latest tag: **v0.7.0** (optional `ROUTE_ENABLE` default-sink routing / `f5-route-1`)

Default first tag is 0.1.0. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in this file only for an intentional 0.9.x RC.

```bash
./scripts/ci-check.sh
git tag -a v0.7.0 -m "v0.7.0"
git push origin main
git push origin v0.7.0
gh release create v0.7.0 --verify-tag --title "v0.7.0" --notes-file CHANGELOG.md
```

Repo URL: `https://github.com/alkitect/astro-a50x-media-pause`

## GitHub About

| Field | Value |
|-------|--------|
| Description | Pause/resume MPRIS media and optionally set PipeWire default sink when a Logitech Astro A50 X docks or soft power-cycles (Linux) |
| Website | _(empty — tip via README Ko-fi badge)_ |
| Topics | `linux`, `astro`, `logitech`, `mpris`, `pipewire`, `hid`, `systemd` |

```bash
gh repo edit alkitect/astro-a50x-media-pause \
  --description "Pause/resume MPRIS media and optionally set PipeWire default sink when a Logitech Astro A50 X docks or soft power-cycles (Linux)" \
  --homepage "" \
  --add-topic linux --add-topic astro --add-topic logitech \
  --add-topic mpris --add-topic pipewire --add-topic hid --add-topic systemd
```

Sidebar (manual if shown): Releases ✓ · Packages ✗ · Deployments ✗

