"""Port of matlab/feature_extraction/Collect_Healthy_SensorData.m.

Collects all healthy, unique BC and WV sensors within a sliding time window
of <= max_window_hours, from `TestBrake` (the output of
`braking_detection.detect_braking_struct_beta`). Each BC/WV entry records
which phase and index it came from; MBP_ID is stored once at top level
(assumed constant across all phases, matching the MATLAB source's own
assumption).

Health rules:
  BC healthy = SensorError==0 && NormalBraking==1
  WV healthy = WV_SensorError==0 && NumSamples>0

Search strategy (faithfully preserved, not "improved" into an optimal/
exhaustive search): try every phase as a candidate window start, in
chronological order; the first window whose collected sensors satisfy both
quotas wins immediately (not necessarily the smallest or best-scoring
window). If no window fully satisfies both quotas, the window that got
closest (by total sensors collected) is returned instead, with
TimeWindowOK=False.

Deviations from the MATLAB source (documented, not silent):
  - `numBC_expected`/`numWV_expected` use Python's `None` as the
    "not provided, auto-detect" sentinel. MATLAB additionally treats an
    explicitly-passed empty array the same as omission (`nargin<2 ||
    isempty(...)`); Python callers should pass `None`, not an empty value,
    for the same effect.
  - MATLAB's `TestBrake(1).MBP_ID` has no guard for an empty `TestBrake`
    (would raise an index-out-of-bounds error). This port raises a clear
    `ValueError` for the same input instead of an opaque IndexError,
    preserving the "fail loudly on genuinely invalid input" behavior.
  - The MATLAB source's `Note` message text hardcodes "2-hour window"
    regardless of the actual `MaxWindowHours` argument passed in -- ported
    verbatim (a cosmetic string, not a computed value) rather than fixed,
    since it doesn't affect any returned data.
"""
from __future__ import annotations

from typing import Optional

import numpy as np


def _detect_expected(test_brake: list, which_field: str) -> int:
    """Port of detect_expected(): unique non-empty sensor IDs observed
    across ALL phases for the given field ('BC' or 'WV'), minimum 1."""
    ids: set = set()
    for phase in test_brake:
        arr = phase.get(which_field)
        if arr:
            for e in arr:
                sid = e.get("ID")
                s = str(sid) if sid is not None else ""
                if s != "":
                    ids.add(s)
    return max(1, len(ids))


def _collect_in_window(test_brake: list, win_idx, num_bc_expected, num_wv_expected) -> tuple:
    """Port of collect_in_window(). win_idx: 0-based indices into
    test_brake, already time-ordered.

    Note on fidelity: MATLAB computes `newIdx` (healthy AND not-yet-picked)
    once per phase *before* the per-entry add loop, then adds from that
    fixed list. This port checks "healthy AND not-yet-picked" incrementally
    while iterating instead. The two are equivalent here because IDs are
    unique *within* a single phase's own BC/WV array (one entry per
    physical sensor channel) -- so no single phase can produce a duplicate
    ID whose incremental-vs-batch pick-state would diverge.
    """
    picked_bc: list = []
    picked_wv: list = []
    picked_bc_set: set = set()
    picked_wv_set: set = set()
    bc_list: list = []
    wv_list: list = []

    for k in win_idx:
        phase = test_brake[int(k)]
        from_phase_idx = phase["PhaseIdx"]  # 1-indexed, matches MATLAB's k

        for ii, bc in enumerate(phase.get("BC") or []):
            if len(picked_bc) >= num_bc_expected:
                break
            healthy = bc.get("SensorError") == 0 and bc.get("NormalBraking") == 1
            bc_id = bc.get("ID")
            if healthy and bc_id not in picked_bc_set:
                picked_bc.append(bc_id)
                picked_bc_set.add(bc_id)
                bc_list.append({
                    "ID": bc_id,
                    "Label": bc.get("Label"),
                    "MaxPressure": float(bc.get("MaxPressure", np.nan)),
                    "FromPhaseIdx": from_phase_idx,
                    "IndexInPhase": ii + 1,  # 1-indexed, matching MATLAB
                })

        for ii, wv in enumerate(phase.get("WV") or []):
            if len(picked_wv) >= num_wv_expected:
                break
            healthy = wv.get("WV_SensorError") == 0 and wv.get("NumSamples", 0) > 0
            wv_id = wv.get("ID")
            if healthy and wv_id not in picked_wv_set:
                picked_wv.append(wv_id)
                picked_wv_set.add(wv_id)
                wv_list.append({
                    "ID": wv_id,
                    "Label": wv.get("Label"),
                    "MeanPressure": float(wv.get("MeanPressure", np.nan)),
                    "FromPhaseIdx": from_phase_idx,
                    "IndexInPhase": ii + 1,
                })

        if len(picked_bc) >= num_bc_expected and len(picked_wv) >= num_wv_expected:
            break

    return bc_list, wv_list, picked_bc, picked_wv


