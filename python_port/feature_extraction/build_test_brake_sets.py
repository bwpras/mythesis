"""Port of matlab/feature_extraction/build_TestBrake_sets.m.

Pairs BC<->WV sensors either (A) by rank within a reference phase, or
(B) by rank from Roster (`collect_healthy_sensor_data`'s output) metrics,
persists the pairing decision to a per-dataset registry file, and splits
`TestBrake` into per-pair sets (1 MBP + 1 BC + 1 WV) with ID-based
flattening.

Save-file behavior (unchanged from MATLAB):
  - If a registry file for this dataset exists AND is "locked"
    (UseReferencePhase==True on any row) -> load pairing and DO NOT
    overwrite, regardless of what reference_phase_idx this call passed.
  - Else: reference_phase_idx valid -> compute from that phase, save with
    UseReferencePhase=True (locks future calls). reference_phase_idx
    None/invalid -> compute from Roster, save with UseReferencePhase=False
    (does not lock; a later call with a valid reference phase can still
    overwrite it).

Deviations from the MATLAB source (documented, not silent):
  - **Registry file location.** MATLAB saves `<DatiXX>_reg.mat` to `pwd`
    (the process's current working directory at call time) -- an
    order-/launch-dependent location, not a repo-relative one. This port
    uses the deterministic, project-root-relative
    `data/interim/pairing_registry/<DatiXX>_reg.csv`, matching the
    precedent already set for the sensor-label registry
    (`data/interim/label_registry/`, see `load_nodo_data.py`). This is a
    new artifact with no pre-existing real files to interoperate with
    (unlike the label registry), so there's no MATLAB `.mat` table to read
    -- CSV via pandas is used throughout, matching the label registry's
    own `.csv` side.
  - **`flattenSetsByPairing`'s "template struct" indirection is dropped.**
    MATLAB builds one template struct (from phase 1's MBP fields + default
    BC_*/WV_* fields) and `repmat`s it across all phases, because MATLAB
    struct arrays require every element to share the same field set. Each
    phase's real MBP field values (including its own `MBP_ID`) then get
    copied over that template in the per-phase loop -- which, since every
    phase carries an `MBP_ID` field already, unconditionally overwrites
    whatever `templ.MBP_ID` (sourced from `Roster.MBP_ID`) was seeded with.
    So that template step is dead code in practice (its value is always
    overwritten before being read) for any TestBrake with >=1 phase, which
    is guaranteed by this function's own top-level guard. Python dicts
    don't share MATLAB's homogeneous-field-set constraint, so this port
    just merges each phase's own MBP fields directly -- functionally
    identical output, without the indirection. `roster` is still accepted
    by `_flatten_sets_by_pairing()` to keep the call signature symmetric
    with the source, even though it is otherwise unused there.
"""
from __future__ import annotations

import math
import re
from datetime import datetime
from pathlib import Path
from typing import Optional, Union

import numpy as np
import pandas as pd


# --------------------------------------------------------------------------
# Small helpers mirroring MATLAB idioms in the source file
# --------------------------------------------------------------------------


def _sget(d: dict, key: str, default):
    """Port of sget(): field-present-and-nonempty, else default. A scalar
    NaN is treated as a valid (non-empty) value, matching MATLAB's
    isempty(NaN) == false -- only None and empty list/array/str count as
    'empty' here."""
    if key not in d:
        return default
    v = d[key]
    if v is None:
        return default
    if isinstance(v, (list, tuple, np.ndarray)) and len(v) == 0:
        return default
    return v


def _default_metric(entry: dict, preferred_field: str, fallback_field: str, agg_fn) -> float:
    """Port of defaultMetric(): use preferred_field if present, else
    agg_fn(fallback_field), else NaN."""
    v = _sget(entry, preferred_field, None)
    if v is None:
        w = _sget(entry, fallback_field, None)
        return float("nan") if w is None else float(agg_fn(w))
    return float(v)


def _normalize_id(x) -> str:
    """Port of normalizeID(). IDs in this codebase are always plain
    strings in practice (Stage 1's sensor ID convention, e.g. '0x74'), so
    the numeric branches below are for fidelity/robustness, not the common
    case."""
    if x is None:
        return ""
    if isinstance(x, str):
        return x
    if isinstance(x, (int, float, np.integer, np.floating)):
        xf = float(x)
        if math.isnan(xf):
            return "NaN"
        if math.isinf(xf):
            return "Inf" if xf > 0 else "-Inf"
        ref = max(1.0, abs(xf))
        if abs(xf - round(xf)) < np.spacing(ref):
            return f"{xf:.0f}"
        return f"{xf:.17g}"
    try:
        import json
        return json.dumps(x)
    except TypeError:
        return str(x)


