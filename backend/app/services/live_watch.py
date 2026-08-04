"""Live-watcher service: watches a folder for new `.bin` files belonging to
one kit, feeds them incrementally through `BrakingCycleDetector`, and scores
each completed braking cycle with the trained model as soon as it closes.

Deliberately NOT built on services/jobs.py: jobs are one-shot, terminal-state
(queued -> running -> done|failed), no stop/resume concept. A watcher is
indefinite, needs on-demand stop, and needs a status shape (is_running,
cycle_in_progress, last_prediction) that doesn't fit a Job's result/error
fields. This is a parallel, equally lightweight registry (dict +
threading.Lock), matching jobs.py's own "no Celery/Redis, not solving a
scaling problem this project doesn't have" precedent.

v1 does not persist detector/filter state across a backend restart --
BrakingCycleDetector/CausalFilterState are deliberately plain, resource-free
state containers (no open file handles, no threads inside them), so
periodic pickling is a trivial, clearly-scoped follow-up if ever needed, not
built now (matches the project's demo/replay scope, not a production
gateway integration).
"""
from __future__ import annotations

import sys
import threading
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

# python_port lives at the repo root, one level up from backend/ -- same
# sys.path precedent already used by services/pipeline.py.
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import pandas as pd  # noqa: E402

from python_port.feature_extraction.braking_detection import BrakingCycleDetector, ChannelSchema  # noqa: E402
from python_port.feature_extraction.build_test_brake_sets import build_test_brake_sets  # noqa: E402
from python_port.feature_extraction.csv_export import export_live_feature_csv  # noqa: E402
from python_port.feature_extraction.detect_subphases_sets import detect_subphases_sets  # noqa: E402
from python_port.feature_extraction.filtering import CausalFilterState  # noqa: E402
from python_port.feature_extraction.pipeline import _DEFAULT_BC_KWARGS, _DEFAULT_MBP_KWARGS  # noqa: E402
from python_port.feature_extraction.postprocessing import build_feature_table, compute_derived_fields  # noqa: E402
from python_port.ingestion.filename_pattern import parse_bin_filename  # noqa: E402
from python_port.ingestion.live_ingest import parse_new_gps_file, parse_new_pressure_file  # noqa: E402
from python_port.ingestion.live_precondition import check_live_precondition  # noqa: E402

from . import live_timeseries
from . import predict as predict_service


@dataclass
class WatcherStatus:
    kit_id: str
    watch_dir: str
    is_running: bool = True
    started_at: str = ""
    last_file_seen_at: Optional[str] = None
    cycle_in_progress: bool = False
    files_processed: int = 0
    phases_completed: int = 0
    last_prediction: Optional[dict] = None
    last_error: Optional[str] = None

    def to_dict(self) -> dict:
        return {
            "kit_id": self.kit_id, "watch_dir": self.watch_dir, "is_running": self.is_running,
            "started_at": self.started_at, "last_file_seen_at": self.last_file_seen_at,
            "cycle_in_progress": self.cycle_in_progress, "files_processed": self.files_processed,
            "phases_completed": self.phases_completed, "last_prediction": self.last_prediction,
            "last_error": self.last_error,
        }


