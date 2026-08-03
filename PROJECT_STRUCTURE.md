# Project structure

```text
.
├── config/             Centralized MATLAB and example JSON paths
├── data/               Documented raw, interim, processed, and external data
├── matlab/             Active MATLAB source only
├── python/             Active Python scripts, package helpers, notebooks
├── outputs/            Feature exports, models, figures, reports, predictions, logs
├── docs/               Technical documentation and reports
└── archive/            Historical code and backups
```

Place new public MATLAB functions in the appropriate `matlab/` category without renaming existing public functions. Call `startup` before using them.

Place reusable Python modules in `python/src/braking_ml/`; keep runnable commands in `python/scripts/`. Notebooks belong in `exploration`, `experiments`, or `inference`.

Raw telemetry is immutable. Derived MATLAB structures belong in `data/interim`, feature tables in `data/processed` or `outputs/features`, and generated results in `outputs/`.
