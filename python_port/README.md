# Python port of the MATLAB pipeline

A parallel Python implementation of the active MATLAB pipeline (`matlab/ingestion/`,
and eventually `matlab/feature_extraction/`). Kept in its own top-level folder,
separate from `python/` (the active, vetted training package), because this
is an unverified port: there is no MATLAB available in this environment to
cross-check numerical output against, so treat it as "believed correct by
line-by-line translation and synthetic-data smoke tests," not "validated
against real hardware data."

## Status

- **Stage 1 (ingestion) — done.** `.bin` -> Nodo-equivalent structures, ported
  and smoke-tested against synthetic packets (see "Validation" below).
- **Stage 2 (feature extraction) — done, end to end.**
  `Nodo` -> `TestBrake` segmentation, pairing, both subphase detectors,
  post-processing, and CSV export are all ported and wired together —
  `feature_extraction/pipeline.py`'s `process_nodo_file()` takes a Stage 1
  `Nodo` pickle and produces `data/processed/TestBrakefinal_data_raw_<DatiXX>.csv`,
  ready for `python/scripts/train_binary_classifier.py` /
  `train_multiclass_classifier.py` to consume directly.
  - `filtering.py` — the causal filtering block from `Algorithm_main_batch.m`.
  - `braking_detection.py` — port of `detect_braking_struct_beta.m`
    (`Nodo` -> `TestBrake` per-braking-event segmentation; everything else
    in Stage 2 consumes its output).
  - `pick_reference_phase.py` / `collect_healthy_sensor_data.py` — ports
    of `pick_reference_phase.m` / `Collect_Healthy_SensorData.m`, both
    pure query functions over `TestBrake`.
  - `build_test_brake_sets.py` — port of `build_TestBrake_sets.m`: BC/WV
    pairing (by reference phase or Roster) plus per-pair `TestBrake_Sets`
    flattening.
  - `mbp_pipe_subphases.py` / `bc_cyl_subphases.py` — ports of
    `detect_MBP_pipe_subphases.m` / `detect_BC_cyl_subphases.m`, the two
    per-pair-set buildup/holding/release subphase detectors, including
    BC's "First phase" initial-buildup curve-shape analysis.
  - `detect_subphases_sets.py` — port of the archived
    `detect_subphases_sets.m` orchestration wrapper (called by the active
    `Algorithm_main_batch.m` but not present in the active `matlab/` tree
    — see `docs/unresolved_issues.md`); runs both subphase detectors per
    pair with per-detector failure isolation.
  - `postprocessing.py` — port of `Algorithm_main_batch.m`'s
    post-processing block: error flags, power/energy efficiency ratios,
    power/pressure delays, the 109-field `KEEP_FIELDS` whitelist
    (cross-checked programmatically against the literal MATLAB source —
    exact match, same fields, same order), and flat feature-table
    construction.
  - `csv_export.py` — **closes a real gap**: MATLAB's own CSV-writing
    call (`update_brake_master.m` with `WriteCSV`) is commented out in
    the active source, so the currently-active MATLAB pipeline computes
    the feature table and then discards it. This module is new
    functionality (not a line-by-line port — there's no active MATLAB
    code computing this), writing directly to the path/filename
    `python/scripts/train_binary_classifier.py` already expects, with
    merge-and-deduplicate-by-composite-key across runs (a whole `DatiXX`
    kit spans many daily `Nodo` files). See that module's docstring for
    the full reasoning.
  - `pipeline.py` — top-level orchestrator tying the whole chain together
    for one `Nodo` pickle, mirroring `Algorithm_main_batch.m`'s per-file
    loop body.

## Layout

