#!/usr/bin/env python3
"""F2e-r2: score passive HID CSVs for soft-disable / power-on event frames.

Schema: ts,t0_ms,hex,phase,cmd  (legacy ts,hex,phase also accepted)
Heartbeat cmd=05 is ignored as a candidate.

Defaults: --prefix-len 14. Lag since previous cmd=05 is diagnostic only
(10s heartbeat → >2s is normal if you flip mid-interval).

Usage:
  score-a50x-hid-passive-power.py PLAY.csv \\
    --off OFF1.csv OFF2.csv OFF3.csv \\
    --on  ON1.csv ON2.csv ON3.csv \\
    [--prefix-len 14] [--lag-ms 2000] [--arm-ms 0] [--min-play-ms 60000]
"""
from __future__ import annotations

import argparse
import collections
import csv
import sys
from pathlib import Path

HEARTBEAT = "05"
DEFAULT_LAG_MS = 2000
DEFAULT_PREFIX_LEN = 14  # hex chars — distinguishes OFF vs ON payloads
DEFAULT_MIN_PLAY_MS = 60000
PREFERRED_OFF_FIRST = "020c04000a0006"


def load_rows(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open(newline="") as f:
        lines = [ln for ln in f if ln.strip() and not ln.startswith("#")]
    if not lines:
        return rows
    reader = csv.DictReader(lines)
    for r in reader:
        hexv = (r.get("hex") or "").strip().lower()
        if not hexv:
            continue
        cmd = (r.get("cmd") or "").strip().lower()
        if not cmd and len(hexv) >= 6:
            cmd = hexv[4:6]
        try:
            t0 = int(r.get("t0_ms") or 0)
        except ValueError:
            t0 = 0
        rows.append(
            {
                "ts": (r.get("ts") or "").strip(),
                "t0_ms": t0,
                "hex": hexv,
                "phase": (r.get("phase") or "").strip(),
                "cmd": cmd,
            }
        )
    return rows


def prefix_of(hexv: str, n: int) -> str:
    return hexv[:n] if len(hexv) >= n else hexv


def non_heartbeat(rows: list[dict]) -> list[dict]:
    return [r for r in rows if r["cmd"] != HEARTBEAT]


def summarize(label: str, rows: list[dict], prefix_len: int) -> None:
    cmds = collections.Counter(r["cmd"] for r in rows)
    nh = non_heartbeat(rows)
    t0_last = rows[-1]["t0_ms"] if rows else 0
    print(f"== {label}: rows={len(rows)} last_t0_ms={t0_last}")
    print(f"   cmd_counts={dict(cmds)} non_heartbeat={len(nh)}")
    prefs = collections.Counter(prefix_of(r["hex"], prefix_len) for r in nh)
    if prefs:
        print(f"   non05_prefixes (len={prefix_len}):")
        for p, n in prefs.most_common(12):
            print(f"     n={n} {p}")


def first_non05(
    rows: list[dict], arm_ms: int, prefix_len: int
) -> tuple[str | None, int | None, str | None]:
    for r in rows:
        if r["t0_ms"] < arm_ms:
            continue
        if r["cmd"] == HEARTBEAT:
            continue
        return prefix_of(r["hex"], prefix_len), r["t0_ms"], r["cmd"]
    return None, None, None


def prefixes_in(rows: list[dict], prefix_len: int, arm_ms: int = 0) -> set[str]:
    out: set[str] = set()
    for r in rows:
        if r["t0_ms"] < arm_ms:
            continue
        if r["cmd"] == HEARTBEAT:
            continue
        out.add(prefix_of(r["hex"], prefix_len))
    return out


def lag_since_prev_05(
    rows: list[dict], prefix: str, arm_ms: int, prefix_len: int
) -> int | None:
    """Ms from previous heartbeat (cmd=05) to first matching non-05 prefix."""
    last05: int | None = None
    for r in rows:
        if r["cmd"] == HEARTBEAT:
            last05 = r["t0_ms"]
            continue
        if r["t0_ms"] < arm_ms:
            continue
        if prefix_of(r["hex"], prefix_len) != prefix:
            continue
        if last05 is None:
            return None
        return r["t0_ms"] - last05
    return None


def first_frame_lag_since_prev_05(rows: list[dict], arm_ms: int) -> int | None:
    """Lag for the first non-05 after arm (preferred pause sensing metric)."""
    last05: int | None = None
    for r in rows:
        if r["cmd"] == HEARTBEAT:
            last05 = r["t0_ms"]
            continue
        if r["t0_ms"] < arm_ms:
            continue
        if last05 is None:
            return None
        return r["t0_ms"] - last05
    return None


def contamination_check(
    play: list[dict], edge_files: list[tuple[str, list[dict]]], prefix_len: int
) -> None:
    """Warn if play shares exact timestamps with off/on captures (multi-reader)."""
    play_ts = {r["ts"] for r in play if r["ts"] and r["cmd"] != HEARTBEAT}
    if not play_ts:
        print("== contamination: play has no non-05 rows (clean)")
        print()
        return
    hits: list[str] = []
    for label, rows in edge_files:
        for r in rows:
            if r["cmd"] == HEARTBEAT or not r["ts"]:
                continue
            if r["ts"] in play_ts:
                hits.append(
                    f"{label} ts={r['ts']} prefix={prefix_of(r['hex'], prefix_len)}"
                )
    if hits:
        print("== CONTAMINATION WARNING: play shares timestamps with edge captures")
        print("   (play probe likely ran concurrent with off/on — round INVALID)")
        for h in hits[:12]:
            print(f"   {h}")
        if len(hits) > 12:
            print(f"   … +{len(hits) - 12} more")
        print()
    else:
        play_prefs = prefixes_in(play, prefix_len)
        edge_prefs: set[str] = set()
        for _, rows in edge_files:
            edge_prefs |= prefixes_in(rows, prefix_len)
        overlap = play_prefs & edge_prefs
        if overlap:
            print(
                "== contamination hint: play non-05 prefixes overlap edge prefixes "
                "(may be real noise OR concurrent capture)"
            )
            print(f"   overlap={sorted(overlap)}")
            print()
        else:
            print("== contamination: no shared timestamps with edge files")
            print()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("play", type=Path, help="PHASE=play CSV")
    ap.add_argument("--off", nargs="+", type=Path, default=[], help="power-off CSVs")
    ap.add_argument("--on", nargs="+", type=Path, default=[], help="power-on CSVs")
    ap.add_argument(
        "--arm-ms",
        type=int,
        default=0,
        help="ignore rows with t0_ms < arm (default 0; lag uses prev-05)",
    )
    ap.add_argument("--lag-ms", type=int, default=DEFAULT_LAG_MS)
    ap.add_argument("--prefix-len", type=int, default=DEFAULT_PREFIX_LEN)
    ap.add_argument(
        "--min-play-ms",
        type=int,
        default=DEFAULT_MIN_PLAY_MS,
        help="minimum play last_t0_ms for formal PASS (default 60000)",
    )
    args = ap.parse_args(argv[1:])

    if args.prefix_len < 14:
        print(
            f"WARN: --prefix-len {args.prefix_len} < 14 may merge OFF/ON payloads",
            file=sys.stderr,
        )

    play = load_rows(args.play)
    summarize(f"play {args.play.name}", play, args.prefix_len)
    play_prefs = prefixes_in(play, args.prefix_len, arm_ms=0)
    play_t0 = play[-1]["t0_ms"] if play else 0
    print(f"   play_non05_prefixes={sorted(play_prefs) or '∅'}")
    print(f"   play_duration_ok={play_t0 >= args.min_play_ms} (need ≥{args.min_play_ms} ms)")
    print()

    edge_loaded: list[tuple[str, list[dict]]] = []
    for p in args.off:
        edge_loaded.append((f"off:{p.name}", load_rows(p)))
    for p in args.on:
        edge_loaded.append((f"on:{p.name}", load_rows(p)))
    contaminated = False
    # contamination_check prints; detect via shared timestamps
    play_ts = {r["ts"] for r in play if r["ts"] and r["cmd"] != HEARTBEAT}
    for _, rows in edge_loaded:
        for r in rows:
            if r["cmd"] != HEARTBEAT and r["ts"] and r["ts"] in play_ts:
                contaminated = True
                break
        if contaminated:
            break
    contamination_check(play, edge_loaded, args.prefix_len)

    def score_edge(kind: str, paths: list[Path]) -> tuple[set[str], list[str | None]]:
        if not paths:
            print(f"== {kind}: (no files)")
            print()
            return set(), []
        per_file: list[set[str]] = []
        first_prefs: list[str | None] = []
        lags_by_pref: dict[str, list[int | None]] = collections.defaultdict(list)
        first_lags: list[int | None] = []

        for p in paths:
            rows = load_rows(p)
            summarize(f"{kind} {p.name}", rows, args.prefix_len)
            pref, t0, cmd = first_non05(rows, args.arm_ms, args.prefix_len)
            prefs = prefixes_in(rows, args.prefix_len, arm_ms=args.arm_ms)
            per_file.append(prefs)
            first_prefs.append(pref)
            fl = first_frame_lag_since_prev_05(rows, args.arm_ms)
            first_lags.append(fl)
            print(
                f"   first_non05(cmd={cmd} t0={t0} prefix={pref}) "
                f"lag_since_prev05_ms={fl} "
                f"prefixes={sorted(prefs) or '∅'}"
            )
            for pr in sorted(prefs):
                lag = lag_since_prev_05(rows, pr, args.arm_ms, args.prefix_len)
                lags_by_pref[pr].append(lag)
                near = lag is not None and lag <= args.lag_ms
                print(
                    f"   lag prefix={pr} since_prev05_ms={lag} "
                    f"{'near_hb' if near else 'diag_only'}"
                )
            print()

        common = set.intersection(*per_file) if per_file else set()
        print(f"== {kind} common non05 prefixes (len={args.prefix_len}): {sorted(common) or '∅'}")
        for pr in sorted(common):
            lags = lags_by_pref.get(pr, [])
            in_play = pr in play_prefs
            print(
                f"   candidate {pr}: lags_ms={lags} "
                f"in_play={'YES_FAIL' if in_play else 'no_OK'} "
                f"(lag since 05 is diagnostic only)"
            )
        # First-frame agreement
        if first_prefs and all(x == first_prefs[0] and x for x in first_prefs):
            print(
                f"   first_frame_stable={first_prefs[0]} "
                f"first_lags_ms={first_lags}"
            )
        else:
            print(f"   first_frame_per_file={first_prefs} first_lags_ms={first_lags}")
        print()
        return common, first_prefs

    off_common, off_firsts = score_edge("power-off", args.off)
    on_common, on_firsts = score_edge("power-on", args.on)

    # Union of all prefs per side (not only intersection) for ranking
    off_any: set[str] = set()
    for p in args.off:
        off_any |= prefixes_in(load_rows(p), args.prefix_len, args.arm_ms)
    on_any: set[str] = set()
    for p in args.on:
        on_any |= prefixes_in(load_rows(p), args.prefix_len, args.arm_ms)

    print("== prefix ranking (any-file presence)")
    print(f"   off_only_any: {sorted(off_any - on_any - play_prefs) or '∅'}")
    print(f"   on_only_any:  {sorted(on_any - off_any - play_prefs) or '∅'}")
    print(f"   both_edges:   {sorted((off_any & on_any) - play_prefs) or '∅'}")
    print(f"   in_play:      {sorted(play_prefs) or '∅'}")
    print()

    print("== F2e soft-disable pause gate (off-only exclusive)")
    off_only = {
        p for p in off_common if p not in play_prefs and p not in on_common
    }
    off_shared_on = {
        p for p in off_common if p not in play_prefs and p in on_common
    }

    preferred_ok = (
        PREFERRED_OFF_FIRST in off_only
        or (
            all(f == PREFERRED_OFF_FIRST for f in off_firsts if f)
            and PREFERRED_OFF_FIRST not in play_prefs
            and PREFERRED_OFF_FIRST not in on_any
        )
    )
    if PREFERRED_OFF_FIRST in off_only or preferred_ok:
        print(f"   preferred first-OFF {PREFERRED_OFF_FIRST}: present as off-only candidate")
    elif all(f == PREFERRED_OFF_FIRST for f in off_firsts if off_firsts):
        print(
            f"   preferred {PREFERRED_OFF_FIRST}: stable first frame but "
            f"blocked (in_play={PREFERRED_OFF_FIRST in play_prefs} "
            f"in_on={PREFERRED_OFF_FIRST in on_any})"
        )

    if off_only:
        print(f"   off-only common candidates: {sorted(off_only)}")
    elif off_shared_on:
        print(f"   shared off+on common: {sorted(off_shared_on)}")
        print("   HINT: try longer --prefix-len or use off_only_any ranking above.")
    else:
        off_all_only = set.intersection(
            *[prefixes_in(load_rows(p), args.prefix_len, args.arm_ms) for p in args.off]
        ) if args.off else set()
        off_all_only -= play_prefs
        off_all_only -= on_any
        if off_all_only:
            print(f"   off-only (all offs, not in on/play): {sorted(off_all_only)}")
        else:
            print("   none — no exclusive off-only common prefix")

    first_stable = bool(off_firsts) and all(
        f == PREFERRED_OFF_FIRST for f in off_firsts
    )
    play_ok = play_t0 >= args.min_play_ms and PREFERRED_OFF_FIRST not in play_prefs
    exclusive = PREFERRED_OFF_FIRST not in on_any and (
        PREFERRED_OFF_FIRST in off_only
        or (
            first_stable
            and all(
                PREFERRED_OFF_FIRST
                in prefixes_in(load_rows(p), args.prefix_len, args.arm_ms)
                for p in args.off
            )
        )
    )

    print()
    print("== F2e VERDICT")
    if contaminated:
        print("   INVALID — play shares timestamps with off/on (stop play before edges)")
    elif not args.off or len(args.off) < 3:
        print("   INVALID — need ≥3 power-off CSVs")
    elif not first_stable:
        print(
            f"   FAIL_or_open — first OFF frame not stable "
            f"{PREFERRED_OFF_FIRST}: {off_firsts}"
        )
    elif not exclusive:
        print(f"   FAIL — {PREFERRED_OFF_FIRST} not off-only vs play/on")
    elif not play_ok:
        print(
            f"   INVALID_or_open — need clean play ≥{args.min_play_ms} ms "
            f"without {PREFERRED_OFF_FIRST} (got last_t0_ms={play_t0})"
        )
    else:
        print(
            f"   PASS — preferred OFF {PREFERRED_OFF_FIRST} exclusive; "
            "F3b eligible (separate plan); no watcher wire here"
        )

    print()
    print("== power-on candidates (resume research; not pause PASS)")
    on_only = {
        p for p in on_common if p not in play_prefs and p not in off_common
    }
    print(f"   on-only common: {sorted(on_only) or '∅'}")
    if on_firsts:
        print(f"   on first_frame_per_file: {on_firsts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
