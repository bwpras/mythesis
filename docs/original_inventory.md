# Original workspace inventory

Generated before source relocation. This is a source-focused inventory; raw telemetry is represented by directory because enumerating every binary packet would not improve restructuring decisions.

| Original path | Type | Likely role | Active/Historical/Unknown | Dependencies | Proposed destination |
|---|---|---|---|---|---|
| `Dati01/`–`Dati27/` | Raw `.bin` telemetry | PJM and pressure source data | Active data | MATLAB ingestion | `data/raw/DatiXX/` (moved intact during restructuring) |
| `NodoChunks/` | `.mat` data | Derived daily Nodo datasets | Active/interim | MATLAB analysis | `data/interim/NodoChunks/` |
| `DataExtraction/` | `.mat`, CSV, figures | Derived/intermediate datasets and outputs | Mixed | legacy MATLAB workflows | Retain data; move source helpers/figures separately where applicable |
| `Algorithm_FeatureExtraction/Algorithm_FeatureExtraction/` | MATLAB | Provisionally selected modern feature pipeline | Active, provisional | labeled `Nodo`; Signal Processing functions | `matlab/main`, `matlab/feature_extraction`, `matlab/analysis`, `matlab/visualization` |
| `MachineLearningModel/ML model binary/main.py` | Python | Binary leakage-model training | Active | feature CSVs, sklearn, imblearn | `python/scripts/train_binary_classifier.py` |
| `MachineLearningModel/ML model multiclass/main_multi.py` | Python | Multiclass leakage-model training | Active | feature CSVs, sklearn, imblearn | `python/scripts/train_multiclass_classifier.py` |
| `MachineLearningModel/*/*.ipynb` | Python notebooks | inference, exploration, and model experiments | Mixed | feature CSVs/models | `python/notebooks/*` or `archive/python_experiments/` |
| `FeatureExtraction/` | MATLAB | Earlier feature-extraction variants | Historical | older `Nodo_press` schemas | `archive/matlab_legacy/feature_extraction_variants` |
| `Algo/`, `01_Padova Colonia/` | MATLAB/data | Earlier and route-specific experiments | Historical | experimental data | `archive/matlab_legacy/` (source only); route data retained |
| `Backup/`, `BackupCode/`, `Backup.zip`, `BackupCode.zip` | backups | Historical backups | Historical | none | `archive/backups/` |
| `Main/` | MATLAB/Python/data | Duplicate operational copy | Historical duplicate | duplicates root/current source | `archive/matlab_legacy/main_duplicate` and `archive/python_experiments/main_duplicate` |
| root `read*.m`, `DataSummary.m`, `DatabaseReader*.m` | MATLAB | ingestion and reporting utilities | Mixed | raw telemetry, Mapping Toolbox | selected functions to `matlab/ingestion`; remainder archived |
| `MonitoringApp/` | MATLAB App | Wagon monitoring UI | Active support, provisional | MATLAB App Designer | `matlab/apps` |
| root `*.xlsx`, `*.csv`, `*.mat`, `*.fig`, `*.png` | Data/output | summaries, datasets, generated plots | Mixed | various scripts | retain contents; document data/output ownership |
| `San Donato data extraction/` | Dataset | separate reference/training data | Unknown | legacy features | retain in place; document as external data |
| `label_registry/` | data | sensor-label registry | Active support, provisional | labeling workflow | retain in place; document as interim support data |

## Source and dependency observations

- Root and `Main/` contain near-duplicate readers and batch scripts.
- The selected MATLAB workflow requires `Nodo` or `Nodo_filtered` structures with `Label`, `Time`, `Pressure`, and associated telemetry fields.
- `Algorithm_main*.m` invoke `Algorithm_BrakingDetection*`, `pick_reference_phase`, `Collect_Healthy_SensorData`, `build_TestBrake_sets`, and `Algorithm_phaseclassification`.
- Python training scripts rely on working-directory-relative CSV/model paths and need centralized path handling.
- Active and historical code contains hard-coded `D:\Kuliah\001_Thesis\Data Processing`, `Z:\MOSTMerci\Programmi Matlab`, and one unrelated `C:\Users\Utente` path.

## Missing or uncertain references

- `Collect_Healthy_SensorData` is called by the selected pipeline but was not found among the initial source-file inventory.
- The exact producer of `model.csv` and each `TestBrakefinal_data_raw_DatiXX.csv` is not fully documented.
