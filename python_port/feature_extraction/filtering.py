"""Port of the causal filtering block in matlab/main/Algorithm_main_batch.m
(lines ~52-131), applied to each Test(j).Pressure before
detect_braking_struct_beta.m consumes it.

Two independent filter cascades run on raw Pressure:
  - 1 Hz cascade: 20-sample causal moving average -> causal 1st-order
    Butterworth (fc=1Hz, Fs=40Hz) -> Pressure_filter. Its discrete
    derivative -> 20-sample causal moving average -> Gradient_pressure_filtered.
  - 10 Hz cascade (independent, from raw Pressure again, not from
    Pressure_filter): 5-sample causal moving average -> causal 1st-order
    Butterworth (fc=10Hz, Fs=40Hz) -> Pressure_filter_10Hz.

Preserved from the source:
  - The moving average's warm-up divisor grows from 1 to window_size over
    the first window_size samples (not a fixed-window NaN-padded average).
  - The Butterworth stage's cold start (`y[0] = b[0]*x[0]`, no `b[1]*x[-1]`
    or `a[1]*y[-1]` term) -- this is exactly scipy.signal.lfilter's default
    zero-initial-state behavior, so no manual recursion is needed for that
    part.
  - Gradient_pressure is the derivative of the *filtered* pressure
    (Pressure_filter), not raw Pressure.

Deviation from the MATLAB source: the moving average is computed via a
cumulative-sum identity instead of MATLAB's explicit circular-buffer loop.
The two are numerically equivalent (verified in
python_port/tests/test_feature_extraction_smoke.py against an independent
reference recursion) -- this is a vectorization, not a behavior change.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy.signal import butter, lfilter


@dataclass(frozen=True)
class FilteredPressure:
    pressure_mean_filter: np.ndarray
    pressure_filter: np.ndarray
    gradient_pressure: np.ndarray
    gradient_pressure_filtered: np.ndarray
    pressure_filter_10hz: np.ndarray


def _causal_moving_average(x: np.ndarray, window: int) -> np.ndarray:
    """Causal moving average with warm-up divisor min(i+1, window).

    Equivalent to Algorithm_main_batch.m's circular buffer
    (`movingSum/min(c1,windowSize)`): at sample i (0-based), the mean is
    over the last min(i+1, window) samples ending at i.
    """
    n = len(x)
    csum = np.cumsum(x, dtype=np.float64)
    window_sum = csum.copy()
    if n > window:
        window_sum[window:] = csum[window:] - csum[:-window]
    divisor = np.minimum(np.arange(1, n + 1), window)
    return window_sum / divisor


def apply_causal_filters(pressure: np.ndarray, fs: float = 40.0) -> FilteredPressure:
    """Port of Algorithm_main_batch.m's per-channel filtering loop (lines ~65-131)."""
    pressure = np.asarray(pressure, dtype=np.float64)
    n = len(pressure)

    if n == 0:
        empty = np.zeros(0, dtype=np.float64)
        return FilteredPressure(empty, empty, empty, empty, empty)

    dt = 1.0 / fs
    window_size = 20
    window_grad = 20
    b, a = butter(1, 1.0 / (fs / 2))

    window_size_buildup = 5
    fc_buildup = 10.0
    b_buildup, a_buildup = butter(1, fc_buildup / (fs / 2))

    pressure_mean_filter = _causal_moving_average(pressure, window_size)
    pressure_filter = lfilter(b, a, pressure_mean_filter)

    gradient_pressure = np.empty(n, dtype=np.float64)
    gradient_pressure[0] = 0.0
    if n > 1:
        gradient_pressure[1:] = np.diff(pressure_filter) / dt
    gradient_pressure_filtered = _causal_moving_average(gradient_pressure, window_grad)

    pressure_mean_filter_10 = _causal_moving_average(pressure, window_size_buildup)
    pressure_filter_10hz = lfilter(b_buildup, a_buildup, pressure_mean_filter_10)

    return FilteredPressure(
        pressure_mean_filter=pressure_mean_filter,
        pressure_filter=pressure_filter,
        gradient_pressure=gradient_pressure,
        gradient_pressure_filtered=gradient_pressure_filtered,
        pressure_filter_10hz=pressure_filter_10hz,
    )
