# Data flow

```text
raw telemetry
  → MATLAB ingestion
  → Nodo structures
  → preprocessing and sensor labeling
  → braking-event detection
  → MBP/BC/WV pairing and phase classification
  → feature tables / CSV files
  → Python training
  → saved models and metadata
  → inference notebooks
  → predictions and evaluation outputs
```

The MATLAB-to-Python feature-table export mechanism is inferred from matching fields and file names; it is not documented by one dedicated export command.
