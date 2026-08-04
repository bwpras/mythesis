"""Incremental Stage 1 ingestion for a live watcher: parses exactly one
newly-arrived `.bin` file at a time, instead of `load_nodo_data()`'s
"rescan a time window, rebuild everything from scratch" batch contract.

This is deliberately a new, light module rather than a wrapper around
`load_nodo_data()` -- that function's whole contract (rglob a folder,
rebuild from scratch, maybe re-run whole-list sensor classification) is a
batch operation. Only the per-file packet parser (`_parse_pressure_file()`)
and the assembly helpers (`_assemble_sensor_chunk()`/`_assemble_gps_chunk()`)
are genuinely shared -- both reused verbatim from `load_nodo_data.py` so
calibration math can never drift between the batch and live paths.
"""
from __future__ import annotations

from pathlib import Path
from typing import Dict, Union

import numpy as np

from .filename_pattern import parse_bin_filename
from .load_nodo_data import _KeyStore, _assemble_gps_chunk, _assemble_sensor_chunk, _parse_pressure_file
from .read_pjm_file import read_pjm_file39


def parse_new_pressure_file(path: Union[str, Path], fsamp: float = 40.0) -> Dict[str, dict]:
    """Parses ONE new `_p.bin` file into `{sensor_id: chunk}` -- Nodo-shaped
    per-sensor dicts containing ONLY this file's newly-arrived samples,
    ready to run through `filtering.CausalFilterState.feed()` then
    `braking_detection.BrakingCycleDetector.feed()`. Uses a fresh per-file
    store: parsing one file's packets is independent of anything parsed
    before it (unlike detection, which needs cross-file state)."""
    path = Path(path)
    parsed = parse_bin_filename(path.name)
    end_time = parsed[0] if parsed is not None else None
    # `_parse_pressure_file`'s own `kit_id` parameter is misleadingly named
    # (inherited from load_nodo_data.py) -- it's actually the per-sensor hex
    # address embedded in the filename (e.g. "0x74"), not a "DatiXX" kit/
    # folder name. Falls back to grouping by sensor address the same way
    # the batch path does when a file has no embedded address.
    sensor_id_hint = parsed[2] if parsed is not None else ""

    store: Dict[str, _KeyStore] = {}
    _parse_pressure_file(path, end_time, sensor_id_hint, fsamp, store)
    return {key: _assemble_sensor_chunk(key, entry) for key, entry in store.items()}


def parse_new_gps_file(path: Union[str, Path]) -> dict:
    """Parses ONE new `_pjm.bin` file into the chunk shape
    `BrakingCycleDetector.feed_gps()` expects."""
    pjm = read_pjm_file39(Path(path))
    timestamp = (np.array(pjm.timestamp, dtype="datetime64[us]") if len(pjm.timestamp)
                 else np.array([], dtype="datetime64[us]"))
    gps = _assemble_gps_chunk(
        gps_lat=pjm.gps_lat, gps_lon=pjm.gps_lon, speed=pjm.speed, rpm=pjm.rpm,
        ibatt=pjm.ibatt, vbatt=pjm.vbatt, timestamp=timestamp,
    )
    return {
        "time": gps["Time_GPS"], "long": gps["GPS_lon"], "lat": gps["GPS_lat"],
        "speed": gps["speed"], "speed_rpm": gps["speed_rpm"],
        "gps_ibatt": gps["Ibatt"], "gps_vbatt": gps["Vbatt"], "rpm_axle": gps["rpm"],
    }
