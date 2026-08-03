"""Port of matlab/feature_extraction/detect_braking_struct_beta.m.

Detects braking phases on the MBP (main brake pipe) signal and attaches
synchronized BC (brake cylinder), WV (wheel valve), and GPS data to each
detected phase.

Input: `test` -- a list of per-channel dicts (one per sensor), each with at
least `Label` (str) and `Time` (np.datetime64[us] array), plus
`Pressure_filter`, `Pressure_filter_10Hz`, `Gradient_pressure_filtered`
(the output of `feature_extraction.filtering.apply_causal_filters`, folded
back onto the channel), and optionally `Vbatt`/`Temperature`/`RSSI`/`ID`/
GPS fields (`Time_GPS`, `Long`, `Lat`, `Speed`, `Speed_RPM`, `GPS_Ibatt`,
`GPS_Vbatt`, `RPM_axle`) -- i.e. Stage 1's `Nodo` records with Stage 2's
filtered-pressure fields attached.

Output: `TestBrake` -- a list of per-phase dicts (see the field list in
each COMMIT section below), plus the list of BC/WV channel indices found.

Deviations from the MATLAB source (documented, not silent):
  - Datetime-only. MATLAB branches on `isdatetime(Time)` vs numeric time;
    Stage 1's own `load_nodo_data.py` output is always `datetime64[us]`,
    so this port drops the numeric-time branch entirely rather than
    replicating dual-mode support Stage 1 never produces.
  - Bug fix: MATLAB's GPS-commit fallback (when no BC end time resolves)
    references an undefined variable `MBP.time(phaseEndIdx)` (no `MBP`
    struct/variable exists in that file -- would throw in real MATLAB if
    that branch were ever hit). This port uses the clearly-intended
    `mbp_time[phase_end_idx]` instead.
  - The MATLAB `SystemStopped` long-stop guard (>=1800s stuck in
    `inBraking`) discards the phase and `continue`s *before* reaching the
    end-condition check in the same iteration, making its own disjunct in
    that check (`... || SystemStopped`) unreachable in the source. This
    port implements the guard's actual effect (discard after 1800s) without
    replicating the dead disjunct.
  - `unique(x, 'stable')` (MATLAB) has no numpy one-liner; ported as
    `_unique_stable()` below via an argsort-of-first-occurrence trick,
    verified equivalent to a naive first-seen scan.
  - "Flag, don't fail" is preserved: no exceptions for data-quality issues
    (missing telemetry, short arrays, sensor errors) -- only flags/NaN in
    the output, matching MATLAB. The one exception is channel discovery: no
    MBP channel found raises ValueError, matching MATLAB's `error(...)`.
  - MATLAB's `[]` (no value) for optional scalar time/id fields is
    represented here as `None`.
"""
from __future__ import annotations

from typing import Optional

import numpy as np

MSG_WAKE = 0x20  # unused here; kept out, no relation -- placeholder removed below

# --------------------------------------------------------------------------
# Small helpers mirroring MATLAB idioms used throughout the source file
# --------------------------------------------------------------------------


def _unique_stable(x: np.ndarray) -> tuple:
    """Port of MATLAB's unique(x, 'stable'): first-occurrence order preserved.

    np.unique(x, return_index=True) gives the index of each value's first
    occurrence, associated with the *sorted* unique values. Sorting those
    indices ascending recovers first-occurrence (i.e. original relative)
    order, since a value's first-occurrence index is order-independent of
    how the unique values themselves get sorted.
    """
    if len(x) == 0:
        return x.copy(), np.zeros(0, dtype=np.int64)
    _, first_idx = np.unique(x, return_index=True)
    order = np.sort(first_idx)
    return x[order], order


def _pad_to_length(x: Optional[np.ndarray], n: int) -> np.ndarray:
    """Port of padToLength = @(x,n) [x(1:min(numel(x),n)); nan(max(0,n-numel(x)),1)]."""
    if x is None or len(x) == 0:
        return np.full(n, np.nan, dtype=np.float64)
    x = np.asarray(x, dtype=np.float64)
    if len(x) >= n:
        return x[:n].copy()
    return np.concatenate([x, np.full(n - len(x), np.nan)])


def _align_by_index(raw: Optional[np.ndarray], idx: np.ndarray, n: int) -> np.ndarray:
    """Port of the repeated MATLAB pattern:
        mapX = uniqueIdx(uniqueIdx <= numel(raw));
        aligned = nan(n,1); aligned(1:numel(mapX)) = raw(mapX);
    i.e. front-packed: valid-index lookups placed at the start of a NaN
    vector of length n, in idx's order; any excess tail stays NaN.
    """
    aligned = np.full(n, np.nan, dtype=np.float64)
    if raw is None or len(raw) == 0:
        return aligned
    raw = np.asarray(raw, dtype=np.float64)
    valid = idx[idx < len(raw)]
    if len(valid) == 0:
        return aligned
    aligned[: len(valid)] = raw[valid]
    return aligned


def _seconds_since(time: np.ndarray, t0: np.datetime64) -> np.ndarray:
    return (time - t0) / np.timedelta64(1, "s")