def _find_row_by_id(entries: Optional[list], target_id: str) -> Optional[int]:
    """Port of findRowByID(). target_id must already be normalized."""
    if not entries:
        return None
    for i, e in enumerate(entries):
        if "ID" in e and _normalize_id(e["ID"]) == target_id:
            return i
    return None


def _find_label_for_id_in_test_brake(test_brake: list, field_name: str, target_id: str) -> str:
    """Port of findLabelForID_in_TestBrake(): scans all phases in order,
    returns the first *non-empty* Label found for a matching ID (a match
    with an empty Label does not stop the scan)."""
    for phase in test_brake:
        idx = _find_row_by_id(phase.get(field_name), target_id)
        if idx is not None:
            lbl = str(_sget(phase[field_name][idx], "Label", ""))
            if lbl != "":
                return lbl
    return ""


def _derive_dataset_key_from_filename(file: Union[str, Path]) -> str:
    """Port of deriveDatasetKeyFromFilename(): regex Dati(\\d+) on the base
    filename, falling back to the parent folder name."""
    file = str(file)
    base = Path(file).stem
    m = re.search(r"Dati(\d+)", base)
    if m:
        return f"Dati{m.group(1)}"
    folder_name = Path(file).parent.name
    m2 = re.search(r"Dati(\d+)", folder_name)
    if m2:
        return f"Dati{m2.group(1)}"
    raise ValueError(f'Cannot find DatiXX in "{base}".')


def _descend_sort_nan_last(values) -> np.ndarray:
    """Port of MATLAB's sort(values,'descend','MissingPlacement','last'):
    returns indices (0-based) into `values`, real numbers descending, NaN
    entries pushed to the end (in their original relative order, matching
    MATLAB's stable sort)."""
    values = np.asarray(values, dtype=np.float64)
    idx = np.arange(len(values))
    is_nan = np.isnan(values)
    real_idx = idx[~is_nan]
    nan_idx = idx[is_nan]
    real_order = real_idx[np.argsort(-values[~is_nan], kind="stable")]
    return np.concatenate([real_order, nan_idx])


def _registry_path(dataset_key: str) -> Path:
    """Canonical, project-root-relative registry location (see module
    docstring for why this differs from MATLAB's pwd-relative path)."""
    if __package__:
        from ..paths import get_paths
    else:
        from python_port.paths import get_paths
    return get_paths().interim / "pairing_registry" / f"{dataset_key}_reg.csv"


def _load_reg_file(reg_path: Path) -> Optional[pd.DataFrame]:
    if not reg_path.is_file():
        return None
    try:
        return pd.read_csv(reg_path, dtype={"BC_ID": str, "WV_ID": str})
    except (OSError, pd.errors.ParserError):
        return None


def _save_reg_file(reg_path: Path, pair_table: pd.DataFrame, source_file, use_ref: bool, ref_idx) -> None:
    """Port of saveRegFile(): best-effort persistence -- a write failure is
    a warning, not a fatal error (matches MATLAB's try/catch->warning)."""
    df = pair_table.copy()
    df["UseReferencePhase"] = bool(use_ref)
    df["RefPhaseIdx"] = ref_idx
    df["SourceFile"] = str(source_file)
    df["SavedOn"] = datetime.now().isoformat(timespec="seconds")
    try:
        reg_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = reg_path.with_suffix(reg_path.suffix + ".tmp")
        df.to_csv(tmp, index=False)
        tmp.replace(reg_path)
        print(f"Saved {len(df)} pair(s) to {reg_path}")
    except OSError as exc:
        print(f"Failed to save registry file {reg_path}: {exc}")


# --------------------------------------------------------------------------
# Pairing strategies
# --------------------------------------------------------------------------


