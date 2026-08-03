# Changelog

## Restructuring session

### Created
- `CHANGELOG.md`: live chronological record for the in-place restructuring.
- `docs/`: documentation directory required for the original inventory.
- `config/`, `data/`, `matlab/`, `python/`, `outputs/`, and `archive/` hierarchies: target maintainable project layout.
- `config/matlab_paths.m`, `matlab/main/startup.m`, configuration examples, and Python path helper: centralized, repository-relative path management.
- Root and workflow documentation, dependency documentation, data documentation, archive documentation, and `.gitignore`: maintainability and reproducibility support.
- `python/requirements.txt`: import-derived dependency manifest without invented versions.
- `README.md`, `PROJECT_STRUCTURE.md`, `docs/matlab_pipeline.md`, `docs/python_pipeline.md`, `docs/data_flow.md`, `docs/dependencies.md`, `docs/unresolved_issues.md`, and `docs/restructuring_report.md`: project operation and restructuring documentation.

### Moved
- `Algorithm_FeatureExtraction/Algorithm_FeatureExtraction/Algorithm_main.m` → `matlab/main/Algorithm_main.m`: selected interactive MATLAB entry point.
- `Algorithm_FeatureExtraction/Algorithm_FeatureExtraction/Algorithm_main_batch.m` → `matlab/main/Algorithm_main_batch.m`: selected batch MATLAB entry point.
- Core braking, pairing, and phase-classification functions → `matlab/feature_extraction/`: selected modern feature pipeline.
- Core aggregation helpers → `matlab/analysis/`: active post-processing and master-table support.
- Current plot and figure helpers → `matlab/visualization/`: active diagnostics.
- `batchprocess.m`, `loadNodoData.m`, PJM readers, and database readers → `matlab/ingestion/`: selected ingestion workflow.
- Selected filtering, labeling, timing, and general helpers → `matlab/preprocessing/` and `matlab/utilities/`.
- `MonitoringApp` source files → `matlab/apps/`: active application support.
- Binary/multiclass Python training scripts → `python/scripts/`: active runnable ML scripts.
- Active inference notebooks → `python/notebooks/inference/`; exploration and experiment notebooks → their corresponding notebook folders.
- Historical model artifacts → `outputs/models/`; legacy test data → `data/processed/legacy_test_data/`.
- Root MATLAB intermediate files → `data/interim/`; root CSV inputs → `data/external/`; root figures and reports → `outputs/figures/` and `outputs/reports/`.
- `Database/` supporting data → `data/external/database_reference/` after its notebook was moved.
- `Dati01/`–`Dati27/` → `data/raw/`: raw telemetry collections relocated intact within the workspace.
- `NodoChunks/` → `data/interim/NodoChunks/`; `NodoChunks_backup/` → `archive/backups/NodoChunks_backup/`.
- `DataExtraction/` → `data/processed/DataExtraction_legacy/`; Padova-Colonia and San Donato datasets → `data/external/`.
- `label_registry/` → `data/interim/label_registry/`: sensor-label support data.
- residual `Algorithm_FeatureExtraction/` artifacts → `archive/matlab_legacy/Algorithm_FeatureExtraction_artifacts/`: historical generated material associated with archived source.
- `MonitoringApp/MovingSummary.mat` → `data/interim/MonitoringApp_MovingSummary.mat`; the remaining empty app-support folder → `archive/backups/MonitoringApp_empty/`.

### Renamed
- `MachineLearningModel/ML model binary/main.py` → `python/scripts/train_binary_classifier.py`: clarify active purpose.
- `MachineLearningModel/ML model multiclass/main_multi.py` → `python/scripts/train_multiclass_classifier.py`: clarify active purpose.
- `MachineLearningModel/ML model multiclass/test_main_multi.ipynb` → `python/notebooks/inference/test_main_multiclass.ipynb`: clarify purpose.
- `DataSummary.ipynb` → `python/notebooks/exploration/data_summary.ipynb`: classify notebook.

