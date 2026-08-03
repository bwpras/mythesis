# Railway Braking Analysis

This workspace ingests railway pressure/PJM telemetry in MATLAB, derives MBP/BC/WV braking features, and trains or applies Python leakage classifiers.

## Status

The selected active MATLAB workflow is provisionally `matlab/main/Algorithm_main.m` and `matlab/main/Algorithm_main_batch.m`. It is internally complete but has not been executed after restructuring. Historical variants are preserved under `archive/`.

## Workflows

1. In MATLAB, run `startup` from `matlab/main`.
2. Run `batchprocess` to decode selected raw telemetry into `Nodo` MATLAB structures.
3. Run `Algorithm_main_batch` (or `Algorithm_main`) on labeled `Nodo`/`Nodo_filtered` data.
4. Supply the resulting feature CSVs to the Python training scripts.
5. Run `python/scripts/train_binary_classifier.py` or `python/scripts/train_multiclass_classifier.py`.

The MATLAB-to-Python handoff is feature CSV data, including fields such as `Total_power_efficiency`, `Std_delay_exp`, and `WV_MeanPressure`. Expected Python inputs are described in `data/README.md`.

## Layout

- `matlab/`: selected active MATLAB ingestion, feature extraction, analysis, visualization, and apps.
- `python/`: active training scripts, package helpers, and organized notebooks.
- `data/`: documented data locations. Large raw collections remain preserved at the workspace root.
- `outputs/`: generated figures, models, predictions, reports, and feature exports.
- `archive/`: historical and duplicate implementations, never added by `startup`.
- `docs/`: workflow, dependency, inventory, and restructuring documentation.

See `PROJECT_STRUCTURE.md`, `docs/matlab_pipeline.md`, `docs/python_pipeline.md`, and `docs/unresolved_issues.md` before running a workflow.
