from __future__ import annotations

import math

from fastapi import APIRouter, HTTPException, Query

from ..services import data_store, predict
from ..services.wagon_type import wagon_type_for_kit

router = APIRouter(prefix="/api/kits", tags=["kits"])


def _clean(obj):
    """Replaces NaN/inf (JSON has no representation for them) with None,
    recursively, so FastAPI's default JSON encoder doesn't choke on the
    many optional/guard-path-omitted feature columns."""
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_clean(v) for v in obj]
    if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
        return None
    return obj


@router.get("")
def list_kits():
    results = []
    for kid in data_store.available_kit_ids():
        summary = data_store.kit_summary(kid)
        summary["wagon_type"] = wagon_type_for_kit(kid)
        preds, _in_scope = predict.predictions_and_scope_for_kit(kid)
        # preds.sum() alone would silently treat "nothing scored" (all-NaN,
        # every event outside the model's trained regime) the same as
        # "scored N events, 0 were leakage" -- pandas' sum() skips NaN by
        # default, so both cases produce 0. Distinguishing them requires
        # checking how many rows actually got a real 0/1 value first.
        scored = preds.dropna() if preds is not None else None
        summary["predicted_leakage_count"] = int((scored == 1).sum()) if scored is not None and len(scored) else None
        summary["model_active"] = preds is not None
        results.append(_clean(summary))
    return results


@router.get("/{kit_id}")
def get_kit(kit_id: str):
    try:
        summary = data_store.kit_summary(kit_id)
        summary["wagon_type"] = wagon_type_for_kit(kit_id)
        return _clean(summary)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/{kit_id}/events")
def get_events(kit_id: str, offset: int = 0, limit: int = Query(default=50, le=500)):
    try:
        preds, in_scope = predict.predictions_and_scope_for_kit(kit_id)
        return _clean(data_store.list_events(kit_id, offset=offset, limit=limit, predictions=preds, in_scope=in_scope))
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/{kit_id}/events/{event_id}")
def get_event(kit_id: str, event_id: int):
    try:
        preds, in_scope = predict.predictions_and_scope_for_kit(kit_id)
        return _clean(data_store.get_event(kit_id, event_id, predictions=preds, in_scope=in_scope))
    except (FileNotFoundError, KeyError) as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/{kit_id}/locations")
def get_kit_locations(kit_id: str):
    try:
        return _clean(data_store.list_locations(kit_id))
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


