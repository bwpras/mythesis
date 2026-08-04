from __future__ import annotations

import math

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..services import data_store, live_watch

router = APIRouter(prefix="/api/live", tags=["live"])


def _clean(obj):
    """Same NaN/inf -> None scrub as kits.py/diagnostics.py (each router
    keeps its own copy -- existing precedent, not worth extracting)."""
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_clean(v) for v in obj]
    if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
        return None
    return obj


class StartWatcherRequest(BaseModel):
    watch_dir: str
    poll_interval_s: float = 1.0


@router.post("/{kit_id}/start")
def start(kit_id: str, req: StartWatcherRequest):
    try:
        status = live_watch.start_watcher(kit_id, req.watch_dir, req.poll_interval_s)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _clean(status)


@router.post("/{kit_id}/stop")
def stop(kit_id: str):
    try:
        status = live_watch.stop_watcher(kit_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return _clean(status)


@router.get("/{kit_id}/status")
def status(kit_id: str):
    result = live_watch.get_watcher_status(kit_id)
    if result is None:
        raise HTTPException(status_code=404, detail=f"No watcher for {kit_id}")
    return _clean(result)


@router.get("/{kit_id}/events")
def recent_events(kit_id: str, limit: int = 50):
    try:
        df = data_store.load_live_kit_table(kit_id)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    df = df.sort_values("Start_brake_time_pipe", ascending=False, na_position="last").head(limit)
    columns = [c for c in data_store.EVENT_LIST_COLUMNS + ["predicted_leakage"] if c in df.columns]
    return _clean(df[columns].to_dict(orient="records"))


@router.get("")
def list_active():
    return _clean(live_watch.list_active_watchers())
