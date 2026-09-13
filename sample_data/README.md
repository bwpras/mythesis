# Sample data

A small (~11MB), working copy of the real dashboard data, provided so the
dashboard runs out of the box after cloning this repo. See the root
[README.md](../README.md#dashboard) for setup instructions.

## What's real and what's changed

Every field is the real, actual data used for this project's results
**except** `GPS_Lat_last` / `GPS_Long_last`, which have been shifted by one
fixed random offset (same offset applied to every kit, so each kit's route
shape and the kits' positions relative to each other are preserved — the
map still looks like one coherent fleet operating in one region) — this is
real operational telemetry from an actual wagon fleet, and the exact real
locations aren't published here. `near-(0,0)` GPS values (a hardware
cold-start sentinel, not a real fix) are left untouched by the shift, same
as everywhere else in this codebase (see `data_store.valid_gps_fix()`).

- `processed/` → real Stage 2 output for 9 kits, GPS-shifted as above.
  Normally lives at `data/processed/` (gitignored, not in this repo).
- `models/finished_thesis/` → the real trained model bundles, byte-for-byte
  unchanged (no GPS or other location data in the model itself). Normally
  lives at `outputs/models/finished_thesis/` (gitignored, not in this repo).
- `raw/Dati05/` → real, unmodified `.bin` telemetry for one kit on one day
  (2025-06-10, ~17:00–21:25), so the Live page has something to replay.
  **Pressure files (`*_p.bin`) only — the GPS files (`*_pjm.bin`) of that day
  are deliberately excluded.** Raw `_pjm.bin` carries true, unshifted
  coordinates, so publishing it would both expose the fleet's real route
  directly and, because `processed/` already publishes *shifted* fixes for
  this same kit and day, make the shift offset recoverable by comparison —
  which would de-shift every kit, not just this one. Nothing is lost by the
  exclusion: the trained models use only `Total_power_efficiency` and
  `Std_delay_exp`, and Stage 2 attaches no GPS to these phases anyway
  (`GPS_NumSamples=0`), so the live event map is empty either way.
  Normally lives at `data/raw/` (gitignored, not in this repo).
- `interim/label_registry/`, `interim/pairing_registry/` → the two
  pipeline-derived artifacts `check_live_precondition()` requires before a
  live watcher may start (cached sensor roles; BC/WV pairing locked to a
  reference phase). Both are reproducible by running the batch pipeline over
  `raw/Dati05/` — verified to regenerate byte-identically — and are shipped
  only because the free-tier disk is ephemeral. Normally lives at
  `data/interim/` (gitignored, not in this repo).
