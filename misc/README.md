# Misc

Files moved here on 2026-08-03: confirmed to have zero references from any
other script, notebook, app, or doc in the active tree, and not tied to the
current raw/interim/processed/output data schema. Kept (not deleted) in case
they're still wanted for reference.

| File | Why it's here |
|---|---|
| `matlab/utilities/FileSelect.m` | One-off script hardcoded to a specific past date-range tag (`2025_110514`–`2025_110523`) for copying `.bin` files; not a reusable tool, not called by anything. |
| `matlab/utilities/savetocsv.m` | References an undefined variable (`Test_features`) that doesn't exist anywhere in the current pipeline's naming (`Test`/`TestBrake`/`TBsets_out`/`TestBrakes_table`); stale leftover from an earlier variable-naming scheme. |
| `matlab/visualization/figure_extract.m` | Hardcoded to `.fig` files (`Malfunction H 2_update_new.fig`, `ManualBrakeCompare3.fig`) that don't exist anywhere in this repo. |
| `matlab/visualization/figure_subplot2oneplot.m` | Hardcoded to `EmergencyBraking.fig`, which also doesn't exist anywhere in this repo. |
| `python/notebooks_backup/Initial Data Exploration.rar` | Redundant compressed backup of files already present, extracted, and current alongside it in `python/notebooks/exploration/initial_data_exploration/`. |

## Deliberately left in place

Several other zero-cross-reference files were reviewed and kept, because they
are generic, reusable, standalone tools that operate on the project's actual
data schema (raw `Dati*` folders, `Nodo`/`TestBrake`/`TBsets` structs,
`MovingSummary.mat`, `GPSSummary.mat`) via `uigetdir`/`uigetfile` rather than
hardcoded stale paths — e.g. `matlab/analysis/DataSummary.m`,
`matlab/analysis/pjm_summary.m`, `matlab/analysis/pjm_summaryLoad.m`,
`matlab/analysis/TableCheck.m`, `matlab/ingestion/DatabaseReader*.m`,
`matlab/visualization/fig_edit.m`, `matlab/visualization/PhaseClassification_edit.m`,
and several unwired-but-schema-consistent helper functions (`concat_TBsets.m`,
`groupIsMovingEvents.m`, `runFiltering.m`, `correct_time_spacing.m`,
`save_all_figures.m`, `wavelet_buildup_features.m`,
`Algorithm_BrakingDetection.m`, `plot_PhaseClassification*.m`,
`plot_TBsets_phases_flags.m`). These look like manual/ad hoc research tools a
user could plausibly still run directly, not dead code — worth a second look
by whoever knows the research workflow, but not moved here on suspicion alone.
