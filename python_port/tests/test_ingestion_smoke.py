"""Self-contained smoke tests for python_port/ingestion (Stage 1).

No real telemetry or MATLAB installation is required -- these build synthetic
.bin files matching the documented packet layout and check the Python port's
control flow, byte parsing, and sensor-classification logic against known
expected outcomes.

This validates internal consistency of the port, NOT numerical agreement
with real MATLAB output (there is no reference file or running MATLAB to
diff against in this environment). For that, see python_port/tools/ and
python_port/README.md.

Run directly:  python python_port/tests/test_ingestion_smoke.py
Or via pytest: pytest python_port/tests
"""
from __future__ import annotations

import pickle
import shutil
import sys
import tempfile
import traceback
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

import numpy as np

_THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_THIS_DIR.parent.parent))  # repo root, for `python_port.*` imports

from python_port.ingestion.load_nodo_data import load_nodo_data
from python_port.ingestion.batch_process import run_batch
from python_port.paths import PortPaths
from python_port.tests._synth import build_pressure_file, bin_filename, bar_to_raw, PCAL_SCALE, PCAL_OFFSET

MBP_BAR, BC_BAR, WV_BAR = 5.0, 0.05, 2.5


def _isolated_paths(tmp_dir: Path):
    """Patch python_port.paths.get_paths() so the label registry (project-root
    relative, independent of rootDir since the LabelDirectory() path fix)
    resolves under the test's own tmp dir instead of the real project's
    data/interim/label_registry -- otherwise every test run would write
    synthetic DatiXX label files into the real, shared registry."""
    fake = PortPaths(
        root=tmp_dir,
        raw=tmp_dir / "raw",
        interim=tmp_dir / "interim",
        processed=tmp_dir / "processed",
        external=tmp_dir / "external",
        features=tmp_dir / "features",
        figures=tmp_dir / "figures",
        models=tmp_dir / "models",
        reports=tmp_dir / "reports",
        logs=tmp_dir / "logs",
        live=tmp_dir / "processed" / "live",
    )
    return mock.patch("python_port.paths.get_paths", return_value=fake)


def test_pjm_reader_survives_out_of_range_speculative_timestamp():
    """Regression test for a real crash found on real data (Dati01, 2025-06-04):
    the 38B/39B disambiguation in read_pjm_file39 speculatively decodes 8
    arbitrary bytes as a posix-ms timestamp and only keeps that interpretation
    if it falls in [2025, 2030); MATLAB's datetime() tolerates wildly
    out-of-range values here, but Python's datetime.fromtimestamp() raised
    OSError on Windows for a byte sequence that decoded to ~year 16149
    (raw uint64 = 447743057664036 ms). That must not crash the parser -- it
    must be treated as implausible and fall through to the 39B interpretation.
    """
    from python_port.ingestion.read_pjm_file import _posix_ms_to_datetime, MAX_DATE

    huge_raw_ms = 447743057664036  # the actual value that crashed on real data
    result = _posix_ms_to_datetime(huge_raw_ms)
    assert result > MAX_DATE, "out-of-range speculative timestamp must sort outside the valid window"


def test_pressure_calibration_inversion():
    """bar_to_raw() must be the exact inverse of loadNodoData.m's pCal formula."""
    for bar in (0.0, 0.05, 2.5, 4.6, 5.0, 8.0):
        raw = bar_to_raw(bar)
        recovered = (raw * PCAL_SCALE) + PCAL_OFFSET
        assert abs(recovered - bar) < 0.01, f"bar={bar} recovered={recovered}"


