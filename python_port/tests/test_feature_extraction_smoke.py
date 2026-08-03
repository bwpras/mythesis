"""Self-contained smoke tests for python_port/feature_extraction (Stage 2, slice 1:
causal filtering + detect_braking_struct_beta).

No real telemetry or MATLAB installation is required. filtering.py is checked
against an independently-written reference recursion (not just trusting the
vectorized cumsum/scipy implementation). braking_detection.py is checked
against a synthetic MBP+BC+WV Test with a hand-designed braking event, run
through the real filtering.py first (so the detector sees the same kind of
smoothed/lagged signal it would in production, not a raw step function).

This validates internal consistency of the port, NOT numerical agreement
with real MATLAB output (there is no reference file or running MATLAB to
diff against in this environment).

Run directly:  python python_port/tests/test_feature_extraction_smoke.py
Or via pytest: pytest python_port/tests
"""
from __future__ import annotations

import math
import sys
import tempfile
import traceback
from pathlib import Path
from unittest import mock

import numpy as np
from scipy.signal import butter

_THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_THIS_DIR.parent.parent))  # repo root, for `python_port.*` imports

from python_port.feature_extraction.filtering import apply_causal_filters
from python_port.feature_extraction.braking_detection import detect_braking_struct_beta
from python_port.feature_extraction.pick_reference_phase import pick_reference_phase
from python_port.feature_extraction.collect_healthy_sensor_data import collect_healthy_sensor_data
from python_port.feature_extraction.build_test_brake_sets import build_test_brake_sets
from python_port.feature_extraction.mbp_pipe_subphases import detect_mbp_pipe_subphases
from python_port.feature_extraction.bc_cyl_subphases import detect_bc_cyl_subphases
from python_port.feature_extraction.detect_subphases_sets import detect_subphases_sets
from python_port.feature_extraction.postprocessing import compute_derived_fields, build_feature_table, KEEP_FIELDS
from python_port.feature_extraction.csv_export import export_feature_csv
from python_port.paths import PortPaths

FS = 40.0
DT = 1.0 / FS


def _isolated_paths(tmp_dir: Path):
    """Patch python_port.paths.get_paths() so registry writes (project-root
    relative, independent of the input `file` path) resolve under the
    test's own tmp dir instead of the real project's data/interim/ --
    mirrors the same isolation already required for the label_registry
    tests in test_ingestion_smoke.py, applied here from the start."""
    fake = PortPaths(
        root=tmp_dir, raw=tmp_dir / "raw", interim=tmp_dir / "interim",
        processed=tmp_dir / "processed", external=tmp_dir / "external",
        features=tmp_dir / "features", figures=tmp_dir / "figures",
        models=tmp_dir / "models", reports=tmp_dir / "reports", logs=tmp_dir / "logs",
    )
    return mock.patch("python_port.paths.get_paths", return_value=fake)


def _reference_causal_filters(pressure: np.ndarray, fs: float = 40.0) -> dict:
    """Independent, non-vectorized reference implementation, transcribed
    directly from Algorithm_main_batch.m's explicit circular-buffer loop
    (not from feature_extraction.filtering's cumsum-based implementation),
    used to cross-check that the vectorized port is numerically equivalent.
    """
    n = len(pressure)
    dt = 1.0 / fs
    window_size = 20
    window_grad = 20
    b, a = butter(1, 1.0 / (fs / 2))
    window_size_buildup = 5
    b10, a10 = butter(1, 10.0 / (fs / 2))

    pressure_mean_filter = np.zeros(n)
    pressure_filter = np.zeros(n)
    gradient_pressure = np.zeros(n)
    gradient_pressure_filtered = np.zeros(n)
    pressure_filter_10hz = np.zeros(n)

    buf = np.zeros(window_size)
    buf_idx = 0
    moving_sum = 0.0
    buf_grad = np.zeros(window_grad)
    buf_grad_idx = 0
    moving_sum_grad = 0.0
    buf10 = np.zeros(window_size_buildup)
    buf10_idx = 0
    moving_sum10 = 0.0
    prev_mean10 = 0.0

    for c1 in range(n):
        new_val = pressure[c1]
        moving_sum = moving_sum - buf[buf_idx] + new_val
        buf[buf_idx] = new_val
        buf_idx = (buf_idx + 1) % window_size
        pressure_mean_filter[c1] = moving_sum / min(c1 + 1, window_size)

        if c1 == 0:
            pressure_filter[c1] = b[0] * pressure_mean_filter[c1]
        else:
            pressure_filter[c1] = (b[0] * pressure_mean_filter[c1] + b[1] * pressure_mean_filter[c1 - 1]
                                    - a[1] * pressure_filter[c1 - 1])

        if c1 > 0:
            gradient_pressure[c1] = (pressure_filter[c1] - pressure_filter[c1 - 1]) / dt
        else:
            gradient_pressure[c1] = 0.0

        new_val_g = gradient_pressure[c1]
        moving_sum_grad = moving_sum_grad - buf_grad[buf_grad_idx] + new_val_g
        buf_grad[buf_grad_idx] = new_val_g
        buf_grad_idx = (buf_grad_idx + 1) % window_grad
        gradient_pressure_filtered[c1] = moving_sum_grad / min(c1 + 1, window_grad)

        new_val10 = pressure[c1]
        moving_sum10 = moving_sum10 - buf10[buf10_idx] + new_val10
        buf10[buf10_idx] = new_val10
        buf10_idx = (buf10_idx + 1) % window_size_buildup
        mean10 = moving_sum10 / min(c1 + 1, window_size_buildup)

        if c1 == 0:
            pressure_filter_10hz[c1] = b10[0] * mean10
        else:
            pressure_filter_10hz[c1] = b10[0] * mean10 + b10[1] * prev_mean10 - a10[1] * pressure_filter_10hz[c1 - 1]
        prev_mean10 = mean10

    return {
        "pressure_mean_filter": pressure_mean_filter,
        "pressure_filter": pressure_filter,
        "gradient_pressure": gradient_pressure,
        "gradient_pressure_filtered": gradient_pressure_filtered,
        "pressure_filter_10hz": pressure_filter_10hz,
    }


