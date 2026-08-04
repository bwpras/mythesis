"""Python port of matlab/ingestion/loadNodoData.m.

Builds a Nodo-equivalent structure (a list of per-sensor dicts) from raw
*.bin files within a time window.

Preserved from the source:
  - Timezone-free datetimes (tz-naive, treated as UTC wall time)
  - +2 hours offset applied to Start_time and Time
  - MSG_WAKE telemetry ignored in per-packet arrays (keeps Start_time aligned)
  - Per-packet telemetry lengths reconciled to Start_time length (defensive)
  - Pressure calibrated at assembly: pCal = ((rawPress * 3.6/3.3) * 0.000788) - 2.3057

Known divergence from the MATLAB source (documented, not a bug):
  - The MATLAB code caches sensor-role labels as a MATLAB table inside
    data/interim/label_registry/<folderKey>_labels.mat (project-root
    relative, independent of rootDir). This port writes its own cache to
    the same directory as <folderKey>_labels.csv instead of a .mat file.
  - Interop is one-directional: this port PREFERS its own .csv cache but
    falls back to reading MATLAB's .mat table directly (via
    mat_table_reader.py, no MATLAB installation needed) if no .csv exists
    yet -- so a folder MATLAB already classified is reused here instead of
    being re-classified from scratch. MATLAB itself still cannot read this
    port's .csv cache; closing that direction would require changing
    loadNodoData.m's ReadLabel() too.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Optional, Union

import numpy as np
import pandas as pd

from .filename_pattern import parse_bin_filename as _parse_bin_filename
from .identify_brake_sensors import identify_brake_sensors, sort_by_label
from .packet_io import fread, fread1
from .read_pjm_file import read_pjm_file39

MSG_WAKE = 0x20
WHEEL_DIAM_M = 0.92


def _posix_ms_to_dt64(raw_ms) -> np.datetime64:
    return np.datetime64(int(raw_ms), "ms").astype("datetime64[us]")


class _KeyStore:
    """Per-sensor accumulator, mirrors the containers.Map bank in loadNodoData.m."""

    def __init__(self):
        self.press_chunks: List[np.ndarray] = []
        self.time_chunks: List[np.ndarray] = []
        self.vbatt: List[float] = []
        self.vin: List[float] = []
        self.id_: List[float] = []
        self.ic: List[float] = []
        self.temp: List[float] = []
        self.rssi: List[float] = []
        self.start_time: List[np.datetime64] = []
        self.msg_wake_count = 0
        self.cont_pkt = 0
        self.end_time = None


def _parse_pressure_file(path: Path, end_time, kit_id: str, fsamp: float, store: Dict[str, _KeyStore]):
    key = kit_id if kit_id else path.stem
    cont_pkt = 0
    cont_msg_wake = 0

    with open(path, "rb") as f:
        while True:
            _sohcar = fread1(f, "uint8")     # unused
            _contatore = fread1(f, "uint8")  # unused
            pktlen = fread1(f, "uint8")
            _id_dest = fread1(f, "uint8")    # unused
            _id_source = fread1(f, "uint8")  # unused
            pk_type = fread1(f, "uint8")

            if pktlen is None:
                break

            if pk_type == MSG_WAKE:
                cont_msg_wake += 1
                fread1(f, "uint8")   # Soglia
                fread1(f, "uint16")  # Vbatt
                fread1(f, "uint16")  # Vin
                fread1(f, "uint16")  # Id
                fread1(f, "uint16")  # Ic
                fread1(f, "int16")   # Temp
                fread1(f, "uint8")   # RSSI
                fread1(f, "uint8")   # eochar
                continue

            # --- DATA PACKET (has Start_time and 80 samples) ---
            vbatt = fread1(f, "uint16")
            if vbatt is None:
                break
            vbatt = vbatt / 1000.0

            vin = fread1(f, "uint16")
            if vin is None:
                break
            vin = vin / 1000.0

            id_v = fread1(f, "uint16")
            if id_v is None:
                break
            id_v = id_v * 0.1

            ic = fread1(f, "uint16")
            if ic is None:
                break
            ic = ic * 0.1

            temp = fread1(f, "int16")
            if temp is None:
                break
            temp = temp * 0.01

            timestamp_raw = fread1(f, "uint64")
            if timestamp_raw is None:
                print("loadNodoData:TruncatedPacket -- Truncated packet (missing timestamp).")
                break

            press = np.zeros(80, dtype=np.int16)

            if fsamp == 40:
                st = _posix_ms_to_dt64(timestamp_raw)
                press80, nread = fread(f, "int16", 80)
                if nread < 80:
                    print(f"loadNodoData:ShortRead -- Expected 80 samples, got {nread}. Dropping partial packet.")
                    break
                cont_pkt += 1
                start_time_val = st
                time_row = st + (np.arange(80, dtype=np.int64) * 25000).astype("timedelta64[us]")
                press[:] = press80
            else:
                fcamp_lp = 1.62181
                st = _posix_ms_to_dt64(timestamp_raw)
                press10, nread = fread(f, "int16", 10)
                if nread < 10:
                    print(f"loadNodoData:ShortReadLP -- Expected 10 LP samples, got {nread}. Dropping partial packet.")
                    break
                cont_pkt += 1
                start_time_val = st
                time_row = np.full(80, np.datetime64("NaT"), dtype="datetime64[us]")
                offsets_us = (np.arange(10, dtype=np.float64) / fcamp_lp * 1e6).astype("int64")
                time_row[:10] = st + offsets_us.astype("timedelta64[us]")
                press[:10] = press10
                fread(f, "int16", 70)  # skip remaining to keep alignment

            fread1(f, "uint16")  # n_sample
            fread1(f, "uint16")  # dummy1
            fread1(f, "uint16")  # dummy2
            rssi = fread1(f, "uint8")
            if rssi is None:
                print("loadNodoData:TruncatedPacket -- Truncated packet (missing RSSI).")
                break
            rssi = -(256 - rssi)
            fread1(f, "uint8")  # eochar

            # ---- append to maps (only now that a full packet is confirmed) ----
            if key not in store:
                store[key] = _KeyStore()
                store[key].end_time = end_time
            entry = store[key]
            entry.press_chunks.append(press)
            entry.time_chunks.append(time_row)
            entry.vbatt.append(vbatt)
            entry.vin.append(vin)
            entry.id_.append(id_v)
            entry.ic.append(ic)
            entry.temp.append(temp)
            entry.rssi.append(rssi)
            entry.start_time.append(start_time_val)

    if key in store:
        store[key].cont_pkt = cont_pkt
        store[key].msg_wake_count = cont_msg_wake


def _assemble_sensor_chunk(key: str, entry: "_KeyStore") -> dict:
    """The Nx80-flatten -> NaT-mask -> telemetry-length-reconcile -> pCal ->
    +2h-offset assembly, extracted from what used to be inlined at the
    bottom of load_nodo_data() so it can be reused for one file's worth of
    freshly-parsed packets at a time (see ingestion/live_ingest.py), not
    just a whole day's accumulated store. Returns one Nodo-shaped per-sensor
    dict (ID, Start_time, Time, Pressure, Vbatt, Vin, Id, Ic, Temperature,
    RSSI, Sensor_Type, Wagon_Type, Label) -- WITHOUT the GPS fields, which
    are shared across every sensor in a Nodo and assembled separately by
    _assemble_gps_chunk(); load_nodo_data() below spreads that shared dict
    onto each sensor's chunk itself, unchanged from before this refactor."""
    tmat = np.stack(entry.time_chunks, axis=0) if entry.time_chunks else np.zeros((0, 80), dtype="datetime64[us]")
    pcol = np.concatenate(entry.press_chunks) if entry.press_chunks else np.array([], dtype=np.int16)
    tcol = tmat.ravel(order="C")

    length = min(len(tcol), len(pcol))
    tcol, pcol = tcol[:length], pcol[:length]

    mask = ~np.isnat(tcol)
    n_total, n_keep = length, int(mask.sum())
    n_removed = n_total - n_keep
    if n_removed > 0:
        print(f"[NaT-mask] {key}: removed {n_removed}/{n_total} "
              f"({100 * n_removed / max(1, n_total):.2f}%) NaT-padded samples")

    time_col = tcol[mask]
    press_col = pcol[mask]

    n_pkt = len(entry.start_time)
    reconciled = {}
    for attr in ("vbatt", "vin", "id_", "ic", "temp", "rssi"):
        v = getattr(entry, attr)
        nv = len(v)
        if nv > n_pkt:
            v = v[:n_pkt]
        elif nv < n_pkt:
            v = v + [np.nan] * (n_pkt - nv)
        reconciled[attr] = v

    p_cal = ((press_col.astype(np.float64) * 3.6 / 3.3) * 0.000788) - 2.3057
    st = np.array(entry.start_time, dtype="datetime64[us]") if entry.start_time else \
        np.array([], dtype="datetime64[us]")
    offset = np.timedelta64(2, "h")

    return {
        "ID": key,
        "Start_time": st + offset,
        "Time": time_col + offset,
        "Pressure": p_cal,
        "Vbatt": np.array(reconciled["vbatt"], dtype=float),
        "Vin": np.array(reconciled["vin"], dtype=float),
        "Id": np.array(reconciled["id_"], dtype=float),
        "Ic": np.array(reconciled["ic"], dtype=float),
        "Temperature": np.array(reconciled["temp"], dtype=float),
        "RSSI": np.array(reconciled["rssi"], dtype=float),
        "Sensor_Type": None,
        "Wagon_Type": None,
        "Label": None,
    }


