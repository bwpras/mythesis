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

Streaming refactor (new, not part of the MATLAB port): the scan loop that
used to be ~30 local variables scoped to one whole-array call is now
`BrakingCycleDetector`, a resumable object whose `.feed()` can be called
once per newly-arrived chunk of samples (e.g. one new `_p.bin` file),
carrying an in-progress braking cycle's buffered state across calls instead
of discarding it if the array it was given happened to end mid-phase.
`detect_braking_struct_beta()` below is now a thin wrapper: one `.feed()`
call with the whole day's data, then `.flush_final()` -- batch is a
*provable special case* of the exact same code path the live pipeline
runs, not a second implementation that could drift from it. See
`python_port/tests/test_braking_detection_incremental.py` for the
regression proof that chunked feeding reproduces whole-array output
exactly.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import numpy as np

# --------------------------------------------------------------------------
# Small helpers mirroring MATLAB idioms used throughout the source file
# (unchanged from the pre-streaming-refactor version -- pure functions, no
# detector state).
# --------------------------------------------------------------------------


def _unique_stable(x: np.ndarray) -> tuple:
    """Port of MATLAB's unique(x, 'stable'): first-occurrence order preserved.

    np.unique(x, return_index=True) gives the index of each value's first
    occurrence, associated with the *sorted* unique values. Sorting those
    indices ascending recovers first-occurrence (i.e. original relative)
    order, since a value's first-occurrence index is order-independent of
    how the unique values themselves get sorted.

    Streaming note: called on a growing array every `.feed()` call (see
    `BrakingCycleDetector._recompute_mbp_view`/`_recompute_stream_view`).
    Because this only ever operates on an *append-only* array, a value's
    first-occurrence position among previously-seen elements can never
    change as new elements are appended -- a newly-appended duplicate of an
    already-seen timestamp is necessarily a *later* occurrence, so it never
    supplants the earlier one. This means any index a caller already holds
    into a previous call's output (e.g. a BC/WV stream's `idx_pointer`)
    stays valid after a later re-dedup of the grown array. Verified
    empirically in test_braking_detection_incremental.py.
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
# Channel schema + chunk-shape helpers for the streaming detector
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class ChannelSchema:
    """Identity of one physical sensor channel, fixed for a detector's whole
    lifetime. `id` must be unique across the MBP + all BC + all WV channels
    of one detector instance -- true by construction for any real kit, since
    Stage 1's `load_nodo_data()` already keys its per-sensor `Nodo` records
    by this same ID in a plain dict."""

    role: str  # "MBP" | "BC" | "WV"
    label: str
    id: object
    test_index: int


def _channel_to_chunk(channel: dict) -> dict:
    """Nodo-with-filtered-fields channel dict -> the chunk shape
    `BrakingCycleDetector.feed()` expects for one sensor."""
    return {
        "time": np.asarray(channel["Time"]),
        "pressure_filter": np.asarray(channel.get("Pressure_filter", []), dtype=np.float64),
        "pressure_filter_10hz": np.asarray(channel.get("Pressure_filter_10Hz", []), dtype=np.float64),
        "gradient_filtered": np.asarray(channel.get("Gradient_pressure_filtered", []), dtype=np.float64),
        "vbatt": channel.get("Vbatt"),
        "temperature": channel.get("Temperature"),
        "rssi": channel.get("RSSI"),
    }


def _channel_to_gps_chunk(channel: dict) -> Optional[dict]:
    time = channel.get("Time_GPS")
    if time is None:
        return None
    return {
        "time": np.asarray(time),
        "long": channel.get("Long"),
        "lat": channel.get("Lat"),
        "speed": channel.get("Speed"),
        "speed_rpm": channel.get("Speed_RPM"),
        "gps_ibatt": channel.get("GPS_Ibatt"),
        "gps_vbatt": channel.get("GPS_Vbatt"),
        "rpm_axle": channel.get("RPM_axle"),
    }


# --------------------------------------------------------------------------
# BrakingCycleDetector -- the resumable scan
# --------------------------------------------------------------------------


class BrakingCycleDetector:
    """Resumable port of detect_braking_struct_beta.m's scan loop.

    Construct once per kit (via `from_schema()` for a live watcher, or
    `from_test_list()` for one-shot batch use), then call `.feed()` with
    each newly-arrived chunk of already-causally-filtered samples per
    sensor (see `feature_extraction.filtering.CausalFilterState` for
    producing that filtered chunk from raw pressure) and `.feed_gps()`
    independently as GPS data arrives. Call `.flush_completed_phases()`
    after each `.feed()` to collect newly-finalized phases, and
    `.flush_final()` once at stream teardown to release the last phase(s)
    regardless of pending post-check status.

    Every phase-detection threshold below is unchanged from the original
    module-level function -- this refactor only relocates state, it does
    not alter behavior. See module docstring for the "batch is a special
    case of streaming" wrapper (`detect_braking_struct_beta()` below) and
    `test_braking_detection_incremental.py` for the equivalence proof.
    """

    MBP_LOWER, MBP_UPPER = 4.7, 5.2
    GRAD_ZERO_TOL = 0.02
    STABLE_FRAC = 0.6
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

    def __init__(
        self,
        mbp: ChannelSchema,
        bc_schemas: list,
        wv_schemas: list,
        window_size: int = 80,
        stable_point_count: Optional[int] = None,
        verbose: bool = True,
    ):
        self.window_size = window_size
        self.verbose = verbose

        self.mbp_label = mbp.label
        self.mbp_id = mbp.id
        self.mbp_test_index = mbp.test_index

        self.bc_schemas = list(bc_schemas)
        self.wv_schemas = list(wv_schemas)
        self.bc_indices = [s.test_index for s in self.bc_schemas]
        self.wv_indices = [s.test_index for s in self.wv_schemas]
        self.num_bc = len(self.bc_schemas)
        self.num_wv = len(self.wv_schemas)

        # STABLE_POINT_COUNT: the original computes this once as
        # ceil(STABLE_FRAC * min(window_size, num_mbp_samples)) using the
        # WHOLE day's final deduped sample count -- knowable in batch, not
        # in a live stream. `from_test_list()` (batch path) passes an
        # explicit override computed the same way as the original, for
        # byte-identical output. `from_schema()` (live path) leaves this
        # None, pinning to ceil(STABLE_FRAC*window_size) -- exactly what
        # the original formula reduces to once num_mbp_samples >= window_size,
        # true for every real day-length dataset. See
        # test_braking_detection_incremental.py for a case starting with a
        # chunk shorter than window_size proving this pin is safe.
        if stable_point_count is None:
            stable_point_count = max(1, int(np.ceil(self.STABLE_FRAC * window_size)))
        self.stable_point_count = stable_point_count

        # ---- growing, append-only per-channel state ----
        self._mbp_t0: Optional[np.datetime64] = None

        self._mbp_time_raw = np.zeros(0, dtype="datetime64[us]")
        self._mbp_pressure_raw = np.zeros(0, dtype=np.float64)
        self._mbp_pressure10hz_raw = np.zeros(0, dtype=np.float64)
        self._mbp_gradient_raw = np.zeros(0, dtype=np.float64)
        self._mbp_vbatt_raw = np.zeros(0, dtype=np.float64)
        self._mbp_temp_raw = np.zeros(0, dtype=np.float64)
        self._mbp_rssi_raw = np.zeros(0, dtype=np.float64)

        self._mbp_time = np.zeros(0, dtype="datetime64[us]")
        self._mbp_time_sec = np.zeros(0, dtype=np.float64)
        self._mbp_pressure = np.zeros(0, dtype=np.float64)
        self._mbp_pressure10hz = np.zeros(0, dtype=np.float64)
        self._mbp_gradient = np.zeros(0, dtype=np.float64)
        self._mbp_vbatt_aligned = np.zeros(0, dtype=np.float64)
        self._mbp_temp_aligned = np.zeros(0, dtype=np.float64)
        self._mbp_rssi_aligned = np.zeros(0, dtype=np.float64)

        self._bc_streams = [self._make_bc_stream(s) for s in self.bc_schemas]
        self._wv_streams = [self._make_wv_stream(s) for s in self.wv_schemas]

        self._gps_time_raw = np.zeros(0, dtype="datetime64[us]")
        self._gps_long_raw = np.zeros(0, dtype=np.float64)
        self._gps_lat_raw = np.zeros(0, dtype=np.float64)
        self._gps_speed_raw = np.zeros(0, dtype=np.float64)
        self._gps_speed_rpm_raw = np.zeros(0, dtype=np.float64)
        self._gps_ibatt_raw = np.zeros(0, dtype=np.float64)
        self._gps_vbatt_raw = np.zeros(0, dtype=np.float64)
        self._gps_rpm_axle_raw = np.zeros(0, dtype=np.float64)
        self._gps_has_data = False
        self._gps: dict = {"has_data": False}

        self._k_next = 0
        self._test_brake: list = []
        self._flushed_count = 0

        # ---- mid-scan state (must survive a .feed() call ending mid-phase) ----
        self._in_braking = False
        self._init_pressure = np.nan
        self._mbp_time_buf: list = []
        self._mbp_pressure_buf: list = []
        self._mbp_pressure10hz_buf: list = []
        self._mbp_gradient_buf: list = []
        self._phase_start_idx: Optional[int] = None
        self._phase_start_time_sec = np.nan

        self._samples_since_drop = 0
        self._control_window_check = False
        self._control_window = False
        self._control_window_start_sec = np.nan
        self._control_window_fluctuation = False
        # Set at every phase onset (mirrors the original's onset-branch-only
        # assignment); must be a persisted attribute (not a bare local) so a
        # phase already mid-flight from a previous .feed() call still sees
        # the correct value on the first k of the next call.
        self._system_stopped = False

        self._sv_hold_active = False
        self._sv_hold_start_sec = np.nan
        self._skip_bc_due_to_sv = False

        self._bc_active = [False] * self.num_bc
        self._bc_time_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_time_sec_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_pressure_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_pressure10hz_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_gradient_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_vbatt_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_temp_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_rssi_buf: list = [[] for _ in range(self.num_bc)]
        self._bc_normal_braking = [False] * self.num_bc
        self._bc_sensor_error = [False] * self.num_bc
        self._bc_badstart = [False] * self.num_bc
        self._bc_low_braking = [False] * self.num_bc
        self._bc_start_above_thresh = [False] * self.num_bc
        self._bc_flat_start_near_zero = [False] * self.num_bc
        self._bc_already_engaged = [False] * self.num_bc
        self._bc_releasing_at_start = [False] * self.num_bc
        self._bc_flat_checked = [False] * self.num_bc

        self._post20_check = {"active": False, "time_limit": np.nan, "phase_idx": None}
        self._post60_check = {"active": False, "time_limit": np.nan, "phase_idx": None}

        if self.verbose:
            print(f"[BrakingCycleDetector] {self.num_bc} BC channel(s), {self.num_wv} WV channel(s).")

    # ---- construction helpers ----

    @staticmethod
    def _make_bc_stream(schema: ChannelSchema) -> dict:
        return {
            "test_index": schema.test_index, "label": schema.label, "id": schema.id,
            "time_raw": np.zeros(0, dtype="datetime64[us]"),
            "pressure_raw": np.zeros(0, dtype=np.float64),
            "pressure10hz_raw": np.zeros(0, dtype=np.float64),
            "gradient_raw": np.zeros(0, dtype=np.float64),
            "vbatt_raw": np.zeros(0, dtype=np.float64),
            "temperature_raw": np.zeros(0, dtype=np.float64),
            "rssi_raw": np.zeros(0, dtype=np.float64),
            "time": np.zeros(0, dtype="datetime64[us]"), "time_sec": np.zeros(0, dtype=np.float64),
            "pressure": np.zeros(0, dtype=np.float64), "pressure10hz": np.zeros(0, dtype=np.float64),
            "gradient": np.zeros(0, dtype=np.float64), "vbatt": np.zeros(0, dtype=np.float64),
            "temperature": np.zeros(0, dtype=np.float64), "rssi": np.zeros(0, dtype=np.float64),
            "idx_pointer": 0,
        }

    @staticmethod
    def _make_wv_stream(schema: ChannelSchema) -> dict:
        return {
            "test_index": schema.test_index, "label": schema.label, "id": schema.id,
            "time_raw": np.zeros(0, dtype="datetime64[us]"),
            "pressure_raw": np.zeros(0, dtype=np.float64),
            "vbatt_raw": np.zeros(0, dtype=np.float64),
            "temperature_raw": np.zeros(0, dtype=np.float64),
            "rssi_raw": np.zeros(0, dtype=np.float64),
            "time": np.zeros(0, dtype="datetime64[us]"), "time_sec": np.zeros(0, dtype=np.float64),
            "pressure": np.zeros(0, dtype=np.float64), "vbatt": np.zeros(0, dtype=np.float64),
            "temperature": np.zeros(0, dtype=np.float64), "rssi": np.zeros(0, dtype=np.float64),
        }

    @classmethod
    def from_schema(cls, mbp: ChannelSchema, bc: list, wv: list,
                     window_size: int = 80, verbose: bool = True) -> "BrakingCycleDetector":
        """Live-path constructor: schema comes from the label registry
        (already-known MBP/BC/WV sensor IDs for this kit), never re-derived
        per `.feed()` call."""
        return cls(mbp, bc, wv, window_size=window_size, stable_point_count=None, verbose=verbose)

    @classmethod
    def from_test_list(cls, test: list, window_size: int = 80, verbose: bool = True) -> "BrakingCycleDetector":
        """Batch-path constructor: discovers channels from `test` (mirrors
        the pre-refactor module-level discovery logic exactly), computes an
        explicit `stable_point_count` from the whole list's final deduped
        MBP sample count (for byte-identical fidelity with the pre-refactor
        `detect_braking_struct_beta()`), then feeds the whole list in one
        shot and returns the detector (not yet flushed -- caller decides
        when to flush)."""
        mbp_idx = None
        for i, channel in enumerate(test):
            label = str(channel.get("Label", "")).strip()
            if label.lower() == "mbp":
                mbp_idx = i
                break
        if mbp_idx is None:
            raise ValueError("No MBP channel found.")

        bc_idx_list, wv_idx_list = [], []
        for i, channel in enumerate(test):
            label = str(channel.get("Label", "")).strip().upper()
            if label.startswith("BC"):
                bc_idx_list.append(i)
            if label.startswith("WV"):
                wv_idx_list.append(i)

        mbp_channel = test[mbp_idx]
        mbp_schema = ChannelSchema(role="MBP", label=str(mbp_channel["Label"]),
                                    id=mbp_channel.get("ID"), test_index=mbp_idx)
        bc_schemas = [ChannelSchema(role="BC", label=str(test[i]["Label"]),
                                     id=test[i].get("ID"), test_index=i) for i in bc_idx_list]
        wv_schemas = [ChannelSchema(role="WV", label=str(test[i]["Label"]),
                                     id=test[i].get("ID"), test_index=i) for i in wv_idx_list]

        mbp_time_raw = np.asarray(mbp_channel["Time"])
        if len(mbp_time_raw) > 0:
            mbp_time_sec_raw = _seconds_since(mbp_time_raw, mbp_time_raw[0])
            mbp_time_sec_u, _ = _unique_stable(mbp_time_sec_raw)
            num_mbp_samples = len(mbp_time_sec_u)
        else:
            num_mbp_samples = 0
        stable_point_count = max(1, int(np.ceil(cls.STABLE_FRAC * min(window_size, max(num_mbp_samples, 1)))))

        detector = cls(mbp_schema, bc_schemas, wv_schemas, window_size=window_size,
                        stable_point_count=stable_point_count, verbose=verbose)

        chunk = {mbp_schema.id: _channel_to_chunk(mbp_channel)}
        for i in bc_idx_list:
            chunk[test[i].get("ID")] = _channel_to_chunk(test[i])
        for i in wv_idx_list:
            chunk[test[i].get("ID")] = _channel_to_chunk(test[i])
        detector.feed(chunk)

        gps_idx = mbp_idx if mbp_channel.get("Time_GPS") is not None else None
        if gps_idx is None:
            for i, channel in enumerate(test):
                if channel.get("Time_GPS") is not None:
                    gps_idx = i
                    break
        if gps_idx is not None:
            gps_chunk = _channel_to_gps_chunk(test[gps_idx])
            if gps_chunk is not None:
                detector.feed_gps(gps_chunk)

        return detector

    # ---- feeding ----

    def feed(self, chunk: dict) -> None:
        """chunk: {sensor_id: {"time", "pressure_filter", "pressure_filter_10hz",
        "gradient_filtered", "vbatt", "temperature", "rssi"}} -- ONLY the
        newly-arrived, already-causally-filtered samples for each channel. A
        sensor id absent from `chunk` this call is simply not extended this
        round."""
        mbp_chunk = chunk.get(self.mbp_id)
        if mbp_chunk is not None and len(mbp_chunk["time"]) > 0:
            self._append_mbp(mbp_chunk)

        for slot, schema in enumerate(self.bc_schemas):
            c = chunk.get(schema.id)
            if c is not None and len(c["time"]) > 0:
                self._append_stream(self._bc_streams[slot], c)

        for slot, schema in enumerate(self.wv_schemas):
            c = chunk.get(schema.id)
            if c is not None and len(c["time"]) > 0:
                self._append_stream(self._wv_streams[slot], c)

        if self._mbp_t0 is None:
            return  # no MBP epoch yet -- nothing scannable regardless

        self._recompute_mbp_view()
        for stream in self._bc_streams:
            self._recompute_stream_view(stream)
        for stream in self._wv_streams:
            self._recompute_stream_view(stream)

        self._scan(len(self._mbp_time))

    def feed_gps(self, chunk: Optional[dict]) -> None:
        """chunk: {"time", "long", "lat", "speed", "speed_rpm", "gps_ibatt",
        "gps_vbatt", "rpm_axle"} -- appended, no scan triggered. GPS commit
        only fires reactively inside .feed()'s phase-commit path, matching
        batch, where GPS is scanned once per commit regardless of GPS's own
        arrival cadence -- so feed_gps() may be called on a totally
        different schedule than feed()."""
        if chunk is None:
            return
        time = np.asarray(chunk.get("time", []))
        if len(time) == 0:
            return
        self._gps_time_raw = np.concatenate([self._gps_time_raw, time])
        for key, raw_attr in (
            ("long", "_gps_long_raw"), ("lat", "_gps_lat_raw"), ("speed", "_gps_speed_raw"),
            ("speed_rpm", "_gps_speed_rpm_raw"), ("gps_ibatt", "_gps_ibatt_raw"),
            ("gps_vbatt", "_gps_vbatt_raw"), ("rpm_axle", "_gps_rpm_axle_raw"),
        ):
            v = chunk.get(key)
            if v is not None and len(v):
                setattr(self, raw_attr, np.concatenate([getattr(self, raw_attr), np.asarray(v)]))
        self._gps_has_data = True
        self._recompute_gps_view()

    def _append_mbp(self, c: dict) -> None:
        if self._mbp_t0 is None:
            self._mbp_t0 = np.asarray(c["time"])[0]
        self._mbp_time_raw = np.concatenate([self._mbp_time_raw, np.asarray(c["time"])])
        self._mbp_pressure_raw = np.concatenate(
            [self._mbp_pressure_raw, np.asarray(c["pressure_filter"], dtype=np.float64)])
        self._mbp_pressure10hz_raw = np.concatenate(
            [self._mbp_pressure10hz_raw, np.asarray(c["pressure_filter_10hz"], dtype=np.float64)])
        self._mbp_gradient_raw = np.concatenate(
            [self._mbp_gradient_raw, np.asarray(c["gradient_filtered"], dtype=np.float64)])
        if c.get("vbatt") is not None and len(c["vbatt"]):
            self._mbp_vbatt_raw = np.concatenate([self._mbp_vbatt_raw, np.asarray(c["vbatt"], dtype=np.float64)])
        if c.get("temperature") is not None and len(c["temperature"]):
            self._mbp_temp_raw = np.concatenate([self._mbp_temp_raw, np.asarray(c["temperature"], dtype=np.float64)])
        if c.get("rssi") is not None and len(c["rssi"]):
            self._mbp_rssi_raw = np.concatenate([self._mbp_rssi_raw, np.asarray(c["rssi"], dtype=np.float64)])

    @staticmethod
    def _append_stream(stream: dict, c: dict) -> None:
        stream["time_raw"] = np.concatenate([stream["time_raw"], np.asarray(c["time"])])
        stream["pressure_raw"] = np.concatenate(
            [stream["pressure_raw"], np.asarray(c["pressure_filter"], dtype=np.float64)])
        if "pressure10hz_raw" in stream:  # BC only
            stream["pressure10hz_raw"] = np.concatenate(
                [stream["pressure10hz_raw"], np.asarray(c["pressure_filter_10hz"], dtype=np.float64)])
            stream["gradient_raw"] = np.concatenate(
                [stream["gradient_raw"], np.asarray(c["gradient_filtered"], dtype=np.float64)])
        if c.get("vbatt") is not None and len(c["vbatt"]):
            stream["vbatt_raw"] = np.concatenate([stream["vbatt_raw"], np.asarray(c["vbatt"], dtype=np.float64)])
        if c.get("temperature") is not None and len(c["temperature"]):
            stream["temperature_raw"] = np.concatenate(
                [stream["temperature_raw"], np.asarray(c["temperature"], dtype=np.float64)])
        if c.get("rssi") is not None and len(c["rssi"]):
            stream["rssi_raw"] = np.concatenate([stream["rssi_raw"], np.asarray(c["rssi"], dtype=np.float64)])

    def _recompute_mbp_view(self) -> None:
        """Re-dedup the whole accumulated MBP arrays -- mirrors the
        original's one-shot lines exactly, just re-run each `.feed()` call
        instead of once. See `_unique_stable()`'s docstring for why
        previously-issued positions stay valid across this recomputation.
        Known tradeoff, not a correctness issue: this is O(N log N) in the
        day's total-samples-so-far each call; trivial at demo scale."""
        mbp_time_sec_raw = _seconds_since(self._mbp_time_raw, self._mbp_t0)
        mbp_time_sec_u, ia = _unique_stable(mbp_time_sec_raw)

        if len(mbp_time_sec_u) < len(mbp_time_sec_raw):
            mbp_time = self._mbp_time_raw[ia]
            if len(self._mbp_pressure_raw) > ia.max():
                mbp_pressure = self._mbp_pressure_raw[ia]
                mbp_pressure10hz = self._mbp_pressure10hz_raw[ia]
            else:
                ia_p = ia[ia < len(self._mbp_pressure_raw)]
                mbp_pressure = self._mbp_pressure_raw[ia_p]
                mbp_pressure10hz = self._mbp_pressure10hz_raw[ia_p]
                mbp_time_sec_u = mbp_time_sec_u[: len(ia_p)]
                mbp_time = mbp_time[: len(ia_p)]
            if len(self._mbp_gradient_raw) > ia.max():
                mbp_gradient = self._mbp_gradient_raw[ia]
            else:
                ia_g = ia[ia < len(self._mbp_gradient_raw)]
                mbp_gradient = self._mbp_gradient_raw[ia_g]
            mbp_time_sec = mbp_time_sec_u
        else:
            mbp_time = self._mbp_time_raw
            mbp_pressure = self._mbp_pressure_raw
            mbp_pressure10hz = self._mbp_pressure10hz_raw
            mbp_gradient = self._mbp_gradient_raw
            mbp_time_sec = mbp_time_sec_raw

        self._mbp_time = mbp_time
        self._mbp_time_sec = mbp_time_sec
        self._mbp_pressure = mbp_pressure
        self._mbp_pressure10hz = mbp_pressure10hz
        self._mbp_gradient = mbp_gradient

        n = len(self._mbp_time)
        # MBP_Vbatt/Temperature/RSSI: per-packet telemetry (~1/80th the
        # sample rate) padded via _pad_to_length -- already mostly-NaN
        # beyond the first len(vbatt_raw) positions in the *original*
        # algorithm too (not something this refactor makes worse). These
        # fields are informational only: absent from postprocessing.py's
        # KEEP_FIELDS, not consumed by the trained model.
        self._mbp_vbatt_aligned = _pad_to_length(self._mbp_vbatt_raw, n)
        self._mbp_temp_aligned = _pad_to_length(self._mbp_temp_raw, n)
        self._mbp_rssi_aligned = _pad_to_length(self._mbp_rssi_raw, n)

    def _recompute_stream_view(self, stream: dict) -> None:
        time_sec_raw = _seconds_since(stream["time_raw"], self._mbp_t0)
        time_sec, uidx = _unique_stable(time_sec_raw)
        time_dt = stream["time_raw"][uidx]
        n = len(time_sec)

        stream["time"] = time_dt
        stream["time_sec"] = time_sec
        stream["pressure"] = _align_by_index(stream["pressure_raw"], uidx, n)
        stream["vbatt"] = _align_by_index(stream["vbatt_raw"], uidx, n)
        stream["temperature"] = _align_by_index(stream["temperature_raw"], uidx, n)
        stream["rssi"] = _align_by_index(stream["rssi_raw"], uidx, n)
        if "pressure10hz_raw" in stream:  # BC only
            stream["pressure10hz"] = _align_by_index(stream["pressure10hz_raw"], uidx, n)
            stream["gradient"] = _align_by_index(stream["gradient_raw"], uidx, n)

    def _recompute_gps_view(self) -> None:
        if not self._gps_has_data or self._mbp_t0 is None:
            self._gps = {"has_data": False}
            return
        gps_time_sec_raw = _seconds_since(self._gps_time_raw, self._mbp_t0)
        gps_time_sec, gidx = _unique_stable(gps_time_sec_raw)
        gps_time = self._gps_time_raw[gidx]

        def _col(raw_attr: str):
            v = getattr(self, raw_attr)
            if v is None or len(v) == 0:
                return None
            valid = gidx[gidx < len(v)]
            if len(valid) != len(gidx):
                out = np.full(len(gidx), np.nan)
                out[: len(valid)] = v[valid]
                return out
            return v[gidx]

        self._gps = {
            "has_data": True, "time": gps_time, "time_sec": gps_time_sec,
            "long": _col("_gps_long_raw"), "lat": _col("_gps_lat_raw"), "speed": _col("_gps_speed_raw"),
            "speed_rpm": _col("_gps_speed_rpm_raw"), "gps_ibatt": _col("_gps_ibatt_raw"),
            "gps_vbatt": _col("_gps_vbatt_raw"), "rpm_axle": _col("_gps_rpm_axle_raw"),
        }

    # ---- flushing ----

    def flush_completed_phases(self) -> list:
        """Returns newly-finalized phases (Post20s/Post60s already resolved)
        since the last call. post20_check/post60_check are single-slot and
        always point at the most-recently-committed phase (a new onset
        cancels the old check rather than letting two coexist -- see
        original lines 445-448), so every phase strictly before that one is
        already final; only that one tail phase is ever held back."""
        upper = len(self._test_brake)
        if self._post20_check["active"]:
            upper = min(upper, self._post20_check["phase_idx"])
        if self._post60_check["active"]:
            upper = min(upper, self._post60_check["phase_idx"])
        out = self._test_brake[self._flushed_count: upper]
        self._flushed_count = upper
        return out

    def flush_final(self) -> list:
        """Releases all remaining phases regardless of pending post-check
        status -- their Post20s/Post60s simply stay at their committed-time
        default (False/NaN), exactly matching batch's own behavior when a
        day's array runs out before the check fires."""
        out = self._test_brake[self._flushed_count:]
        self._flushed_count = len(self._test_brake)
        return out

    @property
    def in_progress(self) -> bool:
        """True while a braking cycle's onset has fired but its end
        condition hasn't -- exposed read-only for watcher status displays."""
        return self._in_braking

    # ---- the scan loop itself: unmodified logic from the original
    # module-level function, just relocated onto self + resumable via
    # self._k_next ----

    def _reset_phase_state(self) -> None:
        self._in_braking = False
        self._init_pressure = np.nan
        self._mbp_time_buf = []
        self._mbp_pressure_buf = []
        self._mbp_pressure10hz_buf = []
        self._mbp_gradient_buf = []
        self._phase_start_idx = None
        self._phase_start_time_sec = np.nan
        self._samples_since_drop = 0
        self._control_window_check = False
        self._control_window = False
        self._control_window_start_sec = np.nan
        self._control_window_fluctuation = False

    def _scan(self, n_total: int) -> None:
        for k in range(self._k_next, n_total):
            window_start = max(0, k - self.window_size + 1)
            window_slice = self._mbp_gradient[window_start: k + 1]
            is_stable_now = int(np.sum(np.abs(window_slice) <= self.GRAD_ZERO_TOL)) >= self.stable_point_count

            if not self._in_braking:
                if (is_stable_now and self._mbp_gradient[k] <= self.INIT_GRAD_THRESH
                        and self._mbp_pressure[k] > self.MBP_LOWER):
                    t_drop = self._mbp_time_sec[k]
                    if self._post20_check["active"] and t_drop < self._post20_check["time_limit"]:
                        self._post20_check["active"] = False
                    if self._post60_check["active"] and t_drop < self._post60_check["time_limit"]:
                        self._post60_check["active"] = False

                    self._in_braking = True
                    self._init_pressure = self._mbp_pressure[k]
                    self._phase_start_idx = k
                    self._phase_start_time_sec = self._mbp_time_sec[k]

                    self._mbp_time_buf = [self._mbp_time[k]]
                    self._mbp_pressure_buf = [self._mbp_pressure[k]]
                    self._mbp_pressure10hz_buf = [self._mbp_pressure10hz[k]]
                    self._mbp_gradient_buf = [self._mbp_gradient[k]]

                    if self.verbose:
                        print(f"[Phase {len(self._test_brake) + 1}] MBP onset at {self._mbp_time[k]}, "
                              f"P={self._mbp_pressure[k]:.2f}, G={self._mbp_gradient[k]:.3f}")

                    self._samples_since_drop = 0
                    self._control_window_check = False
                    self._control_window = False
                    self._control_window_start_sec = np.nan
                    self._control_window_fluctuation = False
                    self._system_stopped = False

                    self._skip_bc_due_to_sv = self._init_pressure > self.MBP_UPPER
                    if self._skip_bc_due_to_sv and self.verbose:
                        print(f"  [Phase {len(self._test_brake) + 1}] SV_Error=1 at onset "
                              f"— skipping BC & WV this phase.")

                    if not self._skip_bc_due_to_sv:
                        for b in range(self.num_bc):
                            self._bc_active[b] = True
                            self._bc_time_buf[b] = []
                            self._bc_time_sec_buf[b] = []
                            self._bc_pressure_buf[b] = []
                            self._bc_pressure10hz_buf[b] = []
                            self._bc_gradient_buf[b] = []
                            self._bc_vbatt_buf[b] = []
                            self._bc_temp_buf[b] = []
                            self._bc_rssi_buf[b] = []
                            self._bc_start_above_thresh[b] = False
                            self._bc_flat_start_near_zero[b] = False
                            self._bc_already_engaged[b] = False
                            self._bc_releasing_at_start[b] = False
                            self._bc_flat_checked[b] = False
                            self._bc_normal_braking[b] = False
                            self._bc_sensor_error[b] = False
                            self._bc_badstart[b] = False
                            self._bc_low_braking[b] = False

                            stream = self._bc_streams[b]
                            while stream["idx_pointer"] < len(stream["time_sec"]) and \
                                    stream["time_sec"][stream["idx_pointer"]] < self._phase_start_time_sec:
                                stream["idx_pointer"] += 1

            else:
                self._mbp_time_buf.append(self._mbp_time[k])
                self._mbp_pressure_buf.append(self._mbp_pressure[k])
                self._mbp_pressure10hz_buf.append(self._mbp_pressure10hz[k])
                self._mbp_gradient_buf.append(self._mbp_gradient[k])
                force_end_sv = False

                self._samples_since_drop += 1
                seconds_post_drop = self._mbp_time_sec[k] - self._phase_start_time_sec

                if not self._system_stopped and seconds_post_drop >= self.CONTROL_WINDOW_STOP_MAX_SEC:
                    self._system_stopped = True
                    if self.verbose:
                        print(f"  [Phase {len(self._test_brake) + 1}] Long-stop guard: "
                              f"{seconds_post_drop:.1f}s >= {self.CONTROL_WINDOW_STOP_MAX_SEC}s -> FORCE END (discard)")
                    self._reset_phase_state()
                    continue

                if not self._control_window_check and seconds_post_drop >= self.CONTROL_WINDOW_DELAY_SEC:
                    self._control_window_check = True
                    self._control_window = True
                    self._control_window_start_sec = self._mbp_time_sec[k]
                    self._control_window_fluctuation = False
                    if self.verbose:
                        print(f"  [Phase {len(self._test_brake) + 1}] Control Window ACTIVATED "
                              f"at +{seconds_post_drop:.1f}s")

                if self._control_window:
                    if self._mbp_gradient[k] < 0:
                        self._control_window_fluctuation = True
                        self._control_window = False
                        if self.verbose:
                            print(f"  [Phase {len(self._test_brake) + 1}] Control Window DEACTIVATED (fluctuation)")
                    else:
                        if (self._mbp_time_sec[k] - self._control_window_start_sec) >= self.CONTROL_WINDOW_ACTIVE_MAX_SEC \
                                and not self._control_window_fluctuation:
                            if self.verbose:
                                print(f"  [Phase {len(self._test_brake) + 1}] Acquisition DISCARDED by guard "
                                      f"(stable {self._mbp_time_sec[k] - self._control_window_start_sec:.1f}s)")
                            self._reset_phase_state()
                            continue

                if self._skip_bc_due_to_sv:
                    if abs(self._mbp_gradient[k]) < self.GRADIENT_STABLE_THRESHOLD:
                        if not self._sv_hold_active:
                            self._sv_hold_active = True
                            self._sv_hold_start_sec = self._mbp_time_sec[k]
                        else:
                            if (self._mbp_time_sec[k] - self._sv_hold_start_sec) >= self.SV_END_STABLE_HOLD_S:
                                force_end_sv = True
                    else:
                        self._sv_hold_active = False
                        self._sv_hold_start_sec = np.nan

                # ---- BC streaming ----
                if not self._skip_bc_due_to_sv and self.num_bc > 0:
                    for b in range(self.num_bc):
                        if not self._bc_active[b]:
                            continue
                        stream = self._bc_streams[b]

                        if len(self._bc_pressure_buf[b]) == 0 and stream["idx_pointer"] < len(stream["time_sec"]):
                            ptr = stream["idx_pointer"]
                            if stream["time_sec"][ptr] <= self._mbp_time_sec[k]:
                                if stream["pressure"][ptr] >= self.BC_BUILDUP_PHASE_P:
                                    self._bc_start_above_thresh[b] = True
                                    if self.verbose:
                                        print(f"    [BC {stream['id']}] Bad Start >= {self.BC_BUILDUP_PHASE_P:.2f} bar "
                                              f"-> SensorError=true (kept and recorded)")

                        while stream["idx_pointer"] < len(stream["time_sec"]) and \
                                stream["time_sec"][stream["idx_pointer"]] <= self._mbp_time_sec[k]:
                            ptr = stream["idx_pointer"]
                            self._bc_time_buf[b].append(stream["time"][ptr])
                            self._bc_time_sec_buf[b].append(stream["time_sec"][ptr])
                            self._bc_pressure_buf[b].append(stream["pressure"][ptr])
                            self._bc_pressure10hz_buf[b].append(stream["pressure10hz"][ptr])
                            self._bc_gradient_buf[b].append(stream["gradient"][ptr])

                            if len(stream["vbatt"]) > 0:
                                self._bc_vbatt_buf[b].append(stream["vbatt"][ptr])
                            if len(stream["temperature"]) > 0:
                                self._bc_temp_buf[b].append(stream["temperature"][ptr])
                            if len(stream["rssi"]) > 0:
                                self._bc_rssi_buf[b].append(stream["rssi"][ptr])

                            if stream["pressure"][ptr] >= self.BC_BUILDUP_PHASE_P + self.WV_FLUCTUATION:
                                self._bc_normal_braking[b] = True
                            stream["idx_pointer"] += 1

                        if not self._bc_flat_checked[b] and len(self._bc_time_sec_buf[b]) >= 5:
                            t_first = self._bc_time_sec_buf[b][0]
                            span_s = self._bc_time_sec_buf[b][-1] - t_first
                            if span_s >= 5:
                                tarr = np.asarray(self._bc_time_sec_buf[b])
                                parr = np.asarray(self._bc_pressure_buf[b])
                                garr = np.asarray(self._bc_gradient_buf[b])
                                mask_flat = (tarr - t_first) <= 5
                                press_flat = parr[mask_flat]
                                grad_flat = garr[mask_flat]

                                dp = float(np.max(press_flat) - np.min(press_flat))
                                mean_p = float(np.nanmean(press_flat))
                                mean_grad = float(np.nanmean(grad_flat))
                                flat = abs(mean_grad) < 0.01 and dp < 0.05

                                if flat and mean_p < 0.05:
                                    self._bc_flat_start_near_zero[b] = True
                                elif flat and mean_p >= 0.05:
                                    self._bc_already_engaged[b] = True
                                elif mean_grad < -0.01:
                                    self._bc_releasing_at_start[b] = True

                                self._bc_flat_checked[b] = True

                        if self._bc_start_above_thresh[b] or self._bc_flat_start_near_zero[b] or \
                                self._bc_already_engaged[b] or self._bc_releasing_at_start[b]:
                            self._bc_sensor_error[b] = True
                            self._bc_badstart[b] = True
                        else:
                            self._bc_sensor_error[b] = False
                            self._bc_badstart[b] = False

                # ---- Phase END condition ----
                end_pressure_target = self._init_pressure - self.P_RELEASE
                regular_end = self._mbp_pressure[k] > end_pressure_target and self._mbp_gradient[k] > self.GRAD_END_THRESH
                sv_early_end = self._skip_bc_due_to_sv and force_end_sv

                if regular_end or sv_early_end or self._system_stopped:
                    self._commit_phase(k)
                    self._reset_phase_state()
                    self._skip_bc_due_to_sv = False
                    self._sv_hold_active = False
                    self._sv_hold_start_sec = np.nan
                    if self.verbose:
                        print("  Moving to next phase scan...")

            self._capture_post_checks(k)

        self._k_next = n_total

    def _commit_phase(self, phase_end_idx: int) -> None:
        total_drop = self._init_pressure - float(np.min(self._mbp_pressure_buf))

        if total_drop < self.MIN_P_DROP:
            if self.verbose:
                print(f"[Phase {len(self._test_brake) + 1}] MBP discarded: "
                      f"dP={total_drop:.3f} < {self.MIN_P_DROP:.3f}")
            return

        sv_error = self._init_pressure > self.MBP_UPPER
        up_error = self._init_pressure < self.MBP_LOWER

        phase = {
            "PhaseIdx": len(self._test_brake) + 1,
            "MBP_Label": self.mbp_label,
            "MBP_Time": np.asarray(self._mbp_time_buf),
            "MBP_Pressure": np.asarray(self._mbp_pressure_buf, dtype=np.float64),
            "MBP_Pressure10hz": np.asarray(self._mbp_pressure10hz_buf, dtype=np.float64),
            "MBP_Gradient": np.asarray(self._mbp_gradient_buf, dtype=np.float64),
            "SV_Error": bool(sv_error),
            "UP_Error": bool(up_error),
            "EmergencyBrake": bool(total_drop >= self.EMERGENCY_BRAKING),
            "InitPressure": self._init_pressure,
            "MBP_StartIdx": self._phase_start_idx,
            "MBP_StartTime": self._mbp_time[self._phase_start_idx],
            "MBP_EndOfBrakeIdx": phase_end_idx,
            "MBP_EndOfBrakeTime": self._mbp_time[phase_end_idx],
            "MBP_TestIndex": self.mbp_test_index,
            "MBP_ID": self.mbp_id,
            "Post20s_Valid": False,
            "Post20s_Time": None,
            "Post20s_MBP_Pressure": np.nan,
            "Post20s_BC_Pressure": np.full(self.num_bc, np.nan),
            "Post60s_Valid": False,
            "Post60s_Time": None,
            "Post60s_MBP_Pressure": np.nan,
            "Post60s_BC_Pressure": np.full(self.num_bc, np.nan),
        }

        t_end_sec = self._mbp_time_sec[phase_end_idx]
        this_phase_idx = len(self._test_brake)  # 0-based index into test_brake, filled below
        self._post20_check["active"], self._post20_check["time_limit"], self._post20_check["phase_idx"] = \
            True, t_end_sec + 20, this_phase_idx
        self._post60_check["active"], self._post60_check["time_limit"], self._post60_check["phase_idx"] = \
            True, t_end_sec + 60, this_phase_idx

        idx_slice = slice(self._phase_start_idx, phase_end_idx + 1)
        phase["MBP_Vbatt"] = self._mbp_vbatt_aligned[idx_slice]
        phase["MBP_Temperature"] = self._mbp_temp_aligned[idx_slice]
        phase["MBP_RSSI"] = self._mbp_rssi_aligned[idx_slice]

        # ===== COMMIT: BC =====
        bc_list = [_default_bc_entry() for _ in range(self.num_bc)]
        if sv_error:
            for b in range(self.num_bc):
                bc_list[b]["Label"] = self._bc_streams[b]["label"]
                bc_list[b]["SensorError"] = True
                bc_list[b]["NormalBraking"] = False
                bc_list[b]["TestIndex"] = self._bc_streams[b]["test_index"]
                bc_list[b]["ID"] = self._bc_streams[b]["id"]
                bc_list[b]["MaxPressure"] = np.nan
        else:
            time_limit_sec = self._mbp_time_sec[phase_end_idx] + self.BC_EXTEND_AFTER_MBP_S
            for b in range(self.num_bc):
                stream = self._bc_streams[b]
                if len(self._bc_pressure_buf[b]) > 0:
                    while stream["idx_pointer"] < len(stream["time_sec"]) and \
                            stream["time_sec"][stream["idx_pointer"]] <= time_limit_sec:
                        ptr = stream["idx_pointer"]
                        self._bc_time_buf[b].append(stream["time"][ptr])
                        self._bc_time_sec_buf[b].append(stream["time_sec"][ptr])
                        self._bc_pressure_buf[b].append(stream["pressure"][ptr])
                        self._bc_pressure10hz_buf[b].append(stream["pressure10hz"][ptr])
                        self._bc_gradient_buf[b].append(stream["gradient"][ptr])
                        if len(stream["vbatt"]) > 0:
                            self._bc_vbatt_buf[b].append(stream["vbatt"][ptr])
                        if len(stream["temperature"]) > 0:
                            self._bc_temp_buf[b].append(stream["temperature"][ptr])
                        if len(stream["rssi"]) > 0:
                            self._bc_rssi_buf[b].append(stream["rssi"][ptr])
                        if stream["pressure"][ptr] >= self.BC_BUILDUP_END:
                            self._bc_normal_braking[b] = True
                        stream["idx_pointer"] += 1

                        ns = len(self._bc_pressure_buf[b])
                        if ns >= self.BC_END_WIN_SAMPLES:
                            p_now = self._bc_pressure_buf[b][ns - 1]
                            g_win = np.asarray(self._bc_gradient_buf[b][ns - self.BC_END_WIN_SAMPLES: ns])
                            mostly_down = float(np.mean(g_win < 0)) > self.BC_END_MOSTLY_DOWN_FRAC
                            if p_now < self.BC_END_THRESHOLD and mostly_down:
                                break

                has_data = len(self._bc_pressure_buf[b]) > 0 and len(self._bc_time_buf[b]) > 0
                if has_data:
                    start_time_bc = self._bc_time_buf[b][0]
                    end_time_bc = self._bc_time_buf[b][-1]
                    max_p = float(np.max(self._bc_pressure_buf[b]))
                    end_pressure = self._bc_pressure_buf[b][-1]
                else:
                    start_time_bc, end_time_bc, max_p, end_pressure = None, None, np.nan, np.nan
                    self._bc_sensor_error[b] = True

                if not self._bc_sensor_error[b] and not self._bc_normal_braking[b]:
                    self._bc_low_braking[b] = True

                e = bc_list[b]
                e["Label"] = stream["label"]
                e["Time"] = np.asarray(self._bc_time_buf[b])
                e["Pressure"] = np.asarray(self._bc_pressure_buf[b], dtype=np.float64)
                e["Pressure10hz"] = np.asarray(self._bc_pressure10hz_buf[b], dtype=np.float64)
                e["Gradient"] = np.asarray(self._bc_gradient_buf[b], dtype=np.float64)
                e["Vbatt"] = np.asarray(self._bc_vbatt_buf[b], dtype=np.float64)
                e["Temperature"] = np.asarray(self._bc_temp_buf[b], dtype=np.float64)
                e["RSSI"] = np.asarray(self._bc_rssi_buf[b], dtype=np.float64)
                e["BadStart"] = bool(self._bc_badstart[b])
                e["SensorError"] = bool(self._bc_sensor_error[b])
                e["NormalBraking"] = bool(self._bc_normal_braking[b])
                e["LowBraking"] = bool(self._bc_low_braking[b])
                e["StartAboveThresh"] = bool(self._bc_start_above_thresh[b])
                e["FlatStartNearZero"] = bool(self._bc_flat_start_near_zero[b])
                e["AlreadyEngagedStart"] = bool(self._bc_already_engaged[b])
                e["ReleasingAtStart"] = bool(self._bc_releasing_at_start[b])
                e["StartTime"] = start_time_bc
                e["EndTime"] = end_time_bc
                e["TestIndex"] = stream["test_index"]
                e["ID"] = stream["id"]
                e["MaxPressure"] = max_p
                e["EndPressure"] = end_pressure
        phase["BC"] = bc_list

        # ===== COMMIT: WV =====
        wv_list = [_default_wv_entry() for _ in range(self.num_wv)]
        if sv_error:
            for w in range(self.num_wv):
                wv_list[w]["Label"] = self._wv_streams[w]["label"]
                wv_list[w]["WV_SensorError"] = True
                wv_list[w]["TestIndex"] = self._wv_streams[w]["test_index"]
                wv_list[w]["ID"] = self._wv_streams[w]["id"]
                wv_list[w]["MeanPressure"] = np.nan
                wv_list[w]["NumSamples"] = 0
        else:
            t_start_num = self._mbp_time_sec[self._phase_start_idx]
            t_end_num = self._mbp_time_sec[phase_end_idx]
            for w in range(self.num_wv):
                stream = self._wv_streams[w]
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

        # ===== COMMIT: GPS =====
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

        if self._gps.get("has_data"):
            bc_end_times = [e["EndTime"] for e in bc_list if e["EndTime"] is not None]
            bc_end_max = max(bc_end_times) if bc_end_times else None

            if bc_end_max is not None:
                end_time_abs = bc_end_max
            else:
                end_time_abs = self._mbp_time[phase_end_idx]

            t_start_num = self._mbp_time[self._phase_start_idx]
            t_end_num = end_time_abs
            mask_gps = (self._gps["time"] >= t_start_num) & (self._gps["time"] <= t_end_num)
            n_gps = int(np.sum(mask_gps))

            if n_gps < 2:
                phase["GPS_SensorError"] = True
            else:
                phase["GPS_Time"] = self._gps["time"][mask_gps]
                for out_key, gps_key in (
                    ("GPS_Long", "long"), ("GPS_Lat", "lat"), ("GPS_Speed", "speed"),
                    ("GPS_Speed_RPM", "speed_rpm"), ("GPS_Ibatt", "gps_ibatt"),
                    ("GPS_Vbatt", "gps_vbatt"), ("GPS_RPM_axle", "rpm_axle"),
                ):
                    col = self._gps.get(gps_key)
                    if col is not None:
                        phase[out_key] = col[mask_gps]
                first_i = _find_first(mask_gps)
                last_i = _find_last(mask_gps)
                phase["GPS_StartTime"] = self._gps["time"][first_i]
                phase["GPS_EndTime"] = self._gps["time"][last_i]
                phase["GPS_NumSamples"] = n_gps
        else:
            phase["GPS_SensorError"] = True

        self._test_brake.append(phase)

    def _capture_post_checks(self, k: int) -> None:
        """Realtime capture of post +20s / +60s (matches the original's
        end-of-iteration block, run once per k regardless of in_braking)."""
        t_now = self._mbp_time_sec[k]

        for check, bc_field, mbp_field, valid_field, time_field in (
            (self._post20_check, "Post20s_BC_Pressure", "Post20s_MBP_Pressure", "Post20s_Valid", "Post20s_Time"),
            (self._post60_check, "Post60s_BC_Pressure", "Post60s_MBP_Pressure", "Post60s_Valid", "Post60s_Time"),
        ):
            if check["active"] and t_now >= check["time_limit"]:
                ph = self._test_brake[check["phase_idx"]]
                t_end_s = _seconds_since(np.asarray([ph["MBP_EndOfBrakeTime"]]), self._mbp_t0)[0]
                t_cap = check["time_limit"]

                mask = (self._mbp_time_sec > t_end_s) & (self._mbp_time_sec <= t_cap)
                stable = bool(np.any(mask))  # gradient-stability check intentionally disabled, matching source

                if stable:
                    ph[valid_field] = True
                    ph[time_field] = self._mbp_t0 + np.timedelta64(int(round(t_cap * 1e6)), "us")
                    ph[mbp_field] = _nearest_interp(self._mbp_time_sec, self._mbp_pressure, t_cap)
                    if self.num_bc > 0:
                        bc_press = np.full(self.num_bc, np.nan)
                        for r in range(self.num_bc):
                            stream = self._bc_streams[r]
                            if len(stream["time_sec"]) > 0 and len(stream["pressure"]) > 0:
                                bc_press[r] = _nearest_interp(stream["time_sec"], stream["pressure"], t_cap)
                        ph[bc_field] = bc_press
                else:
                    ph[valid_field] = False

                check["active"] = False


# --------------------------------------------------------------------------
# Main entry point -- thin batch wrapper over BrakingCycleDetector
# --------------------------------------------------------------------------


def detect_braking_struct_beta(
    test: list, window_size: int = 80, verbose: bool = True
) -> tuple:
    """Port of detect_braking_struct_beta.m. Returns (TestBrake, bc_indices, wv_indices).

    Now a thin wrapper over `BrakingCycleDetector`: one `.feed()` call with
    the whole day's data (via `from_test_list()`), then `.flush_final()`.
    Batch is a provable special case of the exact code path the live
    pipeline runs -- see the module docstring."""
    if verbose:
        num_mbp = sum(1 for c in test if str(c.get("Label", "")).strip().lower() == "mbp")
        print(f"[detect_braking_struct_beta] Scanning {len(test)} channel(s) ({num_mbp} MBP)")

    detector = BrakingCycleDetector.from_test_list(test, window_size=window_size, verbose=verbose)
    test_brake = detector.flush_final()

    if verbose:
        print(f"[detect_braking_struct_beta] Done. Phases: {len(test_brake)}")

    return test_brake, detector.bc_indices, detector.wv_indices
