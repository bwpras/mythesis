"""Wraps python_port's Stage 1 (ingestion) + Stage 2 (feature extraction)
so a job can drive both from one call. This is the only place the backend
touches python_port directly -- routers call this, not python_port.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

# python_port lives at the repo root, one level up from backend/.
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import re

import numpy as np

from python_port.ingestion.batch_process import run_batch  # noqa: E402
from python_port.feature_extraction.pipeline import process_nodo_file  # noqa: E402
from python_port.paths import get_paths  # noqa: E402

_PKL_DAY_RE = re.compile(r"_(\d{8})_\d{8}\.pkl$")


def _pkl_day(path: Path) -> "np.datetime64 | None":
    m = _PKL_DAY_RE.search(path.name)
    if not m:
        return None
    d = m.group(1)
    return np.datetime64(f"{d[:4]}-{d[4:6]}-{d[6:8]}")


def run_ingest_and_extract(
    kit_id: str,
    start_date: str,
    end_date: str,
    fsamp: int = 40,
    workers: int = 4,
) -> Callable[[Callable[[str], None]], dict]:
    """Returns a job function: Stage 1 over [start_date, end_date) for
    `kit_id` (e.g. "Dati01"), then Stage 2 over every Nodo pickle it wrote.
    """

    def job(report_progress: Callable[[str], None]) -> dict:
        report_progress(f"Stage 1: ingesting {kit_id} {start_date} -> {end_date}")
        root_dir = _REPO_ROOT / "data" / "raw" / kit_id
        out_dir = get_paths().interim / "python_port"
        run_batch(
            root_dir=root_dir,
            out_dir=out_dir,
            fsamp=fsamp,
            start_date=np.datetime64(start_date),
            end_date=np.datetime64(end_date),
            workers=workers,
        )

        # run_batch() writes files but doesn't hand back their paths -- collect
        # them ourselves, restricted to this kit AND the requested day range.
        # Without the date filter, a job for e.g. one new day would silently
        # re-run Stage 2 over every day ever ingested for this kit (all
        # existing Nodo_<kit>_*.pkl files match the glob, not just today's).
        kit_dir = out_dir / kit_id
        all_pkls = sorted(kit_dir.glob(f"Nodo_{kit_id}_*.pkl")) if kit_dir.is_dir() else []
        start = np.datetime64(start_date)
        end = np.datetime64(end_date)
        pkl_paths = [p for p in all_pkls if (d := _pkl_day(p)) is not None and start <= d < end]
        report_progress(f"Stage 1 done: {len(pkl_paths)} day-file(s) in range for {kit_id}")

        total_phases = 0
        csv_path = None
        failed_days = []
        for i, pkl_path in enumerate(pkl_paths, start=1):
            report_progress(f"Stage 2: {i}/{len(pkl_paths)} ({Path(pkl_path).name})")
            try:
                result = process_nodo_file(pkl_path)
            except Exception as exc:  # noqa: BLE001 - one bad day (no MBP channel
                # found, an empty BC/WV roster, a malformed timestamp -- all seen
                # in real field data) must not lose every other day's already-
                # computed result. "Flag, don't fail": the same ethos
                # detect_subphases_sets.py and braking_detection.py already apply
                # to a single failing phase/pair, applied here to a single day.
                report_progress(f"Stage 2: {Path(pkl_path).name} SKIPPED ({exc})")
                failed_days.append({"file": Path(pkl_path).name, "error": str(exc)})
                continue
            total_phases += result["n_phases"]
            csv_path = str(result["csv_path"])

        report_progress("Done")
        return {
            "kit_id": kit_id,
            "days_ingested": len(pkl_paths),
            "days_failed": len(failed_days),
            "failed_days": failed_days,
            "total_phases": total_phases,
            "csv_path": csv_path,
        }

    return job
