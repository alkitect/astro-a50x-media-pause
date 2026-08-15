# Research / matrix tools (optional)

Closed HID research ladder (F2b–F2e probes and scorers). **Not required** for daily pause/resume.

Install only with:

```bash
./scripts/install-to-local.sh --with-tools
```

Probes keep their own `find_a50_hidraw` helpers — **do not** sync them with `scripts/lib/hid.sh` (product watcher HID path).
