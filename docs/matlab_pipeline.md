# MATLAB pipeline

## Provisional active implementation

- Interactive entry point: `matlab/main/Algorithm_main.m`
- Batch entry point: `matlab/main/Algorithm_main_batch.m`
- Setup: `matlab/main/startup.m`
- Ingestion entry point: `matlab/ingestion/batchprocess.m`

This selection is based on the most internally complete modern implementation and direct call relationships. It is an assumption, not runtime confirmation.

## Execution order

1. Run `startup` to add active folders only.
2. Use `batchprocess` to create daily `Nodo` data from selected `DatiXX` telemetry.
3. Ensure input structures contain sensor labels and the expected sensor fields.
4. Run the interactive or batch analysis script.

`Algorithm_main.m` uses `Algorithm_BrakingDetection_test`; `Algorithm_main_batch.m` uses `detect_braking_struct_beta`. Both are retained because substituting either would alter behavior.

## Direct feature dependencies

`Collect_Healthy_SensorData` → `build_TestBrake_sets` → `Algorithm_phaseclassification` → `detect_MBP_pipe_subphases` and `detect_BC_cyl_subphases`.

The pipeline also uses `pick_reference_phase` and supporting braking-detection functions.

## Input and output schema

Inputs must contain `Nodo` or `Nodo_filtered`, with labeled MBP, BC, and WV sensor records. Active code assumes fields including `Label`, `Time`, `Pressure`, filtered-pressure fields created in the entry point, and optional telemetry/GPS fields.

The batch output is `TBsets_out` saved as `<input>_output.mat` in `outputs/features/`. It preserves the existing feature fields and output variable name.

## Archived alternatives

One-Hz, earlier feature extraction, route-specific, backup, and experimental workflows were preserved in `archive/matlab_legacy/`.

## Unresolved point

`Collect_Healthy_SensorData.m` is present and now active, but its sensor-roster assumptions need data-backed manual review.