def test_hp_classification_and_calibration():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Dati99"
        root.mkdir()
        dt0 = datetime(2026, 1, 15, 10, 0, 0, tzinfo=timezone.utc)

        build_pressure_file(root, bin_filename(dt0, "0xAAAA", "S1"), dt0, MBP_BAR, packet_kind="hp")
        build_pressure_file(root, bin_filename(dt0, "0xBBBB", "S2"), dt0, BC_BAR, packet_kind="hp")
        build_pressure_file(root, bin_filename(dt0, "0xCCCC", "S3"), dt0, WV_BAR, packet_kind="hp")

        with _isolated_paths(Path(tmp)):
            nodo = load_nodo_data(np.datetime64("2026-01-15T00:00:00"),
                                   np.datetime64("2026-01-16T00:00:00"), fsamp=40, root_dir=root)

        assert len(nodo) == 3, f"expected 3 sensors, got {len(nodo)}"
        by_id = {s["ID"]: s for s in nodo}
        assert by_id["0xAAAA"]["Label"] == "MBP"
        assert by_id["0xBBBB"]["Label"] == "BC"
        assert by_id["0xCCCC"]["Label"] == "WV"

        for sid, expected_bar in (("0xAAAA", MBP_BAR), ("0xBBBB", BC_BAR), ("0xCCCC", WV_BAR)):
            s = by_id[sid]
            assert len(s["Pressure"]) == 5 * 80, f"{sid}: expected 400 samples, got {len(s['Pressure'])}"
            mean_p = float(np.mean(s["Pressure"]))
            assert abs(mean_p - expected_bar) < 0.05, f"{sid}: mean pressure {mean_p} vs expected {expected_bar}"

        # +2h offset must be applied consistently to both Start_time and Time
        s = by_id["0xAAAA"]
        assert (s["Time"][0] - s["Start_time"][0]) == np.timedelta64(0, "us")


def test_lp_nat_masking_drops_padding():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Dati98"
        root.mkdir()
        dt0 = datetime(2026, 3, 1, 8, 0, 0, tzinfo=timezone.utc)
        n_packets = 6

        build_pressure_file(root, bin_filename(dt0, "0xDDDD", "S1"), dt0, MBP_BAR,
                             n_packets=n_packets, dt_step_sec=5.0, packet_kind="lp")
        build_pressure_file(root, bin_filename(dt0, "0xEEEE", "S2"), dt0, BC_BAR,
                             n_packets=n_packets, dt_step_sec=5.0, packet_kind="lp")
        build_pressure_file(root, bin_filename(dt0, "0xFFFF", "S3"), dt0, WV_BAR,
                             n_packets=n_packets, dt_step_sec=5.0, packet_kind="lp")

        with _isolated_paths(Path(tmp)):
            nodo = load_nodo_data(np.datetime64("2026-03-01T00:00:00"),
                                   np.datetime64("2026-03-02T00:00:00"), fsamp=1, root_dir=root)

        assert len(nodo) == 3
        for s in nodo:
            # each LP packet carries 80 int16 slots but only 10 are real samples;
            # the other 70 are zero-padded and must be dropped via the NaT time mask.
            assert len(s["Pressure"]) == n_packets * 10, \
                f"{s['ID']}: expected {n_packets*10} samples after NaT-mask, got {len(s['Pressure'])}"
            assert len(s["Time"]) == len(s["Pressure"])


def test_msg_wake_packet_is_skipped_without_corrupting_stream():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Dati97"
        root.mkdir()
        dt0 = datetime(2026, 5, 1, 9, 0, 0, tzinfo=timezone.utc)

        # MBP sensor gets a leading MSG_WAKE packet before its real data packets.
        build_pressure_file(root, bin_filename(dt0, "0x1111", "S1"), dt0, MBP_BAR,
                             n_packets=4, packet_kind="hp", with_leading_wake=True)
        build_pressure_file(root, bin_filename(dt0, "0x2222", "S2"), dt0, BC_BAR, n_packets=4, packet_kind="hp")
        build_pressure_file(root, bin_filename(dt0, "0x3333", "S3"), dt0, WV_BAR, n_packets=4, packet_kind="hp")

        with _isolated_paths(Path(tmp)):
            nodo = load_nodo_data(np.datetime64("2026-05-01T00:00:00"),
                                   np.datetime64("2026-05-02T00:00:00"), fsamp=40, root_dir=root)

        by_id = {s["ID"]: s for s in nodo}
        assert len(by_id["0x1111"]["Pressure"]) == 4 * 80, (
            "MSG_WAKE packet must not contribute samples or misalign the byte stream"
        )
        assert by_id["0x1111"]["Label"] == "MBP"