def test_filtering_matches_independent_reference_recursion():
    rng = np.random.default_rng(42)
    n = 300
    # Step + noise, to exercise both the cold-start and warm-up-divisor paths.
    pressure = np.concatenate([np.full(100, 2.0), np.full(200, 5.0)]) + rng.normal(0, 0.01, n)

    got = apply_causal_filters(pressure, fs=FS)
    ref = _reference_causal_filters(pressure, fs=FS)

    assert np.allclose(got.pressure_mean_filter, ref["pressure_mean_filter"], atol=1e-9)
    assert np.allclose(got.pressure_filter, ref["pressure_filter"], atol=1e-9)
    assert np.allclose(got.gradient_pressure, ref["gradient_pressure"], atol=1e-9)
    assert np.allclose(got.gradient_pressure_filtered, ref["gradient_pressure_filtered"], atol=1e-9)
    assert np.allclose(got.pressure_filter_10hz, ref["pressure_filter_10hz"], atol=1e-9)


def test_filtering_cold_start_and_warmup_divisor():
    """Sample 0 of the moving average must equal the raw sample itself
    (divisor min(1,window)=1), and the Butterworth stage's sample 0 must be
    b[0]*x[0] exactly (no b[1]*x[-1] or a[1]*y[-1] term)."""
    pressure = np.array([3.0, 3.0, 3.0, 3.0, 3.0])
    got = apply_causal_filters(pressure, fs=FS)
    assert got.pressure_mean_filter[0] == 3.0
    b, _ = butter(1, 1.0 / (FS / 2))
    assert abs(got.pressure_filter[0] - b[0] * 3.0) < 1e-12


def test_filtering_empty_input():
    got = apply_causal_filters(np.zeros(0), fs=FS)
    assert len(got.pressure_filter) == 0
    assert len(got.gradient_pressure_filtered) == 0


# ---------------------------------------------------------------------------
# detect_braking_struct_beta: synthetic Test channels
# ---------------------------------------------------------------------------


def _make_time(n: int) -> np.ndarray:
    t0 = np.datetime64("2026-01-01T00:00:00.000000")
    return t0 + (np.arange(n) * (DT * 1e6)).astype("int64").astype("timedelta64[us]")


def _make_channel(label: str, ident: str, time: np.ndarray, pressure: np.ndarray) -> dict:
    filt = apply_causal_filters(pressure, fs=FS)
    return {
        "Label": label,
        "ID": ident,
        "Time": time,
        "Pressure_filter": filt.pressure_filter,
        "Pressure_filter_10Hz": filt.pressure_filter_10hz,
        "Gradient_pressure_filtered": filt.gradient_pressure_filtered,
    }


def _mbp_profile_with_one_braking_event() -> np.ndarray:
    """3s flat at 5.0 bar -> 3s ramp down to 3.0 bar -> 2s hold -> 2s ramp
    back up to 5.0 bar -> 5s flat. Calibrated (see scratch calibration) to
    produce exactly one committed phase with InitPressure ~4.97 bar and a
    total drop ~1.97 bar, comfortably clearing every relevant threshold
    (MBP_Lower=4.7, InitGrad_Thresh=-0.05, Min_P_drop=0.2) with margin, and
    with a sustained negative gradient spanning the control-window's
    [2s, 6s] post-onset activation range so the phase is not discarded by
    the control-window guard.
    """
    n_base, n_down, n_hold, n_up, n_tail = (int(s * FS) for s in (3.0, 3.0, 2.0, 2.0, 5.0))
    return np.concatenate([
        np.full(n_base, 5.0),
        np.linspace(5.0, 3.0, n_down),
        np.full(n_hold, 3.0),
        np.linspace(3.0, 5.0, n_up),
        np.full(n_tail, 5.0),
    ])


def _bc_profile_matching_braking_event(n: int) -> np.ndarray:
    """Brake-cylinder response: near-zero baseline, rises to 3.5 bar during
    the MBP hold, falls back -- mirrors real BC behavior so the detector's
    BC anomaly checks (flat-start/already-engaged/etc) don't spuriously fire."""
    p = np.full(n, 0.02)
    n_base, n_down, n_hold, n_up = (int(s * FS) for s in (3.0, 3.0, 2.0, 2.0))
    p[n_base : n_base + n_down] = np.linspace(0.02, 3.5, n_down)
    p[n_base + n_down : n_base + n_down + n_hold] = 3.5
    p[n_base + n_down + n_hold : n_base + n_down + n_hold + n_up] = np.linspace(3.5, 0.02, n_up)
    return p


def _build_test(mbp_pressure: np.ndarray) -> list:
    """Full scenario with a realistic BC buildup profile matching
    _mbp_profile_with_one_braking_event()'s specific timing -- only valid
    for that profile's length; use _build_simple_test for other MBP shapes."""
    n = len(mbp_pressure)
    time = _make_time(n)
    mbp = _make_channel("MBP", "0xAAAA", time, mbp_pressure)
    bc = _make_channel("BC1", "0xBBBB", time, _bc_profile_matching_braking_event(n))
    wv = _make_channel("WV1", "0xCCCC", time, np.full(n, 2.5))
    return [mbp, bc, wv]


