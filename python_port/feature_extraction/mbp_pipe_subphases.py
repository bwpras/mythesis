"""Port of matlab/feature_extraction/detect_MBP_pipe_subphases.m.

Operates on one BC/WV pair's flattened phase list (one element of
`build_test_brake_sets`'s `test_brake_sets[p]`), adding MBP "pipe"
buildup/holding/release subphase fields to each phase dict in place (and
returning the same list, matching the source's `TestBrake = f(TestBrake)`
signature).

State machine: idle -> buildup/braking -> releasing, driven by
`MBP_Gradient` against `grad_start`/`grad_release` thresholds, with a
"distributor pressure" proxy (`p[0] - p`, rises as MBP empties during
braking) used for saturation clamping, a steady-release run-length counter,
and a windowed distributor-pressure-drop test. All energy is integrated via
`trapz` on the *final* concatenated Brake/Buildup/Holding/Release arrays
*after* the loop -- matching the source exactly, where the equivalent
in-loop incremental-energy code is present but commented out (dead), not a
live accumulation path.

Deviations from the MATLAB source (documented, not silent):
  - **Bug fix.** `flatCount` and `SteadyRelease` are declared once at
    function scope in the source, *outside* the per-phase loop, and never
    explicitly reset at the top of each phase's processing -- only via
    specific in-state-machine transitions. `flatCount` is always
    reset (to 0) at every transition into 'releasing' before it's ever
    read there, so its cross-phase carry-over is provably inert (this port
    just declares it fresh per phase, a harmless simplification). But
    `SteadyRelease` has no such guarantee: it's read (compared against
    `cfg.SteadyRelease`) on the *same* iteration it's updated, in both
    'buildup' and 'braking', including the very first iteration of a new
    phase -- so a value left just below threshold at the end of one phase
    (e.g. a phase whose data ends mid-buildup, without ever reaching
    'releasing') can combine with the new phase's first qualifying sample
    to trigger an immediate, spurious buildup-to-releasing transition one
    sample into the next phase. Nothing in the source suggests this
    cross-phase memory is intentional (there's no comment describing it,
    and the whole point of `SteadyRelease` is to measure sustained
    stability *within* one braking event). This port resets both counters
    at the start of each phase, closing that leak.
  - `segment_start_idx` and the `t_seg`/`p_seg` window it feeds are
    dropped: in the source they only feed the commented-out (dead)
    in-loop energy-accumulation code, never anything live.
  - `UseProvidedGradient` (an inputParser default that's declared but never
    read anywhere in the source body) is not exposed as a parameter here.
  - The guard-path (missing/empty `MBP_Time`/`MBP_Pressure`) omits the
    three `MBP_Mask_*PipeMask` fields the source's `fill_empty_fields()`
    sets -- confirmed dead/legacy scaffolding (never read anywhere in this
    codebase, and never set at all on the normal, non-guard path either).
  - Field presence intentionally differs between the guard path and the
    normal path, **matching the source exactly**: the guard path does not
    set `Speed_*`/`Gateway_*_Error` (the source's `fill_empty_fields()`
    doesn't set them either), so those keys are simply absent on
    guard-path phase dicts here, same as in MATLAB.
"""
from __future__ import annotations

from typing import Optional

import numpy as np


def _seconds_between(t1, t0) -> float:
    return float((t1 - t0) / np.timedelta64(1, "s"))


def _trapz(t_rel: np.ndarray, p: np.ndarray) -> float:
    """np.trapz(y, x) -- argument order is reversed from MATLAB's trapz(x, y)."""
    return float(np.trapz(p, t_rel))