class _WatcherHandle:
    def __init__(self, kit_id: str, watch_dir: Path, poll_interval_s: float,
                 detector: BrakingCycleDetector, label_map: Dict[str, str]):
        self.kit_id = kit_id
        self.watch_dir = watch_dir
        self.poll_interval_s = poll_interval_s
        self.detector = detector
        self.filter_states: Dict[str, CausalFilterState] = {}
        self.label_map = label_map
        self.seen_files: set = set()
        self.stop_event = threading.Event()
        self.status = WatcherStatus(
            kit_id=kit_id, watch_dir=str(watch_dir),
            started_at=datetime.now().isoformat(timespec="seconds"),
        )
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self.stop_event.is_set():
            try:
                self._poll_once()
            except Exception as exc:  # noqa: BLE001 - "flag, don't fail" ethos, matches braking_detection.py
                self.status.last_error = f"{exc}\n{traceback.format_exc()}"
            self.stop_event.wait(self.poll_interval_s)
        try:
            self._flush_and_export(self.detector.flush_final())
        except Exception as exc:  # noqa: BLE001
            self.status.last_error = f"final flush: {exc}\n{traceback.format_exc()}"
        self.status.is_running = False

    def _poll_once(self) -> None:
        new_files = []
        for path in self.watch_dir.glob("*.bin"):
            if path.name in self.seen_files:
                continue
            parsed = parse_bin_filename(path.name)
            if parsed is None:
                continue
            end_time, kind, sensor_id = parsed
            new_files.append((path, end_time, kind, sensor_id))
        new_files.sort(key=lambda row: row[1])

        for path, _end_time, kind, sensor_id in new_files:
            self.seen_files.add(path.name)
            try:
                if kind == "p":
                    self._feed_pressure_file(path)
                else:
                    self.detector.feed_gps(parse_new_gps_file(path))
            except Exception as exc:  # noqa: BLE001 - one bad file must not kill the watcher
                self.status.last_error = f"{path.name}: {exc}"
                continue
            self.status.files_processed += 1
            self.status.last_file_seen_at = datetime.now().isoformat(timespec="seconds")

        self.status.cycle_in_progress = self.detector.in_progress
        completed = self.detector.flush_completed_phases()
        if completed:
            self._flush_and_export(completed)

    def _feed_pressure_file(self, path: Path) -> None:
        parsed_chunks = parse_new_pressure_file(path, fsamp=40.0)
        chunk = {}
        for sensor_id, raw_chunk in parsed_chunks.items():
            role = self.label_map.get(sensor_id)
            if role is None:
                # Unlike batch's load_nodo_data() (which silently defaults an
                # unrecognized sensor to "WV"), skip it here -- a live demo
                # is a much worse place for a silent misclassification than
                # a batch CSV a human reviews later.
                self.status.last_error = f"{path.name}: unrecognized sensor id {sensor_id!r}, skipped"
                continue
            filt = self.filter_states.setdefault(sensor_id, CausalFilterState(fs=40.0)).feed(raw_chunk["Pressure"])
            chunk[sensor_id] = {
                "time": raw_chunk["Time"], "pressure_filter": filt.pressure_filter,
                "pressure_filter_10hz": filt.pressure_filter_10hz,
                "gradient_filtered": filt.gradient_pressure_filtered,
                "vbatt": raw_chunk["Vbatt"], "temperature": raw_chunk["Temperature"], "rssi": raw_chunk["RSSI"],
            }
        if chunk:
            self.detector.feed(chunk)

    def _flush_and_export(self, phases: List[dict]) -> None:
        if not phases:
            return
        # Parent-folder name carries dataset_key ("DatiXX") for both
        # build_test_brake_sets._derive_dataset_key_from_filename() and
        # postprocessing._derive_run_file_folder()'s fallback regex.
        synthetic_file = Path(self.kit_id) / "live.pkl"

        # roster={} and reference_phase_idx=None are inert here: the
        # precondition already guarantees a LOCKED pairing registry, so
        # build_test_brake_sets() always takes its cheap "reference(saved)"
        # branch (a per-ID lookup) and returns before ever touching roster.
        test_brake_sets, _pair_table, dataset_key, _reg_path, _used_method = build_test_brake_sets(
            phases, roster={}, file=synthetic_file, reference_phase_idx=None, verbose=False,
        )
        test_brake_sets = detect_subphases_sets(
            test_brake_sets, mbp_kwargs=_DEFAULT_MBP_KWARGS, bc_kwargs=_DEFAULT_BC_KWARGS, verbose=False,
        )

        # Must run AFTER detect_subphases_sets() (needs Start_brake_time_pipe,
        # which is only added by mbp_pipe_subphases.py's own state machine --
        # NOT the raw TestBrake phase dict's MBP_StartTime, see
        # live_timeseries.py's module docstring for why that distinction
        # matters) and BEFORE compute_derived_fields()/build_feature_table()
        # (which only keep KEEP_FIELDS' scalar columns -- the raw
        # MBP_Time/MBP_Pressure/BC_Time/BC_Pressure arrays are gone after
        # that). Best-effort: a save failure is a warning, not a reason to
        # skip the CSV export these same phases still need.
        try:
            live_timeseries.save_phase_timeseries_from_sets(self.kit_id, test_brake_sets)
        except Exception as exc:  # noqa: BLE001
            self.status.last_error = f"timeseries save failed: {exc}"

        test_brake_sets = compute_derived_fields(test_brake_sets)
        table = build_feature_table(test_brake_sets, synthetic_file)
        if table.empty:
            return

        bundle = predict_service.get_active_bundle()
        if bundle is not None:
            try:
                table = table.assign(predicted_leakage=predict_service.predict_for_dashboard(bundle, table))
            except KeyError:
                pass  # missing feature -- score-less row still exported, matches kits.py's best-effort pattern

        export_live_feature_csv(table, dataset_key)

        self.status.phases_completed += len(phases)
        last_row = table.iloc[-1]
        self.status.last_prediction = {
            "Start_brake_time_pipe": str(last_row.get("Start_brake_time_pipe")),
            "predicted_leakage": (
                None if "predicted_leakage" not in table.columns or pd.isna(last_row["predicted_leakage"])
                else float(last_row["predicted_leakage"])
            ),
        }


