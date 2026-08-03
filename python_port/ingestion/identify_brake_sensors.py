"""Python port of matlab/preprocessing/identify_brake_sensors.m.

Steady-window classifier with hard constraints:
  - LPF 1 Hz (Butterworth 4th order, zero-phase) on a uniform 5 Hz grid
  - Compute dP/dt (bar/s)
  - Find contiguous "steady" regions where for ALL sensors:
      |dP/dt| < 0.01  AND nearest raw sample <= 3 s away
  - Apply only on a steady region that contains any pressure > 4.6 bar
  - Window can be short; if longer than 10 min, clip to 10 min around max pressure
  - Classify by median pressure in that window: >4.6 -> MBP, <0.2 -> BC, else -> WV
  - Enforce: exactly 1 MBP; equal numbers of WV and BC among the rest
  - If no candidate steady region is found, skip classification and return the
    original order with empty labels.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, List, Optional, Tuple

import numpy as np
from scipy.signal import butter, filtfilt


@dataclass
class SteadyInfo:
    candidate_found: bool
    reason: Optional[str] = None
    tgrid: Optional[np.ndarray] = None
    p_filtered: Optional[np.ndarray] = None
    dp_dt: Optional[np.ndarray] = None
    steady_all: Optional[np.ndarray] = None
    steady_mask: Optional[np.ndarray] = None
    window_idx: Optional[Tuple[int, int]] = None
    window_time: Optional[Tuple[Any, Any]] = None
    max_window_min: Optional[float] = None
    from_cache: bool = False


def _contiguous_blocks(x: np.ndarray) -> np.ndarray:
    """Return Nx2 array of [start, end] (inclusive, 0-based) for runs of True in x."""
    x = np.asarray(x, dtype=bool)
    if not x.any():
        return np.zeros((0, 2), dtype=int)
    d = np.diff(np.concatenate(([False], x, [False])).astype(int))
    starts = np.where(d == 1)[0]
    ends = np.where(d == -1)[0] - 1
    return np.column_stack([starts, ends])


def _nearest_gap_seconds(tk_seconds: np.ndarray, query_seconds: np.ndarray) -> np.ndarray:
    """abs(query - nearest tk) for each query point, clamped at the array bounds
    (mirrors interp1(tkS, idx, t0s, 'nearest', 'extrap'))."""
    n = len(tk_seconds)
    idx = np.searchsorted(tk_seconds, query_seconds)
    idx_hi = np.clip(idx, 0, n - 1)
    idx_lo = np.clip(idx - 1, 0, n - 1)
    d_hi = np.abs(query_seconds - tk_seconds[idx_hi])
    d_lo = np.abs(query_seconds - tk_seconds[idx_lo])
    return np.minimum(d_hi, d_lo)


def _retime_linear(tk_seconds: np.ndarray, pk: np.ndarray, tgrid_seconds: np.ndarray) -> np.ndarray:
    """Linear interpolation onto tgrid, NaN outside [tk_seconds[0], tk_seconds[-1]]
    (mirrors MATLAB timetable retime(..., 'linear'), which does not extrapolate)."""
    return np.interp(tgrid_seconds, tk_seconds, pk, left=np.nan, right=np.nan)


def sort_by_label(nodo: List[dict]) -> List[dict]:
    """Sort MBP first, then WV, then BC (Unknown/blank last)."""
    order_rank = {"MBP": 0, "WV": 1, "BC": 2}
    return sorted(nodo, key=lambda s: order_rank.get(str(s.get("Label") or ""), 3))


def _skip_and_fill_empty(nodo: List[dict], ids: List[str], reason: str) -> Tuple[List[dict], List[dict], SteadyInfo]:
    nodo_out = [dict(s) for s in nodo]
    for s in nodo_out:
        s["Label"] = ""
    roles_table = [
        {"OriginalIdx": i, "ID": ids[i], "Label": "", "MedianP_Steady": np.nan}
        for i in range(len(nodo))
    ]
    print(f"\n[identify_brake_sensors] SKIPPED: {reason}")
    if nodo and nodo[0].get("Time") is not None and len(nodo[0]["Time"]) > 0:
        t0, t1 = nodo[0]["Time"][0], nodo[0]["Time"][-1]
        if not (np.isnat(t0) or np.isnat(t1)):
            span_h = (t1 - t0) / np.timedelta64(1, "h")
            print(f"  Data span (sensor 1): {t0} -> {t1} ({span_h:.1f} h)")
    return nodo_out, roles_table, SteadyInfo(candidate_found=False, reason=reason)


def identify_brake_sensors(
    nodo: List[dict],
    fs_grid: float = 5.0,
    fc: float = 1.0,
    grad_tol: float = 0.01,
    max_gap_sec: float = 3.0,
    max_window_min: float = 10.0,
    min_window_sec: float = 15.0,
) -> Tuple[List[dict], List[dict], SteadyInfo]:
    """Returns (nodo_out, roles_table, steady_info). nodo_out entries get a
    'Label' field and are re-ordered MBP -> WV -> BC (-> Unknown)."""
    n = len(nodo)
    if n == 0:
        raise ValueError("Empty Nodo.")

    ids = [str(s["ID"]) for s in nodo]
    T: List[np.ndarray] = [None] * n
    P: List[np.ndarray] = [None] * n

    for k in range(n):
        t = np.asarray(nodo[k]["Time"]).ravel()
        x = np.asarray(nodo[k]["Pressure"], dtype=float).ravel()
        good = ~np.isnat(t) & np.isfinite(x)
        t, x = t[good], x[good]

        if len(t):
            order = np.argsort(t, kind="stable")
            t, x = t[order], x[order]
            t, unique_idx = np.unique(t, return_index=True)
            x = x[unique_idx]

        if len(t) < 2:
            return _skip_and_fill_empty(nodo, ids, f"Sensor {ids[k]} has <2 unique time samples.")

        T[k], P[k] = t, x

    t0 = max(t[0] for t in T)
    t1 = min(t[-1] for t in T)
    if np.isnat(t0) or np.isnat(t1) or t0 >= t1:
        return _skip_and_fill_empty(nodo, ids, "No temporal overlap across sensors.")

    # ---- grid & filter ----
    dt = np.timedelta64(int(round(1e9 / fs_grid)), "ns")
    tgrid = np.arange(t0, t1 + dt, dt)
    m = len(tgrid)
    wn = fc / (fs_grid / 2)
    if wn >= 1:
        return _skip_and_fill_empty(nodo, ids, "Invalid LPF setup: Fc must be < Fs/2.")
    b, a = butter(4, wn)

    tgrid_seconds = (tgrid - tgrid[0]) / np.timedelta64(1, "s")

    Pr = np.full((m, n), np.nan)
    Pf = np.full((m, n), np.nan)
    dP = np.full((m, n), np.nan)
    valid_near = np.zeros((m, n), dtype=bool)

    for k in range(n):
        tk_seconds = (T[k] - tgrid[0]) / np.timedelta64(1, "s")
        pk = P[k]

        y = _retime_linear(tk_seconds, pk, tgrid_seconds)
        Pr[:, k] = y

        gap = _nearest_gap_seconds(tk_seconds, tgrid_seconds)
        valid_near[:, k] = gap <= max_gap_sec

        # simple inpaint for filtering only (keep NaN after)
        yi = y.copy()
        nan_mask = np.isnan(yi)
        if nan_mask.any():
            good_idx = np.flatnonzero(~nan_mask)
            if good_idx.size:
                yi[nan_mask] = np.interp(np.flatnonzero(nan_mask), good_idx, yi[good_idx])

        if np.all(~np.isnan(yi)):
            yf = filtfilt(b, a, yi)
        else:
            yf = yi

        yf = yf.copy()
        yf[~valid_near[:, k]] = np.nan
        Pf[:, k] = yf

        g = np.concatenate(([0.0], np.diff(yf))) * fs_grid
        bad = np.isnan(yf) | np.concatenate(([False], np.isnan(yf[:-1])))
        g[bad] = np.nan
        dP[:, k] = g

    # ---- steady mask (all sensors must be steady & valid) ----
    steady_per_sensor = (np.abs(dP) < grad_tol) & valid_near
    steady_all = np.all(steady_per_sensor, axis=1)

    # ---- find steady blocks that contain any P>4.6 ----
    blocks = _contiguous_blocks(steady_all)
    min_win_td = np.timedelta64(int(round(min_window_sec * 1e9)), "ns")
    cand = []
    for i1b, i2b in blocks:
        if (tgrid[i2b] - tgrid[i1b]) < min_win_td:
            continue
        seg = Pf[i1b:i2b + 1, :]
        if np.any(seg > 4.6):
            cand.append((i1b, i2b))
    if not cand:
        # fallback: allow even shorter steady blocks if they contain P>4.6
        for i1b, i2b in blocks:
            seg = Pf[i1b:i2b + 1, :]
            if np.any(seg > 4.6):
                cand.append((i1b, i2b))
    if not cand:
        info = SteadyInfo(
            candidate_found=False,
            reason="No steady window found that contains any pressure > 4.6 bar.",
            tgrid=tgrid, p_filtered=Pf, dp_dt=dP, steady_all=steady_all,
        )
        nodo_out, roles_table, _ = _skip_and_fill_empty(
            nodo, ids, "No steady window found that contains any pressure > 4.6 bar."
        )
        return nodo_out, roles_table, info

    # pick candidate with the longest duration
    durations = [i2 - i1 + 1 for i1, i2 in cand]
    i1, i2 = cand[int(np.argmax(durations))]

    # clip to MaxWindowMin around time of maximum pressure within block
    max_win_samples = int(round(max_window_min * 60 * fs_grid))
    seg_p = Pf[i1:i2 + 1, :]
    idx_local_max = int(np.argmax(np.nanmax(seg_p, axis=1)))
    center = i1 + idx_local_max
    if (i2 - i1 + 1) > max_win_samples:
        half = max_win_samples // 2
        a_ = max(center - half, i1)
        b_ = min(a_ + max_win_samples - 1, i2)
        i1, i2 = a_, b_
    steady_mask = np.zeros(m, dtype=bool)
    steady_mask[i1:i2 + 1] = True

    # ---- classification by median pressure in chosen steady window ----
    median_p = np.full(n, np.nan)
    for k in range(n):
        pk = Pf[steady_mask, k]
        pk = pk[~np.isnan(pk)]
        if pk.size:
            median_p[k] = np.median(pk)

    roles = np.full(n, "WV", dtype=object)
    roles[median_p > 4.6] = "MBP"
    roles[median_p < 0.2] = "BC"
    roles[~np.isfinite(median_p)] = "Unknown"

    # ---- enforce exactly ONE MBP ----
    mbp_idx = np.flatnonzero(roles == "MBP")
    if mbp_idx.size == 0:
        imax = int(np.nanargmax(median_p)) if np.any(np.isfinite(median_p)) else None
        if imax is not None and np.isfinite(median_p[imax]):
            roles[imax] = "MBP"
            mbp_idx = np.array([imax])
    elif mbp_idx.size > 1:
        jmax = mbp_idx[np.argmax(median_p[mbp_idx])]
        flip = np.setdiff1d(mbp_idx, [jmax])
        roles[flip] = "WV"
        mbp_idx = np.array([jmax])

    # ---- enforce equal BC and WV among the rest ----
    rest = np.setdiff1d(np.arange(n), mbp_idx)
    num_rest = len(rest)
    target = num_rest // 2

    is_bc = roles[rest] == "BC"
    excess_bc = int(is_bc.sum()) - target
    if excess_bc > 0:
        rc = rest[is_bc]
        # sort descending by MedianP (NaN last), move the highest (closest to 0.2 from below)
        vals = median_p[rc]
        order = sorted(range(len(rc)), key=lambda i: (np.isnan(vals[i]), -vals[i] if not np.isnan(vals[i]) else 0))
        move = rc[order[:excess_bc]]
        roles[move] = "WV"

    is_bc = roles[rest] == "BC"
    need_bc = target - int(is_bc.sum())
    if need_bc > 0:
        rc = rest[roles[rest] == "WV"]
        vals = median_p[rc]
        order = sorted(range(len(rc)), key=lambda i: (np.isnan(vals[i]), vals[i] if not np.isnan(vals[i]) else 0))
        move = rc[order[:need_bc]]
        roles[move] = "BC"

    # ---- produce outputs: LABEL + SORTED Nodo ----
    nodo_labeled = [dict(s) for s in nodo]
    for k in range(n):
        nodo_labeled[k]["Label"] = str(roles[k])

    mbp_idx = np.flatnonzero(roles == "MBP")
    wv_idx = np.flatnonzero(roles == "WV")
    bc_idx = np.flatnonzero(roles == "BC")
    unk_idx = np.flatnonzero(roles == "Unknown")
    order = np.concatenate([mbp_idx, wv_idx, bc_idx, unk_idx]).astype(int)

    nodo_out = [nodo_labeled[i] for i in order]
    roles_table = [
        {
            "OriginalIdx": int(i),
            "ID": ids[i],
            "Label": str(roles[i]),
            "MedianP_Steady": float(median_p[i]),
        }
        for i in order
    ]

    print("\n[identify_brake_sensors]")
    print(f"  Steady window used: {tgrid[i1]} -> {tgrid[i2]} "
          f"({(tgrid[i2] - tgrid[i1]) / np.timedelta64(1, 'm'):.1f} min)")
    print(f"  Grid Fs = {fs_grid:.1f} Hz, LPF Fc = {fc:.1f} Hz, "
          f"|dP/dt| < {grad_tol:.3f} bar/s, MaxGap <= {max_gap_sec:.0f} s")
    print("  Classification by median pressure in steady window: >4.6=MBP, <0.2=BC, else=WV")
    for row in roles_table:
        print(f"    {row}")

    steady_info = SteadyInfo(
        candidate_found=True,
        tgrid=tgrid, p_filtered=Pf, dp_dt=dP, steady_all=steady_all,
        steady_mask=steady_mask, window_idx=(i1, i2),
        window_time=(tgrid[i1], tgrid[i2]), max_window_min=max_window_min,
    )
    return nodo_out, roles_table, steady_info