def _assemble_gps_chunk(gps_lat, gps_lon, speed, rpm, ibatt, vbatt, timestamp) -> dict:
    """The `valid = gps_lat != 0` filter + speed_rpm calculation, extracted
    from what used to be inlined in load_nodo_data()'s GPS block so it can
    be applied to one newly-arrived _pjm.bin file's arrays at a time (see
    ingestion/live_ingest.py) exactly as readily as to the concatenated
    whole-day arrays load_nodo_data() below still builds. Filtering is
    elementwise, so filtering-then-concatenating-across-files (streaming)
    and concatenating-then-filtering-once (batch, unchanged here) are
    equivalent."""
    gps_lat = np.asarray(gps_lat, dtype=float)
    valid = gps_lat != 0
    rpm = np.asarray(rpm, dtype=float)
    gps_dat = {
        "GPS_lat": gps_lat[valid],
        "GPS_lon": np.asarray(gps_lon, dtype=float)[valid],
        "speed": np.asarray(speed, dtype=float)[valid],
        "Time_GPS": np.asarray(timestamp, dtype="datetime64[us]")[valid] if len(timestamp)
        else np.array([], dtype="datetime64[us]"),
        "rpm": rpm[valid],
        "Ibatt": np.asarray(ibatt, dtype=float)[valid],
        "Vbatt": np.asarray(vbatt, dtype=float)[valid],
    }
    gps_dat["speed_rpm"] = gps_dat["rpm"] * ((1 / 60) * 2 * np.pi * (WHEEL_DIAM_M / 2) * 3.6)
    return gps_dat


