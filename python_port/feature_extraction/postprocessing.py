"""Port of matlab/main/Algorithm_main_batch.m's post-processing block
(the "Phase Classification Post Processing" section, running after
`detect_subphases_sets`): per-phase error flags, power/energy efficiency
ratios, power/pressure delays, then the `keepFields` column whitelist and
flat feature-table construction with `RunFile`/`RunFolder` metadata.

`compute_derived_fields()` operates on `test_brake_sets` (a
`list[list[dict]]`, i.e. `detect_subphases_sets`'s output) in place.
`build_feature_table()` flattens it into one `pandas.DataFrame`, one row
per phase per pair, matching MATLAB's `horzcat` + sort-by-
`Start_brake_time_pipe` + `keepFields` column selection.

Deviations from the MATLAB source (documented, not silent):
  - Every field this module reads is a plain scalar (or an already-1-D
    array) in this port's per-phase dict schema -- never the
    generically-array-shaped values MATLAB's `isscalar`/elementwise-NaN-
    masking code defends against. This port drops that array-generality
    accordingly (see `_safe_ratio`/`_ieee_div` docstrings).
  - MATLAB's struct-array auto-homogenization (assigning a new field to
    one element of a struct array backfills `[]` onto every other element
    automatically) has no Python equivalent for a plain `dict`. Rather
    than replicate it explicitly, `build_feature_table()` reindexes every
    phase dict against `KEEP_FIELDS` with `.get(field, None)`, which
    produces the same net effect: any phase whose detector guard path
    skipped a given field gets `None`/NaN there instead of a `KeyError`.
"""
from __future__ import annotations

import math
import re
from pathlib import Path
from typing import Union

import numpy as np
import pandas as pd

KEEP_FIELDS = [
    "PhaseIdx", "MBP_ID", "BC_ID", "WV_ID", "GPS_NumSamples",
    "Start_brake_time_pipe", "End_brake_time_pipe", "Brake_timing_pipe", "Brake_energy_pipe", "Brake_power_pipe",
    "Start_buildup_time_pipe", "End_buildup_time_pipe", "Start_release_time_pipe", "End_release_time_pipe",
    "Buildup_timing_pipe", "Buildup_gradient_pipe", "Buildup_energy_pipe", "Buildup_power_pipe",
    "Holding_timing_pipe", "Holding_energy_pipe", "Holding_power_pipe",
    "Release_timing_pipe", "Release_gradient_pipe", "Release_energy_pipe", "Release_power_pipe",
    "Max_pressure_pipe", "Mean_pipe", "Std_pipe",
    "Start_brake_time_cyl", "End_brake_time_cyl", "Brake_timing_cyl", "Brake_energy_cyl", "Brake_power_cyl",
    "Buildup_timing_cyl", "Buildup_gradient_cyl", "Buildup_energy_cyl", "Buildup_power_cyl",
    "Holding_timing_cyl", "Holding_energy_cyl", "Holding_power_cyl",
    "Release_timing_cyl", "Release_gradient_cyl", "Release_energy_cyl", "Release_power_cyl",
    "WV_MeanPressure", "BC_MaxPressure", "Max_pressure_cyl",
    "First_phase_error", "First_phase_timing", "First_phase_timing_half",
    "First_phase_half_time_ratio", "First_phase_first_gradient", "First_phase_mean_curvature",
    "First_phase_max_gradient", "First_phase_inflection_point", "First_phase_energy", "First_phase_power",
    "First_phase_timing_1hz", "First_phase_timing_half_1hz",
    "First_phase_half_time_ratio_1hz", "First_phase_first_gradient_1hz", "First_phase_mean_curvature_1hz",
    "First_phase_max_gradient_1hz", "First_phase_inflection_point_1hz", "First_phase_energy_1hz", "First_phase_power_1hz",
    "Start_brake_speed", "End_brake_speed", "Speed_difference", "Speed_gradient",
    "Consecutive_braking_pipe", "BC_BadStart", "BC_NormalBraking", "BC_LowBraking",
    "BC_StartAboveThresh", "BC_FlatStartNearZero", "BC_AlreadyEngagedStart", "BC_ReleasingAtStart",
    "Total_power_efficiency", "Total_EN_eff", "Power_ratio", "Energy_ratio",
    "Total_power_pipe", "Total_power_cyl", "EmergencyBrake_action",
    "Brake_power_delay", "Release_power_delay", "Total_power_delay",
    "Buildup_end_pressure_delay", "Release_start_pressure_delay",
    "Total_power_normalized", "Total_power_weighted",
    "Brake_action_cyl", "EmergencyBrake", "Non_Standard_Braking",
    "MBP_PhaseClassification_error", "BC_PhaseClassification_error",
    "MBP_braketiming_error", "BC_braketiming_error",
    "SV_Error", "UB_Error", "UR_Error", "DS_Error",
    "MBP_Sensor_error", "BC_SensorError", "WV_SensorError",
    "GPS_SensorError", "Gateway_VB_Error", "Gateway_CB_Error",
]