def _build_simple_test(mbp_pressure: np.ndarray) -> list:
    """Any-length scenario with flat BC/WV -- for tests that only care about
    the MBP accept/reject state machine, not BC/WV commit-field correctness."""
    n = len(mbp_pressure)
    time = _make_time(n)
    mbp = _make_channel("MBP", "0xAAAA", time, mbp_pressure)
    bc = _make_channel("BC1", "0xBBBB", time, np.full(n, 0.02))
    wv = _make_channel("WV1", "0xCCCC", time, np.full(n, 2.5))
    return [mbp, bc, wv]


def test_detects_one_braking_phase_with_sane_commit_fields():
    test = _build_test(_mbp_profile_with_one_braking_event())
    test_brake, bc_indices, wv_indices = detect_braking_struct_beta(test, verbose=False)

    assert bc_indices == [1]
    assert wv_indices == [2]
    assert len(test_brake) == 1, f"expected exactly 1 phase, got {len(test_brake)}"

    ph = test_brake[0]
    assert 4.9 < ph["InitPressure"] < 5.0
    total_drop = ph["InitPressure"] - float(ph["MBP_Pressure"].min())
    assert total_drop > 0.2, "the whole point of this scenario is a drop that clears Min_P_drop"
    assert ph["SV_Error"] is False and ph["UP_Error"] is False
    assert ph["MBP_ID"] == "0xAAAA"
    assert ph["PhaseIdx"] == 1

    assert len(ph["BC"]) == 1
    bc = ph["BC"][0]
    assert bc["SensorError"] is False, "a realistic BC buildup profile must not trip the anomaly checks"
    assert bc["NormalBraking"] is True
    assert bc["MaxPressure"] > 3.0

    assert len(ph["WV"]) == 1
    wv = ph["WV"][0]
    assert wv["WV_SensorError"] is False
    assert wv["MeanPressure"] == 2.5
    assert wv["NumSamples"] > 0


def test_sub_threshold_drop_is_rejected():
    """A dip that recovers before totalDrop reaches Min_P_drop (0.2 bar)
    must not be committed as a phase."""
    n_base, n_down, n_hold, n_up, n_tail = (int(s * FS) for s in (3.0, 0.5, 0.3, 0.5, 3.0))
    mbp_pressure = np.concatenate([
        np.full(n_base, 5.0),
        np.linspace(5.0, 4.85, n_down),  # only a 0.15 bar dip
        np.full(n_hold, 4.85),
        np.linspace(4.85, 5.0, n_up),
        np.full(n_tail, 5.0),
    ])
    test = _build_simple_test(mbp_pressure)
    test_brake, _, _ = detect_braking_struct_beta(test, verbose=False)
    assert test_brake == [], f"expected the sub-threshold dip to be rejected, got {len(test_brake)} phase(s)"


def test_control_window_discards_spurious_flat_onset():
    """An onset trigger followed by a long flat plateau (no further negative
    gradient within the control window's active range) must be discarded,
    not committed -- this is the guard against false onsets from noise."""
    n_base, n_down, n_plateau = int(3.0 * FS), int(0.3 * FS), int(10.0 * FS)
    mbp_pressure = np.concatenate([
        np.full(n_base, 5.0),
        np.linspace(5.0, 4.8, n_down),
        np.full(n_plateau, 4.8),
    ])
    test = _build_simple_test(mbp_pressure)
    test_brake, _, _ = detect_braking_struct_beta(test, verbose=False)
    assert test_brake == [], f"expected the flat-plateau onset to be discarded, got {len(test_brake)} phase(s)"


def test_missing_mbp_channel_raises():
    n = 100
    time = _make_time(n)
    bc = _make_channel("BC1", "0xBBBB", time, np.full(n, 0.02))
    try:
        detect_braking_struct_beta([bc], verbose=False)
        assert False, "expected ValueError for missing MBP channel"
    except ValueError as exc:
        assert "MBP" in str(exc)


def test_bc_wv_label_matching_is_case_insensitive_and_prefix_based():
    n = 50
    time = _make_time(n)
    mbp = _make_channel("mbp", "0xAAAA", time, np.full(n, 5.0))  # lowercase, must still match
    bc = _make_channel("bc_extra", "0xBBBB", time, np.full(n, 0.02))  # prefix match, not exact
    wv2 = _make_channel("WV02", "0xCCCC", time, np.full(n, 2.5))
    _, bc_indices, wv_indices = detect_braking_struct_beta([mbp, bc, wv2], verbose=False)
    assert bc_indices == [1]
    assert wv_indices == [2]


# ---------------------------------------------------------------------------
# pick_reference_phase / collect_healthy_sensor_data: hand-built TestBrake
# fixtures (these two modules only read TestBrake dicts, no signal
# processing, so precise fixtures are more direct than running the full
# detector).
# ---------------------------------------------------------------------------


def _make_bc_entry(ident, *, sensor_error=False, normal_braking=True, max_pressure=3.5, label="BC1"):
    return {
        "Label": label, "ID": ident, "Time": np.arange(5), "Pressure": np.arange(5, dtype=float),
        "SensorError": sensor_error, "NormalBraking": normal_braking, "MaxPressure": max_pressure,
    }


