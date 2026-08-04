"""Regression tests proving `BrakingCycleDetector`'s chunked/incremental
`.feed()` reproduces `detect_braking_struct_beta()`'s whole-array batch
output exactly -- the correctness contract the live watcher depends on.

Reuses the synthetic-scenario builders already in test_feature_extraction_smoke.py
(`_mbp_profile_with_one_braking_event`, `_bc_profile_matching_braking_event`,
`_make_time`) rather than duplicating them; importing them is safe since that
module only runs its own tests under `if __name__ == "__main__":` / pytest
collection, never as an import side effect.

Run directly:  python python_port/tests/test_braking_detection_incremental.py
Or via pytest: pytest python_port/tests
"""
from __future__ import annotations

import sys
import traceback
from pathlib import Path

import numpy as np

_THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_THIS_DIR.parent.parent))  # repo root, for `python_port.*` imports

from python_port.feature_extraction.filtering import CausalFilterState
from python_port.feature_extraction.braking_detection import (
    BrakingCycleDetector, ChannelSchema, detect_braking_struct_beta,
)
from python_port.tests.test_feature_extraction_smoke import (
    _make_time, _mbp_profile_with_one_braking_event, _bc_profile_matching_braking_event, FS,
)

# ---------------------------------------------------------------------------
# Chunked-feed harness
# ---------------------------------------------------------------------------


def _raw_scenario(mbp_pressure: np.ndarray, with_bc_wv: bool = True) -> dict:
    """RAW (unfiltered) per-channel pressure -- what a live watcher would
    actually receive from ingestion, before any filtering. Returns
    {sensor_id: {"label", "id", "pressure"}}; time base is shared via
    `_make_time(n)` at feed time."""
    n = len(mbp_pressure)
    channels = {"0xAAAA": {"label": "MBP", "id": "0xAAAA", "pressure": mbp_pressure}}
    if with_bc_wv:
        channels["0xBBBB"] = {"label": "BC1", "id": "0xBBBB", "pressure": _bc_profile_matching_braking_event(n)}
        channels["0xCCCC"] = {"label": "WV1", "id": "0xCCCC", "pressure": np.full(n, 2.5)}
    return channels


def _split_points(n: int, num_chunks: int) -> list:
    """Contiguous split indices for `n` samples into `num_chunks` pieces
    (uneven splits allowed -- np.array_split's own convention)."""
    sizes = np.array_split(np.arange(n), num_chunks)
    return [len(s) for s in sizes]


def run_chunked(mbp_pressure: np.ndarray, chunk_sizes: list, with_bc_wv: bool = True) -> list:
    """Feeds the same raw scenario detect_braking_struct_beta() would see in
    one shot, but split into `chunk_sizes`-shaped pieces through independent
    per-sensor CausalFilterState + a single BrakingCycleDetector -- the exact
    shape a live watcher uses (one .bin file's worth of raw samples per
    sensor per call). Returns the flushed TestBrake list."""
    n = len(mbp_pressure)
    assert sum(chunk_sizes) == n
    time = _make_time(n)
    channels = _raw_scenario(mbp_pressure, with_bc_wv=with_bc_wv)

    mbp_schema = ChannelSchema(role="MBP", label="MBP", id="0xAAAA", test_index=0)
    bc_schemas = [ChannelSchema(role="BC", label="BC1", id="0xBBBB", test_index=1)] if with_bc_wv else []
    wv_schemas = [ChannelSchema(role="WV", label="WV1", id="0xCCCC", test_index=2)] if with_bc_wv else []

    detector = BrakingCycleDetector.from_schema(mbp_schema, bc_schemas, wv_schemas, verbose=False)
    filter_states = {sid: CausalFilterState(fs=FS) for sid in channels}

    offset = 0
    for size in chunk_sizes:
        sl = slice(offset, offset + size)
        chunk = {}
        for sid, ch in channels.items():
            filt = filter_states[sid].feed(ch["pressure"][sl])
            chunk[sid] = {
                "time": time[sl],
                "pressure_filter": filt.pressure_filter,
                "pressure_filter_10hz": filt.pressure_filter_10hz,
                "gradient_filtered": filt.gradient_pressure_filtered,
                "vbatt": None, "temperature": None, "rssi": None,
            }
        detector.feed(chunk)
        offset += size

    return detector.flush_final()


def run_batch(mbp_pressure: np.ndarray, with_bc_wv: bool = True) -> list:
    """Reference: the pre-refactor call shape, one whole-array call."""
    n = len(mbp_pressure)
    time = _make_time(n)
    channels = _raw_scenario(mbp_pressure, with_bc_wv=with_bc_wv)
    test = []
    for sid, ch in channels.items():
        filt = CausalFilterState(fs=FS).feed(ch["pressure"])
        test.append({
            "Label": ch["label"], "ID": ch["id"], "Time": time,
            "Pressure_filter": filt.pressure_filter,
            "Pressure_filter_10Hz": filt.pressure_filter_10hz,
            "Gradient_pressure_filtered": filt.gradient_pressure_filtered,
        })
    test_brake, _, _ = detect_braking_struct_beta(test, verbose=False)
    return test_brake