```
python_port/
  paths.py                        # self-locating repo paths (mirrors config/matlab_paths.m)
  ingestion/
    packet_io.py                  # fread()-equivalent binary readers
    read_pjm_file.py              # port of matlab/ingestion/read_pjm_file39.m
    identify_brake_sensors.py     # port of matlab/preprocessing/identify_brake_sensors.m
    load_nodo_data.py             # port of matlab/ingestion/loadNodoData.m
    mat_table_reader.py           # reads MATLAB's label_registry *.mat table cache (no MATLAB needed)
    batch_process.py              # port of matlab/ingestion/batchprocess.m (CLI)
  feature_extraction/
    filtering.py                  # port of Algorithm_main_batch.m's causal filtering block
    braking_detection.py          # port of matlab/feature_extraction/detect_braking_struct_beta.m
    pick_reference_phase.py       # port of matlab/feature_extraction/pick_reference_phase.m
    collect_healthy_sensor_data.py  # port of matlab/feature_extraction/Collect_Healthy_SensorData.m
    build_test_brake_sets.py      # port of matlab/feature_extraction/build_TestBrake_sets.m
    mbp_pipe_subphases.py         # port of matlab/feature_extraction/detect_MBP_pipe_subphases.m
    bc_cyl_subphases.py           # port of matlab/feature_extraction/detect_BC_cyl_subphases.m
    detect_subphases_sets.py      # port of archive/.../detect_subphases_sets.m (orchestration wrapper)
    postprocessing.py             # port of Algorithm_main_batch.m's post-processing block + KEEP_FIELDS
    csv_export.py                 # NEW: closes the CSV-export gap (MATLAB's call is commented out)
    pipeline.py                   # top-level orchestrator: Nodo pickle -> TestBrakefinal_data_raw_*.csv
```

## Usage

```bash
pip install -r python_port/requirements.txt

python -m python_port.ingestion.batch_process data/raw/Dati10 \
    --fsamp 40 \
    --start-date 2026-01-01 --end-date 2026-02-18 \
    --workers 4
```

This writes `data/interim/python_port/Dati10/Nodo_Dati10_yyyyMMdd_yyyyMMdd.pkl`
(one per day found), each a pickled `list[dict]` — the Python equivalent of
MATLAB's `Nodo` struct array. Each dict has the same fields as the MATLAB
`Nodo` struct (`ID`, `Time`, `Pressure`, `Label`, GPS fields, etc.); array
fields are numpy arrays (`Time`/`Start_time`/`Time_GPS` as `datetime64[us]`,
`Pressure` as `float64`).

**Why `data/interim/python_port/...` and not `data/interim/Dati10/...`
directly:** `matlab/ingestion/batchprocess.m`, if run today, writes to
exactly `data/interim/<DatiXX>/Nodo_<DatiXX>_yyyyMMdd_yyyyMMdd.mat` — same
folder-naming convention this port uses, differing only in extension. Rather
than have this port's `.pkl` files sit in the same folder MATLAB would use
(differentiated only by a file extension a casual glance would miss), its
output is nested one level deeper, under its own `python_port/` subfolder,
so the two are never in the same directory.

Note this is *not* the same location as the pre-existing
`data/interim/NodoChunks/*.mat` files already in this repo — those use a
different naming scheme (`DatiXX_yyyyMMdd_HHMM_to_yyyyMMdd_HHMM.mat`) that no
script currently in `matlab/` or `archive/` produces. They appear to be
output from an older/external version of the ingestion code that predates
this repo's restructuring (consistent with `docs/unresolved_issues.md`
already flagging sensor-label/provenance inconsistency in this area). Neither
current MATLAB nor this port will write there or read from there.

To call the ingestion function directly instead of the CLI:

```python
import numpy as np
from python_port.ingestion.load_nodo_data import load_nodo_data

nodo = load_nodo_data(
    np.datetime64("2026-01-15T00:00:00"),
    np.datetime64("2026-01-16T00:00:00"),
    fsamp=40,
    root_dir="data/raw/Dati10",
)
```

### Stage 2: `Nodo` pickle -> feature CSV

```python
from python_port.feature_extraction.pipeline import process_nodo_file

result = process_nodo_file("data/interim/python_port/Dati10/Nodo_Dati10_20260115_20260116.pkl")
print(result["csv_path"])   # data/processed/TestBrakefinal_data_raw_Dati10.csv
print(result["n_phases"])   # braking phases detected in this one day's file
print(result["table"])      # the DataFrame that was written/merged
```

Each call merges its rows into the *same* per-`DatiXX` CSV (deduplicating
by sensor IDs + start/end time, new rows winning on a collision) — since
one `Nodo` pickle only covers one day, and a full `DatiXX` kit's dataset
spans many days, this needs to be called once per day-file to build up the
complete `data/processed/TestBrakefinal_data_raw_<DatiXX>.csv` that
`python/scripts/train_binary_classifier.py` / `train_multiclass_classifier.py`
read directly.

## Fidelity notes and deliberate deviations