def _make_wv_entry(ident, *, wv_sensor_error=False, num_samples=5, mean_pressure=2.5, label="WV1"):
    return {
        "Label": label, "ID": ident, "Time": np.arange(5), "Pressure": np.arange(5, dtype=float),
        "WV_SensorError": wv_sensor_error, "NumSamples": num_samples, "MeanPressure": mean_pressure,
    }


def _make_phase(phase_idx, start_time, *, n_mbp=20, bc=None, wv=None,
                 sv_error=False, up_error=False, emergency_brake=False, mbp_id="0xAAAA"):
    return {
        "PhaseIdx": phase_idx,
        "MBP_ID": mbp_id,
        "MBP_StartTime": start_time,
        "MBP_Time": np.arange(n_mbp),
        "MBP_Pressure": np.arange(n_mbp, dtype=float),
        "BC": bc or [],
        "WV": wv or [],
        "SV_Error": sv_error,
        "UP_Error": up_error,
        "EmergencyBrake": emergency_brake,
    }


def test_pick_reference_phase_selects_clean_highest_scoring_phase():
    t0 = np.datetime64("2026-01-01T00:00:00")
    phases = [
        _make_phase(1, t0, bc=[_make_bc_entry("0xB1"), _make_bc_entry("0xB2")],
                    wv=[_make_wv_entry("0xW1"), _make_wv_entry("0xW2")]),  # clean -> score 100
        _make_phase(2, t0 + np.timedelta64(1, "m"),
                    bc=[_make_bc_entry("0xB1"), _make_bc_entry("0xB2")],
                    wv=[_make_wv_entry("0xW1"), _make_wv_entry("0xW2")],
                    sv_error=True),  # eligible but has an error flag -> score 90
        _make_phase(3, t0 + np.timedelta64(2, "m"),
                    bc=[_make_bc_entry("0xB1"), _make_bc_entry("0xB2", normal_braking=False)],
                    wv=[_make_wv_entry("0xW1"), _make_wv_entry("0xW2")]),  # one BC not "normal braking" -> ineligible
    ]
    ref_phase, scores, report = pick_reference_phase(phases)
    assert ref_phase == 1, f"expected phase 1 (highest clean score), got {ref_phase}"
    assert scores[0] == 100
    assert scores[1] == 90
    assert scores[2] == -math.inf
    assert report[2]["BC_OK"] is False


def test_pick_reference_phase_returns_none_when_nothing_eligible():
    t0 = np.datetime64("2026-01-01T00:00:00")
    phases = [_make_phase(1, t0, n_mbp=5)]  # < 10 samples -> MBP_OK False
    ref_phase, scores, _ = pick_reference_phase(phases)
    assert ref_phase is None
    assert scores == [-math.inf]


def test_pick_reference_phase_empty_input():
    ref_phase, scores, report = pick_reference_phase([])
    assert ref_phase is None
    assert scores == []
    assert report == []


def test_collect_healthy_sensor_data_gathers_unique_sensors_across_phases():
    t0 = np.datetime64("2026-01-01T00:00:00")
    # Two phases within the default 2h window; together they cover 2 distinct
    # BC IDs and 2 distinct WV IDs -- quotas should be met by phase 2.
    phases = [
        _make_phase(1, t0, bc=[_make_bc_entry("0xB1")], wv=[_make_wv_entry("0xW1")]),
        _make_phase(2, t0 + np.timedelta64(10, "m"),
                    bc=[_make_bc_entry("0xB1"), _make_bc_entry("0xB2")],
                    wv=[_make_wv_entry("0xW1"), _make_wv_entry("0xW2")]),
    ]
    usable = collect_healthy_sensor_data(phases, num_bc_expected=2, num_wv_expected=2)
    assert usable["TimeWindowOK"] is True
    assert set(usable["PickedBC_IDs"]) == {"0xB1", "0xB2"}
    assert set(usable["PickedWV_IDs"]) == {"0xW1", "0xW2"}
    assert usable["MBP_ID"] == "0xAAAA"
    # 0xB1 must have been picked from phase 1 (first time it appears healthy), not phase 2
    b1 = next(e for e in usable["BC"] if e["ID"] == "0xB1")
    assert b1["FromPhaseIdx"] == 1


def test_collect_healthy_sensor_data_unhealthy_sensors_excluded():
    t0 = np.datetime64("2026-01-01T00:00:00")
    phases = [
        _make_phase(1, t0,
                    bc=[_make_bc_entry("0xB1", sensor_error=True), _make_bc_entry("0xB2")],
                    wv=[_make_wv_entry("0xW1", wv_sensor_error=True), _make_wv_entry("0xW2")]),
    ]
    usable = collect_healthy_sensor_data(phases, num_bc_expected=1, num_wv_expected=1)
    assert usable["PickedBC_IDs"] == ["0xB2"]
    assert usable["PickedWV_IDs"] == ["0xW2"]


def test_collect_healthy_sensor_data_quota_not_met_returns_best_partial():
    t0 = np.datetime64("2026-01-01T00:00:00")
    phases = [_make_phase(1, t0, bc=[_make_bc_entry("0xB1")], wv=[_make_wv_entry("0xW1")])]
    usable = collect_healthy_sensor_data(phases, num_bc_expected=3, num_wv_expected=3)
    assert usable["TimeWindowOK"] is False
    assert usable["PickedBC_IDs"] == ["0xB1"]
    assert "Quotas not fully met" in usable["Note"]


