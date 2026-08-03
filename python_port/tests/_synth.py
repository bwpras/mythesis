"""Synthetic .bin file builders matching the exact packet layout documented in
matlab/ingestion/loadNodoData.m. Used only by the smoke tests -- there is no
real hardware sample data or MATLAB install in this environment, so these
tests validate control-flow/byte-layout correctness, not numerical agreement
with real MATLAB output (see python_port/README.md).
"""
from __future__ import annotations

import struct
from datetime import datetime, timezone
from pathlib import Path

PCAL_SCALE = 3.6 / 3.3 * 0.000788
PCAL_OFFSET = -2.3057


def bar_to_raw(bar: float) -> int:
    """Invert pCal = ((raw*3.6/3.3)*0.000788) - 2.3057."""
    raw = int(round((bar - PCAL_OFFSET) / PCAL_SCALE))
    return max(-32000, min(32000, raw))


def _dt_to_ms(dt: datetime) -> int:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def write_msg_wake(f):
    f.write(struct.pack("<B", 0))    # sohcar
    f.write(struct.pack("<B", 0))    # contatore
    f.write(struct.pack("<B", 10))   # pktlen
    f.write(struct.pack("<B", 0))    # idDest
    f.write(struct.pack("<B", 0))    # idSource
    f.write(struct.pack("<B", 0x20))  # PkType = MSG_WAKE
    f.write(struct.pack("<B", 0))    # Soglia
    f.write(struct.pack("<H", 0))    # Vbatt
    f.write(struct.pack("<H", 0))    # Vin
    f.write(struct.pack("<H", 0))    # Id
    f.write(struct.pack("<H", 0))    # Ic
    f.write(struct.pack("<h", 0))    # Temp
    f.write(struct.pack("<B", 0))    # RSSI
    f.write(struct.pack("<B", 0))    # eochar


def write_hp_packet(f, dt, bar, vbatt_raw=24000, vin_raw=24500, id_raw=15, ic_raw=20,
                     temp_raw=2500, rssi_byte=200):
    raw = bar_to_raw(bar)
    press80 = [raw + (i % 5) for i in range(80)]
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 62))
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 0x01))  # PkType != MSG_WAKE
    f.write(struct.pack("<H", vbatt_raw))
    f.write(struct.pack("<H", vin_raw))
    f.write(struct.pack("<H", id_raw))
    f.write(struct.pack("<H", ic_raw))
    f.write(struct.pack("<h", temp_raw))
    f.write(struct.pack("<Q", _dt_to_ms(dt)))
    f.write(struct.pack("<80h", *press80))
    f.write(struct.pack("<H", 80))  # n_sample
    f.write(struct.pack("<H", 0))   # dummy1
    f.write(struct.pack("<H", 0))   # dummy2
    f.write(struct.pack("<B", rssi_byte))
    f.write(struct.pack("<B", 0))   # eochar


def write_lp_packet(f, dt, bar, vbatt_raw=24000, vin_raw=24500, id_raw=15, ic_raw=20,
                     temp_raw=2500, rssi_byte=200):
    raw = bar_to_raw(bar)
    press10 = [raw + i for i in range(10)]
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 62))
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 0))
    f.write(struct.pack("<B", 0x01))
    f.write(struct.pack("<H", vbatt_raw))
    f.write(struct.pack("<H", vin_raw))
    f.write(struct.pack("<H", id_raw))
    f.write(struct.pack("<H", ic_raw))
    f.write(struct.pack("<h", temp_raw))
    f.write(struct.pack("<Q", _dt_to_ms(dt)))
    f.write(struct.pack("<10h", *press10))
    f.write(struct.pack("<70h", *([0] * 70)))  # the padding region the NaT-mask must drop
    f.write(struct.pack("<H", 10))
    f.write(struct.pack("<H", 0))
    f.write(struct.pack("<H", 0))
    f.write(struct.pack("<B", rssi_byte))
    f.write(struct.pack("<B", 0))


def build_pressure_file(root: Path, fname: str, dt_start: datetime, bar: float,
                         n_packets: int = 5, dt_step_sec: float = 2.0,
                         packet_kind: str = "hp", with_leading_wake: bool = False) -> Path:
    path = root / fname
    writer = write_hp_packet if packet_kind == "hp" else write_lp_packet
    with open(path, "wb") as f:
        if with_leading_wake:
            write_msg_wake(f)
        for p in range(n_packets):
            ts = dt_start.timestamp() + p * dt_step_sec
            dt = datetime.fromtimestamp(ts, tz=timezone.utc)
            writer(f, dt, bar)
    return path


def bin_filename(dt: datetime, kit_hex: str, tag: str, kind: str = "p") -> str:
    return f"{dt.year:04d}_{dt.month:02d}{dt.day:02d}{dt.hour:02d}{dt.minute:02d}{dt.second:02d}_{kit_hex}_{tag}_{kind}.bin"