_SCALAR_FIELDS = (
    "PhaseIdx", "MBP_Label", "SV_Error", "UP_Error", "EmergencyBrake", "InitPressure",
    "MBP_StartIdx", "MBP_StartTime", "MBP_EndOfBrakeIdx", "MBP_EndOfBrakeTime",
    "MBP_TestIndex", "MBP_ID", "Post20s_Valid", "Post20s_Time", "Post20s_MBP_Pressure",
    "Post60s_Valid", "Post60s_Time", "Post60s_MBP_Pressure",
    "GPS_StartTime", "GPS_EndTime", "GPS_NumSamples", "GPS_SensorError",
)
_ARRAY_FIELDS = (
    "MBP_Time", "MBP_Pressure", "MBP_Pressure10hz", "MBP_Gradient",
    "MBP_Vbatt", "MBP_Temperature", "MBP_RSSI",
    "Post20s_BC_Pressure", "Post60s_BC_Pressure",
    "GPS_Time", "GPS_Long", "GPS_Lat", "GPS_Speed", "GPS_Speed_RPM",
    "GPS_Ibatt", "GPS_Vbatt", "GPS_RPM_axle",
)
_BC_FIELDS = (
    "Label", "SensorError", "NormalBraking", "BadStart", "LowBraking",
    "StartAboveThresh", "FlatStartNearZero", "AlreadyEngagedStart", "ReleasingAtStart",
    "StartTime", "EndTime", "TestIndex", "ID", "MaxPressure", "EndPressure",
)
_WV_FIELDS = (
    "Label", "WV_SensorError", "StartTime", "EndTime", "TestIndex", "ID",
    "MeanPressure", "NumSamples",
)


def _assert_close(a, b, path: str) -> None:
    if isinstance(a, float) and isinstance(b, float) and np.isnan(a) and np.isnan(b):
        return
    if isinstance(a, np.ndarray) or isinstance(b, np.ndarray):
        a_arr, b_arr = np.asarray(a), np.asarray(b)
        assert a_arr.shape == b_arr.shape, f"{path}: shape {a_arr.shape} != {b_arr.shape}"
        if a_arr.dtype.kind == "f" or b_arr.dtype.kind == "f":
            assert np.allclose(a_arr, b_arr, atol=1e-9, equal_nan=True), f"{path}: {a_arr} != {b_arr}"
        else:
            assert np.array_equal(a_arr, b_arr), f"{path}: {a_arr} != {b_arr}"
        return
    if isinstance(a, float) and isinstance(b, float):
        assert abs(a - b) < 1e-9 or (np.isnan(a) and np.isnan(b)), f"{path}: {a} != {b}"
        return
    assert a == b, f"{path}: {a!r} != {b!r}"


def assert_phase_equal(a: dict, b: dict, path: str = "phase") -> None:
    for f in _SCALAR_FIELDS + _ARRAY_FIELDS:
        assert f in a and f in b, f"{path}: field {f} missing"
        _assert_close(a[f], b[f], f"{path}.{f}")

    assert len(a["BC"]) == len(b["BC"]), f"{path}: BC count differs"
    for i, (bc_a, bc_b) in enumerate(zip(a["BC"], b["BC"])):
        for f in _BC_FIELDS:
            _assert_close(bc_a[f], bc_b[f], f"{path}.BC[{i}].{f}")
        _assert_close(bc_a["Pressure"], bc_b["Pressure"], f"{path}.BC[{i}].Pressure")
        _assert_close(bc_a["Time"], bc_b["Time"], f"{path}.BC[{i}].Time")

    assert len(a["WV"]) == len(b["WV"]), f"{path}: WV count differs"
    for i, (wv_a, wv_b) in enumerate(zip(a["WV"], b["WV"])):
        for f in _WV_FIELDS:
            _assert_close(wv_a[f], wv_b[f], f"{path}.WV[{i}].{f}")


def assert_test_brake_equal(chunked: list, batch: list) -> None:
    assert len(chunked) == len(batch), f"phase count differs: chunked={len(chunked)} batch={len(batch)}"
    for i, (a, b) in enumerate(zip(chunked, batch)):
        assert_phase_equal(a, b, path=f"phase[{i}]")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_chunked_detector_matches_batch_at_various_chunk_counts():
    mbp_pressure = _mbp_profile_with_one_braking_event()
    n = len(mbp_pressure)
    batch = run_batch(mbp_pressure)
    assert len(batch) == 1, "sanity: scenario must produce exactly one phase"

    for num_chunks in (1, 2, 3, 5, 17):
        chunked = run_chunked(mbp_pressure, _split_points(n, num_chunks))
        assert_test_brake_equal(chunked, batch)