def _compute_pairing_from_reference_phase(test_brake: list, reference_phase_idx: int) -> pd.DataFrame:
    """STRICT reference-phase pairing (1-indexed reference_phase_idx, matching
    pick_reference_phase's PhaseIdx-based return value):
      BC usable: Pressure nonempty && SensorError==0
      WV usable: Pressure nonempty && WV_SensorError==0
      (NormalBraking is ignored for eligibility, matching the source.)
    Ranks: BC by MaxPressure (fallback max(Pressure)), WV by MeanPressure
    (fallback mean(Pressure)), both descending, NaN last.
    """
    tb_ref = test_brake[reference_phase_idx - 1]
    if "BC" not in tb_ref or "WV" not in tb_ref:
        raise ValueError(f"Missing field on reference phase {reference_phase_idx}: 'BC' or 'WV'.")
    bc_ref, wv_ref = tb_ref["BC"], tb_ref["WV"]
    if not bc_ref or not wv_ref:
        raise ValueError(f"Reference phase {reference_phase_idx} has empty BC or WV arrays.")

    bc_idx = [i for i, b in enumerate(bc_ref)
              if _sget(b, "Pressure", None) is not None and not bool(_sget(b, "SensorError", 0))]
    wv_idx = [i for i, w in enumerate(wv_ref)
              if _sget(w, "Pressure", None) is not None and not bool(_sget(w, "WV_SensorError", 0))]
    if not bc_idx or not wv_idx:
        raise ValueError(f"Reference phase {reference_phase_idx} lacks usable BC or WV for pairing.")

    bc_max = np.array([_default_metric(bc_ref[i], "MaxPressure", "Pressure", np.max) for i in bc_idx])
    wv_avg = np.array([_default_metric(wv_ref[i], "MeanPressure", "Pressure", np.mean) for i in wv_idx])

    bc_order = _descend_sort_nan_last(bc_max)
    wv_order = _descend_sort_nan_last(wv_avg)

    npairs = min(len(bc_order), len(wv_order))
    bc_used_ref = [bc_idx[i] for i in bc_order[:npairs]]
    wv_used_ref = [wv_idx[i] for i in wv_order[:npairs]]

    bc_id = [_normalize_id(_sget(bc_ref[i], "ID", "")) for i in bc_used_ref]
    wv_id = [_normalize_id(_sget(wv_ref[i], "ID", "")) for i in wv_used_ref]
    bc_lab = [str(_sget(bc_ref[i], "Label", "")) for i in bc_used_ref]
    wv_lab = [str(_sget(wv_ref[i], "Label", "")) for i in wv_used_ref]
    bc_mp = [_default_metric(bc_ref[i], "MaxPressure", "Pressure", np.max) for i in bc_used_ref]
    wv_mp = [_default_metric(wv_ref[i], "MeanPressure", "Pressure", np.mean) for i in wv_used_ref]

    return pd.DataFrame({
        "PairIdx": np.arange(1, npairs + 1),
        "BC_ID": bc_id, "BC_MaxPressure": bc_mp, "BC_Label": bc_lab,
        "WV_ID": wv_id, "WV_MeanPressure": wv_mp, "WV_Label": wv_lab,
        "UseReferencePhase": [True] * npairs,
        "RefPhaseIdx": [float(reference_phase_idx)] * npairs,
    })


def _compute_pairing_from_roster(test_brake: list, roster: dict) -> pd.DataFrame:
    bc_list = roster.get("BC") or []
    wv_list = roster.get("WV") or []
    if not bc_list:
        raise ValueError("Roster['BC'] is empty.")
    if not wv_list:
        raise ValueError("Roster['WV'] is empty.")

    bc_ids = [_normalize_id(_sget(b, "ID", None)) for b in bc_list]
    wv_ids = [_normalize_id(_sget(w, "ID", None)) for w in wv_list]
    bc_mp = np.array([_sget(b, "MaxPressure", np.nan) for b in bc_list], dtype=np.float64)
    wv_mp = np.array([_sget(w, "MeanPressure", np.nan) for w in wv_list], dtype=np.float64)

    ord_bc = _descend_sort_nan_last(bc_mp)
    ord_wv = _descend_sort_nan_last(wv_mp)

    npairs = min(len(ord_bc), len(ord_wv))
    if npairs == 0:
        raise ValueError("No usable BC/WV pairs (Roster).")

    bc_ids_used = [bc_ids[i] for i in ord_bc[:npairs]]
    wv_ids_used = [wv_ids[i] for i in ord_wv[:npairs]]
    bc_mp_used = bc_mp[ord_bc[:npairs]]
    wv_mp_used = wv_mp[ord_wv[:npairs]]

    bc_labels_used = [_find_label_for_id_in_test_brake(test_brake, "BC", bid) for bid in bc_ids_used]
    wv_labels_used = [_find_label_for_id_in_test_brake(test_brake, "WV", wid) for wid in wv_ids_used]

    return pd.DataFrame({
        "PairIdx": np.arange(1, npairs + 1),
        "BC_ID": bc_ids_used, "BC_MaxPressure": bc_mp_used, "BC_Label": bc_labels_used,
        "WV_ID": wv_ids_used, "WV_MeanPressure": wv_mp_used, "WV_Label": wv_labels_used,
        "UseReferencePhase": [False] * npairs,
        "RefPhaseIdx": [np.nan] * npairs,
    })