def _is_nan(x) -> bool:
    return x is None or (isinstance(x, float) and math.isnan(x))


def _safe_ratio(numerator, denominator) -> float:
    """Port of MATLAB's `X = A./B; if B==0, X=NaN` pattern (used for
    Brake/Release power and energy efficiency ratios). Every value in this
    schema is a plain scalar, so the source's `isscalar`/elementwise-NaN-
    masking branches (for when B could be an array) are dropped -- there's
    only ever the scalar case here."""
    if _is_nan(denominator) or denominator == 0:
        return float("nan")
    if _is_nan(numerator):
        return float("nan")
    return float(numerator) / float(denominator)


def _ieee_div(numerator, denominator) -> float:
    """Natural, unguarded division matching MATLAB's `./` semantics
    (0/0=nan, x/0=+-inf) -- used only where the source does not add its
    own explicit zero-denominator override."""
    n = float("nan") if _is_nan(numerator) else float(numerator)
    d = float("nan") if _is_nan(denominator) else float(denominator)
    return float(np.float64(n) / np.float64(d))


def _nan_safe_sum(a, b) -> float:
    """Port of the `bothNaN = isnan(A)&isnan(B); Az=A;Az(isnan)=0; ...;
    Total=Az+Bz; Total(bothNaN)=NaN` pattern: NaN only if *both* inputs
    are NaN, otherwise treat a NaN input as 0."""
    a_nan, b_nan = _is_nan(a), _is_nan(b)
    if a_nan and b_nan:
        return float("nan")
    return (0.0 if a_nan else float(a)) + (0.0 if b_nan else float(b))


