"""Closes the CSV export gap identified during exploration: MATLAB's
`matlab/main/Algorithm_main_batch.m` builds `TestBrakes_table` (via
`postprocessing.build_feature_table`) but its call to
`matlab/analysis/update_brake_master.m` (the function that would actually
write a CSV) is commented out -- so the currently-active MATLAB pipeline
computes the feature table and then discards it. Confirmed separately:
even if that call were re-enabled as written, its output naming
(`<DatiXX>_Master.csv`, `TestBrake_Master.csv`) would not match what the
actual downstream consumers (`python/scripts/train_binary_classifier.py`,
`train_multiclass_classifier.py`) read -- they expect
`TestBrakefinal_data_raw_<DatiXX>.csv` (confirmed via
`train_binary_classifier.py`'s `load_Monorail()`, which extracts the kit
number via `re.search(r'Dati(\\d+)', os.path.basename(filepath))` and via
its `main()`'s explicit `paths.processed_data / "TestBrakefinal_data_raw_Dati01.csv"`
style paths).

This module is a from-scratch addition, not a line-by-line port -- there
is no active MATLAB code computing this. It borrows `update_brake_master.m`'s
useful core idea (merge-and-deduplicate across runs by a composite key,
preferring new rows) since a single MBP `Nodo` file only covers one day,
and the CSV the training scripts want is accumulated across a whole
`DatiXX` kit's days. It deliberately does NOT replicate:
  - `update_brake_master.m`'s `.mat`-format global/per-folder "master"
    files (no MATLAB round-trip need exists for a Python-only artifact).
  - Its CWD-relative default path (`'TestBrake_Master.mat'`) -- this port
    uses the deterministic `data/processed/TestBrakefinal_data_raw_<DatiXX>.csv`,
    matching what the training scripts actually read, following the same
    "explicit project-relative path, not process CWD" precedent already
    used for the label and pairing registries.
  - Its best-effort/non-fatal save-failure handling. The label/pairing
    registries are *caches* -- losing a write just costs recomputation
    next run. This CSV is the *terminal output* of the whole Stage 2
    pipeline for a run; silently swallowing a write failure here would
    mean losing that run's entire computed result with no signal. Write
    failures propagate (raise) instead.
"""
from __future__ import annotations

from pathlib import Path
from typing import Union

import pandas as pd

_KEY_COLUMNS = ["MBP_ID", "BC_ID", "WV_ID", "Start_brake_time_pipe", "End_brake_time_pipe"]
_DATETIME_COLUMNS = ["Start_brake_time_pipe", "End_brake_time_pipe"]


def _output_path(dataset_key: str) -> Path:
    if __package__:
        from ..paths import get_paths
    else:
        from python_port.paths import get_paths
    return get_paths().processed / f"TestBrakefinal_data_raw_{dataset_key}.csv"


def _coerce_datetimes(df: pd.DataFrame) -> pd.DataFrame:
    for col in _DATETIME_COLUMNS:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col])
    return df


def _composite_key(df: pd.DataFrame) -> pd.Series:
    """Port of update_brake_master.m's buildCompositeKey(): join key
    columns with '|', formatting datetimes to a fixed-precision string and
    missing values to sentinel tokens, so exact-match dedup is stable
    across a CSV round-trip."""
    parts = []
    for col in _KEY_COLUMNS:
        if col not in df.columns:
            parts.append(pd.Series(["<missing>"] * len(df), index=df.index))
            continue
        v = df[col]
        if pd.api.types.is_datetime64_any_dtype(v):
            s = v.dt.strftime("%Y%m%dT%H%M%S.%f")
            s = s.where(v.notna(), "NaT")
        else:
            s = v.astype(str)
            s = s.where(v.notna(), "<missing>")
        parts.append(s)

    key = parts[0].astype(str)
    for p in parts[1:]:
        key = key.str.cat(p.astype(str), sep="|")
    return key


def export_feature_csv(table: pd.DataFrame, dataset_key: str, *, prefer_new: bool = True) -> Path:
    """Merges `table` (one run's output from `postprocessing.build_feature_table`)
    into `data/processed/TestBrakefinal_data_raw_<dataset_key>.csv`,
    deduplicating by (MBP_ID, BC_ID, WV_ID, Start_brake_time_pipe,
    End_brake_time_pipe) -- new rows win on a key collision by default,
    matching `update_brake_master.m`'s `PreferNew=true` default. Returns
    the path written. Raises on I/O failure (see module docstring for why
    this isn't best-effort like the registry caches)."""
    out_path = _output_path(dataset_key)

    new_table = _coerce_datetimes(table.copy())

    if out_path.is_file():
        existing = pd.read_csv(out_path, dtype={"MBP_ID": str, "BC_ID": str, "WV_ID": str})
        existing = _coerce_datetimes(existing)

        new_key = _composite_key(new_table)
        existing_key = _composite_key(existing)
        if prefer_new:
            existing = existing.loc[~existing_key.isin(set(new_key))]
        else:
            new_table = new_table.loc[~new_key.isin(set(existing_key))]
        combined = pd.concat([existing, new_table], ignore_index=True)
    else:
        combined = new_table

    # Safety net: enforce uniqueness by key (stable, keep first) -- matches
    # update_brake_master.m's own defensive re-dedup after merging.
    combined_key = _composite_key(combined)
    combined = combined.loc[~combined_key.duplicated(keep="first")]

    if "Start_brake_time_pipe" in combined.columns:
        combined = combined.sort_values(
            "Start_brake_time_pipe", na_position="last", kind="stable"
        ).reset_index(drop=True)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    combined.to_csv(tmp, index=False)
    tmp.replace(out_path)
    return out_path
