"""Reads Stage 2's per-kit feature CSVs (data/processed/TestBrakefinal_data_raw_*.csv)
directly. One kit's CSV is a few hundred KB to low MB -- there's no need for
a SQLite/Parquet cache at this scale; if more kits are added later and this
gets slow, that's the point to add one, not before.
"""
from __future__ import annotations

import re
from pathlib import Path

import pandas as pd

from ..config import get_paths

_CSV_PATTERN = re.compile(r"TestBrakefinal_data_raw_(Dati\d+)\.csv$")

# Columns shown in the event list view (not the full ~115-column detail
# row). Not every kit CSV has every column here -- e.g. PhaseIdx/RunFile/
# RunFolder only exist in CSVs this port generated itself, not the real
# ones copied in from the finished thesis -- so list_events() filters this
# down to whatever's actually present rather than assuming all of it is.
EVENT_LIST_COLUMNS = [
    "event_id", "PhaseIdx", "MBP_ID", "BC_ID", "WV_ID",
    "Start_brake_time_pipe", "End_brake_time_pipe",
    "Total_power_efficiency", "Max_pressure_pipe", "Max_pressure_cyl",
    "Non_Standard_Braking", "EmergencyBrake_action",
    "MBP_Sensor_error", "BC_SensorError", "WV_SensorError",
]


def _kit_csv_path(kit_id: str) -> Path:
    return get_paths().processed / f"TestBrakefinal_data_raw_{kit_id}.csv"


def _live_kit_csv_path(kit_id: str) -> Path:
    return get_paths().live / f"{kit_id}_live.csv"


def valid_gps_fix(df: pd.DataFrame) -> pd.DataFrame:
    """Rows with a real GPS_Lat_last/GPS_Long_last fix. Excludes NaN *and*
    near-(0,0) -- a classic GPS-cold-start/no-fix sentinel value, not an
    actual location (would plot in the Gulf of Guinea for this fleet's real
    Northern-Italy operating region). Found in ~0.2% of real fixes (4/1837
    across all 9 kits, all in one kit) while building the route-coverage
    map -- without this filter, one bad row can blow out that map's
    auto-zoom to cover half the globe."""
    has_fix = df.dropna(subset=["GPS_Lat_last", "GPS_Long_last"])
    null_island = (has_fix["GPS_Lat_last"].abs() < 0.5) & (has_fix["GPS_Long_last"].abs() < 0.5)
    return has_fix.loc[~null_island]


def available_kit_ids() -> list[str]:
    processed = get_paths().processed
    if not processed.is_dir():
        return []
    ids = []
    for p in processed.glob("TestBrakefinal_data_raw_*.csv"):
        m = _CSV_PATTERN.search(p.name)
        if m:
            ids.append(m.group(1))
    return sorted(ids)


def load_kit_table(kit_id: str) -> pd.DataFrame:
    """Loads one kit's CSV fresh (no in-memory caching -- a re-run pipeline
    job overwrites this file, and staleness here would be a worse bug than
    the cost of re-reading a small CSV per request)."""
    path = _kit_csv_path(kit_id)
    if not path.is_file():
        raise FileNotFoundError(f"No processed data for kit '{kit_id}' at {path}")
    df = pd.read_csv(path, dtype={"MBP_ID": str, "BC_ID": str, "WV_ID": str})
    df.insert(0, "event_id", df.index)
    return df


def load_live_kit_table(kit_id: str) -> pd.DataFrame:
    """Same contract as load_kit_table(): fresh read every call, no cache --
    a running live watcher rewrites this file as new cycles complete."""
    path = _live_kit_csv_path(kit_id)
    if not path.is_file():
        raise FileNotFoundError(f"No live data for kit '{kit_id}' at {path}")
    df = pd.read_csv(path, dtype={"MBP_ID": str, "BC_ID": str, "WV_ID": str})
    df.insert(0, "event_id", df.index)
    return df


def kit_summary(kit_id: str) -> dict:
    df = load_kit_table(kit_id)
    non_standard = df["Non_Standard_Braking"].fillna(0).astype(int)
    return {
        "kit_id": kit_id,
        "event_count": int(len(df)),
        "date_range": [
            df["Start_brake_time_pipe"].min() if len(df) else None,
            df["Start_brake_time_pipe"].max() if len(df) else None,
        ],
        "non_standard_count": int(non_standard.sum()),
        "sensor_error_count": int(
            df[["MBP_Sensor_error", "BC_SensorError", "WV_SensorError"]]
            .fillna(0).astype(int).any(axis=1).sum()
        ),
    }


def list_events(kit_id: str, offset: int = 0, limit: int = 50,
                 predictions: "pd.Series | None" = None,
                 in_scope: "pd.Series | None" = None) -> dict:
    df = load_kit_table(kit_id)
    if predictions is not None:
        df = df.assign(predicted_leakage=predictions)
    if in_scope is not None:
        df = df.assign(prediction_in_scope=in_scope)
    df = df.sort_values("Start_brake_time_pipe", na_position="last")
    total = len(df)
    wanted = (
        EVENT_LIST_COLUMNS
        + (["predicted_leakage"] if predictions is not None else [])
        + (["prediction_in_scope"] if in_scope is not None else [])
    )
    columns = [c for c in wanted if c in df.columns]
    page = df.iloc[offset: offset + limit][columns]
    return {
        "total": total,
        "offset": offset,
        "limit": limit,
        "events": page.to_dict(orient="records"),
    }


def get_event(kit_id: str, event_id: int, predictions: "pd.Series | None" = None,
               in_scope: "pd.Series | None" = None) -> dict:
    df = load_kit_table(kit_id)
    if predictions is not None:
        df = df.assign(predicted_leakage=predictions)
    if in_scope is not None:
        df = df.assign(prediction_in_scope=in_scope)
    row = df.loc[df["event_id"] == event_id]
    if row.empty:
        raise KeyError(f"No event {event_id} for kit {kit_id}")
    return row.iloc[0].to_dict()


def get_live_event(kit_id: str, event_id: int) -> dict:
    """Same contract as get_event(), against the live CSV -- predicted_leakage
    is already a column here (baked in at export time by live_watch.py), so
    unlike get_event() there's no separate predictions Series to assign."""
    df = load_live_kit_table(kit_id)
    row = df.loc[df["event_id"] == event_id]
    if row.empty:
        raise KeyError(f"No live event {event_id} for kit {kit_id}")
    return row.iloc[0].to_dict()


def list_locations(kit_id: str) -> list[dict]:
    """Every distinct GPS fix this kit's events have -- for a "route
    coverage" map, not a table, so it skips pagination. Deduped by
    (lat, lon, time): GPS is committed once per phase in Stage 2, but each
    phase emits one row per candidate BC/WV pairing (2-3 rows sharing the
    exact same GPS fix) -- without deduping, the map would show 2-3
    identical overlapping markers per real location."""
    df = load_kit_table(kit_id)
    if "GPS_Lat_last" not in df.columns or "GPS_Long_last" not in df.columns:
        return []
    has_fix = valid_gps_fix(df)
    has_fix = has_fix.drop_duplicates(subset=["GPS_Lat_last", "GPS_Long_last", "Start_brake_time_pipe"])
    out = has_fix[["event_id", "GPS_Lat_last", "GPS_Long_last", "Start_brake_time_pipe"]].rename(
        columns={"GPS_Lat_last": "lat", "GPS_Long_last": "lon", "Start_brake_time_pipe": "time"}
    )
    return out.to_dict(orient="records")
