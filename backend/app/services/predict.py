"""Inference against the real, finished-thesis model bundles
(outputs/models/finished_thesis/*_inference.joblib) -- the actual models
validated in the thesis, not a retrain. See module-level docs in
wagon_type.py for the kit/wagon-type mapping this all builds on.

Deliberately NOT wired to outputs/models/artifacts_leakage/ -- that bundle's
60 features are ~65% drawn from model.csv's raw reference-only schema
(*_exp-suffixed bench-test fields) that Stage 2's real Monorail CSV export
never produced before the postprocessing.py fix (confirmed by diffing its
metadata.joblib feature_order against KEEP_FIELDS: only 22/63 overlapped).

Model selection is data-driven, not hardcoded: mirrors the thesis's own
test_main_binary.ipynb exactly -- run all 3 models (knn/rf/svm) against the
real generalization-test kits (T3000's held-out Dati30 + every other-wagon
kit), compute False Alarm Rate per wagon type (ground truth assumed healthy
for this in-service field data, matching the notebook's own y_true=0
assumption), and treat the model with the lowest mean FAR as "active".
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import joblib
import numpy as np
import pandas as pd

from ..config import get_paths
from . import data_store
from .wagon_type import GENERALIZATION_TEST_KITS, wagon_type_for_kit

_LABEL_COLUMNS = ["LeakageLabel", "label", "Malfunction"]


def _finished_models_dir() -> Path:
    return get_paths().models / "finished_thesis"


def list_finished_bundles() -> dict[str, Path]:
    """{model_name: path}, e.g. {'20260220_135649_feat2_rf': Path(...)}."""
    models_dir = _finished_models_dir()
    if not models_dir.is_dir():
        return {}
    return {p.stem.replace("_inference", ""): p for p in sorted(models_dir.glob("*_inference.joblib"))}


_bundle_cache: dict[Path, dict] = {}


def load_bundle(path: Path) -> dict:
    """Cached by path (immutable once written)."""
    if path not in _bundle_cache:
        _bundle_cache[path] = joblib.load(path)
    return _bundle_cache[path]


def add_wv_bin(df: pd.DataFrame) -> pd.DataFrame:
    """Port of test_main_binary.ipynb's add_wv_bin(): 0 if <2, 2 if >3, else 1."""
    df = df.copy()
    df["WV_bin"] = df["WV_MeanPressure"].apply(
        lambda p: np.nan if pd.isna(p) else (0 if p < 2 else (2 if p > 3 else 1))
    )
    return df


def prepare_for_inference(df: pd.DataFrame) -> pd.DataFrame:
    """Port of load_and_prepare_monorail() + remove_label_columns(): add
    WV_bin, drop any label columns that shouldn't be visible at inference
    time (matches the notebook's own safety check)."""
    df = add_wv_bin(df)
    return df.drop(columns=[c for c in _LABEL_COLUMNS if c in df.columns])


def quality_filtered(df: pd.DataFrame) -> pd.DataFrame:
    """Port of test_main_binary.ipynb's df_wv1 filter: WV_bin==1 (the
    regime the model was trained on) & clean braking only."""
    return df.loc[
        df["Non_Standard_Braking"].eq(0)
        & df["BC_BadStart"].eq(0)
        & df["WV_bin"].eq(1)
    ]


def predict(bundle: dict, df: pd.DataFrame) -> pd.Series:
    """Runs bundle['pipeline'] over bundle['features']. Raises KeyError up
    front (not deep inside sklearn) if a required feature is missing."""
    missing = [f for f in bundle["features"] if f not in df.columns]
    if missing:
        raise KeyError(f"Input data is missing required model features: {missing}")
    X = df[bundle["features"]]
    return pd.Series(bundle["pipeline"].predict(X), index=df.index)


