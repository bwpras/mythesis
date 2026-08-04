from __future__ import annotations

import math

from fastapi import APIRouter, HTTPException

from ..services import diagnostics, predict

router = APIRouter(prefix="/api", tags=["diagnostics"])


def _clean(obj):
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_clean(v) for v in obj]
    if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
        return None
    return obj


@router.get("/model")
def get_model_info():
    info = predict.model_diagnostics()
    if info is None:
        raise HTTPException(status_code=404, detail="No trained model available yet")
    return _clean(info)


@router.get("/diagnostics")
def get_fleet_diagnostics():
    return _clean(diagnostics.fleet_diagnostics())


@router.get("/diagnostics/{kit_id}")
def get_kit_diagnostics(kit_id: str):
    try:
        return _clean(diagnostics.kit_diagnostics(kit_id))
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
