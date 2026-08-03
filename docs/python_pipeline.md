# Python pipeline

Training entry points are `python/scripts/train_binary_classifier.py` and `python/scripts/train_multiclass_classifier.py`.

Both scripts load one labeled reference dataset and operational feature CSVs, filter to the middle wheel-valve-pressure regime, tune RF/SVM/KNN pipelines, and save Joblib artifacts plus metadata under `outputs/models/`.

The binary script maps leakage codes C–G to one leakage class. The multiclass script retains healthy, auxiliary leakage, and combined leakage classes. No classifier settings, feature names, thresholds, or output metadata fields were intentionally changed.

Inference notebooks are under `python/notebooks/inference/`; exploratory and historical model notebooks are separated from active scripts.