# --------------------------------------------------------------------------
# Flattening
# --------------------------------------------------------------------------


def _default_bc_wv_fields() -> dict:
    """Port of addDefaultBCWVFields()."""
    return {
        "BC_Label": "", "BC_Time": None, "BC_Pressure": None, "BC_Pressure10hz": None,
        "BC_Gradient": None, "BC_SensorError": False, "BC_NormalBraking": False,
        "BC_LowBraking": False, "BC_BadStart": False,
        "BC_StartAboveThresh": False, "BC_FlatStartNearZero": False,
        "BC_AlreadyEngagedStart": False, "BC_ReleasingAtStart": False,
        "BC_StartTime": None, "BC_EndTime": None, "BC_TestIndex": np.nan,
        "BC_ID": "", "BC_MaxPressure": np.nan, "BC_Pressure_at_MBP_End": np.nan,
        "WV_Label": "", "WV_Time": None, "WV_Pressure": None,
        "WV_StartTime": None, "WV_EndTime": None, "WV_TestIndex": np.nan,
        "WV_ID": "", "WV_MeanPressure": np.nan, "WV_NumSamples": np.nan,
        "WV_SensorError": False,
    }


def _flatten_sets_by_pairing(test_brake: list, pair_table: pd.DataFrame, roster: dict, verbose: bool = True) -> list:
    """Port of flattenSetsByPairing(). Returns a list of length npairs;
    each element is a list of length num_phases (one dict per phase),
    matching MATLAB's `1 x npairs` cell array of `1 x numPhases` struct
    arrays. `roster` is unused here -- see module docstring."""
    del roster  # kept for call-signature symmetry with the MATLAB source; see module docstring
    num_phases = len(test_brake)
    mbp_only = [{k: v for k, v in phase.items() if k not in ("BC", "WV")} for phase in test_brake]

    npairs = len(pair_table)
    test_brake_sets = []

    for p in range(npairs):
        bc_id = pair_table["BC_ID"].iloc[p]
        wv_id = pair_table["WV_ID"].iloc[p]
        pair_idx = pair_table["PairIdx"].iloc[p]
        set_p = []

        for k in range(num_phases):
            entry = dict(mbp_only[k])
            entry.update(_default_bc_wv_fields())
            entry["PairIdx"] = pair_idx
            entry["BC_ID"] = bc_id
            entry["WV_ID"] = wv_id

            idx_bc = _find_row_by_id(test_brake[k].get("BC"), bc_id)
            if idx_bc is not None:
                b = test_brake[k]["BC"][idx_bc]
                entry["BC_Label"] = str(_sget(b, "Label", ""))
                entry["BC_Time"] = _sget(b, "Time", None)
                entry["BC_Pressure"] = _sget(b, "Pressure", None)
                entry["BC_Pressure10hz"] = _sget(b, "Pressure10hz", None)
                entry["BC_Gradient"] = _sget(b, "Gradient", None)
                entry["BC_SensorError"] = bool(_sget(b, "SensorError", 0))
                entry["BC_NormalBraking"] = bool(_sget(b, "NormalBraking", 0))
                entry["BC_LowBraking"] = bool(_sget(b, "LowBraking", 0))
                entry["BC_BadStart"] = bool(_sget(b, "BadStart", 0))
                entry["BC_StartTime"] = _sget(b, "StartTime", None)
                entry["BC_EndTime"] = _sget(b, "EndTime", None)
                entry["BC_TestIndex"] = _sget(b, "TestIndex", np.nan)
                entry["BC_Pressure_at_MBP_End"] = _sget(b, "EndPressure", np.nan)
                entry["BC_StartAboveThresh"] = bool(_sget(b, "StartAboveThresh", False))
                entry["BC_FlatStartNearZero"] = bool(_sget(b, "FlatStartNearZero", False))
                entry["BC_AlreadyEngagedStart"] = bool(_sget(b, "AlreadyEngagedStart", False))
                entry["BC_ReleasingAtStart"] = bool(_sget(b, "ReleasingAtStart", False))

                mp = _sget(b, "MaxPressure", None)
                pr = _sget(b, "Pressure", None)
                entry["BC_MaxPressure"] = (np.nan if pr is None else float(np.max(pr))) if mp is None else mp

            idx_wv = _find_row_by_id(test_brake[k].get("WV"), wv_id)
            if idx_wv is not None:
                w = test_brake[k]["WV"][idx_wv]
                entry["WV_Label"] = str(_sget(w, "Label", ""))
                entry["WV_Time"] = _sget(w, "Time", None)
                entry["WV_Pressure"] = _sget(w, "Pressure", None)
                entry["WV_StartTime"] = _sget(w, "StartTime", None)
                entry["WV_EndTime"] = _sget(w, "EndTime", None)
                entry["WV_TestIndex"] = _sget(w, "TestIndex", np.nan)
                entry["WV_SensorError"] = bool(_sget(w, "WV_SensorError", 0))

                mp = _sget(w, "MeanPressure", None)
                pr = _sget(w, "Pressure", None)
                entry["WV_MeanPressure"] = (np.nan if pr is None else float(np.mean(pr))) if mp is None else mp
                ns = _sget(w, "NumSamples", None)
                entry["WV_NumSamples"] = (0 if pr is None else len(pr)) if ns is None else ns

            set_p.append(entry)

        test_brake_sets.append(set_p)

    if verbose:
        print(f"[build_test_brake_sets] Built {npairs} set(s) (1 MBP + 1 BC + 1 WV) across {num_phases} phase(s).")

    return test_brake_sets


