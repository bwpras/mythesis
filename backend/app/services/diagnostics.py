"""Fleet health summary per kit: airbrake system health (sensor errors,
non-standard braking, predicted leakage) and GPS health (sensor coverage),
plus last-known GPS location for a map view.

Sensor-error and GPS-error rates are computed over the same quality-filtered
regime predict.py's compute_far_by_wagon_type() scores against (WV_bin==1,
Non_Standard_Braking==0, BC_BadStart==0) -- NOT the raw per-row rate. Stage 2
emits one row per phase per *candidate* BC/WV pairing (2-3 candidates per
phase), and only one candidate is ever the real pairing; the others
structurally show sensor errors by construction, inflating a raw-row error
rate to 65-97% for every kit regardless of actual health. Filtering first
removes that artifact and leaves a rate that actually discriminates.

Status thresholds below are illustrative defaults for a monitoring
dashboard, not validated engineering limits -- there's no domain-specified
threshold in the thesis data for "this many sensor errors means warning
vs. critical." Documented here so they're easy to find and tune.
"""
from __future__ import annotations

import math

from . import data_store, predict
from .wagon_type import wagon_type_for_kit

AIRBRAKE_WARNING_SENSOR_ERROR_PCT = 15.0
AIRBRAKE_CRITICAL_SENSOR_ERROR_PCT = 35.0
AIRBRAKE_WARNING_LEAKAGE_PCT = 5.0
AIRBRAKE_CRITICAL_LEAKAGE_PCT = 20.0

GPS_WARNING_ERROR_PCT = 40.0
GPS_CRITICAL_ERROR_PCT = 70.0


def _status(value: float, warning: float, critical: float) -> str:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "unknown"
    if value >= critical:
        return "critical"
    if value >= warning:
        return "warning"
    return "healthy"


def _worse(a: str, b: str) -> str:
    order = {"healthy": 0, "unknown": 1, "warning": 2, "critical": 3}
    return a if order[a] >= order[b] else b


def _pct(count: int, total: int) -> float:
    return round(100 * count / total, 2) if total else float("nan")


def kit_diagnostics(kit_id: str) -> dict:
    df = data_store.load_kit_table(kit_id)
    n = len(df)

    # The quality-filtered regime: one row per phase (the real pairing),
    # not per candidate. This is what sensor/GPS error rates below are
    # computed over -- see module docstring.
    regime = predict.quality_filtered(predict.add_wv_bin(df))
    n_regime = len(regime)

    non_standard = df["Non_Standard_Braking"].fillna(0).astype(int)
    non_standard_pct = _pct(int(non_standard.sum()), n)

    if n_regime:
        sensor_error = (
            regime[["MBP_Sensor_error", "BC_SensorError", "WV_SensorError"]]
            .fillna(0).astype(int).any(axis=1)
        )
        sensor_error_pct = _pct(int(sensor_error.sum()), n_regime)
    else:
        sensor_error_pct = None

    predicted_leakage_pct = None
    bundle = predict.get_active_bundle()
    if bundle is not None:
        try:
            preds = predict.predict_for_dashboard(bundle, df)
            scored = preds.dropna()
            if len(scored):
                predicted_leakage_pct = _pct(int((scored == 1).sum()), len(scored))
        except KeyError:
            pass

    airbrake_status = _status(sensor_error_pct, AIRBRAKE_WARNING_SENSOR_ERROR_PCT, AIRBRAKE_CRITICAL_SENSOR_ERROR_PCT)
    if predicted_leakage_pct is not None:
        airbrake_status = _worse(
            airbrake_status,
            _status(predicted_leakage_pct, AIRBRAKE_WARNING_LEAKAGE_PCT, AIRBRAKE_CRITICAL_LEAKAGE_PCT),
        )

    if n_regime and "GPS_SensorError" in regime.columns:
        gps_error_pct = _pct(int(regime["GPS_SensorError"].fillna(0).astype(int).sum()), n_regime)
    else:
        gps_error_pct = None
    gps_status = (
        _status(gps_error_pct, GPS_WARNING_ERROR_PCT, GPS_CRITICAL_ERROR_PCT)
        if gps_error_pct is not None else "unknown"
    )

    last_location = None
    if "GPS_Lat_last" in df.columns and "GPS_Long_last" in df.columns:
        has_fix = data_store.valid_gps_fix(df)
        if len(has_fix):
            latest = has_fix.sort_values("Start_brake_time_pipe").iloc[-1]
            last_location = {
                "lat": float(latest["GPS_Lat_last"]),
                "lon": float(latest["GPS_Long_last"]),
                "time": str(latest["Start_brake_time_pipe"]),
            }

    return {
        "kit_id": kit_id,
        "wagon_type": wagon_type_for_kit(kit_id),
        "airbrake_health": {
            "status": airbrake_status,
            "non_standard_pct": non_standard_pct,
            "sensor_error_pct": sensor_error_pct,
            "predicted_leakage_pct": predicted_leakage_pct,
            # A model being active but predicted_leakage_pct still None
            # means every one of this kit's rows fell outside the model's
            # trained regime (WV_bin/BC_BadStart/Non_Standard_Braking) --
            # distinguishes that from "no model loaded at all" so the
            # dashboard can show "out of scope" instead of a bare dash.
            "model_active": bundle is not None,
        },
        "gps_health": {
            "status": gps_status,
            "gps_error_pct": gps_error_pct,
        },
        "last_location": last_location,
    }


def fleet_diagnostics() -> list[dict]:
    return [kit_diagnostics(kid) for kid in data_store.available_kit_ids()]