This was ported for **line-by-line numerical fidelity** to the MATLAB source
(same packet field order, same calibration formula, same steady-window
sensor-classification thresholds, same causal/zero-phase filter design),
not idiomatic restructuring. A few things necessarily differ:

- **No GUI pickers.** `uigetdir`/`uigetfile` are replaced by required CLI
  arguments / function parameters.
- **Output format.** MATLAB saves `.mat` (v7.3) files; this port pickles a
  `list[dict]`. Neither format is readable by the other tool without a
  conversion step.
- **Sensor-label cache format.** `loadNodoData.m` caches classified sensor
  roles to `data/interim/label_registry/<DatiXX>_labels.mat` (a MATLAB
  table, project-root relative, independent of which `rootDir` was scanned).
  This port caches its own classifications to the *same directory* but as
  `<DatiXX>_labels.csv`. (Both sides used to compute this directory as
  `<parent of rootDir>/label_registry`, e.g. `data/raw/label_registry`,
  silently ignoring the pre-existing `data/interim/label_registry` cache and
  re-classifying sensors on every run from a new folder; that path bug is
  fixed — see `docs/unresolved_issues.md`.)
  **Format interop is one-directional.** `load_nodo_data.py` prefers its
  own `.csv` cache, but if none exists yet it reads MATLAB's `.mat` table
  directly — no MATLAB installation needed — via
  `python_port/ingestion/mat_table_reader.py`, which decodes MATLAB's
  opaque MCOS `table`/`string` object encoding for this one fixed 3-column
  schema (reverse-engineered against, and tested against, all 14 real
  registry files in this repo; see that module's docstring for how). So a
  `DatiXX` already classified by MATLAB is reused here instead of being
  re-classified from scratch. The reverse direction is still closed: MATLAB
  cannot read this port's `.csv` cache (would require changing
  `loadNodoData.m`'s `ReadLabel()`).
- **`batchprocess.m`'s hardcoded date window is a CLI flag here.** The
  MATLAB script had a baked-in `tMin`/`tMax` filter at the time of the last
  review (see the main conversation / `docs/matlab_pipeline.md`). This port
  exposes it as optional `--start-date`/`--end-date` instead of requiring a
  code edit.
- **`parfor` -> optional `ProcessPoolExecutor`.** Serial by default
  (`--workers 1`); pass `--workers N` to parallelize across days.
- **Debug-only counters kept, with the same quirk.** `cont_pkt` /
  `MSG_WAKE` counts are reset per-file and overwrite the previous file's
  count per sensor key (matching `loadNodoData.m`'s `nodo_cont_pkt(key) = cont_pkt`
  inside the per-file loop) — neither is read again downstream in the
  MATLAB source, so this is preserved as-is rather than "fixed."

### Stage 2 (`feature_extraction/`) specifics

- **Bug fix, documented.** `detect_braking_struct_beta.m`'s GPS-commit
  fallback (used when no BC end time resolves for a phase) references an
  undefined MATLAB variable `MBP.time(phaseEndIdx)` — no `MBP` struct
  exists in that file; this would throw in real MATLAB if that branch were
  ever hit. `braking_detection.py` uses the clearly-intended
  `mbp_time[phase_end_idx]` instead (see the fix inline, in the GPS commit
  section, and the module docstring).
- **Dead-code simplification, documented.** MATLAB's `SystemStopped`
  long-stop guard (phase stuck in `inBraking` for >=1800s) discards the
  phase and `continue`s *before* the end-condition check that also
  references `SystemStopped` runs in the same iteration — making that
  disjunct unreachable in the source. This port implements the guard's
  actual effect (force-discard after 1800s) without replicating the
  unreachable disjunct.
- **Datetime-only.** MATLAB branches on `isdatetime(Time)` vs numeric time
  throughout; Stage 1's own `load_nodo_data.py` output is always
  `datetime64[us]`, so this port drops the numeric-time branch entirely.
- **`unique(x,'stable')`** (MATLAB, first-occurrence order preserved) has
  no numpy one-liner; ported as `_unique_stable()` in `braking_detection.py`
  via an argsort-of-first-occurrence-index trick.
- Everything else — all named thresholds (`MBP_Lower`, `GradStart`-style
  gradient cutoffs, control-window timings, BC anomaly-detection windows,
  etc.), the BC streaming-cursor design, the post-20s/60s async telemetry
  capture, and the "flag data-quality issues, don't raise" philosophy —
  is ported for line-by-line fidelity, matching Stage 1's approach.

`pick_reference_phase.py` and `collect_healthy_sensor_data.py` specifics:

- **Bug fix, documented — and a correction to an earlier wrong diagnosis
  of the same bug.** `pick_reference_phase.m` checks an *optional* struct
  field named `'BrakingAct'` for BC eligibility, which is never actually
  set anywhere in this codebase (confirmed: every sibling file uses
  `NormalBraking` for this exact concept, and `Collect_Healthy_SensorData.m`'s
  own docstring still says `"BrakingAct==1"` while its real code already
  reads `.NormalBraking` — a stale rename, not intentional). Because
  `count_valid_streams()`'s optional-field check defaults to "pass" when
  absent, the actual effect is that the `NormalBraking` condition is
  silently never enforced (a *weaker* filter than documented) — **not**
  "BC validity always fails," which was an earlier, incorrect read of this
  bug (since corrected in `docs/unresolved_issues.md`). This port maps the
  optional-field name to `'NormalBraking'`, restoring the documented
  behavior.
- **1-indexed `refPhase`, `FromPhaseIdx`, `IndexInPhase`, `WindowPhaseIdx`.**
  These are kept 1-indexed (matching each phase's own `PhaseIdx` field and
  MATLAB's 1-based indexing) rather than converted to 0-indexed, since
  `build_test_brake_sets.py` consumes `refPhase` the same way MATLAB does
  (`TestBrake(refPhaseIdx)`), and keeping the convention consistent avoids
  an off-by-one class of bug at that integration point.
- `Collect_Healthy_SensorData.m`'s unguarded `TestBrake(1).MBP_ID` (would
  raise an index error on an empty `TestBrake` in MATLAB) raises a clearer
  `ValueError` here instead — same "fail loudly," clearer message.

`build_test_brake_sets.py` specifics:

- **Registry file location, deliberately changed (not a silent
  replication).** MATLAB saves `<DatiXX>_reg.mat` to `pwd` — the process's
  current working directory *at call time* — an order-/launch-dependent
  location, not a repo-relative one. This port uses the deterministic
  `data/interim/pairing_registry/<DatiXX>_reg.csv`, following the same
  precedent already set for the sensor-label registry
  (`data/interim/label_registry/`). This is a brand-new artifact with no
  pre-existing real `.mat` files to interoperate with (unlike the label
  registry), so CSV via pandas is used throughout — no MCOS decoding
  needed here.
- **Test isolation applied from the start.** Writing test fixtures against
  this registry risked the exact same real-`data/interim/`-pollution
  mistake made (and then fixed) during the label-registry work — this
  time the `get_paths()`-patching isolation was written into the tests
  before they were ever run, not retrofitted after.
- **The `flattenSetsByPairing` "template struct" indirection is dropped.**
  MATLAB seeds a template struct from phase 1's MBP fields (for
  `repmat`-based struct-array homogeneity, a MATLAB-specific constraint)
  and layers `Roster.MBP_ID` onto it — a value that's then unconditionally
  overwritten by each phase's own real `MBP_ID` field in the per-phase
  copy loop that follows, making the `Roster.MBP_ID` step dead code for
  any non-empty `TestBrake` (guaranteed by this function's own top-level
  guard). Python dicts don't share MATLAB's homogeneous-field constraint,
  so this port merges each phase's own fields directly instead — same
  output, without the indirection. See the module docstring for the full
  reasoning.

