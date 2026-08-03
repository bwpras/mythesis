"""Summarize a Python-port Nodo_*.pkl file to CSV, in the same format as
export_nodo_summary.m, so the two can be diffed by compare_summaries.py.

Usage:
    python -m python_port.tools.export_nodo_summary <nodo.pkl> [out.csv]
"""
from __future__ import annotations

import pickle
import sys
from pathlib import Path

import numpy as np
import pandas as pd


def export_nodo_summary(pkl_path: Path, out_csv: Path = None) -> Path:
    pkl_path = Path(pkl_path)
    if out_csv is None:
        out_csv = pkl_path.with_name(pkl_path.stem + "_summary.csv")

    with open(pkl_path, "rb") as f:
        nodo = pickle.load(f)

    rows = []
    for s in nodo:
        p = np.asarray(s["Pressure"], dtype=float)
        t = np.asarray(s["Time"])
        rows.append({
            "ID": str(s["ID"]),
            "Label": str(s["Label"]),
            "NumSamples": len(p),
            "FirstTime": str(t[0]) if len(t) else "",
            "LastTime": str(t[-1]) if len(t) else "",
            "MeanPressure": float(np.mean(p)) if len(p) else np.nan,
            # ddof=1 to match MATLAB's std() default (normalizes by N-1)
            "StdPressure": float(np.std(p, ddof=1)) if len(p) > 1 else np.nan,
            "MinPressure": float(np.min(p)) if len(p) else np.nan,
            "MaxPressure": float(np.max(p)) if len(p) else np.nan,
        })

    df = pd.DataFrame(rows)
    df.to_csv(out_csv, index=False)
    print(f"Wrote summary for {len(df)} sensors to {out_csv}")
    return out_csv


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print(__doc__)
        sys.exit(1)
    pkl_path = Path(argv[0])
    out_csv = Path(argv[1]) if len(argv) > 1 else None
    export_nodo_summary(pkl_path, out_csv)


if __name__ == "__main__":
    main()
