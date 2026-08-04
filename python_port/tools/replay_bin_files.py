"""Demo/replay tool: drip-feeds historical `.bin` files from a source kit
folder (e.g. data/raw/Dati10) into a destination folder at real or
sped-up inter-file timing, so a live watcher pointed at the destination
folder reacts to "new" files the same way it would to a real live gateway.

Not part of the MATLAB port -- this is a from-scratch tool for demoing the
streaming pipeline built in braking_detection.py/live_watch.py against
existing historical data, per the project's own scope decision (demo/
replay, not a real live-gateway integration).

Usage:
    python -m python_port.tools.replay_bin_files data/raw/Dati10 /path/to/watch_dir --speed 60
    python -m python_port.tools.replay_bin_files data/raw/Dati10 /path/to/watch_dir --burst
"""
from __future__ import annotations

import argparse
import shutil
import sys
import time
from pathlib import Path
from typing import List, Optional

import numpy as np

if __package__:
    from .. import paths as _paths_mod  # noqa: F401 -- import guard, package context
    from ..ingestion.filename_pattern import parse_bin_filename
else:  # allow `python replay_bin_files.py ...` as well as `-m python_port.tools.replay_bin_files`
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
    from python_port.ingestion.filename_pattern import parse_bin_filename


def _sorted_bin_files(source_dir: Path, start_from: Optional[np.datetime64]) -> List[tuple]:
    """Returns [(path, timestamp)], sorted ascending by filename-embedded
    timestamp. Files that don't match the naming convention, or that fall
    before `start_from`, are skipped (matches load_nodo_data()'s own
    "unparseable filename -> ignore" precedent, not a new behavior)."""
    rows = []
    for path in source_dir.rglob("*.bin"):
        parsed = parse_bin_filename(path.name)
        if parsed is None:
            continue
        end_time = parsed[0]
        if start_from is not None and end_time < start_from:
            continue
        rows.append((path, end_time))
    rows.sort(key=lambda r: r[1])
    return rows


def replay(source_dir: Path, dest_dir: Path, speed: float = 60.0,
           start_from: Optional[str] = None, loop: bool = False,
           report=print) -> None:
    """Copies (never moves -- source_dir must stay byte-identical across
    repeated demo runs) every matched `.bin` file from source_dir into
    dest_dir, in filename-timestamp order, sleeping between files by their
    real inter-file gap divided by `speed` (0 = no delay, burst mode)."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    start_ts = np.datetime64(start_from) if start_from else None

    while True:
        rows = _sorted_bin_files(source_dir, start_ts)
        if not rows:
            report(f"No matching .bin files found under: {source_dir}")
            return

        report(f"Replaying {len(rows)} file(s) from {source_dir} -> {dest_dir} "
               f"(speed={'burst' if speed <= 0 else speed}x)")

        prev_ts: Optional[np.datetime64] = None
        for i, (path, ts) in enumerate(rows, start=1):
            if speed > 0 and prev_ts is not None:
                gap_s = float((ts - prev_ts) / np.timedelta64(1, "s"))
                if gap_s > 0:
                    time.sleep(gap_s / speed)
            prev_ts = ts

            shutil.copy2(path, dest_dir / path.name)
            if i % 25 == 0 or i == len(rows):
                report(f"  [{i}/{len(rows)}] {path.name}")

        report("Replay pass complete.")
        if not loop:
            return


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path, help="Raw BIN folder to replay from, e.g. data/raw/Dati10")
    parser.add_argument("dest_dir", type=Path, help="Folder the live watcher is watching")
    parser.add_argument("--speed", type=float, default=60.0,
                         help="Real-time delay divided by this factor (default 60x). "
                              "0 or --burst copies with no delay.")
    parser.add_argument("--burst", action="store_true", help="Shorthand for --speed 0.")
    parser.add_argument("--start-from", type=str, default=None,
                         help="Skip files timestamped before this ISO datetime, e.g. 2025-05-13T10:00:00")
    parser.add_argument("--loop", action="store_true", help="Repeat the replay pass indefinitely.")
    args = parser.parse_args(argv)

    speed = 0.0 if args.burst else args.speed
    replay(args.source_dir, args.dest_dir, speed=speed, start_from=args.start_from, loop=args.loop)


if __name__ == "__main__":
    main()