# --------------------------------------------------------------------------
# Main entry point
# --------------------------------------------------------------------------


def build_test_brake_sets(
    test_brake: list,
    roster: dict,
    file: Union[str, Path],
    reference_phase_idx: Optional[int],
    verbose: bool = True,
) -> tuple:
    """Returns (test_brake_sets, pair_table, dataset_key, reg_path, used_method).

    reference_phase_idx: 1-indexed (matching each phase's own 'PhaseIdx'
    field and pick_reference_phase's return convention), or None to force
    Roster-based pairing.
    used_method: one of "reference(saved)", "reference", "roster".
    """
    if not test_brake:
        raise ValueError("TestBrake must be a non-empty list.")
    if not isinstance(file, (str, Path)):
        raise TypeError("`file` must be a filename (str or Path).")

    dataset_key = _derive_dataset_key_from_filename(file)
    reg_path = _registry_path(dataset_key)

    if verbose:
        print(f"[build_test_brake_sets] Registry path: {reg_path}")

    loaded_pairing = _load_reg_file(reg_path)
    loaded_use_ref = False
    if loaded_pairing is not None and "UseReferencePhase" in loaded_pairing.columns:
        loaded_use_ref = bool(loaded_pairing["UseReferencePhase"].astype(bool).any())

    if loaded_use_ref:
        if verbose:
            ref_vals = (loaded_pairing["RefPhaseIdx"].unique().tolist()
                        if "RefPhaseIdx" in loaded_pairing.columns else [])
            print(f"[build_test_brake_sets] Using saved reference-phase pairing for {dataset_key} "
                  f"(RefPhaseIdx={ref_vals}). No overwrite.")
        pair_table = loaded_pairing
        used_method = "reference(saved)"
        test_brake_sets = _flatten_sets_by_pairing(test_brake, pair_table, roster, verbose)
        return test_brake_sets, pair_table, dataset_key, reg_path, used_method

    use_ref_this_run = reference_phase_idx is not None and 1 <= reference_phase_idx <= len(test_brake)

    if use_ref_this_run:
        pair_table = _compute_pairing_from_reference_phase(test_brake, reference_phase_idx)
        used_method = "reference"
        if verbose:
            print(f"[build_test_brake_sets] Computed pairing from reference phase {reference_phase_idx} "
                  f"for {dataset_key} and locking registry.")
        _save_reg_file(reg_path, pair_table, file, True, reference_phase_idx)
    else:
        if not isinstance(roster, dict) or "BC" not in roster or "WV" not in roster:
            raise ValueError("Roster must be a dict with keys 'BC' and 'WV' for Roster-based pairing.")
        pair_table = _compute_pairing_from_roster(test_brake, roster)
        used_method = "roster"
        if verbose:
            action = "Overwriting" if reg_path.is_file() else "Creating"
            print(f"[build_test_brake_sets] Roster-based pairing for {dataset_key}. {action} {reg_path}")
        _save_reg_file(reg_path, pair_table, file, False, np.nan)

    test_brake_sets = _flatten_sets_by_pairing(test_brake, pair_table, roster, verbose)
    return test_brake_sets, pair_table, dataset_key, reg_path, used_method
