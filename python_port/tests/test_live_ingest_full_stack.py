"""Full-stack regression test: writes synthetic `.bin` files representing
one continuous braking event deliberately split across multiple file
boundaries, then compares the batch path (`load_nodo_data()` reading every
file at once) against the live path (`live_ingest.py` parsing one file at a
time, fed through `CausalFilterState` + `BrakingCycleDetector`) -- proving
the ingestion-layer wiring (byte parsing -> assembly -> filter -> detect),
not just the in-memory-array-level equivalence already proven in
test_braking_detection_incremental.py, correctly carries a cycle across
file arrivals instead of losing it.

Run directly:  python python_port/tests/test_live_ingest_full_stack.py
Or via pytest: pytest python_port/tests
"""
from __future__ import annotations

import struct
import sys
import tempfile
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import numpy as np

_THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_THIS_DIR.parent.parent))  # repo root, for `python_port.*` imports

from python_port.feature_extraction.braking_detection import (
    BrakingCycleDetector, ChannelSchema, detect_braking_struct_beta,
)
from python_port.feature_extraction.filtering import CausalFilterState
from python_port.ingestion.filename_pattern import parse_bin_filename
from python_port.ingestion.live_ingest import parse_new_pressure_file
from python_port.ingestion.load_nodo_data import load_nodo_data
from python_port.paths import PortPaths
from python_port.tests._synth import bar_to_raw, bin_filename, write_hp_packet

FS = 40.0
DT_STEP_SEC = 2.0  # one HP packet = 80 samples @ 25ms = exactly 2s, so packets are contiguous


def _isolated_paths(tmp_dir: Path):
    """Same isolation pattern used by test_ingestion_smoke.py/test_feature_extraction_smoke.py --
    keeps this test's label/pairing registry writes out of the real project's data/interim/."""
    fake = PortPaths(
        root=tmp_dir, raw=tmp_dir / "raw", interim=tmp_dir / "interim",
        processed=tmp_dir / "processed", external=tmp_dir / "external",
        features=tmp_dir / "features", figures=tmp_dir / "figures",
        models=tmp_dir / "models", reports=tmp_dir / "reports", logs=tmp_dir / "logs",
        live=tmp_dir / "processed" / "live",
    )
    return mock.patch("python_port.paths.get_paths", return_value=fake)


def _mbp_packet_bars() -> list:
    """26 packets (52s @ 2s/packet): 5 flat @5.0 -> 6-packet ramp 5.0->3.0 ->
    4 flat @3.0 -> 6-packet ramp 3.0->5.0 -> 5 flat @5.0. Coarser than the
    per-sample ramp in test_braking_detection_incremental.py (one bar per
    whole 2s packet, not per 25ms sample) but the same shape, comfortably
    clearing MBP_LOWER=4.7, INIT_GRAD_THRESH via the packet-boundary step,
    and MIN_P_DROP=0.2 (total drop 2.0 bar)."""
    down = list(np.linspace(5.0, 3.0, 6))
    up = list(np.linspace(3.0, 5.0, 6))
    return [5.0] * 5 + down + [3.0] * 4 + up + [5.0] * 5


def _write_packet_group(root: Path, kit_hex: str, tag: str, dt_start: datetime,
                         bars: list, file_splits: list) -> list:
    """Writes one sensor's packets (constant-within-packet bar, one value
    per `bars` entry) split across len(file_splits)+1 files at the given
    packet-index boundaries. Returns the written file paths in order. Each
    file's name timestamp is its own last packet's time, matching the real
    convention -- ordering files by filename timestamp (as the live watcher
    does) reproduces packet arrival order."""
    bounds = [0] + list(file_splits) + [len(bars)]
    paths = []
    for i in range(len(bounds) - 1):
        lo, hi = bounds[i], bounds[i + 1]
        pkt_times = [dt_start + timedelta(seconds=p * DT_STEP_SEC) for p in range(lo, hi)]
        fname = bin_filename(pkt_times[-1], kit_hex, tag, kind="p")
        path = root / fname
        with open(path, "wb") as f:
            for t, bar in zip(pkt_times, bars[lo:hi]):
                write_hp_packet(f, t, bar)
        paths.append(path)
    return paths


def _run_batch(root: Path, t_start: np.datetime64, t_end: np.datetime64) -> list:
    nodo = load_nodo_data(t_start, t_end, 40.0, root)
    test = []
    for sensor in nodo:
        if len(sensor.get("Time", [])) == 0:
            continue
        filt = CausalFilterState(fs=FS).feed(np.asarray(sensor["Pressure"], dtype=np.float64))
        channel = dict(sensor)
        channel["Pressure_filter"] = filt.pressure_filter
        channel["Pressure_filter_10Hz"] = filt.pressure_filter_10hz
        channel["Gradient_pressure_filtered"] = filt.gradient_pressure_filtered
        test.append(channel)
    test_brake, _, _ = detect_braking_struct_beta(test, verbose=False)
    return test_brake