_watchers: Dict[str, _WatcherHandle] = {}
_lock = threading.Lock()


def start_watcher(kit_id: str, watch_dir: Path, poll_interval_s: float = 1.0) -> dict:
    """Runs check_live_precondition() first (raises ValueError with the
    actionable message on failure), builds the detector from the
    precondition's label map + locked pairing, starts a daemon thread."""
    with _lock:
        existing = _watchers.get(kit_id)
        if existing is not None and existing.status.is_running:
            raise ValueError(f"A watcher for {kit_id} is already running.")

        pre = check_live_precondition(kit_id)
        if not pre.ok:
            raise ValueError(" ".join(pre.reasons))

        mbp_id = next((sid for sid, role in pre.label_map.items() if role == "MBP"), None)
        if mbp_id is None:
            raise ValueError(f"No MBP sensor in {kit_id}'s label registry.")
        bc_ids = [sid for sid, role in pre.label_map.items() if role == "BC"]
        wv_ids = [sid for sid, role in pre.label_map.items() if role == "WV"]

        mbp_schema = ChannelSchema(role="MBP", label="MBP", id=mbp_id, test_index=0)
        bc_schemas = [ChannelSchema(role="BC", label="BC", id=sid, test_index=i + 1)
                      for i, sid in enumerate(bc_ids)]
        wv_schemas = [ChannelSchema(role="WV", label="WV", id=sid, test_index=i + 1 + len(bc_ids))
                      for i, sid in enumerate(wv_ids)]
        detector = BrakingCycleDetector.from_schema(mbp_schema, bc_schemas, wv_schemas, verbose=False)

        watch_dir = Path(watch_dir)
        watch_dir.mkdir(parents=True, exist_ok=True)
        handle = _WatcherHandle(
            kit_id=kit_id, watch_dir=watch_dir, poll_interval_s=poll_interval_s,
            detector=detector, label_map=pre.label_map,
        )
        _watchers[kit_id] = handle
        handle.thread.start()
        return handle.status.to_dict()


def stop_watcher(kit_id: str) -> dict:
    with _lock:
        handle = _watchers.get(kit_id)
    if handle is None:
        raise KeyError(f"No watcher for {kit_id}")
    handle.stop_event.set()
    handle.thread.join(timeout=10)
    return handle.status.to_dict()


def get_watcher_status(kit_id: str) -> Optional[dict]:
    with _lock:
        handle = _watchers.get(kit_id)
    return handle.status.to_dict() if handle is not None else None


def list_active_watchers() -> List[dict]:
    with _lock:
        handles = list(_watchers.values())
    return [h.status.to_dict() for h in handles]
