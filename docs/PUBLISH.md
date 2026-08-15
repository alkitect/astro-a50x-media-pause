# Publish notes

Before tag: README must pass `./scripts/ci-check.sh` (required H2s + README ban tokens + Ko-fi `FUNDING.yml` / tip link). See [CONTRIBUTING.md](../CONTRIBUTING.md) § README conventions.

First public tag: v0.6.1

Default first tag is 0.1.0. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in this file only for an intentional 0.9.x RC.

```bash
./scripts/ci-check.sh
git tag -a v0.6.1 -m "v0.6.1"
git push origin main
git push origin v0.6.1
```

Repo URL: `https://github.com/alkitect/astro-a50x-media-pause`

## GitHub About

| Field | Value |
|-------|--------|
| Description | Pause/resume MPRIS media when an Astro A50 X docks or soft power-cycles (Linux) |
| Website | https://ko-fi.com/alkitect |
| Topics | `linux`, `astro`, `logitech`, `mpris`, `pipewire`, `hid`, `systemd` |

```bash
gh repo edit alkitect/astro-a50x-media-pause \
  --description "Pause/resume MPRIS media when an Astro A50 X docks or soft power-cycles (Linux)" \
  --homepage "https://ko-fi.com/alkitect" \
  --add-topic linux --add-topic astro --add-topic logitech \
  --add-topic mpris --add-topic pipewire --add-topic hid --add-topic systemd
```

Sidebar (manual if shown): Releases ✓ · Packages ✗ · Deployments ✗