`mbp_pipe_subphases.py` and `bc_cyl_subphases.py` specifics (the two
largest, most intricate files in Stage 2 — full source was read end to
end, twice, before writing any code, given how much precision this level
of state-machine logic demands):

- **Bug fix, documented.** In `detect_MBP_pipe_subphases.m`, `flatCount`
  and `SteadyRelease` are declared once at function scope, *outside* the
  per-phase loop, and never explicitly reset at the top of each phase's
  processing — only via specific in-state-machine transitions.
  `flatCount`'s cross-phase carry-over is provably inert (always reset
  before ever being read again). `SteadyRelease`'s is not: it's read on
  the *same* iteration it's updated, including a new phase's very first
  buildup/braking sample — so a counter left just under threshold at the
  end of one phase (e.g. one whose data ends mid-buildup, never reaching
  'releasing') can combine with the next phase's first qualifying sample
  to trigger an immediate, spurious transition one sample into that new
  phase. Nothing in the source suggests this cross-phase memory is
  intentional. This port resets both counters at the start of each phase.
- **Dead code dropped.** `detect_MBP_pipe_subphases.m`'s in-loop energy
  accumulation (`t_seg`/`p_seg`/`segment_start_idx`, and the running
  `brake_energy_pipe`-style accumulators) is entirely commented out in the
  source — all energy there is actually computed once, post-loop, via
  `trapz` on the final concatenated arrays. This port only implements the
  live, post-loop path; the MATLAB-side dead code is described, not
  ported. (`detect_BC_cyl_subphases.m` is different: its equivalent
  in-loop `trapz` accumulation *is* live there, and is ported as such.)
