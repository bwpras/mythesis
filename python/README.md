# Python machine-learning area

Active scripts:

- `scripts/train_binary_classifier.py`
- `scripts/train_multiclass_classifier.py`

Both resolve repository paths through `braking_ml.utilities.paths`, so they do not require a particular working directory. They expect `data/external/model.csv` and processed feature CSVs named in `config/model_config.example.json`.

`requirements.txt` intentionally has no versions because none were specified by the original project. Notebook-only dependencies are marked by comments.