def test_collect_healthy_sensor_data_outside_window_not_collected():
    t0 = np.datetime64("2026-01-01T00:00:00")
    phases = [
        _make_phase(1, t0, bc=[_make_bc_entry("0xB1")], wv=[_make_wv_entry("0xW1")]),
        # 3 hours later -- outside the default 2h window starting from phase 1
        _make_phase(2, t0 + np.timedelta64(3, "h"), bc=[_make_bc_entry("0xB2")], wv=[_make_wv_entry("0xW2")]),
    ]
    usable = collect_healthy_sensor_data(phases, num_bc_expected=2, num_wv_expected=2)
    # Neither window (starting at phase 1 or phase 2) can see both phases at once,
    # so the 2-sensor quota is never met from a single window.
    assert usable["TimeWindowOK"] is False


def test_collect_healthy_sensor_data_empty_test_brake_raises():
    try:
        collect_healthy_sensor_data([])
        assert False, "expected ValueError for empty TestBrake"
    except ValueError as exc:
        assert "empty" in str(exc).lower()


def test_collect_healthy_sensor_data_auto_detects_expected_counts():
    t0 = np.datetime64("2026-01-01T00:00:00")
    phases = [
        _make_phase(1, t0, bc=[_make_bc_entry("0xB1"), _make_bc_entry("0xB2")], wv=[_make_wv_entry("0xW1")]),
    ]
    # num_bc_expected/num_wv_expected omitted -> auto-detected as 2 and 1
    usable = collect_healthy_sensor_data(phases)
    assert usable["TimeWindowOK"] is True
    assert len(usable["PickedBC_IDs"]) == 2
    assert len(usable["PickedWV_IDs"]) == 1


# ---------------------------------------------------------------------------
# build_test_brake_sets: pairing + registry persistence
# ---------------------------------------------------------------------------


def _two_phase_test_brake():
    t0 = np.datetime64("2026-01-01T00:00:00")
    bc_hi = _make_bc_entry("0xB_HI", max_pressure=4.0)
    bc_lo = _make_bc_entry("0xB_LO", max_pressure=1.0)
    wv_hi = _make_wv_entry("0xW_HI", mean_pressure=3.0)
    wv_lo = _make_wv_entry("0xW_LO", mean_pressure=1.5)
    return [
        _make_phase(1, t0, bc=[bc_lo, bc_hi], wv=[wv_lo, wv_hi]),
        _make_phase(2, t0 + np.timedelta64(1, "m"), bc=[bc_lo, bc_hi], wv=[wv_lo, wv_hi]),
    ]


def test_build_test_brake_sets_reference_phase_pairing_ranks_by_pressure():
    test_brake = _two_phase_test_brake()
    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        sets, pair_table, dataset_key, reg_path, used_method = build_test_brake_sets(
            test_brake, roster={}, file="data/interim/Dati07/Nodo_Dati07_x.pkl",
            reference_phase_idx=1, verbose=False,
        )
        assert used_method == "reference"
        assert dataset_key == "Dati07"
        assert reg_path.is_file(), "registry should have been persisted"
        # 2 usable BC and 2 usable WV -> 2 pairs, ranked highest-with-highest,
        # lowest-with-lowest (positional rank pairing, matching the source).
        assert len(pair_table) == 2
        assert pair_table["BC_ID"].iloc[0] == "0xB_HI"
        assert pair_table["WV_ID"].iloc[0] == "0xW_HI"
        assert pair_table["BC_ID"].iloc[1] == "0xB_LO"
        assert pair_table["WV_ID"].iloc[1] == "0xW_LO"
        assert pair_table["UseReferencePhase"].iloc[0] == True  # noqa: E712
        assert pair_table["RefPhaseIdx"].iloc[0] == 1

        assert len(sets) == 2  # npairs
        assert len(sets[0]) == 2  # numPhases
        for phase_entry in sets[0]:
            assert phase_entry["BC_ID"] == "0xB_HI"
            assert phase_entry["WV_ID"] == "0xW_HI"
            assert phase_entry["BC_MaxPressure"] == 4.0
            assert phase_entry["WV_MeanPressure"] == 3.0
            assert phase_entry["PairIdx"] == 1


def test_build_test_brake_sets_locks_and_reuses_registry():
    test_brake = _two_phase_test_brake()
    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        _, pair_table1, _, reg_path, used_method1 = build_test_brake_sets(
            test_brake, roster={}, file="Nodo_Dati09.pkl", reference_phase_idx=1, verbose=False,
        )
        assert used_method1 == "reference"

        # Second call: different (invalid) reference_phase_idx, and no valid Roster --
        # must still succeed by reusing the locked registry, not attempt Roster pairing.
        _, pair_table2, _, _, used_method2 = build_test_brake_sets(
            test_brake, roster={}, file="Nodo_Dati09.pkl", reference_phase_idx=None, verbose=False,
        )
        assert used_method2 == "reference(saved)"
        assert pair_table2["BC_ID"].iloc[0] == pair_table1["BC_ID"].iloc[0]


def test_build_test_brake_sets_roster_pairing_when_no_reference_phase():
    test_brake = _two_phase_test_brake()
    roster = {
        "BC": [{"ID": "0xB_LO", "Label": "BC", "MaxPressure": 1.0},
               {"ID": "0xB_HI", "Label": "BC", "MaxPressure": 4.0}],
        "WV": [{"ID": "0xW_LO", "Label": "WV", "MeanPressure": 1.5},
               {"ID": "0xW_HI", "Label": "WV", "MeanPressure": 3.0}],
    }
    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        sets, pair_table, _, reg_path, used_method = build_test_brake_sets(
            test_brake, roster=roster, file="Nodo_Dati11.pkl", reference_phase_idx=None, verbose=False,
        )
        assert used_method == "roster"
        assert pair_table["BC_ID"].iloc[0] == "0xB_HI"
        assert pair_table["WV_ID"].iloc[0] == "0xW_HI"
        assert pair_table["UseReferencePhase"].iloc[0] == False  # noqa: E712
        assert bool(np.isnan(pair_table["RefPhaseIdx"].iloc[0]))
        # Label backfilled from TestBrake, not from the (label-less-in-this-fixture) Roster entry
        assert pair_table["BC_Label"].iloc[0] == "BC1"


