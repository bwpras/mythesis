"""Diff a MATLAB-produced Nodo summary CSV against a Python-port one.

Usage:
    python -m python_port.tools.compare_summaries matlab_summary.csv python_summary.csv

Exit code 0 if every sensor ID matches within tolerance, 1 otherwise.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

PRESSURE_TOL_BAR = 0.02   # calibration/formula rounding tolerance
TIME_TOL_SEC = 0.05       # clock/packet-boundary tolerance


def compare_summaries(matlab_csv: Path, python_csv: Path) -> bool:
    m = pd.read_csv(matlab_csv, dtype={"ID": str, "Label": str})
    p = pd.read_csv(python_csv, dtype={"ID": str, "Label": str})

    m = m.set_index("ID")
    p = p.set_index("ID")

    ok = True

    only_m = set(m.index) - set(p.index)
    only_p = set(p.index) - set(m.index)
    if only_m:
        print(f"[MISMATCH] Sensors only in MATLAB output: {sorted(only_m)}")
        ok = False
    if only_p:
        print(f"[MISMATCH] Sensors only in Python output: {sorted(only_p)}")
        ok = False

    common = sorted(set(m.index) & set(p.index))
    print(f"Comparing {len(common)} common sensor(s)...\n")

    for sid in common:
        row_m, row_p = m.loc[sid], p.loc[sid]
        problems = []

        if row_m["Label"] != row_p["Label"]:
            problems.append(f"Label: matlab={row_m['Label']!r} python={row_p['Label']!r}")

        if int(row_m["NumSamples"]) != int(row_p["NumSamples"]):
            problems.append(f"NumSamples: matlab={row_m['NumSamples']} python={row_p['NumSamples']}")

        for col in ("MeanPressure", "StdPressure", "MinPressure", "MaxPressure"):
            vm, vp = float(row_m[col]), float(row_p[col])
            if np.isnan(vm) and np.isnan(vp):
                continue
            if np.isnan(vm) != np.isnan(vp) or abs(vm - vp) > PRESSURE_TOL_BAR:
                problems.append(f"{col}: matlab={vm} python={vp} (tol={PRESSURE_TOL_BAR})")

        for col in ("FirstTime", "LastTime"):
            tm = pd.to_datetime(row_m[col], errors="coerce")
            tp = pd.to_datetime(row_p[col], errors="coerce")
            if pd.isna(tm) and pd.isna(tp):
                continue
            if pd.isna(tm) != pd.isna(tp):
                problems.append(f"{col}: matlab={row_m[col]!r} python={row_p[col]!r}")
                continue
            diff_sec = abs((tm - tp).total_seconds())
            if diff_sec > TIME_TOL_SEC:
                problems.append(f"{col}: matlab={tm} python={tp} diff={diff_sec:.3f}s (tol={TIME_TOL_SEC}s)")

        if problems:
            ok = False
            print(f"[MISMATCH] {sid}")
            for msg in problems:
                print(f"    {msg}")
        else:
            print(f"[OK] {sid}: Label={row_m['Label']}, NumSamples={int(row_m['NumSamples'])}")

    print()
    print("RESULT:", "PASS" if ok else "FAIL")
    return ok


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if len(argv) != 2:
        print(__doc__)
        sys.exit(1)
    ok = compare_summaries(Path(argv[0]), Path(argv[1]))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