def compute_derived_fields(test_brake_sets: list) -> list:
    """Adds error flags, efficiency ratios, and delay fields to every
    phase dict in `test_brake_sets`, in place. Returns the same list."""
    for cell in test_brake_sets:
        if not cell:
            continue
        for phase in cell:
            # ---- error flags ----
            init_pressure = phase.get("InitPressure")
            phase["MBP_Sensor_error"] = int((not _is_nan(init_pressure)) and init_pressure <= 0)

            mbp_pc_err = 0
            for f in ("Brake_timing_pipe", "Release_timing_pipe"):
                v = phase.get(f)
                if v is not None and (math.isnan(v) or v < 0.001):
                    mbp_pc_err = 1
            phase["MBP_PhaseClassification_error"] = mbp_pc_err

            bc_pc_err = 0
            for f in ("Brake_timing_cyl", "Release_timing_cyl"):
                v = phase.get(f)
                if v is not None and (math.isnan(v) or v < 0.001):
                    bc_pc_err = 1
            phase["BC_PhaseClassification_error"] = bc_pc_err

            mbp_bt_err = 0
            for f in ("Brake_timing_pipe", "Release_timing_pipe"):
                v = phase.get(f)
                if v is not None and not math.isnan(v) and v > 200:
                    mbp_bt_err = 1
            phase["MBP_braketiming_error"] = mbp_bt_err

            bc_bt_err = 0
            for f in ("Brake_timing_cyl", "Release_timing_cyl"):
                v = phase.get(f)
                if v is not None and not math.isnan(v) and v > 200:
                    bc_bt_err = 1
            phase["BC_braketiming_error"] = bc_bt_err

            # ---- GPS_Time_shifted: source adds "+ hours(0)", a documented no-op ----
            gps_time = phase.get("GPS_Time")
            phase["GPS_Time_shifted"] = gps_time if gps_time is not None and len(gps_time) > 0 else None

            # ---- power efficiencies ----
            bpe = _safe_ratio(phase.get("Brake_power_cyl"), phase.get("Brake_power_pipe"))
            phase["Brake_Power_eff"] = bpe
            rpe = _safe_ratio(phase.get("Release_power_cyl"), phase.get("Release_power_pipe"))
            phase["Release_power_eff"] = rpe
            total_power_efficiency = _nan_safe_sum(bpe, rpe)
            phase["Total_power_efficiency"] = total_power_efficiency

            if not _is_nan(total_power_efficiency):
                phase["Total_power_normalized"] = total_power_efficiency * _ieee_div(
                    phase.get("Max_pressure_cyl"), phase.get("Max_pressure_pipe")
                )
                wv_mean = phase.get("WV_MeanPressure")
                phase["Total_power_weighted"] = (
                    phase["Total_power_normalized"] / wv_mean if not _is_nan(wv_mean) else float("nan")
                )
            else:
                phase["Total_power_normalized"] = float("nan")
                phase["Total_power_weighted"] = float("nan")

            # ---- energy efficiencies ----
            bee = _safe_ratio(phase.get("Brake_energy_cyl"), phase.get("Brake_energy_pipe"))
            phase["Brake_energy_eff"] = bee
            ree = _safe_ratio(phase.get("Release_energy_cyl"), phase.get("Release_energy_pipe"))
            phase["Release_energy_eff"] = ree
            phase["Total_EN_eff"] = _nan_safe_sum(bee, ree)

            # ---- power/energy ratios (pre-guard: 0 denominator -> NaN, then natural divide) ----
            power_mbp = phase.get("Total_power_pipe")
            power_mbp = float("nan") if (_is_nan(power_mbp) or power_mbp == 0) else power_mbp
            energy_mbp = phase.get("Total_energy_pipe")
            energy_mbp = float("nan") if (_is_nan(energy_mbp) or energy_mbp == 0) else energy_mbp
            phase["Power_ratio"] = _ieee_div(phase.get("Total_power_cyl"), power_mbp)
            phase["Energy_ratio"] = _ieee_div(phase.get("Total_energy_cyl"), energy_mbp)

            # ---- power delays (plain subtraction/addition; NaN propagates naturally) ----
            bpc, bpp = phase.get("Brake_power_cyl"), phase.get("Brake_power_pipe")
            phase["Brake_power_delay"] = float("nan") if (_is_nan(bpc) or _is_nan(bpp)) else bpc - bpp
            rpc, rpp = phase.get("Release_power_cyl"), phase.get("Release_power_pipe")
            phase["Release_power_delay"] = float("nan") if (_is_nan(rpc) or _is_nan(rpp)) else rpc - rpp
            bpd, rpd = phase["Brake_power_delay"], phase["Release_power_delay"]
            phase["Total_power_delay"] = float("nan") if (_is_nan(bpd) or _is_nan(rpd)) else bpd + rpd

            # ---- pressure delays ----
            bpc_arr, bpp_arr = phase.get("Buildup_pressure_cyl"), phase.get("Buildup_pressure_pipe")
            if bpc_arr is not None and bpp_arr is not None and len(bpc_arr) and len(bpp_arr):
                phase["Buildup_end_pressure_delay"] = float(bpc_arr[-1] - bpp_arr[-1])
            else:
                phase["Buildup_end_pressure_delay"] = float("nan")

            rpc_arr, rpp_arr = phase.get("Release_pressure_cyl"), phase.get("Release_pressure_pipe")
            if rpc_arr is not None and rpp_arr is not None and len(rpc_arr) and len(rpp_arr):
                phase["Release_start_pressure_delay"] = float(rpc_arr[0] - rpp_arr[0])
            else:
                phase["Release_start_pressure_delay"] = float("nan")

    return test_brake_sets


def _derive_run_file_folder(file: Union[str, Path]) -> tuple:
    """Port of the RunFile/RunFolder derivation at the end of
    Algorithm_main_batch.m's per-file loop."""
    file = Path(file)
    run_file = file.name  # base + ext, e.g. "Nodo_Dati10_20250616_20250618.pkl"
    m = re.search(r"Nodo_(Dati\d+)_", file.stem)
    if m:
        run_folder = m.group(1)
    else:
        m2 = re.search(r"(Dati\d+)", str(file.parent))
        run_folder = m2.group(1) if m2 else "Unknown"
    return run_file, run_folder


def build_feature_table(test_brake_sets: list, file: Union[str, Path]) -> pd.DataFrame:
    """Flattens test_brake_sets into one table: KEEP_FIELDS columns only,
    one row per phase per pair, sorted by Start_brake_time_pipe ascending
    (NaT last, matching MATLAB's default sort), with RunFile/RunFolder
    attached."""
    rows = [
        {field: phase.get(field, None) for field in KEEP_FIELDS}
        for cell in test_brake_sets if cell
        for phase in cell
    ]

    table = pd.DataFrame(rows, columns=KEEP_FIELDS)
    if len(table):
        table["Start_brake_time_pipe"] = pd.to_datetime(table["Start_brake_time_pipe"])
        table = table.sort_values(
            "Start_brake_time_pipe", na_position="last", kind="stable"
        ).reset_index(drop=True)

    run_file, run_folder = _derive_run_file_folder(file)
    table["RunFile"] = run_file
    table["RunFolder"] = run_folder
    return table
