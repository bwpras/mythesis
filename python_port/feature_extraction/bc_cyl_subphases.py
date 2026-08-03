"""Port of matlab/feature_extraction/detect_BC_cyl_subphases.m.

Operates on one BC/WV pair's flattened phase list (one element of
`build_test_brake_sets`'s `test_brake_sets[p]`), adding BC "cylinder"
buildup/holding/release subphase fields plus the "First phase" (initial
buildup curve-shape) analysis to each phase dict in place, returning the
same list.

State machine: idle -> buildup -> braking <-> releasing (an MBP-like shape,
but with an idle-state "control window" that buffers samples in a
just-ended episode's valley so a quick re-engagement can be stitched back
onto the brake series as one continuous event, and a release-side flat/
high-pressure reclassification check). Buildup/braking/releasing states
each accumulate energy *incrementally* during the loop via a rolling
1-2-sample `trapz` (unlike detect_MBP_pipe_subphases.m, where the
equivalent in-loop code is commented out/dead -- here it is live).

Deviations from the MATLAB source (documented, not silent):
  - The source reads `BC_Pressure10hz`/`BC_Gradient` *before* the
    `hasTime`/`hasPress` guard check, with no `isfield` guard of their own
    -- a latent crash risk in MATLAB if those two fields were ever absent
    while `BC_Time`/`BC_Pressure` were present. Moot for this port: every
    phase reaching this function came from `build_test_brake_sets.py`,
    which always sets all four BC_* array fields (empty arrays, not
    missing keys, when there's no BC match) -- so `.get(..., default)`
    here never needs to guard against a missing key, only an empty one,
    which the `hasTime`/`hasPress` check already covers.
  - `UseProvidedGradient` and `TailTrimPressure` (inputParser defaults
    that are declared but never read anywhere in the source body) are not
    exposed as parameters here.
  - Field presence intentionally differs between the guard path and the
    normal path, **matching the source exactly**: the guard path sets a
    smaller, specific field list (see `_fill_guard_fields()`) -- e.g. no
    `BrakeMode*`, no `DS_Error`, no `_1hz`-suffixed curvature/timing
    fields beyond the four listed -- rather than every field the normal
    path can produce.
  - **Naming, preserved exactly (not "fixed")**: fields *without* the
    `_1hz` suffix are built from `BC_Pressure10hz`; fields *with* the
    `_1hz` suffix are built from native-rate `BC_Pressure`. This is
    inverted from what the names suggest, but it's what the source does,
    consistently, so it's preserved rather than silently swapped.
"""
from __future__ import annotations

import numpy as np


def _seconds_between(t1, t0) -> float:
    return float((t1 - t0) / np.timedelta64(1, "s"))


def _trapz(t_rel: np.ndarray, p: np.ndarray) -> float:
    return float(np.trapz(p, t_rel))


def _find_first(mask: np.ndarray):
    idx = np.flatnonzero(mask)
    return int(idx[0]) if len(idx) else None


def _find_last(mask: np.ndarray):
    idx = np.flatnonzero(mask)
    return int(idx[-1]) if len(idx) else None


