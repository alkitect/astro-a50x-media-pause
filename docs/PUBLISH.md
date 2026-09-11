# Publish notes

Before tag: README must pass `./scripts/ci-check.sh` (required H2s + README ban tokens + Ko-fi `FUNDING.yml` / tip link). See [CONTRIBUTING.md](../CONTRIBUTING.md) § README conventions.

README variant: A

First public tag: v0.6.1

Latest tag: **v0.7.1** (`f5-route-2` dual-sink pause gate + `ROUTE_SINK_MATCH` / post-pause override grace)

Default first tag is 0.1.0. Never copy another alkitect repo’s tag. Use `RC-BEFORE-1.0` in this file only for an intentional 0.9.x RC.

```bash
./scripts/ci-check.sh
git tag -a v0.7.1 -m "v0.7.1"
git push origin main
git push origin v0.7.1
gh release create v0.7.1 --title "v0.7.1" --notes-file - <<'EOF'
## 0.7.1

Dual A50 pro-audio sink fix: broad `SINK_MATCH` for pause gates; optional `ROUTE_SINK_MATCH` for Pro 1 / Game; always-log soft-off skips; post-pause override grace (`f5-route-2`).
EOF
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

