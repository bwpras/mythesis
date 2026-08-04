"""Preconditions a live watcher must satisfy before it may start for a
given kit.

Sensor-role classification (`identify_brake_sensors.py`, uses `filtfilt`,
needs a multi-minute steady window) and BC/WV pairing (`build_test_brake_sets.py`,
needs the whole day's phase list the FIRST time via `pick_reference_phase`/
`collect_healthy_sensor_data`) are both batch/multi-phase operations, not
things the live path can compute from a stream of newly-arrived files. Once
each is cached/locked, later use is a cheap per-ID lookup -- so the live
path requires both to already exist for a kit (via the existing batch
pipeline having run over some historical data), rather than attempting to
bootstrap them itself.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

import pandas as pd

from ..feature_extraction.build_test_brake_sets import _load_reg_file, _registry_path
from ..paths import get_paths
from .load_nodo_data import _read_label


@dataclass
class PreconditionResult:
    ok: bool
    reasons: List[str] = field(default_factory=list)
    label_registry_path: Optional[Path] = None
    pairing_registry_path: Optional[Path] = None
    label_map: Optional[Dict[str, str]] = None
    locked_pairing: Optional[pd.DataFrame] = None


def check_live_precondition(kit_id: str) -> PreconditionResult:
    """Checks, in order: (1) a sensor-label cache exists for `kit_id`;
    (2) the BC/WV pairing registry is locked (`UseReferencePhase=True` on
    at least one row). Fails loud with an actionable reason, not silent
    defaulting -- unlike batch's `load_nodo_data()`, which silently
    defaults an unrecognized sensor ID to "WV", a live demo is a much
    worse place for a silent misclassification than a batch CSV a human
    reviews later; callers should skip an unrecognized sensor rather than
    guess (see `label_map.get(id)` with no default, not `.get(id, "WV")`).
    """
    paths = get_paths()
    label_registry_path = paths.interim / "label_registry" / f"{kit_id}_labels.csv"
    pairing_registry_path = _registry_path(kit_id)
    reasons: List[str] = []

    # _read_label()'s root_dir argument only feeds a folder-key derivation
    # that's already resolved to a fixed, project-root-relative path
    # (kept for call-site symmetry with the batch path, see its own
    # docstring) -- kit_id doubles as folder_key here, matching how every
    # other caller derives it (Dati\d+ regex on a "DatiXX"-shaped root).
    cached = _read_label(Path(kit_id), kit_id)
    label_map: Optional[Dict[str, str]] = None
    if cached is None or len(cached) == 0:
        reasons.append(
            f"No sensor-label cache for {kit_id}. Run the batch pipeline "
            f"(POST /api/jobs/ingest) over at least one historical day for this kit first."
        )
    else:
        label_map = dict(zip(cached["SensorID"], cached["SensorLabel"]))

    locked_pairing: Optional[pd.DataFrame] = None
    pairing = _load_reg_file(pairing_registry_path)
    is_locked = (
        pairing is not None
        and "UseReferencePhase" in pairing.columns
        and bool(pairing["UseReferencePhase"].astype(bool).any())
    )
    if not is_locked:
        reasons.append(
            f"BC/WV pairing for {kit_id} is not locked yet. Run the batch pipeline over "
            f"enough historical data to produce at least one fully-eligible reference "
            f"phase (pick_reference_phase) before starting the live watcher."
        )
    else:
        locked_pairing = pairing

    return PreconditionResult(
        ok=len(reasons) == 0,
        reasons=reasons,
        label_registry_path=label_registry_path,
        pairing_registry_path=pairing_registry_path,
        label_map=label_map,
        locked_pairing=locked_pairing,
    )
