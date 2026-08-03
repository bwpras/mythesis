"""Python port of matlab/ingestion/batchprocess.m.

Daily extractor for Nodo-equivalent data (1-day bins):
  - Scans *.bin recursively under a chosen source directory to find the
    calendar days actually present
  - For each day D: tStart = D 00:00:00, tEnd = D+1 00:00:00 (next day)
  - Calls load_nodo_data(tStart, tEnd, fsamp, rootDir)
  - Saves under <out-dir>/<DatiXX>/Nodo_<DatiXX>_yyyyMMdd_yyyyMMdd.pkl
  - Skips output files that already exist

Deviations from the MATLAB source (all deliberate, see README.md):
  - No uigetdir GUI picker; the source folder is a required CLI argument.
  - No hardcoded date-range filter (batchprocess.m had one baked in at the
    time this was ported); pass --start-date/--end-date to restrict it.
  - Output is pickled Python objects (list[dict]), not a MATLAB .mat file.
  - parfor is replaced by an optional ProcessPoolExecutor (--workers).
"""
from __future__ import annotations

import argparse
import pickle
import re
import sys
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import List, Optional

import numpy as np

if __package__:
    from .load_nodo_data import load_nodo_data
else:  # allow `python batch_process.py ...` as well as `-m python_port.ingestion.batch_process`
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
    from python_port.ingestion.load_nodo_data import load_nodo_data

_FNAME_RE = re.compile(
    r"^(?P<YYYY>\d{4})_(?P<MMDD>\d{4})(?P<HH>\d{2})(?P<MN>\d{2})(?P<SS>\d{2}).*?_(?P<kind>pjm|p)\.bin$"
)


def _file_end_time(name: str) -> Optional[np.datetime64]:
    m = _FNAME_RE.match(name)
    if not m:
        return None
    g = m.groupdict()
    return np.datetime64(
        f"{g['YYYY']}-{g['MMDD'][:2]}-{g['MMDD'][2:]}T{g['HH']}:{g['MN']}:{g['SS']}"
    )


def _dataset_tag(root_dir: Path) -> str:
    m = re.search(r"Dati\d+", str(root_dir))
    return m.group(0) if m else "DatiXX"


def _process_one_day(day_start: np.datetime64, root_dir: str, fsamp: float,
                      out_dir: str, dataset_tag: str) -> str:
    day_start = np.datetime64(day_start, "us")
    day_end = day_start + np.timedelta64(1, "D")
    out_path = Path(out_dir) / dataset_tag
    out_path.mkdir(parents=True, exist_ok=True)

    base_name = (f"Nodo_{dataset_tag}_"
                 f"{str(day_start)[:10].replace('-', '')}_"
                 f"{str(day_end)[:10].replace('-', '')}.pkl")
    out_file = out_path / base_name

    if out_file.is_file():
        return f"SKIP (exists): {out_file}"

    try:
        nodo = load_nodo_data(day_start, day_end, fsamp, root_dir)
        if not nodo:
            return f"EMPTY: {day_start} -> {day_end}"
        with open(out_file, "wb") as f:
            pickle.dump(nodo, f, protocol=pickle.HIGHEST_PROTOCOL)
        return f"OK: {out_file}"
    except Exception as exc:
        err_file = out_path / f"ERROR_{str(day_start)[:10].replace('-', '')}_{str(day_end)[:10].replace('-', '')}.txt"
        with open(err_file, "w", encoding="utf-8") as f:
            f.write(f"Error on day {day_start}-{day_end}\n")
            f.write(f"Source: {root_dir}\n")
            f.write(f"Message: {exc}\n\n")
            f.write(traceback.format_exc())
        return f"ERROR (see {err_file}): {exc}"


def run_batch(root_dir: Path, out_dir: Path, fsamp: float = 1,
              start_date: Optional[np.datetime64] = None,
              end_date: Optional[np.datetime64] = None,
              workers: int = 1) -> None:
    root_dir = Path(root_dir)
    dataset_tag = _dataset_tag(root_dir)

    all_bins = sorted(root_dir.rglob("*.bin"))
    if not all_bins:
        print(f"No *.bin files found under: {root_dir}")
        return

    end_times: List[np.datetime64] = []
    for p in all_bins:
        et = _file_end_time(p.name)
        if et is not None:
            end_times.append(et)
    if not end_times:
        print(f"No filenames matched the expected pattern under: {root_dir}")
        return

    end_times = np.array(end_times, dtype="datetime64[us]")
    if start_date is not None:
        end_times = end_times[end_times >= np.datetime64(start_date, "us")]
    if end_date is not None:
        end_times = end_times[end_times < np.datetime64(end_date, "us")]
    if end_times.size == 0:
        print(f"No files in the time range {start_date} to {end_date}.")
        return

    day_starts = np.unique(end_times.astype("datetime64[D]")).astype("datetime64[us]")
    n_days = len(day_starts)
    print(f"Found {n_days} day(s) with data in: {root_dir}")

    out_dir.mkdir(parents=True, exist_ok=True)

    if workers <= 1:
        for d in day_starts:
            print(_process_one_day(d, str(root_dir), fsamp, str(out_dir), dataset_tag))
    else:
        with ProcessPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(_process_one_day, d, str(root_dir), fsamp, str(out_dir), dataset_tag): d
                for d in day_starts
            }
            completed = 0
            for fut in as_completed(futures):
                completed += 1
                print(f"[{completed}/{n_days}] {fut.result()}")

    print(f"Done. Processed {n_days} day(s).")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Port of matlab/ingestion/batchprocess.m")
    parser.add_argument("root_dir", type=Path, help="Raw BIN folder, e.g. data/raw/Dati10")
    parser.add_argument("--out-dir", type=Path, default=None,
                         help="Output root (default: <repo_root>/data/interim/python_port -- "
                              "deliberately NOT data/interim/<DatiXX> directly, since that is "
                              "where matlab/ingestion/batchprocess.m writes its own .mat output "
                              "using the same folder-naming convention; keeping this port's .pkl "
                              "output in its own subfolder avoids the two ever colliding or being "
                              "mistaken for one another)")
    parser.add_argument("--fsamp", type=float, default=1,
                         help="40 selects the 40 Hz 'HP' packet layout; anything else selects "
                              "the fixed 1.62181 Hz 'LP' layout (matches loadNodoData.m's FCAMP switch).")
    parser.add_argument("--start-date", type=str, default=None, help="Inclusive, e.g. 2026-01-01")
    parser.add_argument("--end-date", type=str, default=None, help="Exclusive, e.g. 2026-02-18")
    parser.add_argument("--workers", type=int, default=1, help="1 = serial; >1 uses a process pool")
    args = parser.parse_args(argv)

    if args.out_dir is None:
        if __package__:
            from ..paths import get_paths
        else:
            from python_port.paths import get_paths
        args.out_dir = get_paths().interim / "python_port"

    start_date = np.datetime64(args.start_date) if args.start_date else None
    end_date = np.datetime64(args.end_date) if args.end_date else None

    run_batch(args.root_dir, args.out_dir, fsamp=args.fsamp,
              start_date=start_date, end_date=end_date, workers=args.workers)


if __name__ == "__main__":
    main()
