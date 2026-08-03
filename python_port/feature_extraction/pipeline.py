"""Port of matlab/main/Algorithm_main_batch.m's per-file loop body: loads
one Stage 1 Nodo pickle, runs the full Stage 2 chain, and writes both the
full (unfiltered) TestBrake_Sets and the final CSV feature table.

Not a literal line-by-line port of the whole script -- the MATLAB file
also handles interactive `uigetfile` multi-file selection; this is
replaced by a plain function taking an explicit path, matching the
CLI-argument-not-GUI-picker precedent already set in
`ingestion/batch_process.py`.
"""
from __future__ import annotations

import pickle
from pathlib import Path
from typing import Optional, Union

import numpy as np

from .filtering import apply_causal_filters
from .braking_detection import detect_braking_struct_beta
from .pick_reference_phase import pick_reference_phase
from .collect_healthy_sensor_data import collect_healthy_sensor_data
from .build_test_brake_sets import build_test_brake_sets
from .detect_subphases_sets import detect_subphases_sets
from .postprocessing import compute_derived_fields, build_feature_table
from .csv_export import export_feature_csv

# Matches the exact args Algorithm_main_batch.m passes to detect_subphases_sets:
#   'MBPArgs', {'GradStart', -0.05, 'GradRelease', 0.05, 'DistributorIdleThresh', 0.05}
#   'BCArgs',  {'GradStartPos', +0.05, 'GradReleaseNeg', -0.05, 'EndPressure', 0.40}
# Note DistributorIdleThresh=0.05 here OVERRIDES detect_mbp_pipe_subphases's own
# default of 0.005 -- this is the caller's actual configured value, not the
# module default, and must be threaded through explicitly to match.
_DEFAULT_MBP_KWARGS = {"grad_start": -0.05, "grad_release": 0.05, "distributor_idle_thresh": 0.05}
_DEFAULT_BC_KWARGS = {"grad_start_pos": 0.05, "grad_release_neg": -0.05, "end_pressure": 0.40}


def process_nodo_file(
    nodo_path: Union[str, Path],
    *,
    fsamp: float = 40.0,
    mbp_kwargs: Optional[dict] = None,
    bc_kwargs: Optional[dict] = None,
    verbose: bool = True,
    save_full_output: bool = True,
) -> dict:
    """Runs the full Stage 2 chain over one Stage 1 Nodo pickle.

    Returns a dict: 'csv_path' (Path, or None if no phases were detected),
    'dataset_key', 'used_method' (pairing method from build_test_brake_sets),
    'ref_phase', 'n_phases', 'table' (the DataFrame written to CSV).
    """
    nodo_path = Path(nodo_path)
    with open(nodo_path, "rb") as f:
        nodo = pickle.load(f)

    test = []
    for sensor in nodo:
        if len(sensor.get("Time", [])) == 0:
            continue
        filt = apply_causal_filters(np.asarray(sensor["Pressure"], dtype=np.float64), fs=fsamp)
        channel = dict(sensor)
        channel["Pressure_filter"] = filt.pressure_filter
        channel["Pressure_filter_10Hz"] = filt.pressure_filter_10hz
        channel["Gradient_pressure_filtered"] = filt.gradient_pressure_filtered
        test.append(channel)

    test_brake, _bc_idx, _wv_idx = detect_braking_struct_beta(test, verbose=verbose)
    if not test_brake:
        if verbose:
            print(f"[process_nodo_file] No braking phases detected in {nodo_path.name}; nothing to export.")
        return {"csv_path": None, "dataset_key": None, "used_method": None,
                "ref_phase": None, "n_phases": 0, "table": None}

    ref_phase, _scores, _report = pick_reference_phase(test_brake)
    roster = collect_healthy_sensor_data(test_brake)

    test_brake_sets, _pair_table, dataset_key, _reg_path, used_method = build_test_brake_sets(
        test_brake, roster=roster, file=nodo_path, reference_phase_idx=ref_phase, verbose=verbose,
    )

    test_brake_sets = detect_subphases_sets(
        test_brake_sets,
        mbp_kwargs=mbp_kwargs or _DEFAULT_MBP_KWARGS,
        bc_kwargs=bc_kwargs or _DEFAULT_BC_KWARGS,
        verbose=verbose,
    )

    if save_full_output:
        if __package__:
            from ..paths import get_paths
        else:
            from python_port.paths import get_paths
        out_dir = get_paths().features
        out_dir.mkdir(parents=True, exist_ok=True)
        full_out_path = out_dir / f"{nodo_path.stem}_output.pkl"
        with open(full_out_path, "wb") as f:
            pickle.dump(test_brake_sets, f)
        if verbose:
            print(f"[process_nodo_file] Saved full TestBrake_Sets to {full_out_path}")

    test_brake_sets = compute_derived_fields(test_brake_sets)
    table = build_feature_table(test_brake_sets, nodo_path)

    csv_path = export_feature_csv(table, dataset_key)
    if verbose:
        print(f"[process_nodo_file] Exported {len(table)} row(s) to {csv_path}")

    return {
        "csv_path": csv_path, "dataset_key": dataset_key, "used_method": used_method,
        "ref_phase": ref_phase, "n_phases": len(test_brake), "table": table,
    }
