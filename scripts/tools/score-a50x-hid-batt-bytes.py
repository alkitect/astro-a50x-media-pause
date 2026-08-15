#!/usr/bin/env python3
"""F2d: byte-diff Gen5 battery GET CSVs (play vs power soft-disable).

Schema: ts,phase,t0_ms,level,dock_chg,online,edge,raw_hex
Ignores battery level byte offset 6 (hex chars 12-13).
Dock byte offset 8 is reported as control (expect 0 undocked).

Usage:
  score-a50x-hid-batt-bytes.py PLAY.csv POWER1.csv [POWER2.csv ...]
"""
from __future__ import annotations

import collections
import csv
import sys
from pathlib import Path

LEVEL_BYTE = 6
DOCK_BYTE = 8
SKIP_BYTES = {LEVEL_BYTE}
LAG_FAIL_MS = 2000


def load_rows(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open(newline="") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            break
        else:
            return rows
        f.seek(0)
        reader = csv.DictReader(
            (ln for ln in f if not ln.startswith("#") and ln.strip()),
        )
        for r in reader:
            hexv = (r.get("raw_hex") or "").strip().lower()
            if not hexv:
                continue
            try:
                t0 = int(r.get("t0_ms") or 0)
            except ValueError:
                t0 = 0
            rows.append(
                {
                    "t0_ms": t0,
                    "dock_chg": (r.get("dock_chg") or "").strip(),
                    "online": (r.get("online") or "").strip(),
                    "edge": (r.get("edge") or "").strip(),
                    "raw_hex": hexv,
                }
            )
    return rows


def bytes_from_hex(hexv: str) -> list[int]:
    if len(hexv) % 2:
        hexv = hexv[:-1]
    out: list[int] = []
    for i in range(0, len(hexv), 2):
        out.append(int(hexv[i : i + 2], 16))
    return out


def mode_per_byte(rows: list[dict]) -> dict[int, int]:
    buckets: dict[int, collections.Counter[int]] = collections.defaultdict(
        collections.Counter
    )
    for r in rows:
        raw = bytes_from_hex(r["raw_hex"])
        for i, b in enumerate(raw):
            buckets[i][b] += 1
    return {i: c.most_common(1)[0][0] for i, c in buckets.items() if c}


def split_early_late(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """Default split when online stays 1: first 20% vs last 40%."""
    n = len(rows)
    if n < 5:
        return rows[: max(1, n // 2)], rows[max(1, n // 2) :]
    early_end = max(1, int(n * 0.20))
    late_start = min(n - 1, int(n * 0.60))
    return rows[:early_end], rows[late_start:]


def detect_lag_ms(
    rows: list[dict], offset: int, play_val: int, off_val: int
) -> int | None:
    """Last row matching play_val → first later row matching off_val."""
    last_play_t0: int | None = None
    for r in rows:
        raw = bytes_from_hex(r["raw_hex"])
        if offset >= len(raw):
            continue
        if raw[offset] == play_val:
            last_play_t0 = r["t0_ms"]
        elif last_play_t0 is not None and raw[offset] == off_val:
            return r["t0_ms"] - last_play_t0
    return None


def summarize_file(label: str, rows: list[dict]) -> None:
    edges = collections.Counter(r["edge"] for r in rows if r["edge"] != "none")
    docks = collections.Counter(r["dock_chg"] for r in rows)
    online = collections.Counter(r["online"] for r in rows)
    t0_last = rows[-1]["t0_ms"] if rows else 0
    print(f"== {label}: rows={len(rows)} last_t0_ms={t0_last}")
    print(f"   online={dict(online)} dock_chg={dict(docks)} edges={dict(edges) or '{}'}")


def candidates_vs_play(
    play_mode: dict[int, int], late_mode: dict[int, int]
) -> list[tuple[int, int, int]]:
    out: list[tuple[int, int, int]] = []
    for off, late_v in sorted(late_mode.items()):
        if off in SKIP_BYTES:
            continue
        play_v = play_mode.get(off)
        if play_v is None:
            continue
        if play_v != late_v:
            out.append((off, play_v, late_v))
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "Usage: score-a50x-hid-batt-bytes.py PLAY.csv POWER1.csv [POWER2.csv ...]",
            file=sys.stderr,
        )
        return 2

    play_path = Path(argv[1])
    power_paths = [Path(p) for p in argv[2:]]

    play_rows = load_rows(play_path)
    if not play_rows:
        print(f"ERROR: no hex rows in {play_path}", file=sys.stderr)
        return 1

    play_mode = mode_per_byte(play_rows)
    summarize_file(f"play {play_path.name}", play_rows)
    print(f"   skip_bytes={{level:{LEVEL_BYTE}}} dock_control_byte={DOCK_BYTE}")
    print(
        f"   play_mode sample: "
        + " ".join(f"{i}=0x{play_mode[i]:02x}" for i in sorted(play_mode)[:12])
        + (" ..." if len(play_mode) > 12 else "")
    )
    print()

    # Intersection of candidates across all power files (same offset + off value)
    common: dict[tuple[int, int, int], list[int | None]] = {}

    for pp in power_paths:
        rows = load_rows(pp)
        summarize_file(f"power {pp.name}", rows)
        if not rows:
            print("   ERROR: empty")
            print()
            continue

        early, late = split_early_late(rows)
        early_mode = mode_per_byte(early)
        late_mode = mode_per_byte(late)
        early_vs_late = candidates_vs_play(early_mode, late_mode)
        play_vs_late = candidates_vs_play(play_mode, late_mode)

        print(
            f"   split early={len(early)} late={len(late)} "
            f"early_vs_late_diffs={len(early_vs_late)} play_vs_late_diffs={len(play_vs_late)}"
        )

        # Prefer play_vs_late (exclusivity vs play soak)
        for off, play_v, off_v in play_vs_late:
            lag = detect_lag_ms(rows, off, play_v, off_v)
            tag = "CONTROL_dock" if off == DOCK_BYTE else "candidate"
            lag_s = "none" if lag is None else f"{lag}ms"
            ok = lag is not None and lag <= LAG_FAIL_MS
            print(
                f"   {tag} byte[{off}]: play=0x{play_v:02x} late=0x{off_v:02x} "
                f"detect_lag={lag_s} {'OK' if ok else 'FAIL_or_no_edge'}"
            )
            key = (off, play_v, off_v)
            common.setdefault(key, []).append(lag)
        if not play_vs_late:
            print("   (no play_vs_late byte diffs after skipping level)")
            # Still show early_vs_late for debugging
            for off, a, b in early_vs_late[:8]:
                print(f"   early_vs_late byte[{off}]: 0x{a:02x}→0x{b:02x}")
        print()

    print("== cross-power candidates (same offset+values in every power file)")
    n_powers = len(power_paths)
    survivors = [
        (k, lags)
        for k, lags in common.items()
        if len(lags) == n_powers and k[0] not in SKIP_BYTES
    ]
    if not survivors:
        print("   none — F2d FAIL on byte exclusivity (or incomplete captures)")
        return 0

    any_ok = False
    for (off, play_v, off_v), lags in sorted(survivors, key=lambda x: x[0][0]):
        lags_ok = all(lag is not None and lag <= LAG_FAIL_MS for lag in lags)
        tag = "CONTROL_dock" if off == DOCK_BYTE else "candidate"
        print(
            f"   {tag} byte[{off}]: play=0x{play_v:02x} off=0x{off_v:02x} "
            f"lags_ms={lags} {'PASS_lag' if lags_ok else 'FAIL_lag'}"
        )
        if off != DOCK_BYTE and lags_ok:
            any_ok = True

    # Exclusivity: off value must never appear in play at that offset
    print()
    print("== exclusivity (off value absent from play at offset)")
    for (off, play_v, off_v), lags in sorted(survivors, key=lambda x: x[0][0]):
        if off in SKIP_BYTES:
            continue
        seen = any(
            off < len(bytes_from_hex(r["raw_hex"]))
            and bytes_from_hex(r["raw_hex"])[off] == off_v
            for r in play_rows
        )
        print(
            f"   byte[{off}] off=0x{off_v:02x} in_play={'YES_FAIL' if seen else 'no_OK'}"
        )
        if seen:
            any_ok = False

    print()
    if any_ok:
        print(
            "HINT: at least one non-dock candidate has lag≤2s on all powers — "
            "verify human gates then mark F2d PASS (F3b eligible separately)."
        )
    else:
        print(
            "HINT: no wireable candidate — F2d FAIL (soft-disable stays uncovered)."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