def _nearest_interp(x: np.ndarray, y: np.ndarray, xq: float) -> float:
    """Port of MATLAB's interp1(x, y, xq, 'nearest', 'extrap'): nearest
    neighbor, clamped to the nearest endpoint if xq falls outside [x[0], x[-1]].
    Assumes x is monotonically non-decreasing (as MATLAB's interp1 also
    requires for correct behavior; this mirrors that implicit assumption).
    """
    if len(x) == 0:
        return float("nan")
    idx = int(np.searchsorted(x, xq))
    if idx <= 0:
        return float(y[0])
    if idx >= len(x):
        return float(y[-1])
    if (xq - x[idx - 1]) <= (x[idx] - xq):
        return float(y[idx - 1])
    return float(y[idx])


def _find_first(mask: np.ndarray) -> Optional[int]:
    idx = np.flatnonzero(mask)
    return int(idx[0]) if len(idx) else None


def _find_last(mask: np.ndarray) -> Optional[int]:
    idx = np.flatnonzero(mask)
    return int(idx[-1]) if len(idx) else None


def _default_bc_entry() -> dict:
    """Port of the BC struct template (detect_braking_struct_beta.m ~764-780),
    plus 'Pressure10hz' always present (MATLAB only adds that field
    dynamically in the non-SV_Error branch, which would leave it absent on
    some phases' BC arrays and not others -- this port always includes it,
    defaulting empty, as a harmless normalization)."""
    return {
        "Label": "",
        "Time": np.zeros(0, dtype="datetime64[us]"),
        "Pressure": np.zeros(0, dtype=np.float64),
        "Pressure10hz": np.zeros(0, dtype=np.float64),
        "Gradient": np.zeros(0, dtype=np.float64),
        "Vbatt": np.zeros(0, dtype=np.float64),
        "Temperature": np.zeros(0, dtype=np.float64),
        "RSSI": np.zeros(0, dtype=np.float64),
        "SensorError": False,
        "NormalBraking": False,
        "BadStart": False,
        "LowBraking": False,
        "StartAboveThresh": False,
        "FlatStartNearZero": False,
        "AlreadyEngagedStart": False,
        "ReleasingAtStart": False,
        "StartTime": None,
        "EndTime": None,
        "TestIndex": np.nan,
        "ID": None,
        "MaxPressure": np.nan,
        "EndPressure": np.nan,
    }


def _default_wv_entry() -> dict:
    """Port of the WV struct template (detect_braking_struct_beta.m ~872-879)."""
    return {
        "Label": "",
        "Time": np.zeros(0, dtype="datetime64[us]"),
        "Pressure": np.zeros(0, dtype=np.float64),
        "Vbatt": np.zeros(0, dtype=np.float64),
        "Temperature": np.zeros(0, dtype=np.float64),
        "RSSI": np.zeros(0, dtype=np.float64),
        "WV_SensorError": False,
        "StartTime": None,
        "EndTime": None,
        "TestIndex": np.nan,
        "ID": None,
        "MeanPressure": np.nan,
        "NumSamples": 0,
    }


# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------


