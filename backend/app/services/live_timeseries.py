"""Per-cycle pressure-time-history storage for the live dashboard.

Stage 2's `postprocessing.build_feature_table()` collapses each braking
phase into scalar summary columns (`KEEP_FIELDS`) for the CSV export -- the
raw `MBP_Time`/`MBP_Pressure` and each BC channel's `Time`/`Pressure`
arrays never survive that flattening (a CSV cell can't hold an array).
This module persists those raw arrays separately, one JSON file per phase,
so the dashboard can plot a real pressure-vs-time curve for a cycle
instead of just its scalar summary.

Keyed by (MBP_ID, Start_brake_time_pipe) -- deliberately read off
`build_test_brake_sets()`'s output AFTER `detect_subphases_sets()` has run,
not off the raw `TestBrake` phase dict's `MBP_StartTime`. Those two
timestamps are NOT interchangeable: `Start_brake_time_pipe` is computed by
`mbp_pipe_subphases.py`'s own state machine as the first sample of the
segment IT classifies as "braking", which can differ from the raw onset
`detect_braking_struct_beta()` used to open the phase. Since the exported
CSV only ever carries `Start_brake_time_pipe` (not `MBP_StartTime`), keying
by the raw onset would make a later API lookup by CSV row silently 404 even
when a record exists. `MBP_Time`/`MBP_Pressure` ride along unchanged on
every pairing's flattened entry for a given phase (only `BC_*`/`WV_*`
differ per pairing), so any one pairing's entry supplies the MBP curve;
each pairing supplies its own BC channel's curve, up to 4.

Only the live watcher writes here (`live_watch.py`'s `_flush_and_export()`)
-- the batch pipeline has no equivalent store, since this is dashboard-only,
not part of the MATLAB port.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python_port.feature_extraction.csv_export import _replace_with_retry  # noqa: E402

from ..config import get_paths

_SAFE_CHARS_RE = re.compile(r"[^0-9A-Za-z_.-]")


def _phase_key(mbp_id: str, start_time) -> str:
    """Filesystem-safe key identifying one phase. Deliberately the same
    (MBP_ID, Start_brake_time_pipe) identity `csv_export.py`'s composite
    key already uses for dedup, so the write side (a raw TestBrake phase
    dict) and the read side (a CSV row looked up by event_id) always agree
    on which file a given event maps to."""
    ts = pd.Timestamp(start_time).strftime("%Y%m%dT%H%M%S.%f")
    return _SAFE_CHARS_RE.sub("_", f"{mbp_id}_{ts}")


def _store_dir(kit_id: str) -> Path:
    return get_paths().dashboard_store / "live_timeseries" / kit_id


def _series_to_lists(time: Optional[np.ndarray], pressure: Optional[np.ndarray]) -> dict:
    if time is None or pressure is None or len(time) == 0:
        return {"time": [], "pressure": []}
    pressure = np.asarray(pressure, dtype=float)
    return {
        "time": [pd.Timestamp(t).isoformat() for t in np.asarray(time)],
        "pressure": [None if np.isnan(v) else round(float(v), 4) for v in pressure],
    }


def save_phase_timeseries_from_sets(kit_id: str, test_brake_sets: list) -> None:
    """Writes one JSON record per phase, gathered from `test_brake_sets`
    (`build_test_brake_sets()`'s output, AFTER `detect_subphases_sets()` has
    added `Start_brake_time_pipe`/`End_brake_time_pipe` to each pairing's
    flattened entry) -- `list[pair][phase_index]`. Best-effort: a write
    failure here must not take down the watcher (this is an enrichment for
    plotting, not the terminal CSV export) -- callers should catch and log,
    not propagate.

    `Start_brake_time_pipe` is a deterministic function of `MBP_Time`/
    `MBP_Pressure` alone, which are identical across every pairing for a
    given phase index -- so every pairing that resolves it at all resolves
    it to the same value; the first one found is as good as any."""
    if not test_brake_sets:
        return
    num_phases = max((len(cell) for cell in test_brake_sets if cell), default=0)

    for i in range(num_phases):
        base = next((cell[i] for cell in test_brake_sets if cell and i < len(cell)
                     and cell[i].get("Start_brake_time_pipe") is not None), None)
        if base is None:
            continue  # subphase detection never resolved a pipe-brake segment for this phase
        mbp_id, start_time = base.get("MBP_ID"), base.get("Start_brake_time_pipe")
        if mbp_id is None:
            continue

        bc_series = []
        for cell in test_brake_sets:
            if not cell or i >= len(cell) or len(bc_series) >= 4:
                continue
            entry = cell[i]
            series = _series_to_lists(entry.get("BC_Time"), entry.get("BC_Pressure"))
            if not series["time"]:
                continue
            bc_series.append({"id": str(entry.get("BC_ID")), "label": str(entry.get("BC_Label") or "BC"), **series})

        record = {
            "mbp_id": str(mbp_id),
            "start_brake_time_pipe": pd.Timestamp(start_time).isoformat(),
            "end_brake_time_pipe": (
                pd.Timestamp(base["End_brake_time_pipe"]).isoformat()
                if base.get("End_brake_time_pipe") is not None else None
            ),
            "mbp": {"label": str(base.get("MBP_Label") or "MBP"),
                    **_series_to_lists(base.get("MBP_Time"), base.get("MBP_Pressure"))},
            "bc": bc_series,
        }

        out_dir = _store_dir(kit_id)
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / f"{_phase_key(mbp_id, start_time)}.json"
        tmp = out_path.with_suffix(out_path.suffix + ".tmp")
        tmp.write_text(json.dumps(record), encoding="utf-8")
        _replace_with_retry(tmp, out_path)


def load_phase_timeseries(kit_id: str, mbp_id: str, start_time) -> Optional[dict]:
    """Looks up one phase's stored time-series by the same (MBP_ID,
    Start_brake_time_pipe) identity used to key it. Returns None if not
    found (e.g. this cycle predates the timeseries-saving feature, or the
    save failed and was only logged as a watcher warning)."""
    path = _store_dir(kit_id) / f"{_phase_key(mbp_id, start_time)}.json"
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))