- **Naming, preserved exactly (not "fixed").** In `detect_BC_cyl_subphases.m`,
  `First_phase_*` fields *without* a `_1hz` suffix are built from
  `BC_Pressure10hz`; fields *with* the suffix are built from native-rate
  `BC_Pressure`. Backwards from what the names suggest, but consistent
  throughout the source, so preserved rather than silently swapped.
- **Field presence intentionally differs by code path, matching the
  source exactly** in three separate places: (1) each detector's
  guard path (missing/empty `MBP_Time`/`MBP_Pressure` or
  `BC_Time`/`BC_Pressure`) sets a smaller, specific field list, not
  every field the normal path can produce — e.g. `detect_mbp_pipe_subphases`'s
  guard path never sets `Speed_*`/`Gateway_*_Error`; (2) BC's
  `Non_Standard_Braking` release-extraction fallback has an edge case
  (pressure peak is the last sample) where the source's early MATLAB
  `continue` skips the entire summary-stats block
  (`Total_timing_cyl`/`DS_Error`/`BrakeMode`/`Max_pressure_cyl`/`Mean_cyl`/
  `Std_cyl`/`Consecutive_braking_cyl`) for that one phase — this port
  returns a `gave_up` flag from `_handle_non_standard_release()` and the
  caller `continue`s the same way, leaving those keys genuinely absent
  rather than defaulted; (3) `MBP_Mask_BuildupPipe`/`HoldingPipe`/
  `ReleasePipe` (guard-path-only in the source, confirmed dead/legacy —
  never read anywhere in this codebase, never set on the normal path
  either) are omitted entirely rather than ported as inert output.
- `UseProvidedGradient` (both files) and `TailTrimPressure` (BC only) —
  `inputParser` defaults that are declared but never read anywhere in
  either source file's body — are not exposed as parameters here.

`detect_subphases_sets.py`, `postprocessing.py`, and `csv_export.py`
specifics:

- **Fidelity fix for Python's mutation model.** `detect_mbp_pipe_subphases`/
  `detect_bc_cyl_subphases` mutate each phase dict in place, but MATLAB is
  pass-by-value: if a detector call errors partway through, the source's
  "keep S unchanged" comment means the caller's variable is genuinely
  untouched, not partially mutated. A naive Python port sharing the same
  dicts across the try/except would leave partial mutations visible after
  a mid-call exception — a real behavioral difference. This port passes
  each detector a fresh shallow copy of the phase-dict list and only
  commits the result back on success, restoring MATLAB's true
  all-or-nothing semantics (see the module docstring, and
  `test_detect_subphases_sets_isolates_mbp_failure_without_partial_mutation`
  in the test suite).
- **`KEEP_FIELDS` cross-checked programmatically, not just transcribed by
  hand.** A one-off script diffed this port's list against a regex parse
  of the literal `keepFields = {...}` cell array in
  `Algorithm_main_batch.m`: 109 fields, exact match, exact order, zero
  discrepancy either direction.
- **The CSV export itself is new functionality, not a port** — see
  `csv_export.py`'s module docstring for the full reasoning (MATLAB's own
  `update_brake_master.m` call is commented out in the active source, and
  even enabled, its output naming wouldn't match what
  `train_binary_classifier.py`/`train_multiclass_classifier.py` actually
  read). It borrows `update_brake_master.m`'s useful core idea
  (merge-and-deduplicate by composite key, preferring new rows) but writes
  directly to `data/processed/TestBrakefinal_data_raw_<DatiXX>.csv` (the
  path/name the training scripts already expect) instead of a
  CWD-relative `.mat` master file, and — unlike the label/pairing registry
  caches — treats a write failure as fatal (raises) rather than
  best-effort, since this CSV is Stage 2's terminal output, not a
  regenerable cache.

