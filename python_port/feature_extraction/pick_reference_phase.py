"""Port of matlab/feature_extraction/pick_reference_phase.m.

Chooses a reference phase from `TestBrake` (the output of
`braking_detection.detect_braking_struct_beta`) only if ALL expected BC and
WV streams are valid (GPS ignored). Pure query function -- reads TestBrake,
adds no fields to it.

Eligibility (per phase):
  MBP: Time & Pressure nonempty, equal length, >= 10 samples
  BC : #valid == nBC_expected, each has Time/Pressure nonempty,
       SensorError == 0, NormalBraking == 1
  WV : #valid == nWV_expected, each has Time/Pressure nonempty,
       WV_SensorError == 0

Bug fix, documented (not a silent replication): the MATLAB source checks an
*optional* field named `'BrakingAct'` for BC validity, which does not exist
anywhere in this codebase -- confirmed by reading every field the sibling
files (`detect_braking_struct_beta.m`, `build_TestBrake_sets.m`,
`Collect_Healthy_SensorData.m`) actually set/read; they all use
`NormalBraking` for this exact concept, and `Collect_Healthy_SensorData.m`'s
own docstring even still says "BrakingAct==1" while its real code already
reads `.NormalBraking` -- strong evidence `BrakingAct` is a stale, unrenamed
field-name string, not intentional. Because `count_valid_streams()`'s
optional-field check defaults to "pass" when the field is absent, the
*effect* of this bug in the original is not "BC validity always fails" --
it's "the NormalBraking condition is silently never enforced," a weaker
filter than documented. This port uses `'NormalBraking'`, restoring the
documented behavior.
"""
from __future__ import annotations

import math
from typing import Iterable, Optional

import numpy as np


def _has_nonempty_series(phase: dict, t_field: str, p_field: str, min_len: int) -> bool:
    t = phase.get(t_field)
    p = phase.get(p_field)
    if t is None or p is None or len(t) == 0 or len(p) == 0:
        return False
    return len(t) == len(p) and len(t) >= min_len


def _all_equal(value, target) -> bool:
    """Port of MATLAB's all(X.(field)==val). Fields checked here are always
    plain scalar bools in this codebase's BC/WV dicts, but np.all() is used
    for robustness, matching MATLAB's array-safe `all`."""
    return bool(np.all(np.asarray(value) == target))


def _count_valid_streams(
    entries: Optional[list], req_field: str, req_val, opt_field: Optional[str] = None, opt_val=0
) -> tuple:
    """Port of count_valid_streams(A,tName,pName,reqField,reqVal,optField,optVal).
    tName/pName are always 'Time'/'Pressure' at both call sites in the
    source, so hardcoded here rather than threaded through as parameters."""
    if not entries:
        return 0, 0
    n_total = len(entries)
    n_valid = 0
    for x in entries:
        has_t = x.get("Time") is not None and len(x["Time"]) > 0
        has_p = x.get("Pressure") is not None and len(x["Pressure"]) > 0
        req_ok = req_field in x and x[req_field] is not None and _all_equal(x[req_field], req_val)
        opt_ok = True
        if opt_field:
            if opt_field in x and x[opt_field] is not None:
                opt_ok = _all_equal(x[opt_field], opt_val)
        if has_t and has_p and req_ok and opt_ok:
            n_valid += 1
    return n_valid, n_total


def _any_true_field(phase: dict, fields: Iterable[str]) -> bool:
    for f in fields:
        v = phase.get(f)
        if v is None:
            continue
        if isinstance(v, (list, tuple, np.ndarray)) and len(v) == 0:
            continue
        if bool(np.any(np.asarray(v) != 0)):
            return True
    return False


def pick_reference_phase(test_brake: list) -> tuple:
    """Returns (ref_phase, scores, report).

    ref_phase: 1-indexed phase number (matching each phase's own 'PhaseIdx'
    field, and MATLAB's 1-based `TestBrake(refPhase)` indexing) of the
    highest-scoring eligible phase, or None if no phase is eligible
    (MATLAB's NaN).
    scores: list[float], one per phase, -inf for ineligible, 100-10*has_err
    for eligible (MATLAB ties broken by first occurrence; np.argmax matches).
    report: list[dict], one per phase, diagnostic fields.
    """
    n = len(test_brake)
    scores = [-math.inf] * n
    report: list = []

    if n == 0:
        return None, scores, report

    nbc_expected = max(len(s.get("BC") or []) for s in test_brake)
    nwv_expected = max(len(s.get("WV") or []) for s in test_brake)

    for s in test_brake:
        mbp_ok = _has_nonempty_series(s, "MBP_Time", "MBP_Pressure", 10)

        bc_valid, bc_total = _count_valid_streams(s.get("BC"), "SensorError", 0, "NormalBraking", 1)
        wv_valid, wv_total = _count_valid_streams(s.get("WV"), "WV_SensorError", 0)

        bc_ok = bc_valid == nbc_expected and bc_total >= nbc_expected
        wv_ok = wv_valid == nwv_expected and wv_total >= nwv_expected

        has_err = _any_true_field(s, ("SV_Error", "UP_Error", "EmergencyBrake"))

        i = len(report)
        if mbp_ok and bc_ok and wv_ok:
            scores[i] = 100 - 10 * has_err

        report.append({
            "MBP_OK": mbp_ok,
            "BC_valid": bc_valid, "BC_total": bc_total, "BC_expected": nbc_expected, "BC_OK": bc_ok,
            "WV_valid": wv_valid, "WV_total": wv_total, "WV_expected": nwv_expected, "WV_OK": wv_ok,
            "HasErrors": has_err,
        })

    scores_arr = np.asarray(scores, dtype=np.float64)
    if np.any(np.isfinite(scores_arr)):
        ref_phase = int(np.argmax(scores_arr)) + 1  # 1-indexed
    else:
        ref_phase = None

    return ref_phase, scores, report
