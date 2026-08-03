# Restructuring report

## Summary

- Directories created: 34+ target directories (including all requested major hierarchy branches).
- Files moved: 475,969 files, counted as files in relocated target trees minus the 12 support files created there before this report.
- Files renamed: 5.
- Files modified: 10 unique active/support files, excluding newly created documentation.
- Files archived: 1,271 files currently under `archive/`.
- References repaired: 6 path-reference groups.
- Unresolved issues: 10 documented in `docs/unresolved_issues.md`.

## Active entry points

| Workflow | Entry point | Inputs | Outputs |
|---|---|---|---|
| MATLAB setup | `matlab/main/startup.m` | repository layout | MATLAB path configuration |
| MATLAB ingestion | `matlab/ingestion/batchprocess.m` | `data/raw/DatiXX` telemetry | `data/interim` Nodo files |
| MATLAB interactive analysis | `matlab/main/Algorithm_main.m` | labeled `Nodo`/`Nodo_filtered` MAT file | interactive analysis; configured feature output variable |
| MATLAB batch analysis | `matlab/main/Algorithm_main_batch.m` | selected labeled MAT files | `outputs/features/<input>_output.mat` |
| Binary ML training | `python/scripts/train_binary_classifier.py` | reference and feature CSVs | `outputs/models` artifacts |
| Multiclass ML training | `python/scripts/train_multiclass_classifier.py` | reference and feature CSVs | `outputs/models` artifacts |

## Important changes

| File | Change | Reason | Expected behavior impact |
|---|---|---|---|
| `matlab/main/startup.m` | created | controlled active MATLAB path setup | none until explicitly called |
| `config/matlab_paths.m` | created | root-relative central paths | replaces machine-specific paths |
| `matlab/ingestion/batchprocess.m` | path repair | remove mapped drive | output/default directory only |
| `matlab/main/Algorithm_main*.m` | path repair | centralize input/output locations | no algorithm/threshold changes |
| `python/scripts/train_*.py` | path helper integration | remove working-directory dependence | no model behavior changes |
| `python/requirements.txt` | created | dependency manifest | no runtime change |

## Archived implementations

| Archived item | Reason | Active equivalent |
|---|---|---|
| `archive/matlab_legacy/feature_extraction_variants` | earlier filters/thresholds and schemas | modern `matlab/feature_extraction` workflow |
| `archive/matlab_legacy/algorithm_feature_extraction_inner_variants` | 1 Hz and alternate analyses | `Algorithm_main*` provisional selection |
| `archive/matlab_legacy/Main_duplicate` | duplicate project copy | active MATLAB/Python areas |
| `archive/python_experiments` | exploratory and legacy notebooks | `python/scripts` plus retained inference notebooks |
| `archive/backups` | preserved backups/autosaves | none |

## Remaining manual actions

- Verify `Collect_Healthy_SensorData` expectations with representative labeled data.
- Supply `data/external/model.csv` and named processed feature CSVs if absent.
- Run MATLAB and Python workflows only after reviewing dependencies; none were run here.
- Confirm whether the interactive and batch detector divergence is intentional.

## Validation results

| Check | Result | Evidence |
|---|---|---|
| Expected directories exist | PASS | All requested target branches were checked. |
| Core MATLAB direct dependencies exist | PASS | Eight primary detector/pairing/classification functions found in `matlab/feature_extraction`. |
| MATLAB function filename matching | PASS | Active first-function declarations were statically checked. |
| Active Python path imports | PASS | Both training scripts import the project-local helper. |
| Active absolute legacy paths | PASS | No active `D:\`, `Z:\`, `C:\Users\`, `Data Processing`, or `Programmi Matlab` occurrences. |
| Active archive references | PASS | No active MATLAB/Python source references `archive/`. |
| Source placement | PASS | Active source is under `matlab/`, `python/`, or `config/`; historical source is under `archive/`. |
| Parent-path literal scan | WARNING | `rg -F '..\\'` matched MATLAB `\n` escape text as a false positive; no actual `../` references were found. |
| Python/MATLAB execution | NOT RUN | Explicitly prohibited by request. |