### Modified
- `matlab/ingestion/batchprocess.m`
  - Replaced mapped-drive output and `pwd` default with centralized paths.
  - Behavior is expected to remain unchanged apart from output/default selection location.
- `matlab/main/Algorithm_main.m`
  - Added `startup`, configured file-selection default, and centralized the existing feature-output variable.
  - Scientific logic, thresholds, and output schema are unchanged.
- `matlab/main/Algorithm_main_batch.m`
  - Replaced the mapped-drive/fallback output logic with `outputs/features` through centralized paths.
  - Detector selection, thresholds, and saved `TBsets_out` schema are unchanged.
- `matlab/apps/WagonDatabase.m`
  - Replaced a machine-specific workspace path with centralized paths.
  - Data-processing logic is unchanged.
- `python/scripts/train_binary_classifier.py` and `python/scripts/train_multiclass_classifier.py`
  - Added repository-root path resolution and redirected input/output locations to `data/` and `outputs/models/`.
  - Training algorithms, features, labels, hyperparameters, and artifact metadata are unchanged.
- `docs/original_inventory.md`
  - Updated proposed locations after the authorized intact relocation of raw and interim data.
  - The original-path information remains unchanged.

### Archived
- `FeatureExtraction/` → `archive/matlab_legacy/feature_extraction_variants/`: earlier MATLAB pipeline variants.
- `Algo/` → `archive/matlab_legacy/algo_versions/`: superseded algorithm versions.
- `Main/` → `archive/matlab_legacy/Main_duplicate/`: duplicate MATLAB/Python/data copy.
- `Backup/`, `BackupCode/`, root backup ZIPs and autosaves → `archive/backups/`: historical backups.
- Residual historical `Algorithm_FeatureExtraction` source and its experiment backup → `archive/matlab_legacy/`: unselected implementations.
- Root legacy MATLAB readers and root Python dummy files → `archive/matlab_legacy/root_legacy/` and `archive/python_experiments/root_misc/`: not selected for the active workflow.
- Remaining `MachineLearningModel/` material → `archive/python_experiments/MachineLearningModel_residual/`: unknown/historical experiments and duplicate model material.
- `01_Padova Colonia/Algorithm_update_version.m` → `archive/matlab_legacy/padova_colonia_algorithm_update_version.m`: route-specific historical algorithm.

### References repaired
- `matlab/ingestion/batchprocess.m`
  - `Z:\MOSTMerci\Programmi Matlab\DataExtraction` → `paths.interim`.
- `matlab/main/Algorithm_main_batch.m`
  - `Z:\MOSTMerci\Programmi Matlab\Algorithm_New\Data\DataOutput\DataOutput` → `paths.features`.
- Active Python training scripts
  - working-directory `model.csv`, operational CSVs, and `saved_models` → repository-relative `data/` and `outputs/models/` locations.
- `matlab/apps/WagonDatabase.m`
  - `D:\Kuliah\001_Thesis\Data Processing` → configured project root and report directory.
- Active comments/examples containing old machine paths were replaced with repository-relative examples.

### Excluded or untouched
- Raw telemetry contents were not modified; their parent directories were relocated intact to `data/raw/`.

### Assumptions
- The modern MATLAB pipeline is provisionally the internally complete workflow in `Algorithm_FeatureExtraction/Algorithm_FeatureExtraction/`, pending dependency validation.
- `Algorithm_main.m` and `Algorithm_main_batch.m` are the active entry points. The batch script retains `detect_braking_struct_beta`; the interactive script retains `Algorithm_BrakingDetection_test`, because changing either would alter behavior.

### Unresolved issues
- The active implementation/source of `Collect_Healthy_SensorData` has not yet been confirmed.
- The active implementation is now located, but its data-dependent sensor-roster behavior remains unvalidated.
- Required active Python input files (`model.csv` and named operational feature CSVs) were not found.
- Static validation is recorded in `docs/restructuring_report.md`; MATLAB and Python execution remain intentionally unperformed.
