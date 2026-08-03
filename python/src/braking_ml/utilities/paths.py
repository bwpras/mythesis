"""Location helpers that do not depend on the caller's working directory."""
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProjectPaths:
    root: Path
    raw_data: Path
    interim_data: Path
    processed_data: Path
    external_data: Path
    features_dir: Path
    models_dir: Path
    predictions_dir: Path
    reports_dir: Path
    figures_dir: Path
    logs_dir: Path


def project_paths() -> ProjectPaths:
    root = Path(__file__).resolve().parents[4]
    return ProjectPaths(
        root=root,
        raw_data=root / "data" / "raw",
        interim_data=root / "data" / "interim",
        processed_data=root / "data" / "processed",
        external_data=root / "data" / "external",
        features_dir=root / "outputs" / "features",
        models_dir=root / "outputs" / "models",
        predictions_dir=root / "outputs" / "predictions",
        reports_dir=root / "outputs" / "reports",
        figures_dir=root / "outputs" / "figures",
        logs_dir=root / "outputs" / "logs",
    )