def test_build_test_brake_sets_roster_pairing_does_not_lock():
    test_brake = _two_phase_test_brake()
    roster = {
        "BC": [{"ID": "0xB_HI", "MaxPressure": 4.0}], "WV": [{"ID": "0xW_HI", "MeanPressure": 3.0}],
    }
    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        build_test_brake_sets(test_brake, roster=roster, file="Nodo_Dati12.pkl",
                               reference_phase_idx=None, verbose=False)
        # A later call with a valid reference phase must be able to overwrite
        # the unlocked roster-based registry.
        _, pair_table, _, _, used_method = build_test_brake_sets(
            test_brake, roster=roster, file="Nodo_Dati12.pkl", reference_phase_idx=1, verbose=False,
        )
        assert used_method == "reference"


def test_build_test_brake_sets_empty_test_brake_raises():
    try:
        build_test_brake_sets([], roster={}, file="Nodo_Dati13.pkl", reference_phase_idx=1, verbose=False)
        assert False, "expected ValueError for empty TestBrake"
    except ValueError:
        pass


def test_build_test_brake_sets_dataset_key_from_parent_folder():
    test_brake = _two_phase_test_brake()
    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        # DatiXX not in the filename itself, only in the parent folder name
        _, _, dataset_key, _, _ = build_test_brake_sets(
            test_brake, roster={}, file="data/interim/Dati22/Nodo_x.pkl",
            reference_phase_idx=1, verbose=False,
        )
        assert dataset_key == "Dati22"


# ---------------------------------------------------------------------------
# detect_mbp_pipe_subphases / detect_bc_cyl_subphases
# ---------------------------------------------------------------------------


def _mbp_pipe_buildup_hold_release_phase() -> dict:
    """5.0 bar flat -> ramp down to 3.0 (buildup, distributor 0->2) -> hold
    -> ramp back to 5.0 (release, distributor 2->0)."""
    n_base, n_down, n_hold, n_up, n_tail = (int(s * FS) for s in (2.0, 3.0, 2.0, 2.0, 2.0))
    pressure = np.concatenate([
        np.full(n_base, 5.0), np.linspace(5.0, 3.0, n_down), np.full(n_hold, 3.0),
        np.linspace(3.0, 5.0, n_up), np.full(n_tail, 5.0),
    ])
    n = len(pressure)
    time = _make_time(n)
    gradient = np.gradient(pressure, DT)
    return {"MBP_Time": time, "MBP_Pressure": pressure, "MBP_Gradient": gradient}


def test_mbp_pipe_subphases_detects_buildup_hold_release():
    phase = _mbp_pipe_buildup_hold_release_phase()
    out = detect_mbp_pipe_subphases([phase])
    ph = out[0]
    assert ph["Buildup_timing_pipe"] > 0
    assert ph["Holding_timing_pipe"] > 0
    assert ph["Release_timing_pipe"] > 0
    assert ph["Buildup_gradient_pipe"] > 0  # distributor pressure rising during buildup
    assert ph["Release_gradient_pipe"] < 0  # distributor pressure falling during release
    assert ph["Max_pressure_pipe"] == 2.0  # peak distributor drop (5.0 - 3.0)
    assert ph["EmergencyBrake_action"] == 1.0  # 2.0 bar drop clears the hardcoded 1.5 bar threshold


def test_mbp_pipe_subphases_guard_path_omits_speed_and_gateway_fields():
    """Matches the source's fill_empty_fields(): Speed_*/Gateway_*_Error are
    simply not set on the guard path (missing MBP_Time), unlike the normal
    path which always sets them (with defaults if GPS data is absent)."""
    out = detect_mbp_pipe_subphases([{"MBP_Pressure": np.array([1.0, 2.0])}])
    ph = out[0]
    assert ph["Brake_timing_pipe"] == 0
    assert "Speed_difference" not in ph
    assert "Gateway_VB_Error" not in ph


def _bc_cyl_buildup_hold_release_phase(*, normal_braking=True) -> dict:
    n_base, n_up, n_hold, n_down, n_tail = (int(s * FS) for s in (2.0, 3.0, 3.0, 3.0, 2.0))
    pressure = np.concatenate([
        np.full(n_base, 0.02), np.linspace(0.02, 3.5, n_up), np.full(n_hold, 3.5),
        np.linspace(3.5, 0.02, n_down), np.full(n_tail, 0.02),
    ])
    n = len(pressure)
    time = _make_time(n)
    gradient = np.gradient(pressure, DT)
    return {
        "BC_Time": time, "BC_Pressure": pressure, "BC_Pressure10hz": pressure.copy(), "BC_Gradient": gradient,
        "BC_NormalBraking": normal_braking, "BC_BadStart": 0, "EmergencyBrake": False,
        "BC_Pressure_at_MBP_End": np.array([0.1]),
    }