def _define_folder_key(root_dir: Path) -> str:
    last = root_dir.name
    m = re.search(r"Dati\d+", last)
    return m.group(0) if m else last


def _label_directory(root_dir: Path) -> Path:  # noqa: ARG001 - kept for call-site symmetry with the .m port
    """Canonical, project-root-relative label registry: data/interim/label_registry.
    Independent of rootDir, mirroring the fixed LabelDirectory() in loadNodoData.m,
    so labels are shared across all DatiXX folders regardless of which raw
    folder is scanned."""
    if __package__:
        from ..paths import get_paths
    else:
        from python_port.paths import get_paths
    return get_paths().interim / "label_registry"


def _registry_path(root_dir: Path, folder_key: str) -> Path:
    return _label_directory(root_dir) / f"{folder_key}_labels.csv"


def _read_label(root_dir: Path, folder_key: str) -> Optional[pd.DataFrame]:
    """Load a cached sensor-label table for folder_key. Prefers this port's own
    <folderKey>_labels.csv; if that's absent, falls back to reading MATLAB's
    <folderKey>_labels.mat directly (see mat_table_reader.py) so a registry
    entry classified by MATLAB is reused here instead of being re-classified
    from scratch."""
    csv_path = _registry_path(root_dir, folder_key)
    needed = {"Folder", "SensorID", "SensorLabel"}

    if csv_path.is_file():
        df = pd.read_csv(csv_path, dtype=str)
        if not needed.issubset(df.columns):
            return None
        df = df[df["SensorLabel"].isin(["MBP", "BC", "WV"])]
        return df[["Folder", "SensorID", "SensorLabel"]].reset_index(drop=True)

    mat_path = csv_path.with_suffix(".mat")
    if mat_path.is_file():
        from .mat_table_reader import read_sensor_labels_table

        try:
            df = read_sensor_labels_table(mat_path)
        except (ValueError, OSError, ImportError) as exc:
            print(f"loadNodoData:MatLabelReadFailed -- Could not read {mat_path}: {exc}")
            return None
        if not needed.issubset(df.columns):
            return None
        df = df[df["SensorLabel"].isin(["MBP", "BC", "WV"])]
        return df[["Folder", "SensorID", "SensorLabel"]].reset_index(drop=True)

    return None


