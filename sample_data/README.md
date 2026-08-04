# Sample data

A small (~9MB), working copy of the real dashboard data, provided so the
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
