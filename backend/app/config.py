"""Self-locating project paths for the backend.

Mirrors python_port/paths.py and config/matlab_paths.m: derives the
repository root from this file's own location so paths are correct
regardless of the current working directory the server is launched from.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AppPaths:
    root: Path
    raw: Path
    interim: Path
    processed: Path
    external: Path
    outputs: Path
    models: Path
    dashboard_store: Path
    live: Path  # data/processed/live/ -- mirrors python_port/paths.py::PortPaths.live


def get_paths() -> AppPaths:
    root = Path(__file__).resolve().parents[2]
    data = root / "data"
    outputs = root / "outputs"
    return AppPaths(
        root=root,
        raw=data / "raw",
        interim=data / "interim",
        processed=data / "processed",
        external=data / "external",
        outputs=outputs,
        models=outputs / "models",
        dashboard_store=outputs / "dashboard_store",
        live=data / "processed" / "live",
    )