def _save_folder_label(root_dir: Path, folder_key: str, ids_now: List[str], labels_now: List[str]):
    if len(ids_now) != len(labels_now):
        print("loadNodoData:LabelSaveMismatch -- IDs and labels size mismatch.")
        return
    if not all(l in ("MBP", "BC", "WV") for l in labels_now):
        print("loadNodoData:LabelSaveInvalid -- Contains invalid labels. Not saving.")
        return
    if len(set(ids_now)) != len(ids_now):
        print("loadNodoData:LabelSaveDuplicate -- Duplicate SensorID(s). Not saving.")
        return

    reg_dir = _label_directory(root_dir)
    reg_dir.mkdir(parents=True, exist_ok=True)
    reg_path = _registry_path(root_dir, folder_key)

    df = pd.DataFrame({
        "Folder": [folder_key] * len(ids_now),
        "SensorID": ids_now,
        "SensorLabel": labels_now,
    })
    tmp = reg_path.with_suffix(reg_path.suffix + ".tmp")
    df.to_csv(tmp, index=False)
    tmp.replace(reg_path)
    print(f"Saved {len(df)} sensor labels to {reg_path}")


def load_nodo_data(
    t_start: np.datetime64,
    t_end: np.datetime64,
    fsamp: float,
    root_dir: Union[str, Path],
) -> List[dict]:
    """Build a list of per-sensor Nodo dicts from raw BIN files in [t_start, t_end]."""
    t_start = np.datetime64(t_start, "us")
    t_end = np.datetime64(t_end, "us")
    if t_end < t_start:
        raise ValueError("loadNodoData:InvalidWindow -- End time must be >= start time.")

    root_dir = Path(root_dir)
    if not root_dir.is_dir():
        raise FileNotFoundError(f'loadNodoData:MissingFolder -- Folder "{root_dir}" does not exist.')

    # --------- 1) RECURSIVE LIST OF CANDIDATES ---------
    all_bins = sorted(root_dir.rglob("*.bin"))
    if not all_bins:
        return []

    # --------- 2) ROBUST FILENAME PARSING + 3) FILTER BY TRUE TIME WINDOW ---------
    rows = []
    for path in all_bins:
        parsed = _parse_bin_filename(path.name)
        if parsed is None:
            continue
        end_time, kind, kit_id = parsed
        if t_start <= end_time <= t_end:
            rows.append((path, end_time, kind, kit_id))
    if not rows:
        return []

    rows.sort(key=lambda r: r[1])
    rows = [r for r in rows if 1 <= int(str(r[1])[11:13]) <= 23]
    if not rows:
        return []

    # --------- 4) SPLIT BY MODALITY ---------
    rows_p = [r for r in rows if r[2] == "p"]
    rows_pjm = [r for r in rows if r[2] == "pjm"]

    # --------- Parse pressure files ---------
    store: Dict[str, _KeyStore] = {}
    for h, (path, end_time, _kind, kit_id) in enumerate(rows_p):
        if h % 100 == 0:
            print(f"Reading pressure [{h + 1}/{len(rows_p)}] {path}")
        try:
            _parse_pressure_file(path, end_time, kit_id, fsamp, store)
        except OSError:
            print(f"loadNodoData:FileOpenFailed -- Unable to open file {path}")
            continue

    kk = list(store.keys())
    n_nodi = len(kk)
    if n_nodi == 0:
        return []

    # --------- Read GPS (pjm) files ---------
    gps_lat_l, gps_lon_l, speed_l, rpm_l, ibatt_l, vbatt_l, time_l = [], [], [], [], [], [], []
    for k, (path, _end_time, _kind, _kit_id) in enumerate(rows_pjm):
        if k % 100 == 0:
            print(f"Reading GPS [{k + 1}/{len(rows_pjm)}] {path}")
        try:
            pjm = read_pjm_file39(path)
        except Exception:
            print(f"loadNodoData:PJMReadFailed -- Failed to parse {path}")
            continue
        gps_lat_l.append(pjm.gps_lat)
        gps_lon_l.append(pjm.gps_lon)
        speed_l.append(pjm.speed)
        rpm_l.append(pjm.rpm)
        ibatt_l.append(pjm.ibatt)
        vbatt_l.append(pjm.vbatt)
        time_l.append(np.array(pjm.timestamp, dtype="datetime64[us]") if len(pjm.timestamp) else
                       np.array([], dtype="datetime64[us]"))

    if gps_lat_l:
        gps_dat = _assemble_gps_chunk(
            gps_lat=np.concatenate(gps_lat_l), gps_lon=np.concatenate(gps_lon_l),
            speed=np.concatenate(speed_l), rpm=np.concatenate(rpm_l),
            ibatt=np.concatenate(ibatt_l), vbatt=np.concatenate(vbatt_l),
            timestamp=np.concatenate(time_l) if time_l else np.array([], dtype="datetime64[us]"),
        )
    else:
        gps_dat = {
            "GPS_lat": np.array([]), "GPS_lon": np.array([]), "speed": np.array([]),
            "Time_GPS": np.array([], dtype="datetime64[us]"), "rpm": np.array([]),
            "Ibatt": np.array([]), "Vbatt": np.array([]), "speed_rpm": np.array([]),
        }

    # --------- Assemble Nodo struct (flatten, calibrate, offset, attach shared GPS) ---------
    nodo: List[dict] = []
    for key in kk:
        sensor = _assemble_sensor_chunk(key, store[key])
        sensor.update({
            "Time_GPS": gps_dat["Time_GPS"],
            "Long": gps_dat["GPS_lon"],
            "Lat": gps_dat["GPS_lat"],
            "Speed": gps_dat["speed"],
            "Speed_RPM": gps_dat["speed_rpm"],
            "GPS_Ibatt": gps_dat["Ibatt"],
            "GPS_Vbatt": gps_dat["Vbatt"],
            "RPM_axle": gps_dat["rpm"],
        })
        nodo.append(sensor)

    # ========= Sensor role cache: load-or-classify-and-save =========
    folder_key = _define_folder_key(root_dir)
    ids_now = [str(s["ID"]) for s in nodo]

    cached = _read_label(root_dir, folder_key)
    have_cache = cached is not None and set(ids_now).issubset(set(cached["SensorID"]))

    if have_cache:
        label_map = dict(zip(cached["SensorID"], cached["SensorLabel"]))
        for s in nodo:
            s["Label"] = label_map.get(str(s["ID"]), "WV")
            s["Sensor_Type"] = s["Label"]
        nodo = sort_by_label(nodo)
        print(f"Applied cached sensor labels for {folder_key} ({len(nodo)} sensors).")
    else:
        nodo, _roles_table, _steady_info = identify_brake_sensors(nodo)
        for s in nodo:
            s["Sensor_Type"] = s["Label"]

        labels_now = [str(s["Label"] or "") for s in nodo]
        ok_labels = all(l != "" for l in labels_now) and all(l in ("MBP", "BC", "WV") for l in labels_now)
        ok_count = len(labels_now) == len(ids_now)
        ok_unique = len(set(ids_now)) == len(ids_now)

        if ok_labels and ok_count and ok_unique:
            _save_folder_label(root_dir, folder_key, [str(s["ID"]) for s in nodo], labels_now)
        else:
            print(f"loadNodoData:LabelSaveSkip -- Skipping save: labels incomplete or invalid "
                  f"(|IDs|={len(ids_now)}, |labels|={len(labels_now)}, okLabels={ok_labels}).")

    print(f"Selected {len(rows_p)} pressure files and {len(rows_pjm)} GPS files.")
    return nodo