## Validation

There is no real hardware `.bin`/`.pjm` sample data in this repo and no
MATLAB installation in this environment, so validation happens in two tiers.

### Tier 1 — synthetic self-test (run this now, no data or MATLAB needed)

```bash
pip install -r python_port/requirements.txt
python python_port/tests/test_ingestion_smoke.py
```

(Also runs under `pytest python_port/tests` if you have it installed.)

This builds synthetic `.bin` files matching the exact byte layout documented
in `loadNodoData.m` — both the 40 Hz ("HP") and 1.62181 Hz ("LP") packet
layouts — and checks:

- Pressure calibration recovery (`pCal` formula round-trips a known bar value).
- `MSG_WAKE` packets are skipped without corrupting byte alignment.
- LP-layout NaT-padding removal (70 padded samples/packet dropped, exactly
  10 real samples/packet survive).
- Steady-window MBP/BC/WV classification on synthetic sensors at
  ~5 bar / ~0.05 bar / ~2.5 bar.
- Label-cache reuse on a second run against the same folder.
- End-to-end `batch_process`: day discovery, `Nodo_*.pkl` output, pickle
  round-trip, and skip-if-exists on a repeat run.

This confirms internal control-flow and byte-layout correctness. It
**cannot** confirm numerical agreement with real MATLAB output — there is no
reference file or running MATLAB here to compare against. That's Tier 2.

### Tier 2 — cross-check against real MATLAB output (needs your MATLAB + one real `DatiXX`)

1. In MATLAB, produce (or reuse) one day's `Nodo_*.mat` the normal way
   (`startup` → `batchprocess`), then export a comparison summary:

   ```matlab
   addpath('python_port/tools')
   export_nodo_summary('data/interim/Dati10/Nodo_Dati10_20260115_20260116.mat', ...
                        'python_port/tools/matlab_summary.csv')
   ```

2. Run the Python port over the **same** folder and **same** day, then export
   the matching summary:

   ```bash
   python -m python_port.ingestion.batch_process data/raw/Dati10 --fsamp 40 \
       --start-date 2026-01-15 --end-date 2026-01-16 \
       --out-dir python_port/tools/_tmp_interim

   python -m python_port.tools.export_nodo_summary \
       python_port/tools/_tmp_interim/Dati10/Nodo_Dati10_20260115_20260116.pkl \
       python_port/tools/python_summary.csv
   ```

3. Diff them:

   ```bash
   python -m python_port.tools.compare_summaries \
       python_port/tools/matlab_summary.csv python_port/tools/python_summary.csv
   ```

   Exits 0 and prints `RESULT: PASS` if every sensor's ID, Label,
   NumSamples, first/last timestamp (within 0.05 s), and pressure
   mean/std/min/max (within 0.02 bar) match; otherwise prints exactly which
   sensor and which field diverged, and exits 1.

The comparison tolerances are loose on purpose (packet-boundary timing,
floating-point rounding) — a real bug should show up as either a wrong
`Label`, a wrong `NumSamples`, or a pressure delta far larger than 0.02 bar,
not a borderline near-tolerance value. `export_nodo_summary.m`,
`export_nodo_summary.py`, and `compare_summaries.py` were designed and
tested together on the Python side (see the tooling self-test embedded in
development); the `.m` half could not be executed here, so treat its first
real run as itself a small test of that script, not just of the port.

### Stage 2 validation (`feature_extraction/`)

```bash
python python_port/tests/test_feature_extraction_smoke.py
```

- `filtering.py` is checked against an independently-written reference
  recursion (a direct transcription of `Algorithm_main_batch.m`'s explicit
  circular-buffer loop, not a copy of `filtering.py`'s own cumsum-based
  implementation) — catches vectorization mistakes that a self-consistency
  check against the same code couldn't.
- `braking_detection.py` is checked against a synthetic MBP+BC+WV `Test`
  with a hand-designed, filter-calibrated braking event: exactly one phase
  detected with sane `InitPressure`/BC/WV commit fields, a sub-`Min_P_drop`
  dip correctly rejected, a spurious flat-plateau onset correctly discarded
  by the control-window guard, and a missing-MBP-channel input correctly
  raising.
