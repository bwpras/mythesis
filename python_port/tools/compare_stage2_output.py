"""One-off validation: diffs this port's Stage 2 CSV output against the real,
already-computed TestBrakefinal_data_raw_<DatiXX>.csv the user actually used
for their finished thesis, matching rows by the same composite key
csv_export.py already dedupes on, then comparing shared numeric columns
within a tolerance. Not part of the automated test suite (needs the real
reference file, which isn't part of this repo's tracked/synthetic data).
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

_KEY_COLUMNS = ["MBP_ID", "BC_ID", "WV_ID", "Start_brake_time_pipe", "End_brake_time_pipe"]


def _composite_key(df: pd.DataFrame) -> pd.Series:
    parts = []
    for col in _KEY_COLUMNS:
        v = df[col]
        if pd.api.types.is_datetime64_any_dtype(v) or "time" in col.lower():
            # Round to whole seconds: the real CSV was exported with
            # second-level precision (MATLAB's default datetime->table
            # formatting), this port's with milliseconds -- same underlying
            # timestamps, different precision, so match at the coarser
            # granularity rather than treating that as a real mismatch.
            parsed = pd.to_datetime(v, errors="coerce", format="mixed", dayfirst=True).dt.floor("s")
            s = parsed.dt.strftime("%Y%m%dT%H%M%S")
            s = s.where(parsed.notna(), "NaT")
        else:
            s = v.astype(str)
        parts.append(s)
    key = parts[0].astype(str)
    for p in parts[1:]:
        key = key.str.cat(p.astype(str), sep="|")
    return key


def compare(mine_path: str, real_path: str, tolerance: float = 1e-3) -> int:
    mine = pd.read_csv(mine_path, dtype={"MBP_ID": str, "BC_ID": str, "WV_ID": str})
    real = pd.read_csv(real_path, dtype={"MBP_ID": str, "BC_ID": str, "WV_ID": str})

    mine_key = _composite_key(mine)
    real_key = _composite_key(real)
    mine = mine.set_index(mine_key)
    real = real.set_index(real_key)

    common_keys = mine.index.intersection(real.index)
    print(f"Mine: {len(mine)} rows. Real: {len(real)} rows. Matched by key: {len(common_keys)} rows.")
    if len(common_keys) == 0:
        print("RESULT: FAIL -- no rows matched by composite key.")
        return 1

    common_cols = sorted(set(mine.columns) & set(real.columns) - set(_KEY_COLUMNS))
    numeric_cols = [c for c in common_cols if pd.api.types.is_numeric_dtype(real[c])]
    print(f"Comparing {len(numeric_cols)} shared numeric columns.")

    mismatches = []
    for col in numeric_cols:
        a = mine.loc[common_keys, col].astype(float)
        b = real.loc[common_keys, col].astype(float)
        both_nan = a.isna() & b.isna()
        diff = (a - b).abs()
        bad = ~both_nan & (a.isna() != b.isna()) | (diff > tolerance)
        bad = bad & ~both_nan
        n_bad = int(bad.sum())
        if n_bad:
            mismatches.append((col, n_bad, len(common_keys)))

    if not mismatches:
        print("RESULT: PASS -- every shared numeric column matches within tolerance.")
        return 0

    print("RESULT: FAIL -- mismatches found:")
    for col, n_bad, n_total in mismatches:
        print(f"  {col}: {n_bad}/{n_total} rows differ by more than {tolerance}")
    return 1


if __name__ == "__main__":
    mine_path, real_path = sys.argv[1], sys.argv[2]
    tol = float(sys.argv[3]) if len(sys.argv) > 3 else 1e-3
    sys.exit(compare(mine_path, real_path, tol))
