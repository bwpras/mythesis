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

Streaming refactor (new, not part of the MATLAB port): `CausalFilterState`
carries this filter's state (the moving-average tail + the Butterworth
`lfilter` initial-state vectors + the last filtered-pressure value for the
gradient) across repeated `.feed()` calls, so a live watcher can filter one
newly-arrived chunk at a time instead of needing the whole day's pressure
array up front. `apply_causal_filters()` below is now a thin wrapper: a
fresh `CausalFilterState().feed(pressure)` -- batch is a provable special
case of the same code path the live pipeline runs, matching the same
pattern used for `BrakingCycleDetector` in `braking_detection.py`.
"""
from __future__ import annotations

from dataclasses import dataclass, field

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


def _causal_moving_average_chunk(tail: np.ndarray, chunk: np.ndarray, window: int) -> tuple:
    """Moving average for one new chunk, given the persisted tail (last
    <=window-1 raw samples) of everything fed before it. Returns (values for
    this chunk only, new tail to persist). Prepending the tail and reusing
    the existing whole-array `_causal_moving_average()` unmodified, then
    slicing off the tail-length prefix, reproduces the original's warm-up
    divisor (min(i+1, window)) exactly: an empty tail (first-ever call) is
    mathematically identical to `i` starting at 0 in the whole-array
    version."""
    combined = np.concatenate([tail, chunk]) if len(tail) else chunk
    full = _causal_moving_average(combined, window)
    values = full[len(tail):]
    new_tail = combined[-(window - 1):] if window > 1 else combined[:0]
    return values, new_tail


@dataclass
class CausalFilterState:
    """Per-sensor resumable state for `apply_causal_filters()`'s two filter
    cascades. Call `.feed(raw_pressure_chunk)` once per newly-arrived chunk
    (e.g. one new `.bin` file's samples for this sensor); state persists
    across calls so the live watcher never needs to re-filter from the
    start of the day."""

    fs: float = 40.0
    _tail_raw: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float64))
    _zi_1hz: "np.ndarray | None" = None
    _prev_pressure_filter: float = float("nan")
    _tail_grad: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float64))
    _tail_raw_10: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float64))
    _zi_10hz: "np.ndarray | None" = None
    _seen_any: bool = False

    def feed(self, raw_pressure_chunk: np.ndarray) -> FilteredPressure:
        pressure = np.asarray(raw_pressure_chunk, dtype=np.float64)
        n = len(pressure)
        if n == 0:
            empty = np.zeros(0, dtype=np.float64)
            return FilteredPressure(empty, empty, empty, empty, empty)

        dt = 1.0 / self.fs
        window_size = 20
        window_grad = 20
        window_size_buildup = 5
        b, a = butter(1, 1.0 / (self.fs / 2))
        b_buildup, a_buildup = butter(1, 10.0 / (self.fs / 2))

        if self._zi_1hz is None:
            self._zi_1hz = np.zeros(max(len(a), len(b)) - 1)
        if self._zi_10hz is None:
            self._zi_10hz = np.zeros(max(len(a_buildup), len(b_buildup)) - 1)

        pressure_mean_filter, self._tail_raw = _causal_moving_average_chunk(
            self._tail_raw, pressure, window_size)
        pressure_filter, self._zi_1hz = lfilter(b, a, pressure_mean_filter, zi=self._zi_1hz)

        gradient_pressure = np.empty(n, dtype=np.float64)
        if not self._seen_any:
            gradient_pressure[0] = 0.0
            self._seen_any = True
        else:
            gradient_pressure[0] = (pressure_filter[0] - self._prev_pressure_filter) / dt
        if n > 1:
            gradient_pressure[1:] = np.diff(pressure_filter) / dt
        self._prev_pressure_filter = float(pressure_filter[-1])

        gradient_pressure_filtered, self._tail_grad = _causal_moving_average_chunk(
            self._tail_grad, gradient_pressure, window_grad)

        pressure_mean_filter_10, self._tail_raw_10 = _causal_moving_average_chunk(
            self._tail_raw_10, pressure, window_size_buildup)
        pressure_filter_10hz, self._zi_10hz = lfilter(
            b_buildup, a_buildup, pressure_mean_filter_10, zi=self._zi_10hz)

        return FilteredPressure(
            pressure_mean_filter=pressure_mean_filter,
            pressure_filter=pressure_filter,
            gradient_pressure=gradient_pressure,
            gradient_pressure_filtered=gradient_pressure_filtered,
            pressure_filter_10hz=pressure_filter_10hz,
        )


def apply_causal_filters(pressure: np.ndarray, fs: float = 40.0) -> FilteredPressure:
    """Port of Algorithm_main_batch.m's per-channel filtering loop (lines ~65-131).
    Now a thin wrapper: a fresh `CausalFilterState` fed the whole array in
    one call -- batch is the same code path a live watcher runs, just with
    one big chunk instead of many small ones."""
    return CausalFilterState(fs=fs).feed(pressure)