def test_label_cache_is_reused_on_second_run():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Dati96"
        root.mkdir()
        dt0 = datetime(2026, 6, 1, 7, 0, 0, tzinfo=timezone.utc)
        build_pressure_file(root, bin_filename(dt0, "0xA1A1", "S1"), dt0, MBP_BAR, packet_kind="hp")
        build_pressure_file(root, bin_filename(dt0, "0xB2B2", "S2"), dt0, BC_BAR, packet_kind="hp")
        build_pressure_file(root, bin_filename(dt0, "0xC3C3", "S3"), dt0, WV_BAR, packet_kind="hp")

        t0, t1 = np.datetime64("2026-06-01T00:00:00"), np.datetime64("2026-06-02T00:00:00")
        with _isolated_paths(Path(tmp)):
            nodo1 = load_nodo_data(t0, t1, fsamp=40, root_dir=root)
            cache_file = Path(tmp) / "interim" / "label_registry" / "Dati96_labels.csv"
            assert cache_file.is_file(), "expected a label cache file to be written after first classification"

            nodo2 = load_nodo_data(t0, t1, fsamp=40, root_dir=root)
        labels1 = {s["ID"]: s["Label"] for s in nodo1}
        labels2 = {s["ID"]: s["Label"] for s in nodo2}
        assert labels1 == labels2, "cached-run labels must match freshly-classified labels"


def test_batch_process_end_to_end():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "raw" / "Dati95"
        root.mkdir(parents=True)
        out_dir = Path(tmp) / "interim"
        dt0 = datetime(2026, 2, 10, 6, 0, 0, tzinfo=timezone.utc)
        build_pressure_file(root, bin_filename(dt0, "0xFEED", "S1"), dt0, MBP_BAR, packet_kind="hp")
        build_pressure_file(root, bin_filename(dt0, "0xF00D", "S2"), dt0, BC_BAR, packet_kind="hp")
        build_pressure_file(root, bin_filename(dt0, "0xBEEF", "S3"), dt0, WV_BAR, packet_kind="hp")

        with _isolated_paths(Path(tmp)):
            run_batch(root, out_dir, fsamp=40,
                      start_date=np.datetime64("2026-01-01"), end_date=np.datetime64("2026-03-01"))

            out_file = out_dir / "Dati95" / "Nodo_Dati95_20260210_20260211.pkl"
            assert out_file.is_file(), f"expected output at {out_file}"

            with open(out_file, "rb") as f:
                nodo = pickle.load(f)
            assert len(nodo) == 3
            assert {s["Label"] for s in nodo} == {"MBP", "BC", "WV"}

            # re-running must skip (file already exists) rather than reclassify/overwrite
            run_batch(root, out_dir, fsamp=40,
                      start_date=np.datetime64("2026-01-01"), end_date=np.datetime64("2026-03-01"))


def test_read_real_mat_label_registries():
    """Regression test for mat_table_reader.py against the real, pre-existing
    MATLAB-classified label caches checked into data/interim/label_registry/.

    Unlike the .bin packet format exercised above (whose byte layout is
    fully documented and reproducible from loadNodoData.m), there is no way
    to synthesize a MATLAB v7.3 MCOS `table` object without a MATLAB
    installation -- so this validates against the real fixtures already in
    the repo instead of synthetic ones. Skips (prints, doesn't fail) if that
    directory isn't present, e.g. in a checkout that doesn't have it.
    """
    from python_port.ingestion.mat_table_reader import read_sensor_labels_table

    reg_dir = Path(__file__).resolve().parents[2] / "data" / "interim" / "label_registry"
    mat_files = sorted(reg_dir.glob("*_labels.mat")) if reg_dir.is_dir() else []
    if not mat_files:
        print("  (skipped: no real data/interim/label_registry/*.mat fixtures found)")
        return

    for p in mat_files:
        df = read_sensor_labels_table(p)
        assert set(df.columns) == {"Folder", "SensorID", "SensorLabel"}, f"{p.name}: unexpected columns"
        assert len(df) > 0, f"{p.name}: empty table"
        assert df["SensorLabel"].isin(["MBP", "BC", "WV"]).all(), f"{p.name}: invalid label(s)"
        assert df["SensorID"].is_unique, f"{p.name}: duplicate SensorID"
        assert (df["Folder"] == df["Folder"].iloc[0]).all(), f"{p.name}: inconsistent Folder value"


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
