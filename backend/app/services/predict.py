"""Wraps a saved training-pipeline joblib bundle (model + scaler/imputer +
feature list + metadata, as produced by python/scripts/train_binary_classifier.py's
save_model_artifacts()) for inference against Stage 2's feature CSVs.

Deliberately NOT wired to outputs/models/artifacts_leakage/ -- that bundle's
60 features are ~65% drawn from model.csv's raw reference-only schema
(*_exp-suffixed bench-test fields) that Stage 2's real Monorail CSV export
never produces (confirmed by diffing its metadata.joblib feature_order
against postprocessing.KEEP_FIELDS: only 22/63 features overlap). It cannot
score real field data as-is. This module instead loads whatever bundle the
(now-fixed) training scripts actually produced against real Dati01 data.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Optional

import joblib
import pandas as pd

from ..config import get_paths


def _sanitize_name(s: str) -> str:
    """Mirrors train_binary_classifier.py's sanitize_name() exactly -- must
    stay identical, since it's used here to reconstruct filenames that
    script already wrote, not to write new ones."""
    return str(s).lower().replace(" ", "_").replace("(", "").replace(")", "")


def latest_pipeline_bundle(experiment_tag: str = "feat2") -> Optional[Path]:
    """Picks the best model from the most recent training run, using that
    run's own `_split_test_summary.csv` (already FAR-first ranked by
    evaluate_on_test() -- see train_binary_classifier.py) rather than an
    arbitrary file-sort tiebreak across same-run model files.

    Looks directly under outputs/models/ (non-recursive): historical_saved_models/
    and artifacts_leakage/ hold older/unrelated runs that would otherwise be
    mistaken for "latest" by filename sort."""
    models_dir = get_paths().models
    summaries = sorted(models_dir.glob(f"*_{experiment_tag}_split_test_summary.csv"))
    if not summaries:
        return None
    latest_summary = summaries[-1]

    m = re.match(r"(\d{8}_\d{6})_", latest_summary.name)
    if not m:
        return None
    run_id = m.group(1)

    ranked = pd.read_csv(latest_summary)
    if ranked.empty:
        return None
    best_model_name = _sanitize_name(ranked.iloc[0]["Model"])

    bundle_path = models_dir / f"{run_id}_{experiment_tag}_{best_model_name}_pipeline.joblib"
    return bundle_path if bundle_path.is_file() else None


def _register_main_shims() -> None:
    """train_binary_classifier.py is meant to be run directly
    (`python python/scripts/train_binary_classifier.py`, per docs/python_pipeline.md),
    so at save time its helper functions' `__module__` is `"__main__"` --
    that's what gets baked into the pickled pipeline (it references
    `_rnn_clean_healthy_only`/`_identity_resample` via FunctionSampler).
    Unpickling from a different process (this backend) needs those same
    names reachable on `sys.modules["__main__"]`, or joblib.load() raises
    AttributeError. This registers them there without re-running the
    script (importing it only defines functions -- `main()` is guarded by
    `if __name__ == "__main__":`)."""
    import sys

    main_module = sys.modules["__main__"]
    if hasattr(main_module, "_rnn_clean_healthy_only"):
        return

    repo_root = get_paths().root
    scripts_dir = str(repo_root / "python" / "scripts")
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    import train_binary_classifier as _tbc

    main_module._rnn_clean_healthy_only = _tbc._rnn_clean_healthy_only
    main_module._identity_resample = _tbc._identity_resample


_bundle_cache: dict[Path, dict] = {}


def load_bundle(path: Path) -> dict:
    """Cached by path (immutable once written -- a re-run pipeline job
    always writes a new timestamped filename, never overwrites one)."""
    if path not in _bundle_cache:
        _register_main_shims()
        _bundle_cache[path] = joblib.load(path)
    return _bundle_cache[path]


def get_active_bundle(experiment_tag: str = "feat2") -> Optional[dict]:
    path = latest_pipeline_bundle(experiment_tag)
    return load_bundle(path) if path else None


def model_diagnostics(experiment_tag: str = "feat2") -> Optional[dict]:
    """Metadata + evaluation metrics for whichever model get_active_bundle()
    would use, read from the sidecar files train_binary_classifier.py's
    save_model_artifacts() already writes next to the bundle -- no need to
    inspect the fitted pipeline object itself for this."""
    import json

    bundle_path = latest_pipeline_bundle(experiment_tag)
    if bundle_path is None:
        return None

    meta_path = bundle_path.with_name(bundle_path.name.replace("_pipeline.joblib", "_meta.json"))
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.is_file() else {}

    m = re.match(r"(\d{8}_\d{6})_", bundle_path.name)
    run_id = m.group(1) if m else None
    summary_path = bundle_path.parent / f"{run_id}_{experiment_tag}_split_test_summary.csv"
    eval_row = None
    if summary_path.is_file():
        ranked = pd.read_csv(summary_path)
        model_name = meta.get("model_name")
        match = ranked.loc[ranked["Model"] == model_name] if model_name else ranked.iloc[[0]]
        if not match.empty:
            eval_row = match.iloc[0].to_dict()

    return {
        "bundle_path": str(bundle_path),
        "model_name": meta.get("model_name"),
        "features": meta.get("features"),
        "saved_at": meta.get("saved_at"),
        "test_metrics": eval_row,
    }


def predict(bundle: dict, df: pd.DataFrame) -> pd.Series:
    """Runs bundle['pipeline'] (imputer+scaler+clf) over bundle['features']
    columns of `df`. Raises KeyError up front (not deep inside sklearn) if
    a required feature is missing -- a fast, legible failure over a cryptic
    one, since this is exactly the class of mismatch the artifacts_leakage
    bundle silently can't satisfy (see module docstring)."""
    missing = [f for f in bundle["features"] if f not in df.columns]
    if missing:
        raise KeyError(f"Input data is missing required model features: {missing}")
    X = df[bundle["features"]]
    return pd.Series(bundle["pipeline"].predict(X), index=df.index)
