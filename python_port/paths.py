"""Self-locating project paths for the Python port.

Mirrors config/matlab_paths.m: derives the repository root from this file's
own location so callers get correct paths regardless of the current working
directory.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class PortPaths:
    root: Path
    raw: Path
    interim: Path
    processed: Path
    external: Path
    features: Path
    figures: Path
    models: Path
    reports: Path
    logs: Path
    live: Path  # data/processed/live/ -- live-watcher CSV output, kept separate
    # from the batch training corpus in `processed`; see csv_export.py's
    # _live_output_path() docstring.


def get_paths() -> PortPaths:
    root = Path(__file__).resolve().parent.parent
    data = root / "data"
    outputs = root / "outputs"
    return PortPaths(
        root=root,
        raw=data / "raw",
        interim=data / "interim",
        processed=data / "processed",
        external=data / "external",
        features=outputs / "features",
        figures=outputs / "figures",
        models=outputs / "models",
        reports=outputs / "reports",
        logs=outputs / "logs",
        live=data / "processed" / "live",
    )
