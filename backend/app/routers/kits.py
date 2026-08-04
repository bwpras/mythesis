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


def _predictions_for(kit_id: str):
    """Best-effort: returns None (no predicted_leakage column) if there's
    no trained model yet, or if this kit's data is missing a required
    feature -- prediction is an enrichment, not a reason to fail the
    whole events/kit response."""
    bundle = predict.get_active_bundle()
    if bundle is None:
        return None
    try:
        df = data_store.load_kit_table(kit_id)
        return predict.predict_for_dashboard(bundle, df)
    except KeyError:
        return None


@router.get("")
def list_kits():
    results = []
    for kid in data_store.available_kit_ids():
        summary = data_store.kit_summary(kid)
        summary["wagon_type"] = wagon_type_for_kit(kid)
        preds = _predictions_for(kid)
        summary["predicted_leakage_count"] = int(preds.sum()) if preds is not None else None
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
        preds = _predictions_for(kit_id)
        return _clean(data_store.list_events(kit_id, offset=offset, limit=limit, predictions=preds))
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/{kit_id}/events/{event_id}")
def get_event(kit_id: str, event_id: int):
    try:
        preds = _predictions_for(kit_id)
        return _clean(data_store.get_event(kit_id, event_id, predictions=preds))
    except (FileNotFoundError, KeyError) as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