def collect_healthy_sensor_data(
    test_brake: list,
    num_bc_expected: Optional[int] = None,
    num_wv_expected: Optional[int] = None,
    max_window_hours: float = 2.0,
) -> dict:
    if not test_brake:
        raise ValueError(
            "Collect_Healthy_SensorData: TestBrake is empty. MATLAB's TestBrake(1).MBP_ID "
            "has no guard for this and would raise an index-out-of-bounds error; this port "
            "raises a clearer ValueError for the same condition instead."
        )

    if num_bc_expected is None:
        num_bc_expected = _detect_expected(test_brake, "BC")
    if num_wv_expected is None:
        num_wv_expected = _detect_expected(test_brake, "WV")

    usable: dict = {"MBP_ID": str(test_brake[0]["MBP_ID"])}

    num_phase = len(test_brake)
    phase_t = np.array([s["MBP_StartTime"] for s in test_brake], dtype="datetime64[us]")
    order = np.argsort(phase_t)  # NaT sorts last (verified), ascending otherwise -- matches MATLAB's sort()
    phase_t_sorted = phase_t[order]
    window_td = np.timedelta64(round(max_window_hours * 3600), "s")

    best_bc: list = []
    best_wv: list = []
    best_picked_bc: list = []
    best_picked_wv: list = []
    best_window_idx: list = []
    success = False

    for s in range(num_phase):
        t0 = phase_t_sorted[s]
        if np.isnat(t0):
            continue

        in_win = (phase_t_sorted >= t0) & (phase_t_sorted <= t0 + window_td)
        win_idx = order[in_win]

        bc_list, wv_list, picked_bc, picked_wv = _collect_in_window(
            test_brake, win_idx, num_bc_expected, num_wv_expected
        )

        if len(picked_bc) >= num_bc_expected and len(picked_wv) >= num_wv_expected:
            best_bc, best_wv = bc_list, wv_list
            best_picked_bc, best_picked_wv = picked_bc, picked_wv
            best_window_idx = win_idx
            success = True
            break
        else:
            if len(picked_bc) + len(picked_wv) > len(best_picked_bc) + len(best_picked_wv):
                best_bc, best_wv = bc_list, wv_list
                best_picked_bc, best_picked_wv = picked_bc, picked_wv
                best_window_idx = win_idx

    usable["BC"] = best_bc
    usable["WV"] = best_wv
    usable["PickedBC_IDs"] = best_picked_bc
    usable["PickedWV_IDs"] = best_picked_wv
    usable["WindowPhaseIdx"] = [test_brake[int(i)]["PhaseIdx"] for i in best_window_idx]
    usable["TimeWindowOK"] = success
    usable["Note"] = (
        "All quotas met within 2-hour window." if success
        else "Quotas not fully met within any 2-hour window."
    )
    return usable