def test_chunked_detector_handles_phase_spanning_a_chunk_boundary():
    """The scenario this whole feature exists for: a chunk boundary that
    lands mid-ramp INSIDE the braking event's onset-to-end window (the
    profile's ramp-down is samples [120,240), hold is [240,320), ramp-up is
    [320,400) at FS=40 -- boundaries below are chosen inside each of those
    regions, not at their edges)."""
    mbp_pressure = _mbp_profile_with_one_braking_event()
    n = len(mbp_pressure)
    batch = run_batch(mbp_pressure)
    assert len(batch) == 1

    for boundary in (150, 200, 280, 350):
        chunk_sizes = [boundary, n - boundary]
        chunked = run_chunked(mbp_pressure, chunk_sizes)
        assert_test_brake_equal(chunked, batch)


def test_chunked_detector_handles_multi_phase_scenario_split_mid_event():
    """Two braking events back-to-back (with a flat gap between), chunk
    boundary deliberately inside the SECOND event's ramp-down -- proves
    in-progress-phase state from event 1's completion doesn't leak into or
    get corrupted by event 2 spanning a chunk boundary."""
    one = _mbp_profile_with_one_braking_event()
    gap = np.full(int(5.0 * FS), 5.0)
    mbp_pressure = np.concatenate([one, gap, one])
    n = len(mbp_pressure)
    batch = run_batch(mbp_pressure)
    assert len(batch) == 2, f"expected 2 phases, got {len(batch)}"

    boundary = len(one) + len(gap) + 150  # inside event 2's ramp-down
    chunked = run_chunked(mbp_pressure, [boundary, n - boundary])
    assert_test_brake_equal(chunked, batch)


def test_chunked_detector_stable_point_count_pinned_for_small_first_chunk():
    """First chunk deliberately shorter than window_size=80 -- validates the
    STABLE_POINT_COUNT pin (ceil(STABLE_FRAC*window_size), not
    min(window_size, samples_so_far)) doesn't diverge from batch."""
    mbp_pressure = _mbp_profile_with_one_braking_event()
    n = len(mbp_pressure)
    batch = run_batch(mbp_pressure)
    assert len(batch) == 1

    chunk_sizes = [10, n - 10]
    chunked = run_chunked(mbp_pressure, chunk_sizes)
    assert_test_brake_equal(chunked, batch)


def test_chunked_detector_matches_batch_without_bc_wv():
    """MBP-only scenario (no BC/WV channels at all) -- num_bc=num_wv=0 path."""
    mbp_pressure = _mbp_profile_with_one_braking_event()
    n = len(mbp_pressure)
    batch = run_batch(mbp_pressure, with_bc_wv=False)
    assert len(batch) == 1

    for num_chunks in (1, 4):
        chunked = run_chunked(mbp_pressure, _split_points(n, num_chunks), with_bc_wv=False)
        assert_test_brake_equal(chunked, batch)


def test_chunked_detector_no_phase_when_no_braking_event():
    """Flat signal, no onset anywhere -- both paths must agree on zero
    phases (guards against a false-positive onset introduced by the
    refactor)."""
    mbp_pressure = np.full(int(20.0 * FS), 5.0)
    n = len(mbp_pressure)
    batch = run_batch(mbp_pressure)
    assert batch == []

    chunked = run_chunked(mbp_pressure, _split_points(n, 6))
    assert chunked == []


def test_flush_completed_phases_holds_back_pending_tail_phase():
    """flush_completed_phases() must hold back a phase whose post-20s/60s
    check hasn't resolved yet, and release it once flush_final() is called
    (or once enough further data arrives to resolve the check)."""
    mbp_pressure = _mbp_profile_with_one_braking_event()
    n = len(mbp_pressure)
    time = _make_time(n)
    channels = _raw_scenario(mbp_pressure)

    mbp_schema = ChannelSchema(role="MBP", label="MBP", id="0xAAAA", test_index=0)
    bc_schemas = [ChannelSchema(role="BC", label="BC1", id="0xBBBB", test_index=1)]
    wv_schemas = [ChannelSchema(role="WV", label="WV1", id="0xCCCC", test_index=2)]
    detector = BrakingCycleDetector.from_schema(mbp_schema, bc_schemas, wv_schemas, verbose=False)
    filter_states = {sid: CausalFilterState(fs=FS) for sid in channels}

    # Feed only up through just after the phase ends (MBP_EndOfBrakeIdx=416
    # for this profile, confirmed against run_batch()) -- not enough further
    # data for the +60s post-check to resolve (FS=40 means +60s = 2400 more
    # samples).
    cut = 420
    chunk = {}
    for sid, ch in channels.items():
        filt = filter_states[sid].feed(ch["pressure"][:cut])
        chunk[sid] = {
            "time": time[:cut], "pressure_filter": filt.pressure_filter,
            "pressure_filter_10hz": filt.pressure_filter_10hz,
            "gradient_filtered": filt.gradient_pressure_filtered,
            "vbatt": None, "temperature": None, "rssi": None,
        }
    detector.feed(chunk)

    assert len(detector._test_brake) == 1, "the phase should already be committed by this point"
    assert detector.flush_completed_phases() == [], "must hold back the phase pending its post-check"

    remaining = detector.flush_final()
    assert len(remaining) == 1, "flush_final() must release it regardless of pending post-check"
    assert remaining[0]["Post60s_Valid"] is False, "post-check never resolved -- default, matching batch"


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