def detect_braking_struct_beta(
    test: list, window_size: int = 80, verbose: bool = True
) -> tuple:
    """Port of detect_braking_struct_beta.m. Returns (TestBrake, bc_indices, wv_indices)."""

    # ---- 1) Locate channels by label (source lines 34-52) ----
    mbp_idx = None
    for i, channel in enumerate(test):
        label = str(channel.get("Label", "")).strip()
        if label.lower() == "mbp":
            mbp_idx = i
            break
    if mbp_idx is None:
        raise ValueError("No MBP channel found.")

    bc_indices, wv_indices = [], []
    for i, channel in enumerate(test):
        label = str(channel.get("Label", "")).strip().upper()
        if label.startswith("BC"):
            bc_indices.append(i)
        if label.startswith("WV"):
            wv_indices.append(i)
    num_bc, num_wv = len(bc_indices), len(wv_indices)

    # ---- 2) MBP core signals: baseline grid (source lines 58-127) ----
    mbp_time = np.asarray(test[mbp_idx]["Time"])
    mbp_t0 = mbp_time[0]
    mbp_time_sec = _seconds_since(mbp_time, mbp_t0)

    mbp_pressure = np.asarray(test[mbp_idx]["Pressure_filter"], dtype=np.float64)
    mbp_pressure10hz = np.asarray(test[mbp_idx]["Pressure_filter_10Hz"], dtype=np.float64)
    mbp_gradient = np.asarray(test[mbp_idx]["Gradient_pressure_filtered"], dtype=np.float64)

    mbp_vbatt_raw = test[mbp_idx].get("Vbatt")
    mbp_temp_raw = test[mbp_idx].get("Temperature")
    mbp_rssi_raw = test[mbp_idx].get("RSSI")
    mbp_id = test[mbp_idx].get("ID")
    mbp_label = str(test[mbp_idx]["Label"])

    mbp_time_sec_u, ia = _unique_stable(mbp_time_sec)
    if len(mbp_time_sec_u) < len(mbp_time_sec):
        mbp_time = mbp_time[ia]
        if len(mbp_pressure) > ia.max():
            mbp_pressure = mbp_pressure[ia]
            mbp_pressure10hz = mbp_pressure10hz[ia]
        else:
            # Defensive fallback for raw arrays shorter than the time base
            # (matches MATLAB exactly, including reusing the original `ia`
            # -- not the trimmed `ia_p` -- for the gradient check below;
            # this is a rare pathological-data path, faithfully preserved).
            ia_p = ia[ia < len(mbp_pressure)]
            mbp_pressure = mbp_pressure[ia_p]
            mbp_pressure10hz = mbp_pressure10hz[ia_p]
            mbp_time_sec_u = mbp_time_sec_u[: len(ia_p)]
            mbp_time = mbp_time[: len(ia_p)]
        if len(mbp_gradient) > ia.max():
            mbp_gradient = mbp_gradient[ia]
        else:
            ia_g = ia[ia < len(mbp_gradient)]
            mbp_gradient = mbp_gradient[ia_g]
        mbp_time_sec = mbp_time_sec_u

    num_mbp_samples = len(mbp_time)

    mbp_vbatt_aligned = _pad_to_length(mbp_vbatt_raw, num_mbp_samples)
    mbp_temp_aligned = _pad_to_length(mbp_temp_raw, num_mbp_samples)
    mbp_rssi_aligned = _pad_to_length(mbp_rssi_raw, num_mbp_samples)

    if verbose:
        print(f"[detect_braking_struct_beta] Scanning {num_mbp_samples} MBP samples ({mbp_label})")
        print(f"  Found {num_bc} BC channels, {num_wv} WV channels.")

    # ---- 3) Build BC streams (source lines 137-215) ----
    bc_streams = []
    for bc_idx in bc_indices:
        ch = test[bc_idx]
        time_raw = np.asarray(ch["Time"])
        time_sec_raw = _seconds_since(time_raw, mbp_t0)
        time_sec, uidx = _unique_stable(time_sec_raw)
        time_dt = time_raw[uidx]
        n = len(time_sec)

        stream = {
            "test_index": bc_idx,
            "label": str(ch["Label"]),
            "id": ch.get("ID"),
            "time": time_dt,
            "time_sec": time_sec,
            "pressure": _align_by_index(ch.get("Pressure_filter"), uidx, n),
            "pressure10hz": _align_by_index(ch.get("Pressure_filter_10Hz"), uidx, n),
            "gradient": _align_by_index(ch.get("Gradient_pressure_filtered"), uidx, n),
            "vbatt": _align_by_index(ch.get("Vbatt"), uidx, n),
            "temperature": _align_by_index(ch.get("Temperature"), uidx, n),
            "rssi": _align_by_index(ch.get("RSSI"), uidx, n),
            "idx_pointer": 0,
        }
        bc_streams.append(stream)

    # ---- 4) Build WV static slices (source lines 221-279) ----
    wv_streams = []
    for wv_idx in wv_indices:
        ch = test[wv_idx]
        time_raw = np.asarray(ch["Time"])
        time_sec_raw = _seconds_since(time_raw, mbp_t0)
        time_sec, uidx = _unique_stable(time_sec_raw)
        time_dt = time_raw[uidx]
        n = len(time_sec)

        stream = {
            "test_index": wv_idx,
            "label": str(ch["Label"]),
            "id": ch.get("ID"),
            "time": time_dt,
            "time_sec": time_sec,
            "pressure": _align_by_index(ch.get("Pressure_filter"), uidx, n),
            "vbatt": _align_by_index(ch.get("Vbatt"), uidx, n),
            "temperature": _align_by_index(ch.get("Temperature"), uidx, n),
            "rssi": _align_by_index(ch.get("RSSI"), uidx, n),
        }
        wv_streams.append(stream)

    # ---- 5) GPS (source lines 285-328) ----
    gps_idx = None
    if test[mbp_idx].get("Time_GPS") is not None:
        gps_idx = mbp_idx
    else:
        for i, channel in enumerate(test):
            if channel.get("Time_GPS") is not None:
                gps_idx = i
                break

    gps = {"has_data": False}
    if gps_idx is not None and test[gps_idx].get("Time_GPS") is not None:
        gps_time_raw = np.asarray(test[gps_idx]["Time_GPS"])
        if len(gps_time_raw) > 0:
            gps_time_sec_raw = _seconds_since(gps_time_raw, mbp_t0)
            gps_time_sec, gidx = _unique_stable(gps_time_sec_raw)
            gps_time = gps_time_raw[gidx]

            def _col(name):
                v = test[gps_idx].get(name)
                if v is None or len(v) == 0:
                    return None
                return np.asarray(v)[gidx]

            gps = {
                "has_data": True,
                "time": gps_time,
                "time_sec": gps_time_sec,
                "long": _col("Long"),
                "lat": _col("Lat"),
                "speed": _col("Speed"),
                "speed_rpm": _col("Speed_RPM"),
                "gps_ibatt": _col("GPS_Ibatt"),
                "gps_vbatt": _col("GPS_Vbatt"),
                "rpm_axle": _col("RPM_axle"),
            }

    # ---- 6) Detection parameters (source lines 333-356) ----
    MBP_LOWER, MBP_UPPER = 4.7, 5.2
    GRAD_ZERO_TOL = 0.02
    STABLE_FRAC = 0.6
    STABLE_POINT_COUNT = max(1, int(np.ceil(STABLE_FRAC * min(window_size, num_mbp_samples))))
    INIT_GRAD_THRESH = -0.05
    P_RELEASE = 0.05
    MIN_P_DROP = 0.2
    EMERGENCY_BRAKING = 1.50
    GRAD_END_THRESH = 0.00
    GRADIENT_STABLE_THRESHOLD = 0.02
    CONTROL_WINDOW_DELAY_SEC = 2
    CONTROL_WINDOW_ACTIVE_MAX_SEC = 4
    CONTROL_WINDOW_STOP_MAX_SEC = 1800
    SV_END_STABLE_HOLD_S = 5

    BC_BUILDUP_END = 0.6
    BC_END_THRESHOLD = 0.40
    WV_FLUCTUATION = 0.2
    BC_BUILDUP_PHASE_P = 0.4
    BC_END_WIN_SAMPLES = 40
    BC_END_MOSTLY_DOWN_FRAC = 0.70
    BC_EXTEND_AFTER_MBP_S = 10

    # ---- 7) State (source lines 361-411) ----
    in_braking = False
    init_pressure = np.nan
    mbp_time_buf: list = []
    mbp_pressure_buf: list = []
    mbp_pressure10hz_buf: list = []
    mbp_gradient_buf: list = []
    phase_start_idx = None
    phase_start_time_sec = np.nan

    test_brake: list = []

    samples_since_drop = 0
    control_window_check = False
    control_window = False
    control_window_start_sec = np.nan
    control_window_fluctuation = False

    sv_hold_active = False
    sv_hold_start_sec = np.nan

    skip_bc_due_to_sv = False

    bc_active = [False] * num_bc
    bc_time_buf: list = [[] for _ in range(num_bc)]
    bc_time_sec_buf: list = [[] for _ in range(num_bc)]
    bc_pressure_buf: list = [[] for _ in range(num_bc)]
    bc_pressure10hz_buf: list = [[] for _ in range(num_bc)]
    bc_gradient_buf: list = [[] for _ in range(num_bc)]
    bc_vbatt_buf: list = [[] for _ in range(num_bc)]
    bc_temp_buf: list = [[] for _ in range(num_bc)]
    bc_rssi_buf: list = [[] for _ in range(num_bc)]
    bc_normal_braking = [False] * num_bc
    bc_sensor_error = [False] * num_bc
    bc_badstart = [False] * num_bc
    bc_low_braking = [False] * num_bc
    bc_start_above_thresh = [False] * num_bc
    bc_flat_start_near_zero = [False] * num_bc
    bc_already_engaged = [False] * num_bc
    bc_releasing_at_start = [False] * num_bc
    bc_flat_checked = [False] * num_bc

    post20_check = {"active": False, "time_limit": np.nan, "phase_idx": None}
    post60_check = {"active": False, "time_limit": np.nan, "phase_idx": None}

    def _reset_phase_state():
        nonlocal in_braking, init_pressure, mbp_time_buf, mbp_pressure_buf
        nonlocal mbp_pressure10hz_buf, mbp_gradient_buf, phase_start_idx, phase_start_time_sec
        nonlocal samples_since_drop, control_window_check, control_window
        nonlocal control_window_start_sec, control_window_fluctuation
        in_braking = False
        init_pressure = np.nan
        mbp_time_buf = []
        mbp_pressure_buf = []
        mbp_pressure10hz_buf = []
        mbp_gradient_buf = []
        phase_start_idx = None
        phase_start_time_sec = np.nan
        samples_since_drop = 0
        control_window_check = False
        control_window = False
        control_window_start_sec = np.nan
        control_window_fluctuation = False

    # ---- 8) Main scan over MBP grid (source lines 416-1126) ----
    for k in range(num_mbp_samples):
        window_start = max(0, k - window_size + 1)
        window_slice = mbp_gradient[window_start : k + 1]
        is_stable_now = int(np.sum(np.abs(window_slice) <= GRAD_ZERO_TOL)) >= STABLE_POINT_COUNT

        if not in_braking:
            if is_stable_now and mbp_gradient[k] <= INIT_GRAD_THRESH and mbp_pressure[k] > MBP_LOWER:
                t_drop = mbp_time_sec[k]
                if post20_check["active"] and t_drop < post20_check["time_limit"]:
                    post20_check["active"] = False
                if post60_check["active"] and t_drop < post60_check["time_limit"]:
                    post60_check["active"] = False

                in_braking = True
                init_pressure = mbp_pressure[k]
                phase_start_idx = k
                phase_start_time_sec = mbp_time_sec[k]

                mbp_time_buf = [mbp_time[k]]
                mbp_pressure_buf = [mbp_pressure[k]]
                mbp_pressure10hz_buf = [mbp_pressure10hz[k]]
                mbp_gradient_buf = [mbp_gradient[k]]

                if verbose:
                    print(f"[Phase {len(test_brake) + 1}] MBP onset at {mbp_time[k]}, "
                          f"P={mbp_pressure[k]:.2f}, G={mbp_gradient[k]:.3f}")

                samples_since_drop = 0
                control_window_check = False
                control_window = False
                control_window_start_sec = np.nan
                control_window_fluctuation = False
                system_stopped = False

                skip_bc_due_to_sv = init_pressure > MBP_UPPER
                if skip_bc_due_to_sv and verbose:
                    print(f"  [Phase {len(test_brake) + 1}] SV_Error=1 at onset — skipping BC & WV this phase.")

                if not skip_bc_due_to_sv:
                    for b in range(num_bc):
                        bc_active[b] = True
                        bc_time_buf[b] = []
                        bc_time_sec_buf[b] = []
                        bc_pressure_buf[b] = []
                        bc_pressure10hz_buf[b] = []
                        bc_gradient_buf[b] = []
                        bc_vbatt_buf[b] = []
                        bc_temp_buf[b] = []
                        bc_rssi_buf[b] = []
                        bc_start_above_thresh[b] = False
                        bc_flat_start_near_zero[b] = False
                        bc_already_engaged[b] = False
                        bc_releasing_at_start[b] = False
                        bc_flat_checked[b] = False
                        bc_normal_braking[b] = False
                        bc_sensor_error[b] = False
                        bc_badstart[b] = False
                        bc_low_braking[b] = False

                        stream = bc_streams[b]
                        while stream["idx_pointer"] < len(stream["time_sec"]) and \
                                stream["time_sec"][stream["idx_pointer"]] < phase_start_time_sec:
                            stream["idx_pointer"] += 1

        else:
            mbp_time_buf.append(mbp_time[k])
            mbp_pressure_buf.append(mbp_pressure[k])
            mbp_pressure10hz_buf.append(mbp_pressure10hz[k])
            mbp_gradient_buf.append(mbp_gradient[k])
            force_end_sv = False

            samples_since_drop += 1
            seconds_post_drop = mbp_time_sec[k] - phase_start_time_sec

            if not system_stopped and seconds_post_drop >= CONTROL_WINDOW_STOP_MAX_SEC:
                system_stopped = True
                if verbose:
                    print(f"  [Phase {len(test_brake) + 1}] Long-stop guard: "
                          f"{seconds_post_drop:.1f}s >= {CONTROL_WINDOW_STOP_MAX_SEC}s -> FORCE END (discard)")
                _reset_phase_state()
                continue

            if not control_window_check and seconds_post_drop >= CONTROL_WINDOW_DELAY_SEC:
                control_window_check = True
                control_window = True
                control_window_start_sec = mbp_time_sec[k]
                control_window_fluctuation = False
                if verbose:
                    print(f"  [Phase {len(test_brake) + 1}] Control Window ACTIVATED at +{seconds_post_drop:.1f}s")

            if control_window:
                if mbp_gradient[k] < 0:
                    control_window_fluctuation = True
                    control_window = False
                    if verbose:
                        print(f"  [Phase {len(test_brake) + 1}] Control Window DEACTIVATED (fluctuation)")
                else:
                    if (mbp_time_sec[k] - control_window_start_sec) >= CONTROL_WINDOW_ACTIVE_MAX_SEC \
                            and not control_window_fluctuation:
                        if verbose:
                            print(f"  [Phase {len(test_brake) + 1}] Acquisition DISCARDED by guard "
                                  f"(stable {mbp_time_sec[k]-control_window_start_sec:.1f}s)")
                        _reset_phase_state()
                        continue

            if skip_bc_due_to_sv:
                if abs(mbp_gradient[k]) < GRADIENT_STABLE_THRESHOLD:
                    if not sv_hold_active:
                        sv_hold_active = True
                        sv_hold_start_sec = mbp_time_sec[k]
                    else:
                        if (mbp_time_sec[k] - sv_hold_start_sec) >= SV_END_STABLE_HOLD_S:
                            force_end_sv = True
                else:
                    sv_hold_active = False
                    sv_hold_start_sec = np.nan

            # ---- BC streaming (source lines 585-690) ----
            if not skip_bc_due_to_sv and num_bc > 0:
                for b in range(num_bc):
                    if not bc_active[b]:
                        continue
                    stream = bc_streams[b]

                    if len(bc_pressure_buf[b]) == 0 and stream["idx_pointer"] < len(stream["time_sec"]):
                        ptr = stream["idx_pointer"]
                        if stream["time_sec"][ptr] <= mbp_time_sec[k]:
                            if stream["pressure"][ptr] >= BC_BUILDUP_PHASE_P:
                                bc_start_above_thresh[b] = True
                                if verbose:
                                    print(f"    [BC {stream['id']}] Bad Start >= {BC_BUILDUP_PHASE_P:.2f} bar "
                                          f"-> SensorError=true (kept and recorded)")

                    while stream["idx_pointer"] < len(stream["time_sec"]) and \
                            stream["time_sec"][stream["idx_pointer"]] <= mbp_time_sec[k]:
                        ptr = stream["idx_pointer"]
                        bc_time_buf[b].append(stream["time"][ptr])
                        bc_time_sec_buf[b].append(stream["time_sec"][ptr])
                        bc_pressure_buf[b].append(stream["pressure"][ptr])
                        bc_pressure10hz_buf[b].append(stream["pressure10hz"][ptr])
                        bc_gradient_buf[b].append(stream["gradient"][ptr])

                        # MATLAB guards each append with ~isempty(BC(bcIdx).Vbatt) -- the
                        # *stream-level* aligned array, which _align_by_index always
                        # allocates at fixed length (NaN-filled) whenever the channel has
                        # any samples at all, never a zero-length array. So the faithful
                        # port checks "does this stream have samples", not "are they all
                        # NaN" -- the latter would wrongly skip appending (and desync this
                        # buffer's length from time/pressure) whenever raw telemetry was
                        # entirely absent for an otherwise-valid channel.
                        if len(stream["vbatt"]) > 0:
                            bc_vbatt_buf[b].append(stream["vbatt"][ptr])
                        if len(stream["temperature"]) > 0:
                            bc_temp_buf[b].append(stream["temperature"][ptr])
                        if len(stream["rssi"]) > 0:
                            bc_rssi_buf[b].append(stream["rssi"][ptr])

                        if stream["pressure"][ptr] >= BC_BUILDUP_PHASE_P + WV_FLUCTUATION:
                            bc_normal_braking[b] = True
                        stream["idx_pointer"] += 1

                    if not bc_flat_checked[b] and len(bc_time_sec_buf[b]) >= 5:
                        t_first = bc_time_sec_buf[b][0]
                        span_s = bc_time_sec_buf[b][-1] - t_first
                        if span_s >= 5:
                            tarr = np.asarray(bc_time_sec_buf[b])
                            parr = np.asarray(bc_pressure_buf[b])
                            garr = np.asarray(bc_gradient_buf[b])
                            mask_flat = (tarr - t_first) <= 5
                            press_flat = parr[mask_flat]
                            grad_flat = garr[mask_flat]

                            dp = float(np.max(press_flat) - np.min(press_flat))
                            mean_p = float(np.nanmean(press_flat))
                            mean_grad = float(np.nanmean(grad_flat))
                            flat = abs(mean_grad) < 0.01 and dp < 0.05

                            if flat and mean_p < 0.05:
                                bc_flat_start_near_zero[b] = True
                            elif flat and mean_p >= 0.05:
                                bc_already_engaged[b] = True
                            elif mean_grad < -0.01:
                                bc_releasing_at_start[b] = True

                            bc_flat_checked[b] = True

                    if bc_start_above_thresh[b] or bc_flat_start_near_zero[b] or \
                            bc_already_engaged[b] or bc_releasing_at_start[b]:
                        bc_sensor_error[b] = True
                        bc_badstart[b] = True
                    else:
                        bc_sensor_error[b] = False
                        bc_badstart[b] = False

            # ---- Phase END condition (source lines 692-1016) ----
            end_pressure_target = init_pressure - P_RELEASE
            regular_end = mbp_pressure[k] > end_pressure_target and mbp_gradient[k] > GRAD_END_THRESH
            sv_early_end = skip_bc_due_to_sv and force_end_sv

            if regular_end or sv_early_end or system_stopped:
                phase_end_idx = k
                total_drop = init_pressure - float(np.min(mbp_pressure_buf))

                if total_drop >= MIN_P_DROP:
                    sv_error = init_pressure > MBP_UPPER
                    up_error = init_pressure < MBP_LOWER

                    phase = {
                        "PhaseIdx": len(test_brake) + 1,
                        "MBP_Label": mbp_label,
                        "MBP_Time": np.asarray(mbp_time_buf),
                        "MBP_Pressure": np.asarray(mbp_pressure_buf, dtype=np.float64),
                        "MBP_Pressure10hz": np.asarray(mbp_pressure10hz_buf, dtype=np.float64),
                        "MBP_Gradient": np.asarray(mbp_gradient_buf, dtype=np.float64),
                        "SV_Error": bool(sv_error),
                        "UP_Error": bool(up_error),
                        "EmergencyBrake": bool(total_drop >= EMERGENCY_BRAKING),
                        "InitPressure": init_pressure,
                        "MBP_StartIdx": phase_start_idx,
                        "MBP_StartTime": mbp_time[phase_start_idx],
                        "MBP_EndOfBrakeIdx": phase_end_idx,
                        "MBP_EndOfBrakeTime": mbp_time[phase_end_idx],
                        "MBP_TestIndex": mbp_idx,
                        "MBP_ID": mbp_id,
                        "Post20s_Valid": False,
                        "Post20s_Time": None,
                        "Post20s_MBP_Pressure": np.nan,
                        "Post20s_BC_Pressure": np.full(num_bc, np.nan),
                        "Post60s_Valid": False,
                        "Post60s_Time": None,
                        "Post60s_MBP_Pressure": np.nan,
                        "Post60s_BC_Pressure": np.full(num_bc, np.nan),
                    }

                    t_end_sec = mbp_time_sec[phase_end_idx]
                    this_phase_idx = len(test_brake)  # 0-based index into test_brake, filled below
                    post20_check["active"], post20_check["time_limit"], post20_check["phase_idx"] = \
                        True, t_end_sec + 20, this_phase_idx
                    post60_check["active"], post60_check["time_limit"], post60_check["phase_idx"] = \
                        True, t_end_sec + 60, this_phase_idx

                    idx_slice = slice(phase_start_idx, phase_end_idx + 1)
                    phase["MBP_Vbatt"] = mbp_vbatt_aligned[idx_slice]
                    phase["MBP_Temperature"] = mbp_temp_aligned[idx_slice]
                    phase["MBP_RSSI"] = mbp_rssi_aligned[idx_slice]

                    # ===== COMMIT: BC (source lines 763-869) =====
                    bc_list = [_default_bc_entry() for _ in range(num_bc)]
                    if sv_error:
                        for b in range(num_bc):
                            bc_list[b]["Label"] = bc_streams[b]["label"]
                            bc_list[b]["SensorError"] = True
                            bc_list[b]["NormalBraking"] = False
                            bc_list[b]["TestIndex"] = bc_streams[b]["test_index"]
                            bc_list[b]["ID"] = bc_streams[b]["id"]
                            bc_list[b]["MaxPressure"] = np.nan
                    else:
                        time_limit_sec = mbp_time_sec[phase_end_idx] + BC_EXTEND_AFTER_MBP_S
                        for b in range(num_bc):
                            stream = bc_streams[b]
                            if len(bc_pressure_buf[b]) > 0:
                                while stream["idx_pointer"] < len(stream["time_sec"]) and \
                                        stream["time_sec"][stream["idx_pointer"]] <= time_limit_sec:
                                    ptr = stream["idx_pointer"]
                                    bc_time_buf[b].append(stream["time"][ptr])
                                    bc_time_sec_buf[b].append(stream["time_sec"][ptr])
                                    bc_pressure_buf[b].append(stream["pressure"][ptr])
                                    bc_pressure10hz_buf[b].append(stream["pressure10hz"][ptr])
                                    bc_gradient_buf[b].append(stream["gradient"][ptr])
                                    if len(stream["vbatt"]) > 0:
                                        bc_vbatt_buf[b].append(stream["vbatt"][ptr])
                                    if len(stream["temperature"]) > 0:
                                        bc_temp_buf[b].append(stream["temperature"][ptr])
                                    if len(stream["rssi"]) > 0:
                                        bc_rssi_buf[b].append(stream["rssi"][ptr])
                                    if stream["pressure"][ptr] >= BC_BUILDUP_END:
                                        bc_normal_braking[b] = True
                                    stream["idx_pointer"] += 1

                                    ns = len(bc_pressure_buf[b])
                                    if ns >= BC_END_WIN_SAMPLES:
                                        p_now = bc_pressure_buf[b][ns - 1]
                                        g_win = np.asarray(bc_gradient_buf[b][ns - BC_END_WIN_SAMPLES : ns])
                                        mostly_down = float(np.mean(g_win < 0)) > BC_END_MOSTLY_DOWN_FRAC
                                        if p_now < BC_END_THRESHOLD and mostly_down:
                                            break

                            has_data = len(bc_pressure_buf[b]) > 0 and len(bc_time_buf[b]) > 0
                            if has_data:
                                start_time_bc = bc_time_buf[b][0]
                                end_time_bc = bc_time_buf[b][-1]
                                max_p = float(np.max(bc_pressure_buf[b]))
                                end_pressure = bc_pressure_buf[b][-1]
                            else:
                                start_time_bc, end_time_bc, max_p, end_pressure = None, None, np.nan, np.nan
                                bc_sensor_error[b] = True

                            if not bc_sensor_error[b] and not bc_normal_braking[b]:
                                bc_low_braking[b] = True

                            e = bc_list[b]
                            e["Label"] = stream["label"]
                            e["Time"] = np.asarray(bc_time_buf[b])
                            e["Pressure"] = np.asarray(bc_pressure_buf[b], dtype=np.float64)
                            e["Pressure10hz"] = np.asarray(bc_pressure10hz_buf[b], dtype=np.float64)
                            e["Gradient"] = np.asarray(bc_gradient_buf[b], dtype=np.float64)
                            e["Vbatt"] = np.asarray(bc_vbatt_buf[b], dtype=np.float64)
                            e["Temperature"] = np.asarray(bc_temp_buf[b], dtype=np.float64)
                            e["RSSI"] = np.asarray(bc_rssi_buf[b], dtype=np.float64)
                            e["BadStart"] = bool(bc_badstart[b])
                            e["SensorError"] = bool(bc_sensor_error[b])
                            e["NormalBraking"] = bool(bc_normal_braking[b])
                            e["LowBraking"] = bool(bc_low_braking[b])
                            e["StartAboveThresh"] = bool(bc_start_above_thresh[b])
                            e["FlatStartNearZero"] = bool(bc_flat_start_near_zero[b])
                            e["AlreadyEngagedStart"] = bool(bc_already_engaged[b])
                            e["ReleasingAtStart"] = bool(bc_releasing_at_start[b])
                            e["StartTime"] = start_time_bc
                            e["EndTime"] = end_time_bc
                            e["TestIndex"] = stream["test_index"]
                            e["ID"] = stream["id"]
                            e["MaxPressure"] = max_p
                            e["EndPressure"] = end_pressure
                    phase["BC"] = bc_list

                    # ===== COMMIT: WV (source lines 871-924) =====
                    wv_list = [_default_wv_entry() for _ in range(num_wv)]
                    if sv_error:
                        for w in range(num_wv):
                            wv_list[w]["Label"] = wv_streams[w]["label"]
                            wv_list[w]["WV_SensorError"] = True
                            wv_list[w]["TestIndex"] = wv_streams[w]["test_index"]
                            wv_list[w]["ID"] = wv_streams[w]["id"]
                            wv_list[w]["MeanPressure"] = np.nan
                            wv_list[w]["NumSamples"] = 0
                    else:
                        t_start_num = mbp_time_sec[phase_start_idx]
                        t_end_num = mbp_time_sec[phase_end_idx]
                        for w in range(num_wv):
                            stream = wv_streams[w]
                            mask_wv = (stream["time_sec"] >= t_start_num) & (stream["time_sec"] <= t_end_num)
                            count_wv = int(np.sum(mask_wv))
                            e = wv_list[w]
                            if count_wv == 0:
                                e["Label"] = stream["label"]
                                e["WV_SensorError"] = True
                                e["TestIndex"] = stream["test_index"]
                                e["ID"] = stream["id"]
                                e["NumSamples"] = 0
                            elif count_wv < 2:
                                e["Label"] = stream["label"]
                                e["WV_SensorError"] = True
                                e["TestIndex"] = stream["test_index"]
                                e["ID"] = stream["id"]
                            else:
                                e["Label"] = stream["label"]
                                e["Time"] = stream["time"][mask_wv]
                                e["Pressure"] = stream["pressure"][mask_wv]
                                e["Vbatt"] = stream["vbatt"][mask_wv]
                                e["Temperature"] = stream["temperature"][mask_wv]
                                e["RSSI"] = stream["rssi"][mask_wv]
                                first_i = _find_first(mask_wv)
                                last_i = _find_last(mask_wv)
                                e["StartTime"] = stream["time"][first_i]
                                e["EndTime"] = stream["time"][last_i]
                                e["TestIndex"] = stream["test_index"]
                                e["ID"] = stream["id"]
                                e["MeanPressure"] = round(float(np.nanmean(stream["pressure"][mask_wv])), 1)
                                e["NumSamples"] = count_wv
                    phase["WV"] = wv_list

                    # ===== COMMIT: GPS (source lines 926-997) =====
                    phase["GPS_Time"] = np.zeros(0, dtype="datetime64[us]")
                    phase["GPS_Long"] = np.zeros(0)
                    phase["GPS_Lat"] = np.zeros(0)
                    phase["GPS_Speed"] = np.zeros(0)
                    phase["GPS_Speed_RPM"] = np.zeros(0)
                    phase["GPS_Ibatt"] = np.zeros(0)
                    phase["GPS_Vbatt"] = np.zeros(0)
                    phase["GPS_RPM_axle"] = np.zeros(0)
                    phase["GPS_StartTime"] = None
                    phase["GPS_EndTime"] = None
                    phase["GPS_NumSamples"] = 0
                    phase["GPS_SensorError"] = False

                    if gps.get("has_data"):
                        bc_end_times = [e["EndTime"] for e in bc_list if e["EndTime"] is not None]
                        bc_end_max = max(bc_end_times) if bc_end_times else None

                        if bc_end_max is not None:
                            end_time_abs = bc_end_max
                        else:
                            # Bug fix (documented in module docstring): MATLAB references an
                            # undefined `MBP.time(phaseEndIdx)` here. Using the clearly-intended
                            # mbp_time[phase_end_idx] instead.
                            end_time_abs = mbp_time[phase_end_idx]

                        t_start_num = mbp_time[phase_start_idx]
                        t_end_num = end_time_abs
                        mask_gps = (gps["time"] >= t_start_num) & (gps["time"] <= t_end_num)
                        n_gps = int(np.sum(mask_gps))

                        if n_gps < 2:
                            phase["GPS_SensorError"] = True
                        else:
                            phase["GPS_Time"] = gps["time"][mask_gps]
                            for out_key, gps_key in (
                                ("GPS_Long", "long"), ("GPS_Lat", "lat"), ("GPS_Speed", "speed"),
                                ("GPS_Speed_RPM", "speed_rpm"), ("GPS_Ibatt", "gps_ibatt"),
                                ("GPS_Vbatt", "gps_vbatt"), ("GPS_RPM_axle", "rpm_axle"),
                            ):
                                col = gps.get(gps_key)
                                if col is not None:
                                    phase[out_key] = col[mask_gps]
                            first_i = _find_first(mask_gps)
                            last_i = _find_last(mask_gps)
                            phase["GPS_StartTime"] = gps["time"][first_i]
                            phase["GPS_EndTime"] = gps["time"][last_i]
                            phase["GPS_NumSamples"] = n_gps
                    else:
                        phase["GPS_SensorError"] = True

                    test_brake.append(phase)
                elif verbose:
                    print(f"[Phase {len(test_brake) + 1}] MBP discarded: dP={total_drop:.3f} < {MIN_P_DROP:.3f}")

                _reset_phase_state()
                skip_bc_due_to_sv = False
                sv_hold_active = False
                sv_hold_start_sec = np.nan
                if verbose:
                    print("  Moving to next phase scan...")

        # ---- Realtime capture of post +20s / +60s (source lines 1019-1124) ----
        t_now = mbp_time_sec[k]

        for check, bc_field, mbp_field, valid_field, time_field in (
            (post20_check, "Post20s_BC_Pressure", "Post20s_MBP_Pressure", "Post20s_Valid", "Post20s_Time"),
            (post60_check, "Post60s_BC_Pressure", "Post60s_MBP_Pressure", "Post60s_Valid", "Post60s_Time"),
        ):
            if check["active"] and t_now >= check["time_limit"]:
                ph = test_brake[check["phase_idx"]]
                t_end_s = _seconds_since(np.asarray([ph["MBP_EndOfBrakeTime"]]), mbp_t0)[0]
                t_cap = check["time_limit"]

                mask = (mbp_time_sec > t_end_s) & (mbp_time_sec <= t_cap)
                stable = bool(np.any(mask))  # gradient-stability check intentionally disabled, matching source

                if stable:
                    ph[valid_field] = True
                    ph[time_field] = mbp_t0 + np.timedelta64(int(round(t_cap * 1e6)), "us")
                    ph[mbp_field] = _nearest_interp(mbp_time_sec, mbp_pressure, t_cap)
                    if num_bc > 0:
                        bc_press = np.full(num_bc, np.nan)
                        for r in range(num_bc):
                            stream = bc_streams[r]
                            if len(stream["time_sec"]) > 0 and len(stream["pressure"]) > 0:
                                bc_press[r] = _nearest_interp(stream["time_sec"], stream["pressure"], t_cap)
                        ph[bc_field] = bc_press
                else:
                    ph[valid_field] = False

                check["active"] = False

    if verbose:
        print(f"[detect_braking_struct_beta] Done. Phases: {len(test_brake)}")

    return test_brake, bc_indices, wv_indices
