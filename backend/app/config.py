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


def resolve_under_data(path: str | Path) -> Path:
    """Resolves a caller-supplied directory to an absolute path inside
    data/, rejecting anything that escapes it.

    The live watcher and replay runner take their directories straight
    from request bodies, and the API is reachable by anyone who has the
    dashboard's URL -- without this, a request could point them at any
    path the server process can read, or (the replay runner creates its
    destination) write. Relative paths are taken as relative to data/,
    which is also what makes the Live page's directory field usable
    without knowing the server's absolute layout.
    """
    data_root = (get_paths().root / "data").resolve()
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = data_root / candidate
    resolved = candidate.resolve()
    if not resolved.is_relative_to(data_root):
        raise ValueError(f"Directory must be inside {data_root}, got: {path}")
    return resolved