def detect_bc_cyl_subphases(
    test_brake: list,
    *,
    grad_start_pos: float = 0.05,
    grad_release_neg: float = -0.05,
    end_pressure: float = 0.40,
    end_buildup: float = 0.40,
    action_thresh: float = 0.60,
    idle_controlwindow_s: float = 30,
    idle_dp: float = 0.4,
) -> list:
    flat_grad = 0.01
    flat_max_count = 210
    eps = np.finfo(float).eps

    for phase in test_brake:
        bc_p_end = phase.get("BC_Pressure_at_MBP_End")
        flag = bool(np.any(np.asarray(bc_p_end if bc_p_end is not None else []) > end_pressure))
        phase["UR_Error"] = flag

        has_time = phase.get("BC_Time") is not None and len(phase["BC_Time"]) > 0
        has_press = phase.get("BC_Pressure") is not None and len(phase["BC_Pressure"]) > 0

        time_bc = np.asarray(phase.get("BC_Time", np.zeros(0, dtype="datetime64[us]")))
        pressure_bc = np.asarray(phase.get("BC_Pressure", np.zeros(0)), dtype=np.float64)
        pressure_bc_10hz = np.asarray(phase.get("BC_Pressure10hz", np.zeros(0)), dtype=np.float64)
        grad_bc = np.asarray(phase.get("BC_Gradient", np.zeros(0)), dtype=np.float64)

        if not (has_time and has_press):
            _fill_guard_fields(phase)
            continue

        abnormal_case = phase.get("BC_NormalBraking") == 0
        phase["Non_Standard_Braking"] = abnormal_case
        emergency_braking = phase.get("EmergencyBrake") == 1
        bc_bad_start = phase.get("BC_BadStart", 0)
        ds_error_buildup = False
        ds_error_release = False

        brake_time_series: list = []
        brake_pressure_series: list = []
        brake_gradient_series: list = []
        buildup_time_series: list = []
        buildup_pressure_series: list = []
        buildup_gradient_series: list = []
        release_time_series: list = []
        release_pressure_series: list = []
        release_gradient_series: list = []
        buildup_pressure10hz_series: list = []

        brake_duration_s = 0.0
        brake_energy = 0.0
        release_duration_s = 0.0
        release_energy = 0.0

        max_pressure = -np.inf
        sum_pressure = 0.0
        sum_pressure_sq = 0.0
        num_samples = 0
        consecutive_braking_count = 0

        idlebuf_active = False
        idlebuf_time: list = []
        idlebuf_press: list = []
        idlebuf_grad: list = []

        state = "idle"
        segment_start_index = 1  # MATLAB literal 2 (1-based) -> 0-based 1
        buildup_end = False
        firstbuildup_end = False
        flat_count = 0
        controlwindow = False
        consec_braking = False
        idle_t0 = None

        n = len(time_bc)
        for kk in range(1, n):
            time_k = time_bc[kk]
            pressure_k = pressure_bc[kk]
            pressure10hz_k = pressure_bc_10hz[kk]
            gradient_k = grad_bc[kk]

            dt_s = _seconds_between(time_bc[kk], time_bc[kk - 1])
            if not np.isfinite(dt_s) or dt_s <= 0:
                dt_s = 0.0

            if state == "idle":
                consec_braking = False
                if buildup_end and gradient_k > grad_start_pos and not controlwindow:
                    controlwindow = True
                    idle_t0 = time_bc[kk - 1]
                if idlebuf_active:
                    idlebuf_time.append(time_k)
                    idlebuf_press.append(pressure_k)
                    idlebuf_grad.append(gradient_k)
                if controlwindow:
                    elapsed = _seconds_between(time_k, idle_t0)
                    if pressure_k >= idle_dp:
                        consec_braking = True
                        controlwindow = False
                    elif elapsed >= idle_controlwindow_s:
                        controlwindow = False
                        idlebuf_active = False
                        idlebuf_time, idlebuf_press, idlebuf_grad = [], [], []

                if gradient_k > grad_start_pos and buildup_end and consec_braking:
                    state = "braking"
                    brake_time_series.extend(release_time_series); brake_time_series.extend(idlebuf_time)
                    brake_pressure_series.extend(release_pressure_series); brake_pressure_series.extend(idlebuf_press)
                    brake_gradient_series.extend(release_gradient_series); brake_gradient_series.extend(idlebuf_grad)
                    brake_duration_s += release_duration_s
                    brake_energy += release_energy
                    release_time_series, release_pressure_series, release_gradient_series = [], [], []
                    release_duration_s, release_energy = 0.0, 0.0
                    idlebuf_active = False
                    idlebuf_time, idlebuf_press, idlebuf_grad = [], [], []
                    segment_start_index = kk - 1
                    consecutive_braking_count += 1
                    brake_time_series.append(time_bc[kk - 1])
                    brake_pressure_series.append(pressure_bc[kk - 1])
                    brake_gradient_series.append(grad_bc[kk - 1])
                    buildup_end = False
                    firstbuildup_end = False
                elif gradient_k > grad_start_pos and not buildup_end:
                    idlebuf_active = False
                    idlebuf_time, idlebuf_press, idlebuf_grad = [], [], []
                    state = "buildup"
                    segment_start_index = kk - 1
                    buildup_end = False
                    firstbuildup_end = False
                    flat_count = 0

            elif state == "buildup":
                seg_times = time_bc[segment_start_index : kk + 1]
                seg_press = pressure_bc[segment_start_index : kk + 1]

                brake_time_series.append(time_k)
                brake_pressure_series.append(pressure_k)
                brake_gradient_series.append(gradient_k)
                buildup_time_series.append(time_k)
                buildup_pressure_series.append(pressure_k)
                buildup_gradient_series.append(gradient_k)

                if bc_bad_start == 0 and not firstbuildup_end and pressure_bc_10hz[0] < 0.1:
                    buildup_pressure10hz_series.append(pressure10hz_k)
                if pressure_k >= end_buildup:
                    firstbuildup_end = True

                brake_duration_s += dt_s
                if len(seg_times) >= 2:
                    t_rel = (seg_times - seg_times[0]) / np.timedelta64(1, "s")
                    brake_energy += _trapz(t_rel, seg_press)
                segment_start_index = kk - 1

                if pressure_k >= action_thresh:
                    buildup_end = True

                flat_count = flat_count + 1 if abs(gradient_k) <= flat_grad else 0

                if flat_count >= flat_max_count and buildup_end:
                    state = "releasing"
                    segment_start_index = kk - 1
                    flat_count = 0
                if gradient_k < grad_release_neg and buildup_end:
                    state = "releasing"
                    segment_start_index = kk - 1
                    flat_count = 0

            elif state == "braking":
                seg_times = time_bc[segment_start_index : kk + 1]
                seg_press = pressure_bc[segment_start_index : kk + 1]

                brake_time_series.append(time_k)
                brake_pressure_series.append(pressure_k)
                brake_gradient_series.append(gradient_k)

                brake_duration_s += dt_s
                if len(seg_times) >= 2:
                    t_rel = (seg_times - seg_times[0]) / np.timedelta64(1, "s")
                    brake_energy += _trapz(t_rel, seg_press)
                segment_start_index = kk - 1

                if pressure_k >= end_pressure:
                    buildup_end = True

                if gradient_k < grad_release_neg and buildup_end:
                    release_time_series.append(time_bc[kk - 1])
                    release_pressure_series.append(pressure_bc[kk - 1])
                    release_gradient_series.append(grad_bc[kk - 1])
                    state = "releasing"
                    segment_start_index = kk - 1

            elif state == "releasing":
                seg_times = time_bc[segment_start_index : kk + 1]
                seg_press = pressure_bc[segment_start_index : kk + 1]
                release_time_series.append(time_bc[kk - 1])
                release_pressure_series.append(pressure_bc[kk - 1])
                release_gradient_series.append(grad_bc[kk - 1])

                release_duration_s += dt_s
                if len(seg_times) >= 2:
                    t_rel = (seg_times - seg_times[0]) / np.timedelta64(1, "s")
                    release_energy += _trapz(t_rel, seg_press)
                segment_start_index = kk - 1

                flat_count = flat_count + 1 if abs(gradient_k) <= flat_grad else 0

                if flat_count >= flat_max_count and len(release_pressure_series) >= flat_max_count:
                    pressure_drop = release_pressure_series[0] - pressure_k
                    min_pressure_drop_threshold = 0.05
                    if pressure_drop < min_pressure_drop_threshold:
                        state = "braking"
                        brake_time_series.extend(release_time_series)
                        brake_pressure_series.extend(release_pressure_series)
                        brake_gradient_series.extend(release_gradient_series)
                        release_time_series, release_pressure_series, release_gradient_series = [], [], []
                        brake_duration_s += release_duration_s
                        release_duration_s = 0.0
                        brake_energy += release_energy
                        release_energy = 0.0
                        segment_start_index = kk - 1
                        flat_count = 0
                        consecutive_braking_count += 1
                elif gradient_k > grad_start_pos:
                    state = "braking"
                    brake_time_series.extend(release_time_series)
                    brake_pressure_series.extend(release_pressure_series)
                    brake_gradient_series.extend(release_gradient_series)
                    release_time_series, release_pressure_series, release_gradient_series = [], [], []
                    brake_duration_s += release_duration_s
                    release_duration_s = 0.0
                    brake_energy += release_energy
                    release_energy = 0.0
                    segment_start_index = kk - 1
                    consecutive_braking_count += 1
                elif pressure_k < end_pressure and buildup_end:
                    state = "idle"
                    segment_start_index = kk - 1
                    flat_count = 0
                    idlebuf_active = True
                    idlebuf_time = [time_bc[kk - 1]]
                    idlebuf_press = [pressure_bc[kk - 1]]
                    idlebuf_grad = [grad_bc[kk - 1]]

            if pressure_k > max_pressure:
                max_pressure = pressure_k
            sum_pressure += pressure_k
            sum_pressure_sq += pressure_k ** 2
            num_samples += 1

        # ---- Split Holding using 90% of Buildup peak ----
        buildup_pressure_arr = np.asarray(buildup_pressure_series, dtype=np.float64)
        end_buildup_idx = None
        if len(buildup_pressure_arr):
            threshold90 = 0.9 * np.nanmax(buildup_pressure_arr)
            if np.isfinite(threshold90):
                idx = _find_first(buildup_pressure_arr >= threshold90)
                end_buildup_idx = idx

        buildup_time_arr = np.array(buildup_time_series, dtype="datetime64[us]") if buildup_time_series else np.zeros(0, dtype="datetime64[us]")
        buildup_pressure10hz_arr = np.asarray(buildup_pressure10hz_series, dtype=np.float64)
        brake_time_arr = np.array(brake_time_series, dtype="datetime64[us]") if brake_time_series else np.zeros(0, dtype="datetime64[us]")
        brake_pressure_arr = np.asarray(brake_pressure_series, dtype=np.float64)

        _compute_first_phase(phase, buildup_pressure10hz_arr, buildup_pressure_arr, buildup_time_arr)

        # ---- Write arrays & metrics: Brake ----
        if len(brake_time_series):
            phase["Brake_time_cyl"] = brake_time_arr
            phase["Brake_pressure_cyl"] = brake_pressure_arr
            phase["Start_brake_time_cyl"] = brake_time_arr[0]
            phase["End_brake_time_cyl"] = brake_time_arr[-1]
            phase["Brake_timing_cyl"] = _seconds_between(brake_time_arr[-1], brake_time_arr[0])
            trel = (brake_time_arr - brake_time_arr[0]) / np.timedelta64(1, "s")
            phase["Brake_energy_cyl"] = _trapz(trel, brake_pressure_arr) if len(trel) >= 2 else np.nan
            phase["Brake_power_cyl"] = phase["Brake_energy_cyl"] / max(eps, phase["Brake_timing_cyl"])
        else:
            phase["Brake_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
            phase["Brake_pressure_cyl"] = np.zeros(0, dtype=np.float64)
            phase["Start_brake_time_cyl"] = None
            phase["End_brake_time_cyl"] = None
            phase["Brake_timing_cyl"] = np.nan
            phase["Brake_energy_cyl"] = np.nan
            phase["Brake_power_cyl"] = np.nan

        # ---- Buildup ----
        if end_buildup_idx is not None:
            ei = end_buildup_idx
            phase["Buildup_time_cyl"] = buildup_time_arr[: ei + 1]
            phase["Buildup_pressure_cyl"] = buildup_pressure_arr[: ei + 1]
            phase["Buildup_timing_cyl"] = _seconds_between(phase["Buildup_time_cyl"][-1], phase["Buildup_time_cyl"][0])
            phase["Buildup_gradient_cyl"] = (
                (phase["Buildup_pressure_cyl"][-1] - phase["Buildup_pressure_cyl"][0]) / max(eps, phase["Buildup_timing_cyl"])
            )
            trel = (phase["Buildup_time_cyl"] - phase["Buildup_time_cyl"][0]) / np.timedelta64(1, "s")
            phase["Buildup_energy_cyl"] = _trapz(trel, phase["Buildup_pressure_cyl"]) if len(trel) >= 2 else np.nan
            phase["Buildup_power_cyl"] = phase["Buildup_energy_cyl"] / max(eps, phase["Buildup_timing_cyl"])
            if emergency_braking:
                t_b = phase["Buildup_timing_cyl"]
                if 3.5 <= t_b <= 4.5:
                    phase["BrakeMode_Buildup"] = "P"
                elif 21 <= t_b <= 27:
                    phase["BrakeMode_Buildup"] = "G"
                else:
                    phase["BrakeMode_Buildup"] = "unknown"
                    ds_error_buildup = True
            else:
                phase["BrakeMode_Buildup"] = "unknown"
        else:
            phase["Buildup_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
            phase["Buildup_pressure_cyl"] = np.zeros(0, dtype=np.float64)
            phase["Buildup_timing_cyl"] = np.nan
            phase["Buildup_gradient_cyl"] = np.nan
            phase["Buildup_energy_cyl"] = np.nan
            phase["Buildup_power_cyl"] = np.nan
            phase["BrakeMode_Buildup"] = "unknown"
            # (source: DS_ErrorBuildup explicitly forced False here when Emergency and
            # buildup missing -- already False by initialization, no-op, omitted)

        # ---- Holding ----
        if end_buildup_idx is not None and len(brake_time_series):
            ei = end_buildup_idx
            phase["Holding_time_cyl"] = brake_time_arr[ei:]
            phase["Holding_pressure_cyl"] = brake_pressure_arr[ei:]
            phase["Holding_timing_cyl"] = _seconds_between(phase["Holding_time_cyl"][-1], phase["Holding_time_cyl"][0])
            trel = (phase["Holding_time_cyl"] - phase["Holding_time_cyl"][0]) / np.timedelta64(1, "s")
            phase["Holding_energy_cyl"] = _trapz(trel, phase["Holding_pressure_cyl"]) if len(trel) >= 2 else np.nan
            phase["Holding_power_cyl"] = phase["Holding_energy_cyl"] / max(eps, phase["Holding_timing_cyl"])
        else:
            phase["Holding_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
            phase["Holding_pressure_cyl"] = np.zeros(0, dtype=np.float64)
            phase["Holding_timing_cyl"] = np.nan
            phase["Holding_energy_cyl"] = np.nan
            phase["Holding_power_cyl"] = np.nan

        # ---- Release ----
        release_time_arr = np.array(release_time_series, dtype="datetime64[us]") if release_time_series else np.zeros(0, dtype="datetime64[us]")
        release_pressure_arr = np.asarray(release_pressure_series, dtype=np.float64)

        if len(release_time_series):
            cut_idx = _find_first(release_pressure_arr < end_pressure)
            if cut_idx is not None:
                release_time_arr = release_time_arr[: cut_idx + 1]
                release_pressure_arr = release_pressure_arr[: cut_idx + 1]

            phase["Release_time_cyl"] = release_time_arr
            phase["Release_pressure_cyl"] = release_pressure_arr
            phase["Release_timing_cyl"] = _seconds_between(release_time_arr[-1], release_time_arr[0])
            trel = (release_time_arr - release_time_arr[0]) / np.timedelta64(1, "s")
            phase["Release_energy_cyl"] = _trapz(trel, release_pressure_arr) if len(trel) >= 2 else np.nan
            phase["Release_power_cyl"] = phase["Release_energy_cyl"] / max(eps, phase["Release_timing_cyl"])
            phase["Release_gradient_cyl"] = (
                (release_pressure_arr[-1] - release_pressure_arr[0]) / max(eps, phase["Release_timing_cyl"])
            )
            if emergency_braking:
                t_r = phase["Release_timing_cyl"]
                if 15.5 <= t_r <= 19.5:
                    phase["BrakeMode_Release"] = "P"
                elif 46.5 <= t_r <= 58.5:
                    phase["BrakeMode_Release"] = "G"
                else:
                    phase["BrakeMode_Release"] = "unknown"
                    ds_error_release = True
            else:
                phase["BrakeMode_Release"] = "unknown"

        elif phase["Non_Standard_Braking"] == 1:
            gave_up = _handle_non_standard_release(
                phase, brake_pressure_arr, brake_time_arr, end_buildup_idx, eps
            )
            if gave_up:
                continue  # matches source's early `continue` (skip summary stats for this phase)
        else:
            phase["Release_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
            phase["Release_pressure_cyl"] = np.zeros(0, dtype=np.float64)
            phase["Release_timing_cyl"] = np.nan
            phase["Release_energy_cyl"] = np.nan
            phase["Release_power_cyl"] = np.nan
            phase["Release_gradient_cyl"] = np.nan
            phase["BrakeMode_Release"] = "unknown"

        # ---- Summary ----
        phase["Total_timing_cyl"] = phase["Brake_timing_cyl"] + phase["Release_timing_cyl"]
        phase["Total_energy_cyl"] = phase["Brake_energy_cyl"] + phase["Release_energy_cyl"]
        phase["Total_power_cyl"] = phase["Total_energy_cyl"] / phase["Total_timing_cyl"]

        if emergency_braking:
            phase["DS_Error"] = 1 if (ds_error_buildup or ds_error_release) else 0
        else:
            phase["DS_Error"] = 0

        bm = phase["BrakeMode_Buildup"]
        if bm == "unknown":
            bm = phase["BrakeMode_Release"]
        phase["BrakeMode"] = bm

        phase["Max_pressure_cyl"] = max_pressure
        phase["Brake_action_cyl"] = float(max_pressure >= action_thresh)

        mean_p = sum_pressure / max(1, num_samples)
        var_p = max(0.0, sum_pressure_sq / max(1, num_samples) - mean_p ** 2)
        phase["Mean_cyl"] = mean_p
        phase["Std_cyl"] = float(np.sqrt(var_p))
        phase["Consecutive_braking_cyl"] = consecutive_braking_count

    return test_brake


def _compute_first_phase(phase: dict, buildup_pressure10hz_arr, buildup_pressure_arr, buildup_time_arr) -> None:
    """The twice-computed First-phase (initial buildup curve-shape) analysis.
    Fields WITHOUT '_1hz' suffix come from the 10Hz array; fields WITH the
    suffix come from the native-rate array -- inverted from what the names
    suggest, preserved exactly (see module docstring)."""
    eps = np.finfo(float).eps

    end_first_buildup_idx = None
    end_first_buildup_idx_1hz = None
    if len(buildup_pressure10hz_arr):
        phase["First_phase_error"] = bool(buildup_pressure10hz_arr[0] > 0.1)
        end_first_buildup_idx = _find_first(buildup_pressure10hz_arr >= 0.40)
        end_first_buildup_idx_1hz = _find_first(buildup_pressure_arr >= 0.40) if len(buildup_pressure_arr) else None
    else:
        phase["First_phase_error"] = False

    # ---- native-rate ("_1hz"-suffixed) branch ----
    if end_first_buildup_idx_1hz is not None and end_first_buildup_idx_1hz >= 1:
        ei = end_first_buildup_idx_1hz
        fp_p_1hz = buildup_pressure_arr[: ei + 1]
        fp_t_1hz = buildup_time_arr[: ei + 1]
        t_s = (fp_t_1hz - fp_t_1hz[0]) / np.timedelta64(1, "s")

        phase["First_phase_pressure_1hz"] = fp_p_1hz
        phase["First_phase_time_1hz"] = fp_t_1hz
        phase["First_phase_time_s_1hz"] = t_s
        first_phase_timing_1hz = float(t_s[-1] - t_s[0])
        phase["First_phase_timing_1hz"] = first_phase_timing_1hz
        phase["End_first_phase_time_1hz"] = fp_t_1hz[-1]
        phase["End_first_phase_pressure_1hz"] = float(fp_p_1hz[-1])

        grad_1hz = np.gradient(fp_p_1hz, t_s)
        curv_1hz = np.gradient(grad_1hz, t_s)
        true_curv_1hz = curv_1hz / (1 + grad_1hz ** 2) ** 1.5
        phase["First_phase_gradient_1hz"] = grad_1hz
        phase["First_phase_curvature_1hz"] = curv_1hz
        phase["First_phase_curvNorm_1hz"] = true_curv_1hz
        phase["First_phase_mean_curvature_1hz"] = float(np.nanmean(np.abs(true_curv_1hz)))

        half_idx = _find_first(fp_p_1hz >= 0.20)
        half_timing_1hz = float(t_s[half_idx] - t_s[0]) if half_idx is not None else np.nan
        phase["First_phase_timing_half_1hz"] = half_timing_1hz
        phase["First_phase_half_time_ratio_1hz"] = half_timing_1hz / max(eps, first_phase_timing_1hz)
        phase["First_phase_avg_rate_1hz"] = (0.40 - float(fp_p_1hz[0])) / max(eps, first_phase_timing_1hz)

        idx01 = _find_last(fp_p_1hz <= 0.1)
        if idx01 is not None and idx01 >= 1:
            dt01 = float(t_s[idx01] - t_s[0])
            phase["First_phase_first_gradient_1hz"] = (float(fp_p_1hz[idx01]) - float(fp_p_1hz[0])) / max(eps, dt01)
        else:
            phase["First_phase_first_gradient_1hz"] = np.nan

        phase["First_phase_max_gradient_1hz"] = float(np.max(grad_1hz))
        sc = _find_first(np.diff(np.sign(true_curv_1hz)) != 0)
        phase["First_phase_inflection_point_1hz"] = float(t_s[sc]) if sc is not None else np.nan

        energy_1hz = _trapz(t_s, fp_p_1hz)
        phase["First_phase_energy_1hz"] = energy_1hz
        phase["First_phase_power_1hz"] = energy_1hz / max(eps, first_phase_timing_1hz)
    else:
        phase["End_first_phase_time_1hz"] = None
        phase["End_first_phase_pressure_1hz"] = np.nan
        phase["First_phase_pressure_1hz"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_time_1hz"] = np.zeros(0, dtype="datetime64[us]")
        phase["First_phase_time_s_1hz"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_timing_1hz"] = np.nan
        phase["First_phase_gradient_1hz"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_curvature_1hz"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_curvNorm_1hz"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_timing_half_1hz"] = np.nan
        phase["First_phase_half_time_ratio_1hz"] = np.nan
        phase["First_phase_first_gradient_1hz"] = np.nan
        phase["First_phase_mean_curvature_1hz"] = np.nan
        phase["First_phase_max_gradient_1hz"] = np.nan
        phase["First_phase_inflection_point_1hz"] = np.nan
        phase["First_phase_avg_rate_1hz"] = np.nan
        phase["First_phase_energy_1hz"] = np.nan
        phase["First_phase_power_1hz"] = np.nan

    # ---- 10Hz (non-suffixed) branch ----
    if end_first_buildup_idx is not None and end_first_buildup_idx >= 1:
        ei = end_first_buildup_idx
        fp_p = buildup_pressure10hz_arr[: ei + 1]
        t_dt = buildup_time_arr[: ei + 1]
        t_s = (t_dt - t_dt[0]) / np.timedelta64(1, "s")

        phase["First_phase_pressure"] = fp_p
        phase["First_phase_time"] = t_dt
        phase["First_phase_time_s"] = t_s
        first_phase_timing = float(t_s[-1] - t_s[0])
        phase["First_phase_timing"] = first_phase_timing
        phase["End_first_phase_time"] = t_dt[-1]
        phase["End_first_phase_pressure"] = float(fp_p[-1])

        grad = np.gradient(fp_p, t_s)
        curv = np.gradient(grad, t_s)
        true_curv = curv / (1 + grad ** 2) ** 1.5
        phase["First_phase_gradient"] = grad
        phase["First_phase_curvature"] = curv
        phase["First_phase_curvNorm"] = true_curv
        phase["First_phase_mean_curvature"] = float(np.nanmean(np.abs(true_curv)))

        half_idx = _find_first(fp_p >= 0.20)
        half_timing = float(t_s[half_idx] - t_s[0]) if half_idx is not None else np.nan
        phase["First_phase_timing_half"] = half_timing
        phase["First_phase_half_time_ratio"] = half_timing / max(eps, first_phase_timing)
        phase["First_phase_avg_rate"] = (0.40 - float(fp_p[0])) / max(eps, first_phase_timing)

        idx01 = _find_last(fp_p <= 0.1)
        if idx01 is not None and idx01 >= 1:
            phase["First_phase_first_gradient"] = (
                (float(fp_p[idx01]) - float(fp_p[0])) / max(eps, float(t_s[idx01] - t_s[0]))
            )
        else:
            phase["First_phase_first_gradient"] = np.nan

        phase["First_phase_max_gradient"] = float(np.max(grad))
        sc = _find_first(np.diff(np.sign(true_curv)) != 0)
        phase["First_phase_inflection_point"] = float(t_s[sc]) if sc is not None else np.nan

        energy = _trapz(t_s, fp_p)
        phase["First_phase_energy"] = energy
        phase["First_phase_power"] = energy / max(eps, first_phase_timing)
    else:
        phase["End_first_phase_time"] = None
        phase["End_first_phase_pressure"] = np.nan
        phase["First_phase_pressure"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_time"] = np.zeros(0, dtype="datetime64[us]")
        phase["First_phase_time_s"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_timing"] = np.nan
        phase["First_phase_gradient"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_curvature"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_curvNorm"] = np.zeros(0, dtype=np.float64)
        phase["First_phase_timing_half"] = np.nan
        phase["First_phase_half_time_ratio"] = np.nan
        phase["First_phase_first_gradient"] = np.nan
        phase["First_phase_mean_curvature"] = np.nan
        phase["First_phase_max_gradient"] = np.nan
        phase["First_phase_inflection_point"] = np.nan
        phase["First_phase_avg_rate"] = np.nan
        phase["First_phase_energy"] = np.nan
        phase["First_phase_power"] = np.nan


def _handle_non_standard_release(phase: dict, brake_pressure_arr, brake_time_arr, end_buildup_idx, eps) -> bool:
    """Port of the Non_Standard_Braking fallback: peak-and-threshold-based
    release extraction directly on the Brake array, with retroactive
    Brake/Holding trimming to exclude the newly-identified release region.

    Returns True if the source's early `continue` (peak is the last
    sample -- nothing to extract) applies, signaling the caller to skip
    the rest of that phase's summary-stat fields entirely, matching the
    source's behavior for that edge case exactly."""
    p = brake_pressure_arr
    t = brake_time_arr

    if len(p) == 0:
        phase["Release_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
        phase["Release_pressure_cyl"] = np.zeros(0, dtype=np.float64)
        phase["Release_timing_cyl"] = np.nan
        phase["Release_energy_cyl"] = np.nan
        phase["Release_power_cyl"] = np.nan
        phase["Release_gradient_cyl"] = np.nan
        phase["BrakeMode_Release"] = "unknown"
        return False

    idx_max = int(np.argmax(p))
    pmax = float(p[idx_max])

    if idx_max >= len(p) - 1:
        phase["Release_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
        phase["Release_pressure_cyl"] = np.zeros(0, dtype=np.float64)
        phase["Release_timing_cyl"] = np.nan
        phase["Release_energy_cyl"] = np.nan
        phase["Release_power_cyl"] = np.nan
        phase["Release_gradient_cyl"] = np.nan
        phase["BrakeMode_Release"] = "unknown"
        return True

    thr_start = pmax - 0.005
    thr_release = 0.4 if pmax > 0.42 else pmax * 0.5

    rel_idx = _find_first(p[idx_max + 1 :] <= thr_start)
    first_cut_idx = idx_max + 1 + rel_idx if rel_idx is not None else idx_max + 1
    first_cut_idx = min(first_cut_idx, len(p) - 1)

    rel_local = _find_first(p[first_cut_idx:] <= thr_release)
    end_cut_idx = first_cut_idx + rel_local if rel_local is not None else None

    if end_cut_idx is not None and end_cut_idx > first_cut_idx:
        release_time = t[first_cut_idx : end_cut_idx + 1]
        release_pressure = p[first_cut_idx : end_cut_idx + 1]

        phase["Release_time_cyl"] = release_time
        phase["Release_pressure_cyl"] = release_pressure
        phase["Release_timing_cyl"] = _seconds_between(release_time[-1], release_time[0])
        trel = (release_time - release_time[0]) / np.timedelta64(1, "s")
        phase["Release_energy_cyl"] = _trapz(trel, release_pressure) if len(trel) >= 2 else np.nan
        phase["Release_power_cyl"] = phase["Release_energy_cyl"] / max(eps, phase["Release_timing_cyl"])
        phase["Release_gradient_cyl"] = (
            (float(release_pressure[-1]) - float(release_pressure[0])) / max(eps, phase["Release_timing_cyl"])
        )
        phase["BrakeMode_Release"] = "unknown"

        t_rel_start = release_time[0]
        rel_start_idx_in_brake = int(np.argmin(np.abs((brake_time_arr - t_rel_start) / np.timedelta64(1, "s"))))
        rel_start_idx_in_brake = max(0, min(rel_start_idx_in_brake, len(brake_time_arr) - 1))

        if rel_start_idx_in_brake > 0:
            brake_time_trim = brake_time_arr[:rel_start_idx_in_brake]
            brake_pressure_trim = brake_pressure_arr[:rel_start_idx_in_brake]
        else:
            brake_time_trim = np.zeros(0, dtype="datetime64[us]")
            brake_pressure_trim = np.zeros(0, dtype=np.float64)

        if len(brake_time_trim):
            phase["Brake_time_cyl"] = brake_time_trim
            phase["Brake_pressure_cyl"] = brake_pressure_trim
            phase["Start_brake_time_cyl"] = brake_time_trim[0]
            phase["End_brake_time_cyl"] = brake_time_trim[-1]
            phase["Brake_timing_cyl"] = _seconds_between(brake_time_trim[-1], brake_time_trim[0])
            trel = (brake_time_trim - brake_time_trim[0]) / np.timedelta64(1, "s")
            phase["Brake_energy_cyl"] = _trapz(trel, brake_pressure_trim) if len(trel) >= 2 else np.nan
            phase["Brake_power_cyl"] = phase["Brake_energy_cyl"] / max(eps, phase["Brake_timing_cyl"])
        else:
            phase["Brake_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
            phase["Brake_pressure_cyl"] = np.zeros(0, dtype=np.float64)
            phase["Start_brake_time_cyl"] = None
            phase["End_brake_time_cyl"] = None
            phase["Brake_timing_cyl"] = np.nan
            phase["Brake_energy_cyl"] = np.nan
            phase["Brake_power_cyl"] = np.nan

        if end_buildup_idx is not None and len(brake_pressure_arr):
            hold_end_idx = max(end_buildup_idx, min(rel_start_idx_in_brake - 1, len(brake_time_arr) - 1))
            if hold_end_idx >= end_buildup_idx:
                phase["Holding_time_cyl"] = brake_time_arr[end_buildup_idx : hold_end_idx + 1]
                phase["Holding_pressure_cyl"] = brake_pressure_arr[end_buildup_idx : hold_end_idx + 1]
                phase["Holding_timing_cyl"] = _seconds_between(phase["Holding_time_cyl"][-1], phase["Holding_time_cyl"][0])
                th = (phase["Holding_time_cyl"] - phase["Holding_time_cyl"][0]) / np.timedelta64(1, "s")
                phase["Holding_energy_cyl"] = _trapz(th, phase["Holding_pressure_cyl"]) if len(th) >= 2 else np.nan
                phase["Holding_power_cyl"] = phase["Holding_energy_cyl"] / max(eps, phase["Holding_timing_cyl"])
            else:
                phase["Holding_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
                phase["Holding_pressure_cyl"] = np.zeros(0, dtype=np.float64)
                phase["Holding_timing_cyl"] = np.nan
                phase["Holding_energy_cyl"] = np.nan
                phase["Holding_power_cyl"] = np.nan
    else:
        phase["Release_time_cyl"] = np.zeros(0, dtype="datetime64[us]")
        phase["Release_pressure_cyl"] = np.zeros(0, dtype=np.float64)
        phase["Release_timing_cyl"] = np.nan
        phase["Release_energy_cyl"] = np.nan
        phase["Release_power_cyl"] = np.nan
        phase["Release_gradient_cyl"] = np.nan
        phase["BrakeMode_Release"] = "unknown"

    return False


def _fill_guard_fields(phase: dict) -> None:
    """Port of the hasTime/hasPress guard-path field list (source lines
    ~60-113) -- deliberately a *smaller* set than the normal path produces
    (no BrakeMode*, DS_Error, etc.), matching the source exactly."""
    empty_dt = np.zeros(0, dtype="datetime64[us]")
    empty_db = np.zeros(0, dtype=np.float64)

    phase["Brake_time_cyl"], phase["Brake_pressure_cyl"] = empty_dt, empty_db
    phase["Buildup_time_cyl"], phase["Buildup_pressure_cyl"] = empty_dt, empty_db
    phase["Holding_time_cyl"], phase["Holding_pressure_cyl"] = empty_dt, empty_db
    phase["Release_time_cyl"], phase["Release_pressure_cyl"] = empty_dt, empty_db

    phase["Start_brake_time_cyl"] = None
    phase["End_brake_time_cyl"] = None

    phase["First_phase_time"] = empty_dt
    phase["First_phase_pressure"] = empty_db
    phase["First_phase_gradient"] = empty_db
    phase["End_first_phase_time"] = None

    phase["First_phase_time_1hz"] = empty_dt
    phase["First_phase_pressure_1hz"] = empty_db
    phase["First_phase_gradient_1hz"] = empty_db
    phase["End_first_phase_time_1hz"] = None

    phase["Brake_timing_cyl"] = np.nan
    phase["Brake_energy_cyl"] = np.nan
    phase["Brake_power_cyl"] = np.nan
    phase["Total_timing_cyl"] = np.nan
    phase["Total_energy_cyl"] = np.nan
    phase["Total_power_cyl"] = np.nan
    phase["Non_Standard_Braking"] = 0

    phase["Buildup_timing_cyl"] = np.nan
    phase["Buildup_gradient_cyl"] = np.nan
    phase["Buildup_energy_cyl"] = np.nan
    phase["Buildup_power_cyl"] = np.nan

    phase["Holding_timing_cyl"] = np.nan
    phase["Holding_energy_cyl"] = np.nan
    phase["Holding_power_cyl"] = np.nan

    phase["Release_timing_cyl"] = np.nan
    phase["Release_gradient_cyl"] = np.nan
    phase["Release_energy_cyl"] = np.nan
    phase["Release_power_cyl"] = np.nan

    phase["Max_pressure_cyl"] = np.nan
    phase["Brake_action_cyl"] = 0
    phase["Mean_cyl"] = np.nan
    phase["Std_cyl"] = np.nan
    phase["Consecutive_braking_cyl"] = 0