def compute_far_by_wagon_type() -> list[dict]:
    """Exact port of test_main_binary.ipynb's FAR-by-wagon-type table:
    every finished model scored against the real generalization-test kits,
    grouped by wagon type, with ground truth assumed healthy (this is
    in-service field data with no known faults -- a "1" prediction here is
    a false alarm by construction, same assumption the thesis notebook
    makes)."""
    frames = []
    for kit_id in GENERALIZATION_TEST_KITS:
        try:
            df = data_store.load_kit_table(kit_id)
        except FileNotFoundError:
            continue
        df["WagonType"] = wagon_type_for_kit(kit_id)
        frames.append(df)
    if not frames:
        return []

    df_test = pd.concat(frames, ignore_index=True)
    df_test = prepare_for_inference(df_test)
    df_wv1 = quality_filtered(df_test)

    rows = []
    for model_name, bundle_path in list_finished_bundles().items():
        bundle = load_bundle(bundle_path)
        missing = [f for f in bundle["features"] if f not in df_wv1.columns]
        if missing:
            continue
        y_pred = bundle["pipeline"].predict(df_wv1[bundle["features"]])
        df_res = df_wv1.assign(Prediction=y_pred)
        for wagon, df_w in df_res.groupby("WagonType"):
            fp = int((df_w["Prediction"] == 1).sum())
            n = len(df_w)
            rows.append({
                "Model": model_name,
                "WagonType": wagon,
                "FP": fp,
                "TN": n - fp,
                "TotalSamples": n,
                "FalseAlarmRate_pct": round(100 * fp / n, 2) if n > 0 else None,
            })
    return sorted(rows, key=lambda r: (r["WagonType"], r["FalseAlarmRate_pct"] or 0))


_active_model_cache: Optional[str] = None


def _pick_active_model() -> Optional[str]:
    """Model with the lowest mean False Alarm Rate across wagon types, from
    compute_far_by_wagon_type(). Cached for the process lifetime -- the
    underlying real CSVs don't change at runtime."""
    global _active_model_cache
    if _active_model_cache is not None:
        return _active_model_cache

    far_rows = compute_far_by_wagon_type()
    if not far_rows:
        bundles = list_finished_bundles()
        _active_model_cache = next(iter(bundles), None)
        return _active_model_cache

    far_df = pd.DataFrame(far_rows)
    mean_far = far_df.groupby("Model")["FalseAlarmRate_pct"].mean()
    _active_model_cache = mean_far.idxmin()
    return _active_model_cache


def get_active_bundle() -> Optional[dict]:
    model_name = _pick_active_model()
    bundles = list_finished_bundles()
    if model_name is None or model_name not in bundles:
        return None
    return load_bundle(bundles[model_name])


def predict_for_dashboard(bundle: dict, df: pd.DataFrame) -> pd.Series:
    """predict(), but through the same prep AND quality filter real
    inference goes through (prepare_for_inference + quality_filtered:
    WV_bin==1, clean braking only). This matters, not just for consistency
    with compute_far_by_wagon_type(): most individual rows are one of a
    phase's 2-3 candidate BC/WV pairings that didn't turn out to be the
    real one (a structural artifact of how Stage 2 emits one row per
    candidate pairing, not a data-quality problem) -- scoring those with
    the model anyway produces a technically-computable but out-of-regime
    prediction. Rows outside the regime, or missing a required feature,
    score as NaN (not dropped, so the caller can still align by index) --
    dashboard event lists intentionally show every event, not just the
    clean-regime subset, with NaN reading as "not applicable" there."""
    prepared = quality_filtered(prepare_for_inference(df))
    result = pd.Series(np.nan, index=df.index)
    scorable = prepared.dropna(subset=bundle["features"])
    if scorable.empty:
        return result
    preds = bundle["pipeline"].predict(scorable[bundle["features"]])
    result.loc[scorable.index] = preds
    return result


def model_diagnostics() -> Optional[dict]:
    model_name = _pick_active_model()
    bundles = list_finished_bundles()
    if model_name is None or model_name not in bundles:
        return None
    bundle_path = bundles[model_name]

    meta_path = bundle_path.with_name(bundle_path.name.replace("_inference.joblib", "_meta.json"))
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.is_file() else {}

    return {
        "bundle_path": str(bundle_path),
        "model_name": model_name,
        "features": meta.get("features") or load_bundle(bundle_path).get("features"),
        "far_by_wagon_type": compute_far_by_wagon_type(),
    }