def _run_live(files_in_arrival_order: list) -> list:
    """files_in_arrival_order: list of (path, role, id) tuples, already
    sorted by filename timestamp (as the watcher's poll loop would sort
    newly-seen files)."""
    mbp_schema = ChannelSchema(role="MBP", label="MBP", id="0xAAAA", test_index=0)
    bc_schema = ChannelSchema(role="BC", label="BC1", id="0xBBBB", test_index=1)
    wv_schema = ChannelSchema(role="WV", label="WV1", id="0xCCCC", test_index=2)
    detector = BrakingCycleDetector.from_schema(mbp_schema, [bc_schema], [wv_schema], verbose=False)
    filter_states = {"0xAAAA": CausalFilterState(fs=FS), "0xBBBB": CausalFilterState(fs=FS),
                      "0xCCCC": CausalFilterState(fs=FS)}

    for path, _role, sensor_id in files_in_arrival_order:
        parsed_chunks = parse_new_pressure_file(path, fsamp=40.0)
        chunk = {}
        for sid, raw_chunk in parsed_chunks.items():
            filt = filter_states[sid].feed(raw_chunk["Pressure"])
            chunk[sid] = {
                "time": raw_chunk["Time"], "pressure_filter": filt.pressure_filter,
                "pressure_filter_10hz": filt.pressure_filter_10hz,
                "gradient_filtered": filt.gradient_pressure_filtered,
                "vbatt": None, "temperature": None, "rssi": None,
            }
        detector.feed(chunk)

    return detector.flush_final()


def test_full_stack_replay_matches_batch_load_nodo_data():
    # Hour must be in [1,23] -- load_nodo_data() deliberately excludes
    # hour-0 files (see its `1 <= int(str(r[1])[11:13]) <= 23` filter).
    dt_start = datetime(2026, 1, 1, 10, 0, 0, tzinfo=timezone.utc)
    mbp_bars = _mbp_packet_bars()
    n_packets = len(mbp_bars)
    bc_bars = [0.02] * n_packets
    wv_bars = [2.5] * n_packets

    # Split boundaries land mid-ramp-down (packet 8, ramp spans 5..10) and
    # mid-ramp-up (packet 18, ramp spans 15..20) -- the exact case this
    # whole feature exists for: an open braking cycle spanning file arrivals.
    splits = [8, 18]

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        with _isolated_paths(tmp_dir):
            raw_root = tmp_dir / "raw" / "Dati90"
            raw_root.mkdir(parents=True)

            mbp_files = _write_packet_group(raw_root, "0xAAAA", "S1", dt_start, mbp_bars, splits)
            bc_files = _write_packet_group(raw_root, "0xBBBB", "S2", dt_start, bc_bars, splits)
            wv_files = _write_packet_group(raw_root, "0xCCCC", "S3", dt_start, wv_bars, splits)
            assert len(mbp_files) == 3, "sanity: 2 split points must yield 3 files"

            t_start = np.datetime64(dt_start.replace(tzinfo=None))
            t_end = t_start + np.timedelta64(1, "D")
            batch = _run_batch(raw_root, t_start, t_end)
            assert len(batch) == 1, f"sanity: scenario must produce exactly one phase, got {len(batch)}"

            # Arrival order: sort all files by their filename-embedded
            # timestamp, exactly as the watcher's poll loop does -- MBP/BC/WV
            # files interleave here since all three sensors' files share the
            # same packet-time boundaries.
            all_files = (
                [(p, "MBP", "0xAAAA") for p in mbp_files]
                + [(p, "BC", "0xBBBB") for p in bc_files]
                + [(p, "WV", "0xCCCC") for p in wv_files]
            )
            all_files.sort(key=lambda row: parse_bin_filename(row[0].name)[0])

            live = _run_live(all_files)

    assert len(live) == 1, f"live path lost or split the cycle across file boundaries: got {len(live)} phase(s)"

    b, l = batch[0], live[0]
    assert abs(b["InitPressure"] - l["InitPressure"]) < 1e-6
    total_drop_b = b["InitPressure"] - float(b["MBP_Pressure"].min())
    total_drop_l = l["InitPressure"] - float(l["MBP_Pressure"].min())
    assert total_drop_b > 0.2 and abs(total_drop_b - total_drop_l) < 1e-6
    assert b["MBP_EndOfBrakeIdx"] == l["MBP_EndOfBrakeIdx"]

    # Confirm the phase genuinely spans more than one file's worth of real
    # time (proves file-boundary continuation was actually exercised, not
    # just that a single file happened to contain the whole event).
    span_s = (l["MBP_EndOfBrakeTime"] - l["MBP_StartTime"]) / np.timedelta64(1, "s")
    one_file_span_s = 8 * DT_STEP_SEC  # smallest of the three file segments
    assert span_s > one_file_span_s, (
        f"phase span {span_s}s should exceed one file's ~{one_file_span_s}s to prove "
        f"it crossed a file boundary"
    )


def _run_all():
    tests = [(name, fn) for name, fn in sorted(globals().items())
             if name.startswith("test_") and callable(fn)]
    passed, failed = 0, []
    for name, fn in tests:
        try:
            fn()
            print(f"PASS  {name}")
            passed += 1
        except Exception:
            print(f"FAIL  {name}")
            traceback.print_exc()
            failed.append(name)

    print(f"\n{passed}/{len(tests)} passed.")
    if failed:
        print("Failed:", ", ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    _run_all()
