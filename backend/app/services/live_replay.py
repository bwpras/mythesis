"""Replay-runner service: drip-feeds historical `.bin` files from a raw kit
folder into a watch folder at sped-up timing, so `live_watch.py`'s watcher
has something to react to without a real live gateway -- the UI-driven
counterpart to running `python_port/tools/replay_bin_files.py` by hand.

Mirrors live_watch.py's registry pattern (dict + threading.Lock, one thread
per kit, start/stop via threading.Event) for the same reason given there:
this is an indefinite process (especially with loop=True), needs on-demand
stop, and has a status shape (files copied/total, current file) that
doesn't fit services/jobs.py's one-shot Job model.
"""
from __future__ import annotations

import sys
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Optional

# python_port lives at the repo root, one level up from backend/ -- same
# sys.path precedent already used by services/pipeline.py and live_watch.py.
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from python_port.tools.replay_bin_files import replay  # noqa: E402

from ..config import resolve_under_data  # noqa: E402


@dataclass
class ReplayStatus:
    kit_id: str
    source_dir: str
    dest_dir: str
    speed: float
    loop: bool
    is_running: bool = True
    started_at: str = ""
    finished_at: Optional[str] = None
    files_total: int = 0
    files_copied: int = 0
    current_file: Optional[str] = None
    last_error: Optional[str] = None

    def to_dict(self) -> dict:
        return {
            "kit_id": self.kit_id,
            "source_dir": self.source_dir,
            "dest_dir": self.dest_dir,
            "speed": self.speed,
            "loop": self.loop,
            "is_running": self.is_running,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "files_total": self.files_total,
            "files_copied": self.files_copied,
            "current_file": self.current_file,
            "last_error": self.last_error,
        }


class _ReplayHandle:
    def __init__(self, kit_id: str, source_dir: Path, dest_dir: Path, speed: float,
                 start_from: Optional[str], loop: bool):
        self.stop_event = threading.Event()
        self.status = ReplayStatus(
            kit_id=kit_id,
            source_dir=str(source_dir),
            dest_dir=str(dest_dir),
            speed=speed,
            loop=loop,
            started_at=datetime.now(timezone.utc).isoformat(),
        )
        self.thread = threading.Thread(
            target=self._run, args=(source_dir, dest_dir, speed, start_from, loop), daemon=True,
        )

    def _run(self, source_dir: Path, dest_dir: Path, speed: float,
              start_from: Optional[str], loop: bool) -> None:
        def on_progress(i: int, total: int, filename: str) -> None:
            self.status.files_total = total
            self.status.files_copied = i
            self.status.current_file = filename

        try:
            replay(
                source_dir, dest_dir, speed=speed, start_from=start_from, loop=loop,
                progress_cb=on_progress, stop_event=self.stop_event,
            )
        except Exception as exc:  # noqa: BLE001 -- surface to status rather than dying silently on a background thread
            self.status.last_error = str(exc)
        finally:
            self.status.is_running = False
            self.status.finished_at = datetime.now(timezone.utc).isoformat()


_replays: Dict[str, _ReplayHandle] = {}
_lock = threading.Lock()


def start_replay(kit_id: str, dest_dir: str, speed: float = 40.0,
                  start_from: Optional[str] = None, loop: bool = False,
                  source_dir: Optional[str] = None) -> dict:
    with _lock:
        existing = _replays.get(kit_id)
        if existing is not None and existing.status.is_running:
            raise ValueError(f"Replay already running for {kit_id}")

        dest = resolve_under_data(dest_dir)
        # Defaults to the same data/raw/<kit_id> convention pipeline.py uses
        # for batch ingestion -- the one raw source a kit_id maps to.
        src = resolve_under_data(source_dir) if source_dir else resolve_under_data(Path("raw") / kit_id)
        if not src.is_dir():
            raise ValueError(f"Source directory not found: {src}")

        handle = _ReplayHandle(kit_id, src, dest, speed, start_from, loop)
        _replays[kit_id] = handle
        handle.thread.start()
        return handle.status.to_dict()


def stop_replay(kit_id: str) -> dict:
    with _lock:
        handle = _replays.get(kit_id)
    if handle is None:
        raise KeyError(f"No replay for {kit_id}")
    handle.stop_event.set()
    handle.thread.join(timeout=10)
    return handle.status.to_dict()


def get_replay_status(kit_id: str) -> Optional[dict]:
    with _lock:
        handle = _replays.get(kit_id)
    return handle.status.to_dict() if handle else None
