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
- `python_port/`: Python port of the MATLAB ingestion + feature-extraction pipeline (Stage 1 + Stage 2), independently validated against real MATLAB-produced output — see `python_port/README.md`.
- `backend/` + `frontend/`: the monitoring dashboard (FastAPI + React) described below.
- `sample_data/`: small, anonymized demo dataset (GPS coordinates shifted; every other field is real) so the dashboard runs out of the box — see [Dashboard](#dashboard).
- `data/`: documented data locations. Large raw collections remain preserved at the workspace root; not tracked in this repo (see `data/README.md`).
- `outputs/`: generated figures, models, predictions, reports, and feature exports; not tracked in this repo.
- `archive/`: historical and duplicate implementations, never added by `startup`.
- `docs/`: workflow, dependency, inventory, and restructuring documentation.

See `PROJECT_STRUCTURE.md`, `docs/matlab_pipeline.md`, `docs/python_pipeline.md`, and `docs/unresolved_issues.md` before running the MATLAB/Python pipeline directly.

## Dashboard

A FastAPI + React monitoring dashboard: fleet overview, per-kit event tables, GPS maps (fleet-wide, per-kit route coverage, per-event), a leakage-prediction model page, fault/GPS health diagnostics, and a page to run the ingestion pipeline on new raw data.

`data/` and `outputs/` (where the dashboard normally reads real processed data and trained models from) aren't tracked in this repo — they're large and, in this project's case, real operational telemetry. `sample_data/` ships instead: the real feature CSVs and the real trained model, with only GPS coordinates shifted by one fixed random offset (so the map still shows a realistic-looking, internally consistent route per kit, just not the real one). Every other field — pressures, timings, sensor flags, predictions — is unmodified real data.

### Prerequisites

- Python 3.10+ with `pip`
- Node.js 18+ with `npm`

### Setup

```bash
# from the repo root

# 1) put the sample data where the backend expects it
mkdir -p data/processed outputs/models/finished_thesis
cp sample_data/processed/*.csv data/processed/
cp sample_data/models/finished_thesis/* outputs/models/finished_thesis/

# 2) backend
cd backend
pip install -r requirements.txt
cd ..

# 3) frontend
cd frontend
npm install
cd ..
```

### Run

Two terminals, from the repo root:

```bash
# terminal 1 -- backend, http://localhost:8000
cd backend
python -m uvicorn app.main:app --port 8000

# terminal 2 -- frontend, http://localhost:5173
cd frontend
npm run dev
```

Open `http://localhost:5173`. The frontend's dev server proxies `/api/*` to the backend (see `frontend/vite.config.js`) — no separate configuration needed.

### Using your own data instead

Replace what you copied from `sample_data/` in step 1:

- `data/processed/TestBrakefinal_data_raw_<DatiXX>.csv` — Stage 2 output for each kit (see `python_port/README.md`; the Jobs page in the dashboard itself can run Stage 1+2 against raw telemetry under `data/raw/<DatiXX>/`).
- `outputs/models/finished_thesis/*_inference.joblib` — a trained model bundle, as produced by `python/scripts/train_binary_classifier.py`'s `save_model_artifacts()` (dict with `pipeline` and `features` keys). The dashboard picks whichever bundle has the lowest mean False Alarm Rate against the kits listed in `backend/app/services/wagon_type.py`'s `GENERALIZATION_TEST_KITS` — adjust that mapping to match your own fleet/kit naming.
