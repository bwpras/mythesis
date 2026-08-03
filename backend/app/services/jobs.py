"""In-memory background job registry.

This is a single-user, local dashboard (see docs/session notes) -- no
concurrent traffic to serve, so a thread + in-memory dict is enough. No
Celery/Redis: that would be solving a scaling problem this project doesn't
have yet.

Job lifecycle: queued -> running -> done | failed. The frontend polls
GET /api/jobs/{job_id} until status is done or failed.
"""
from __future__ import annotations

import threading
import traceback
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Optional


@dataclass
class Job:
    id: str
    kind: str
    status: str = "queued"  # queued | running | done | failed
    progress: str = ""
    result: Optional[Any] = None
    error: Optional[str] = None
    created_at: str = field(default_factory=lambda: datetime.now().isoformat(timespec="seconds"))
    updated_at: str = field(default_factory=lambda: datetime.now().isoformat(timespec="seconds"))

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "kind": self.kind,
            "status": self.status,
            "progress": self.progress,
            "result": self.result,
            "error": self.error,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


_jobs: dict[str, Job] = {}
_lock = threading.Lock()


def get_job(job_id: str) -> Optional[Job]:
    with _lock:
        return _jobs.get(job_id)


def list_jobs() -> list[Job]:
    with _lock:
        return sorted(_jobs.values(), key=lambda j: j.created_at, reverse=True)


def _set_progress(job_id: str, message: str) -> None:
    with _lock:
        job = _jobs[job_id]
        job.progress = message
        job.updated_at = datetime.now().isoformat(timespec="seconds")


def submit_job(kind: str, fn: Callable[[Callable[[str], None]], Any]) -> Job:
    """Runs `fn(report_progress)` on a background thread. `fn` should call
    `report_progress("...")` periodically and return a JSON-serializable
    result on success."""
    job = Job(id=uuid.uuid4().hex[:12], kind=kind)
    with _lock:
        _jobs[job.id] = job

    def report_progress(message: str) -> None:
        _set_progress(job.id, message)

    def run():
        with _lock:
            job.status = "running"
        try:
            result = fn(report_progress)
            with _lock:
                job.status = "done"
                job.result = result
                job.updated_at = datetime.now().isoformat(timespec="seconds")
        except Exception as exc:  # noqa: BLE001 - surface any failure to the job record
            with _lock:
                job.status = "failed"
                job.error = f"{exc}\n{traceback.format_exc()}"
                job.updated_at = datetime.now().isoformat(timespec="seconds")

    threading.Thread(target=run, daemon=True).start()
    return job