- Also run manually (not part of the automated suite, since it needs a
  real `Nodo` pickle from Stage 1) against real hardware data
  (`data/raw/Dati01`, 2025-07-20): 44 phases detected across ~951k MBP
  samples, with physically plausible pressure drops (0.7-4.9 bar) and
  correct `SV_Error` gating (phases with `InitPressure > MBP_Upper` (5.2
  bar) correctly skip BC/WV data collection). Confirms the port runs
  end-to-end on real data without crashing and produces plausible output —
  not numeric agreement with real MATLAB, which remains unverified (no
  MATLAB installation in this environment, same caveat as Stage 1).
- `pick_reference_phase.py` / `collect_healthy_sensor_data.py`: checked
  against hand-built `TestBrake` fixtures (precise, since these two are
  pure query functions with no signal processing) covering clean-phase
  selection, error-flag score penalty, ineligibility, no-eligible-phase,
  and empty-input cases; and cross-sensor unique-ID collection, unhealthy-
  sensor exclusion, outside-time-window exclusion, quota-not-met fallback,
  auto-detected quotas, and empty-`TestBrake` raising. Also run manually
  against the same real 44-phase Dati01 `TestBrake`: `pick_reference_phase`
  found 6 of 44 phases eligible and selected one with `BC_valid==BC_expected`,
  `WV_valid==WV_expected`, no error flags; `Collect_Healthy_SensorData`
  correctly gathered exactly the dataset's real sensor roster (3 BC + 3 WV
  IDs) within the first 9 phases of the 2-hour window.
- `build_test_brake_sets.py`: checked against hand-built two-phase
  fixtures covering rank-based pairing (highest-pressure BC/WV paired
  together), the registry lock-and-reuse behavior (a second call with a
  different/invalid `reference_phase_idx` still returns the first call's
  locked pairing, `used_method="reference(saved)"`), Roster-based pairing
  not locking (a later reference-phase call can still overwrite it),
  empty-`TestBrake` raising, and dataset-key derivation from both the
  filename and the parent folder. Also run manually against the real
  44-phase Dati01 `TestBrake` + its own `pick_reference_phase`/
  `Collect_Healthy_SensorData` output: correctly formed exactly 3 BC/WV
  pairs (matching the dataset's real 3-BC/3-WV roster), ranked by
  pressure, registry successfully written and re-readable.
- `mbp_pipe_subphases.py` / `bc_cyl_subphases.py`: checked against
  hand-built buildup/hold/release fixtures (sane subphase timings, correct
  buildup/release gradient signs, correct `EmergencyBrake_action`/
  `Max_pressure_cyl` peaks, a resolvable BC `First_phase` curve-shape
  analysis on a clean crossing), each detector's guard path (confirms the
  exact, smaller field set the source's guard path produces, matching
  field-for-field), and the BC non-standard-braking early-`continue` edge
  case (confirms the summary-stat fields are genuinely absent, not
  defaulted, exactly matching the source). Also run manually end-to-end
  (filtering through both subphase detectors) against the real 44-phase
  Dati01 `TestBrake` + its own pairing output: ran without crashing across
  all 3 real BC/WV pairs, with physically plausible data-coverage rates
  (100% of phases got MBP pipe data; 41-55% got valid BC cylinder
  engagement data; 16-41% resolved a valid `First_phase` curve — all
  lower than 100% as expected, since not every detected MBP braking phase
  involves a real engagement from any one specific BC/WV pair).
- `detect_subphases_sets.py` / `postprocessing.py` / `csv_export.py` /
  `pipeline.py`: checked against synthetic fixtures covering both-detectors-run,
  empty-cell passthrough, MBP-failure isolation (confirms no partial
  mutation leaks through, confirms BC still runs), `KEEP_FIELDS` schema
  presence with correct `RunFile`/`RunFolder`, the zero-denominator-forces-NaN
  efficiency-ratio rule, and CSV merge/dedupe (same composite key ->
  one row, new value wins). Also run manually end-to-end
  (`process_nodo_file` on the real Dati01 `Nodo` pickle, the same one used
  throughout this doc): produced a 132-row x 111-column CSV (3 real BC/WV
  pairs x 44 real phases), with all of `train_binary_classifier.py`'s
  required columns present, `KEEP_FIELDS` order preserved, and derived
  fields (efficiency ratios, delays, error flags) populated with plausible
  values (`Total_power_efficiency` non-null on 65/132 rows — a plausible
  rate, since it requires both a resolved BC and a resolved MBP power
  figure for that phase).