def detect_mbp_pipe_subphases(
    test_brake: list,
    *,
    grad_start: float = -0.05,
    grad_release: float = 0.05,
    distributor_idle_thresh: float = 0.005,
    steady_release_grad: float = 0.01,
    steady_release_count: int = 40,
    release_drop_dp: float = 0.2,
    release_drop_window_sec: float = 1.0,
    pressure_saturation: float = 1.5,
) -> list:
    sv_limit = 5.4
    ub_limit = 0.4
    psat = pressure_saturation
    flat_grad = 0.005
    flat_max_count = 400

    for phase in test_brake:
        p20_mbp = phase.get("Post20s_MBP_Pressure")
        p60_mbp = phase.get("Post60s_MBP_Pressure")
        p20_bc = phase.get("Post20s_BC_Pressure")
        p60_bc = phase.get("Post60s_BC_Pressure")

        flag20 = bool(np.any(np.asarray(p20_mbp if p20_mbp is not None else []) > sv_limit)) or \
            bool(np.any(np.asarray(p20_bc if p20_bc is not None else []) > ub_limit))
        flag60 = bool(np.any(np.asarray(p60_mbp if p60_mbp is not None else []) > sv_limit)) or \
            bool(np.any(np.asarray(p60_bc if p60_bc is not None else []) > ub_limit))
        phase["UB_Error"] = flag20 or flag60

        mbp_time = phase.get("MBP_Time")
        mbp_pressure = phase.get("MBP_Pressure")
        if mbp_time is None or mbp_pressure is None or len(mbp_time) == 0 or len(mbp_pressure) == 0:
            _fill_empty_fields(phase)
            continue

        t = np.asarray(mbp_time)
        p = np.asarray(mbp_pressure, dtype=np.float64)
        n = len(t)

        tsecs = (t - t[0]) / np.timedelta64(1, "s")
        dt_vec = np.empty(n, dtype=np.float64)
        # Faithful replication: the source prepends max(eps, tsecs[1]-tsecs[0])
        # -- duplicating the first interval -- rather than a distinct value;
        # only feeds a rough Fs estimate, negligible effect, kept as-is.
        first_dt = max(np.finfo(float).eps, tsecs[1] - tsecs[0]) if n > 1 else np.finfo(float).eps
        dt_vec[0] = first_dt
        if n > 1:
            dt_vec[1:] = np.maximum(np.finfo(float).eps, np.diff(tsecs))
        fs = 1.0 / np.median(dt_vec)
        k_drop = max(1, round(release_drop_window_sec * fs))

        g = np.asarray(phase["MBP_Gradient"], dtype=np.float64)
        distributor = p[0] - p

        time_brake: list = []
        pressure_brake: list = []
        time_buildup: list = []
        pressure_buildup: list = []
        time_release: list = []
        pressure_release: list = []

        max_pressure_pipe = 0.0
        sum_pressure_pipe = 0.0
        sum_pressure_sq_pipe = 0.0
        num_samples_pipe = 0
        consecutive_braking = 0

        state = "idle"
        # Bug fix (see module docstring): fresh per phase, not carried over.
        flat_count = 0
        steady_release = 0

        for c1 in range(1, n - 1):
            gradient = g[c1]
            distributor_p = distributor[c1]

            if state == "idle":
                if gradient < grad_start:
                    state = "buildup"

            elif state == "buildup":
                distributor_p_sat = max(0.0, min(distributor_p, psat))
                time_brake.append(t[c1]); pressure_brake.append(distributor_p_sat)
                time_buildup.append(t[c1]); pressure_buildup.append(distributor_p_sat)

                steady_release = steady_release + 1 if gradient >= steady_release_grad else 0

                distributor_drop = False
                if c1 > k_drop:
                    d_drop = distributor[c1] - distributor[c1 - k_drop]
                    distributor_drop = d_drop <= -release_drop_dp

                if gradient > grad_release or steady_release >= steady_release_count or distributor_drop:
                    state = "releasing"
                    flat_count = 0
                    steady_release = 0

            elif state == "braking":
                distributor_p_sat = max(0.0, min(distributor_p, psat))
                time_brake.append(t[c1]); pressure_brake.append(distributor_p_sat)

                steady_release = steady_release + 1 if gradient >= steady_release_grad else 0

                distributor_drop = False
                if c1 > k_drop:
                    d_drop = distributor[c1] - distributor[c1 - k_drop]
                    distributor_drop = d_drop <= -release_drop_dp

                if gradient > grad_release or distributor_drop or steady_release >= steady_release_count:
                    state = "releasing"
                    flat_count = 0
                    steady_release = 0

            elif state == "releasing":
                distributor_p_sat = max(0.0, min(distributor_p, psat))
                time_release.append(t[c1]); pressure_release.append(distributor_p_sat)

                if distributor_p > psat:
                    state = "braking"
                    time_brake.extend(time_release); pressure_brake.extend(pressure_release)
                    time_release = []; pressure_release = []
                    flat_count = 0

                flat_count = flat_count + 1 if abs(gradient) <= flat_grad else 0

                if gradient < grad_start or flat_count >= flat_max_count:
                    state = "braking"
                    time_brake.extend(time_release); pressure_brake.extend(pressure_release)
                    time_release = []; pressure_release = []
                    consecutive_braking += 1
                    flat_count = 0
                elif distributor_p < distributor_idle_thresh:
                    state = "idle"
                    flat_count = 0

            if distributor_p > max_pressure_pipe:
                max_pressure_pipe = distributor_p
            sum_pressure_pipe += distributor_p
            sum_pressure_sq_pipe += distributor_p ** 2
            num_samples_pipe += 1

        pressure_buildup_arr = np.asarray(pressure_buildup, dtype=np.float64)
        threshold_90 = 0.9 * np.nanmax(pressure_buildup_arr) if len(pressure_buildup_arr) else np.nan
        if not np.isfinite(threshold_90):
            threshold_90 = 0.0
        end_buildup_index: Optional[int] = None
        if len(pressure_buildup_arr):
            hits = np.flatnonzero(pressure_buildup_arr >= threshold_90)
            if len(hits):
                end_buildup_index = int(hits[0])

        time_brake_arr = np.array(time_brake, dtype="datetime64[us]") if time_brake else np.zeros(0, dtype="datetime64[us]")
        pressure_brake_arr = np.asarray(pressure_brake, dtype=np.float64)
        time_release_arr = np.array(time_release, dtype="datetime64[us]") if time_release else np.zeros(0, dtype="datetime64[us]")
        pressure_release_arr = np.asarray(pressure_release, dtype=np.float64)

        # ---- Brake ----
        if len(pressure_brake_arr) and len(time_brake_arr):
            phase["Brake_pressure_pipe"] = pressure_brake_arr
            phase["Brake_time_pipe"] = time_brake_arr
            phase["Start_brake_pressure"] = float(pressure_brake_arr[0])
            phase["Start_brake_time_pipe"] = time_brake_arr[0]
            phase["End_brake_pressure"] = float(pressure_brake_arr[-1])
            phase["End_brake_time_pipe"] = time_brake_arr[-1]
            phase["Brake_timing_pipe"] = _seconds_between(phase["End_brake_time_pipe"], phase["Start_brake_time_pipe"])
            if len(time_brake_arr) >= 2 and len(pressure_brake_arr) >= 2:
                t_rel = (time_brake_arr - time_brake_arr[0]) / np.timedelta64(1, "s")
                p_cap = np.minimum(pressure_brake_arr, pressure_saturation)
                phase["Brake_energy_pipe"] = _trapz(t_rel, p_cap)
            else:
                phase["Brake_energy_pipe"] = 0.0
            phase["Brake_power_pipe"] = phase["Brake_energy_pipe"] / phase["Brake_timing_pipe"]
        else:
            phase["Brake_pressure_pipe"] = np.zeros(0, dtype=np.float64)
            phase["Brake_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
            phase["Start_brake_pressure"] = 0.0
            phase["Start_brake_time_pipe"] = None
            phase["End_brake_pressure"] = 0.0
            phase["End_brake_time_pipe"] = None
            phase["Brake_timing_pipe"] = 0.0
            phase["Brake_energy_pipe"] = 0.0
            phase["Brake_power_pipe"] = 0.0

        # ---- Buildup (sliced from the BRAKE array, using the buildup-tracking
        # array's threshold index -- matches the source exactly: both arrays
        # grow in lockstep while in 'buildup' state, buildup-tracking is a
        # subset of brake by construction, so this indexing is safe) ----
        if end_buildup_index is not None:
            end_i = end_buildup_index
            phase["Buildup_pressure_pipe"] = pressure_brake_arr[: end_i + 1]
            phase["Buildup_time_pipe"] = time_brake_arr[: end_i + 1]
            phase["Start_buildup_time_pipe"] = phase["Buildup_time_pipe"][0]
            phase["Start_buildup_pressure_pipe"] = float(phase["Buildup_pressure_pipe"][0])
            phase["End_buildup_time_pipe"] = phase["Buildup_time_pipe"][-1]
            phase["End_buildup_pressure_pipe"] = float(phase["Buildup_pressure_pipe"][-1])
            phase["Buildup_timing_pipe"] = _seconds_between(phase["End_buildup_time_pipe"], phase["Start_buildup_time_pipe"])
            phase["Buildup_gradient_pipe"] = (
                (phase["End_buildup_pressure_pipe"] - phase["Start_buildup_pressure_pipe"]) / phase["Buildup_timing_pipe"]
            )
            if len(phase["Buildup_time_pipe"]) >= 2 and len(phase["Buildup_pressure_pipe"]) >= 2:
                t_rel = (phase["Buildup_time_pipe"] - phase["Buildup_time_pipe"][0]) / np.timedelta64(1, "s")
                p_cap = np.minimum(phase["Buildup_pressure_pipe"], pressure_saturation)
                phase["Buildup_energy_pipe"] = _trapz(t_rel, p_cap)
            else:
                phase["Buildup_energy_pipe"] = 0.0
            phase["Buildup_power_pipe"] = phase["Buildup_energy_pipe"] / phase["Buildup_timing_pipe"]
        else:
            phase["Buildup_pressure_pipe"] = np.zeros(0, dtype=np.float64)
            phase["Buildup_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
            phase["Start_buildup_time_pipe"] = None
            phase["Start_buildup_pressure_pipe"] = 0.0
            phase["End_buildup_time_pipe"] = None
            phase["End_buildup_pressure_pipe"] = 0.0
            phase["Buildup_timing_pipe"] = 0.0
            phase["Buildup_gradient_pipe"] = 0.0
            phase["Buildup_energy_pipe"] = 0.0
            phase["Buildup_power_pipe"] = 0.0

        # ---- Holding (from the Brake array, starting at the buildup-end
        # index inclusive -- shares one sample with the end of Buildup) ----
        if end_buildup_index is not None and len(pressure_brake_arr):
            end_i = end_buildup_index
            phase["Holding_time_pipe"] = time_brake_arr[end_i:]
            phase["Holding_pressure_pipe"] = pressure_brake_arr[end_i:]
            phase["Start_holding_time_pipe"] = phase["Holding_time_pipe"][0]
            phase["Start_holding_pressure_pipe"] = float(phase["Holding_pressure_pipe"][0])
            phase["End_holding_time_pipe"] = phase["Holding_time_pipe"][-1]
            phase["End_holding_pressure_pipe"] = float(phase["Holding_pressure_pipe"][-1])
            phase["Holding_timing_pipe"] = _seconds_between(phase["End_holding_time_pipe"], phase["Start_holding_time_pipe"])
            if len(phase["Holding_time_pipe"]) >= 2 and len(phase["Holding_pressure_pipe"]) >= 2:
                t_rel = (phase["Holding_time_pipe"] - phase["Holding_time_pipe"][0]) / np.timedelta64(1, "s")
                p_cap = np.minimum(phase["Holding_pressure_pipe"], pressure_saturation)
                phase["Holding_energy_pipe"] = _trapz(t_rel, p_cap)
            else:
                phase["Holding_energy_pipe"] = 0.0
            phase["Holding_power_pipe"] = phase["Holding_energy_pipe"] / phase["Holding_timing_pipe"]
        else:
            phase["Holding_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
            phase["Holding_pressure_pipe"] = np.zeros(0, dtype=np.float64)
            phase["Start_holding_time_pipe"] = None
            phase["Start_holding_pressure_pipe"] = 0.0
            phase["End_holding_time_pipe"] = None
            phase["End_holding_pressure_pipe"] = 0.0
            phase["Holding_timing_pipe"] = 0.0
            phase["Holding_energy_pipe"] = 0.0
            phase["Holding_power_pipe"] = 0.0

        # ---- Release ----
        if len(time_release_arr) and len(pressure_release_arr):
            phase["Release_time_pipe"] = time_release_arr
            phase["Release_pressure_pipe"] = pressure_release_arr
            phase["Start_release_time_pipe"] = time_release_arr[0]
            phase["Start_release_pressure_pipe"] = float(pressure_release_arr[0])
            phase["End_release_time_pipe"] = time_release_arr[-1]
            phase["End_release_pressure_pipe"] = float(pressure_release_arr[-1])
            phase["Release_timing_pipe"] = _seconds_between(phase["End_release_time_pipe"], phase["Start_release_time_pipe"])
            phase["Release_gradient_pipe"] = (
                (phase["End_release_pressure_pipe"] - phase["Start_release_pressure_pipe"]) / phase["Release_timing_pipe"]
            )
            if len(time_release_arr) >= 2 and len(pressure_release_arr) >= 2:
                t_rel = (time_release_arr - time_release_arr[0]) / np.timedelta64(1, "s")
                p_cap = np.minimum(pressure_release_arr, pressure_saturation)
                phase["Release_energy_pipe"] = _trapz(t_rel, p_cap)
            else:
                phase["Release_energy_pipe"] = 0.0
            phase["Release_power_pipe"] = phase["Release_energy_pipe"] / phase["Release_timing_pipe"]
        else:
            phase["Release_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
            phase["Release_pressure_pipe"] = np.zeros(0, dtype=np.float64)
            phase["Start_release_time_pipe"] = None
            phase["Start_release_pressure_pipe"] = 0.0
            phase["End_release_time_pipe"] = None
            phase["End_release_pressure_pipe"] = 0.0
            phase["Release_timing_pipe"] = 0.0
            phase["Release_gradient_pipe"] = 0.0
            phase["Release_energy_pipe"] = 0.0
            phase["Release_power_pipe"] = 0.0
            # (source also sets Total_energy_pipe=0/Total_power_pipe=0 here,
            # but both are unconditionally recomputed right below regardless
            # -- that assignment is dead code, omitted here; see docstring
            # policy on provably-dead assignments.)

        # ---- Summary ----
        phase["Total_energy_pipe"] = phase["Brake_energy_pipe"] + phase["Release_energy_pipe"]
        phase["Total_power_pipe"] = phase["Total_energy_pipe"] / (phase["Brake_timing_pipe"] + phase["Release_timing_pipe"])
        phase["Max_pressure_pipe"] = max_pressure_pipe
        phase["EmergencyBrake_action"] = float(max_pressure_pipe >= 1.5)
        phase["Mean_pipe"] = sum_pressure_pipe / max(1, num_samples_pipe)
        phase["Std_pipe"] = float(np.sqrt(max(0.0, sum_pressure_sq_pipe / max(1, num_samples_pipe) - phase["Mean_pipe"] ** 2)))
        phase["Consecutive_braking_pipe"] = 1 if consecutive_braking >= 1 else 0

        # ---- Speed fields (optional GPS) ----
        gps_speed = phase.get("GPS_Speed")
        if gps_speed is not None and len(gps_speed) > 0:
            s = np.asarray(gps_speed, dtype=np.float64)
            tg = np.asarray(phase["GPS_Time"])
            phase["Start_brake_speed"] = float(s[0])
            phase["End_brake_speed"] = float(s[-1])
            phase["Speed_difference"] = float(s[-1] - s[0])
            if len(tg) >= 2:
                phase["Speed_gradient"] = phase["Speed_difference"] / _seconds_between(tg[-1], tg[0])
            else:
                phase["Speed_gradient"] = 0.0
        else:
            phase["Start_brake_speed"] = 0.0
            phase["End_brake_speed"] = 0.0
            phase["Speed_difference"] = 0.0
            phase["Speed_gradient"] = 0.0

        gps_vbatt = phase.get("GPS_Vbatt")
        if gps_vbatt is not None and len(gps_vbatt) > 0:
            vb = np.asarray(gps_vbatt, dtype=np.float64)
            phase["Gateway_VB_Error"] = int(np.sum((vb < 10) & ~np.isnan(vb)))
        else:
            phase["Gateway_VB_Error"] = 0

        gps_rpm_axle = phase.get("GPS_RPM_axle")
        if gps_rpm_axle is not None and len(gps_rpm_axle) > 0:
            rpm = np.asarray(gps_rpm_axle, dtype=np.float64)
            phase["Gateway_CB_Error"] = int(np.sum(rpm == 308))
        else:
            phase["Gateway_CB_Error"] = 0

    return test_brake


def _fill_empty_fields(phase: dict) -> None:
    """Port of fill_empty_fields(). Deliberately does NOT set
    Speed_*/Gateway_*_Error (the source doesn't either) -- see module
    docstring. MBP_Mask_* fields (dead/legacy, never read anywhere) are
    omitted."""
    phase["Brake_pressure_pipe"] = np.zeros(0, dtype=np.float64)
    phase["Brake_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
    phase["Start_brake_pressure"] = 0.0
    phase["Start_brake_time_pipe"] = None
    phase["End_brake_pressure"] = 0.0
    phase["End_brake_time_pipe"] = None
    phase["Brake_timing_pipe"] = 0.0
    phase["Brake_energy_pipe"] = 0.0
    phase["Brake_power_pipe"] = 0.0

    phase["Buildup_pressure_pipe"] = np.zeros(0, dtype=np.float64)
    phase["Buildup_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
    phase["Start_buildup_time_pipe"] = None
    phase["Start_buildup_pressure_pipe"] = 0.0
    phase["End_buildup_time_pipe"] = None
    phase["End_buildup_pressure_pipe"] = 0.0
    phase["Buildup_timing_pipe"] = 0.0
    phase["Buildup_gradient_pipe"] = 0.0
    phase["Buildup_energy_pipe"] = 0.0
    phase["Buildup_power_pipe"] = 0.0

    phase["Holding_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
    phase["Holding_pressure_pipe"] = np.zeros(0, dtype=np.float64)
    phase["Start_holding_time_pipe"] = None
    phase["Start_holding_pressure_pipe"] = 0.0
    phase["End_holding_time_pipe"] = None
    phase["End_holding_pressure_pipe"] = 0.0
    phase["Holding_timing_pipe"] = 0.0
    phase["Holding_energy_pipe"] = 0.0
    phase["Holding_power_pipe"] = 0.0

    phase["Release_time_pipe"] = np.zeros(0, dtype="datetime64[us]")
    phase["Release_pressure_pipe"] = np.zeros(0, dtype=np.float64)
    phase["Start_release_time_pipe"] = None
    phase["Start_release_pressure_pipe"] = 0.0
    phase["End_release_time_pipe"] = None
    phase["End_release_pressure_pipe"] = 0.0
    phase["Release_timing_pipe"] = 0.0
    phase["Release_gradient_pipe"] = 0.0
    phase["Release_energy_pipe"] = 0.0
    phase["Release_power_pipe"] = 0.0

    phase["Max_pressure_pipe"] = 0.0
    phase["EmergencyBrake_action"] = 0.0
    phase["Mean_pipe"] = 0.0
    phase["Std_pipe"] = 0.0
    phase["Consecutive_braking_pipe"] = 0
    phase["Total_power_pipe"] = 0.0
    phase["Total_energy_pipe"] = 0.0