def test_bc_cyl_subphases_detects_buildup_hold_release_and_first_phase():
    phase = _bc_cyl_buildup_hold_release_phase()
    out = detect_bc_cyl_subphases([phase])
    ph = out[0]
    assert ph["Buildup_timing_cyl"] > 0
    assert ph["Holding_timing_cyl"] > 0
    assert ph["Release_timing_cyl"] > 0
    assert ph["Max_pressure_cyl"] == 3.5
    assert ph["Non_Standard_Braking"] is False
    assert not np.isnan(ph["First_phase_timing"]), "10Hz First_phase should resolve for a clean 0->0.4bar+ crossing"
    assert not np.isnan(ph["First_phase_timing_1hz"])
    assert ph["First_phase_max_gradient"] > 0


def test_bc_cyl_subphases_guard_path_omits_brakemode():
    out = detect_bc_cyl_subphases([{"BC_Pressure": np.array([1.0, 2.0])}])
    ph = out[0]
    assert np.isnan(ph["Brake_timing_cyl"])
    assert "BrakeMode" not in ph  # guard path's field list doesn't include it


def test_bc_cyl_subphases_non_standard_early_continue_omits_summary_fields():
    """Peak-at-last-sample edge case in the Non_Standard_Braking fallback:
    the source's early `continue` skips Total_timing_cyl/DS_Error/BrakeMode/
    Max_pressure_cyl/Mean_cyl/Std_cyl/Consecutive_braking_cyl entirely for
    that phase -- those keys must be genuinely absent, not defaulted."""
    n_base, n_up = int(2.0 * FS), int(2.0 * FS)
    pressure = np.concatenate([np.full(n_base, 0.02), np.linspace(0.02, 3.0, n_up)])
    n = len(pressure)
    phase = {
        "BC_Time": _make_time(n), "BC_Pressure": pressure, "BC_Pressure10hz": pressure.copy(),
        "BC_Gradient": np.gradient(pressure, DT),
        "BC_NormalBraking": False, "BC_BadStart": 0, "EmergencyBrake": False,
        "BC_Pressure_at_MBP_End": np.array([0.1]),
    }
    out = detect_bc_cyl_subphases([phase])
    assert len(out) == 1, "the phase itself is never removed from the list, only its summary fields are skipped"
    ph = out[0]
    assert "Total_timing_cyl" not in ph
    assert "DS_Error" not in ph
    assert "BrakeMode" not in ph


def test_full_pipeline_real_dati01_subphase_detectors_run_without_crashing():
    """Manual, non-automated-suite-blocking sanity check would need a real
    Nodo pickle from Stage 1 -- this test instead builds a synthetic but
    multi-sensor, multi-phase TestBrake_Sets via the full chain
    (filtering -> detect_braking_struct_beta -> build_test_brake_sets) and
    confirms both subphase detectors run end-to-end over it without
    crashing, on a structurally realistic (if synthetic) input shape."""
    test = _build_test(_mbp_profile_with_one_braking_event())
    test_brake, _, _ = detect_braking_struct_beta(test, verbose=False)
    assert len(test_brake) == 1

    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        sets, _, _, _, _ = build_test_brake_sets(
            test_brake, roster={}, file="Nodo_Dati50.pkl", reference_phase_idx=1, verbose=False,
        )
    assert len(sets) == 1
    pair_set = sets[0]
    pair_set = detect_mbp_pipe_subphases(pair_set)
    pair_set = detect_bc_cyl_subphases(pair_set)
    assert "Brake_timing_pipe" in pair_set[0]
    assert "Brake_timing_cyl" in pair_set[0]


# ---------------------------------------------------------------------------
# detect_subphases_sets: orchestration wrapper
# ---------------------------------------------------------------------------


def _one_pair_test_brake_sets():
    test = _build_test(_mbp_profile_with_one_braking_event())
    test_brake, _, _ = detect_braking_struct_beta(test, verbose=False)
    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        sets, _, _, _, _ = build_test_brake_sets(
            test_brake, roster={}, file="Nodo_Dati60.pkl", reference_phase_idx=1, verbose=False,
        )
    return sets


def test_detect_subphases_sets_runs_both_detectors():
    sets = _one_pair_test_brake_sets()
    out = detect_subphases_sets(sets, verbose=False)
    assert len(out) == len(sets)
    assert "Brake_timing_pipe" in out[0][0]
    assert "Brake_timing_cyl" in out[0][0]


def test_detect_subphases_sets_empty_cell_passthrough():
    out = detect_subphases_sets([[], _one_pair_test_brake_sets()[0]], verbose=False)
    assert out[0] == []
    assert "Brake_timing_pipe" in out[1][0]


def test_detect_subphases_sets_isolates_mbp_failure_without_partial_mutation():
    """A phase missing MBP_Gradient (required, unguarded) makes
    detect_mbp_pipe_subphases raise a KeyError partway through -- but only
    *after* it has already set UB_Error on that phase (computed before
    MBP_Gradient is ever touched). The wrapper must discard that entire
    failed attempt, including the pre-crash partial mutation (matching
    MATLAB's pass-by-value "keep S unchanged" semantics for a call that
    errors -- not a partially-applied one), while still running the BC
    detector successfully on the untouched, pre-MBP-attempt cell."""
    cell = _one_pair_test_brake_sets()[0]
    for phase in cell:
        del phase["MBP_Gradient"]

    out = detect_subphases_sets([cell], verbose=False)
    result_cell = out[0]

    assert "Brake_timing_pipe" not in result_cell[0], "MBP genuinely failed; its real output must be absent"
    assert "UB_Error" not in result_cell[0], "MBP's pre-crash partial mutation must not leak through"
    assert "Brake_timing_cyl" in result_cell[0], "BC detector must still have run despite MBP's failure"


