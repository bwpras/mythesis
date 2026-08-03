"""Python port of matlab/ingestion/read_pjm_file39.m.

Robust PJM (GPS/telemetry) reader for 38B and 39B message formats:
  - 38B: timestamp = bytes 31-38 of the record
  - 39B: trailer 0D 0A + 1 filler byte (col 31) + timestamp = bytes 32-39
Disambiguated per-record by checking whether the 38B interpretation decodes
to a plausible date; if not, it re-reads as 39B. Filters timestamps to
[2025-01-01, 2030-01-01).
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List, Union

import numpy as np

from .packet_io import fread

MIN_DATE = datetime(2025, 1, 1)
MAX_DATE = datetime(2030, 1, 1)


@dataclass
class PjmData:
    gps_lat: np.ndarray
    gps_lon: np.ndarray
    speed: np.ndarray
    count: int
    rpm: np.ndarray
    ibatt: np.ndarray
    vbatt: np.ndarray
    payload: List[np.ndarray]
    timestamp: np.ndarray  # dtype=object, python datetimes (tz-naive, UTC wall time)


def _posix_ms_to_datetime(raw_uint64: int) -> datetime:
    """Mirror datetime(x/1000, 'ConvertFrom', 'posixtime') -> tz-naive UTC wall time.

    The 38B/39B disambiguation below deliberately decodes 8 arbitrary bytes as
    a speculative timestamp and only keeps the interpretation if it lands in
    [MIN_DATE, MAX_DATE]; garbage input is expected and must not raise. MATLAB's
    datetime() silently produces an out-of-range value for huge epoch offsets,
    but Python's datetime.fromtimestamp() raises OSError/OverflowError/ValueError
    on Windows well before reaching year 10000 (observed: a genuine misaligned-byte
    case decoded to ~year 16149). Map any such failure to a sentinel far outside
    the valid window instead, so the plausibility check below still rejects it
    and falls through to the 39B interpretation exactly as intended.
    """
    try:
        return datetime.fromtimestamp(raw_uint64 / 1000.0, tz=timezone.utc).replace(tzinfo=None)
    except (OSError, OverflowError, ValueError):
        return MAX_DATE + timedelta(days=1)


def read_pjm_file39(filename: Union[str, Path]) -> PjmData:
    filename = Path(filename)

    gps_lat: List[float] = []
    gps_lon: List[float] = []
    speed: List[float] = []
    rpm: List[float] = []
    ibatt: List[float] = []
    vbatt: List[float] = []
    payload: List[np.ndarray] = []
    timestamp: List[datetime] = []

    count = 0
    packet_ok = 0
    packet_bad = 0
    packet_trunc = 0

    with open(filename, "rb") as f:
        f.seek(0, 2)
        file_size = f.tell()
        f.seek(0, 0)

        while True:
            pos = f.tell()

            # --- floats (12B) ---
            float_data, n = fread(f, "float32", 3)
            if n < 3:
                print(f"EOF/truncated floats at byte {pos}")
                break

            # --- start+header (2B) ---
            start_byte, n1 = fread(f, "uint8", 1)
            header, n2 = fread(f, "uint8", 1)
            if n1 < 1 or n2 < 1:
                print(f"EOF/truncated header at byte {pos + 12}")
                break
            start_byte_v = int(start_byte[0])
            header_v = int(header[0])
            if start_byte_v != 33 or header_v != 14:
                print(f"Bad start/header at byte {pos + 12} (got {start_byte_v:02X} {header_v:02X})")
                f.seek(pos + 1, 0)  # resync
                packet_bad += 1
                continue

            # --- payload (14B) ---
            data_payload, n = fread(f, "uint8", 14)
            if n < 14:
                print(f"Truncated payload at byte {pos + 14}")
                packet_trunc += 1
                break

            # --- trailer (2B, always 0D 0A) ---
            trailer, n = fread(f, "uint8", 2)
            if n < 2:
                print(f"Truncated trailer at byte {pos + 28}")
                packet_trunc += 1
                break
            if not (trailer[0] == 13 and trailer[1] == 10):
                print(f"Bad trailer at byte {pos + 28} ({trailer[0]:02X} {trailer[1]:02X})")
                packet_bad += 1
                continue

            # Peek next 8 bytes (possible 38B timestamp)
            pos_after_trailer = f.tell()
            peek_bytes, n = fread(f, "uint8", 8)
            if n < 8:
                print(f"Truncated timestamp at byte {pos_after_trailer}")
                packet_trunc += 1
                break

            # Try 38B interpretation (cols 31-38)
            ts_raw38 = struct.unpack("<Q", peek_bytes.tobytes())[0]
            ts38 = _posix_ms_to_datetime(ts_raw38)

            if MIN_DATE <= ts38 <= MAX_DATE:
                ts = ts38
            else:
                # Not valid -> rewind and treat as 39B (skip filler col 31, use cols 32-39)
                f.seek(pos_after_trailer + 1, 0)
                ts_bytes, n = fread(f, "uint8", 8)
                if n < 8:
                    print(f"Truncated 39B timestamp at byte {f.tell()}")
                    packet_trunc += 1
                    break
                ts_raw = struct.unpack("<Q", ts_bytes.tobytes())[0]
                ts = _posix_ms_to_datetime(ts_raw)

            # --- decode payload fields ---
            pb = data_payload.tobytes()
            rp = struct.unpack("<H", pb[8:10])[0] / 10.0
            ib = struct.unpack("<H", pb[10:12])[0] / 1000.0
            vb = struct.unpack("<H", pb[12:14])[0] / 100.0

            # --- timestamp filter ---
            if ts < MIN_DATE or ts > MAX_DATE:
                continue

            # --- append ---
            count += 1
            gps_lat.append(float(float_data[0]))
            gps_lon.append(float(float_data[1]))
            speed.append(float(float_data[2]))
            rpm.append(rp)
            ibatt.append(ib)
            vbatt.append(vb)
            payload.append(data_payload.copy())
            timestamp.append(ts)

            packet_ok += 1

            if count % 1000 == 0:
                print(f"Read {count} packets ({100 * f.tell() / file_size:.1f}% of file)")

    print("\n=== Summary ===")
    print(f"Good packets: {packet_ok}")
    print(f"Bad headers : {packet_bad}")
    print(f"Truncated   : {packet_trunc}")
    print(f"Total parsed: {count}")

    return PjmData(
        gps_lat=np.asarray(gps_lat, dtype=float),
        gps_lon=np.asarray(gps_lon, dtype=float),
        speed=np.asarray(speed, dtype=float),
        count=count,
        rpm=np.asarray(rpm, dtype=float),
        ibatt=np.asarray(ibatt, dtype=float),
        vbatt=np.asarray(vbatt, dtype=float),
        payload=payload,
        timestamp=np.asarray(timestamp, dtype=object),
    )