# ---------------------------------------------------------------------------
# postprocessing: derived fields + feature table
# ---------------------------------------------------------------------------


def test_compute_derived_fields_matches_keep_fields_schema():
    sets = _one_pair_test_brake_sets()
    sets = detect_subphases_sets(sets, verbose=False)
    sets = compute_derived_fields(sets)
    table = build_feature_table(sets, "Nodo_Dati60_20260101_20260102.pkl")

    assert list(table.columns)[: len(KEEP_FIELDS)] == KEEP_FIELDS
    assert "RunFile" in table.columns and "RunFolder" in table.columns
    assert table["RunFolder"].iloc[0] == "Dati60"
    assert table["RunFile"].iloc[0] == "Nodo_Dati60_20260101_20260102.pkl"
    assert len(table) == len(sets[0])


def test_compute_derived_fields_zero_denominator_forces_nan():
    """Brake_power_pipe == 0 must force Brake_Power_eff to NaN, matching
    MATLAB's explicit override -- not the natural (Inf-producing) division."""
    phase = {
        "Brake_power_cyl": 5.0, "Brake_power_pipe": 0.0,
        "Release_power_cyl": 1.0, "Release_power_pipe": 2.0,
        "Brake_energy_cyl": 1.0, "Brake_energy_pipe": 1.0,
        "Release_energy_cyl": 1.0, "Release_energy_pipe": 1.0,
        "Max_pressure_cyl": 1.0, "Max_pressure_pipe": 1.0,
        "Total_power_pipe": 1.0, "Total_power_cyl": 1.0,
        "Total_energy_pipe": 1.0, "Total_energy_cyl": 1.0,
        "WV_MeanPressure": 2.0,
        "InitPressure": 5.0,
    }
    compute_derived_fields([[phase]])
    assert math.isnan(phase["Brake_Power_eff"])
    assert phase["Release_power_eff"] == 0.5
    # NaN-safe sum: only one side NaN -> treated as 0, not NaN
    assert phase["Total_power_efficiency"] == 0.5


def test_export_feature_csv_merges_and_dedupes_preferring_new(tmp_path=None):
    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        t0 = np.datetime64("2026-01-01T00:00:00")
        run1 = _feature_row_df(mbp_id="0xAA", bc_id="0xBB", wv_id="0xCC",
                                start=t0, end=t0 + np.timedelta64(5, "s"), max_pressure_pipe=1.0)
        p1 = export_feature_csv(run1, "Dati61")
        assert p1.is_file()

        run2 = _feature_row_df(mbp_id="0xAA", bc_id="0xBB", wv_id="0xCC",
                                start=t0, end=t0 + np.timedelta64(5, "s"), max_pressure_pipe=99.0)
        p2 = export_feature_csv(run2, "Dati61")
        result = _read_csv(p2)
        assert len(result) == 1, "same composite key must dedupe to one row"
        assert result["Max_pressure_pipe"].iloc[0] == 99.0, "new row must win on key collision"


def _feature_row_df(*, mbp_id, bc_id, wv_id, start, end, max_pressure_pipe):
    import pandas as pd
    return pd.DataFrame({
        "MBP_ID": [mbp_id], "BC_ID": [bc_id], "WV_ID": [wv_id],
        "Start_brake_time_pipe": [start], "End_brake_time_pipe": [end],
        "Max_pressure_pipe": [max_pressure_pipe],
    })


def _read_csv(path):
    import pandas as pd
    return pd.read_csv(path)


# ---------------------------------------------------------------------------
# pipeline: end-to-end, Nodo pickle -> CSV
# ---------------------------------------------------------------------------


def test_process_nodo_file_end_to_end_writes_csv():
    import pickle
    from python_port.feature_extraction.pipeline import process_nodo_file

    n = len(_mbp_profile_with_one_braking_event())
    time = _make_time(n)
    nodo = [
        {"Label": "MBP", "ID": "0xAAAA", "Time": time, "Pressure": _mbp_profile_with_one_braking_event()},
        {"Label": "BC1", "ID": "0xBBBB", "Time": time, "Pressure": _bc_profile_matching_braking_event(n)},
        {"Label": "WV1", "ID": "0xCCCC", "Time": time, "Pressure": np.full(n, 2.5)},
    ]

    with tempfile.TemporaryDirectory() as tmp, _isolated_paths(Path(tmp)):
        nodo_path = Path(tmp) / "Dati62" / "Nodo_Dati62_20260101_20260102.pkl"
        nodo_path.parent.mkdir(parents=True)
        with open(nodo_path, "wb") as f:
            pickle.dump(nodo, f)

        result = process_nodo_file(nodo_path, verbose=False)

        assert result["dataset_key"] == "Dati62"
        assert result["n_phases"] == 1
        assert result["csv_path"] is not None and result["csv_path"].is_file()

        import pandas as pd
        table = pd.read_csv(result["csv_path"])
        assert len(table) == 1  # 1 pair x 1 phase
        for col in ("Non_Standard_Braking", "BC_BadStart", "Brake_energy_pipe", "Buildup_timing_pipe"):
            assert col in table.columns


def _run_all():
    tests = [(name, fn) for name, fn in sorted(globals().items())
             if name.startswith("test_") and callable(fn)]
    passed, failed = 0, []
    for name, fn in tests:
        try:
            fn()
            print(f"PASS  {name}")
            passed += 1
        except Exception:
            print(f"FAIL  {name}")
            traceback.print_exc()
            failed.append(name)

    print(f"\n{passed}/{len(tests)} passed.")
    if failed:
        print("Failed:", ", ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    _run_all()
