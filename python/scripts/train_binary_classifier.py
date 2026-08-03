# train_pipeline.py

import os
import re
import sys
from datetime import datetime
from pathlib import Path
import json
import joblib
import numpy as np
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "python" / "src"))
from braking_ml.utilities.paths import project_paths

from sklearn.model_selection import RepeatedStratifiedKFold, train_test_split, GridSearchCV, StratifiedKFold
from sklearn.metrics import (
    confusion_matrix,
    balanced_accuracy_score,
    precision_score,
    recall_score,
    f1_score,
    classification_report,
)

from sklearn.impute import SimpleImputer
from sklearn.preprocessing import RobustScaler
from sklearn.pipeline import Pipeline as SkPipeline

from sklearn.base import clone
from sklearn.ensemble import RandomForestClassifier
from sklearn.svm import SVC
from sklearn.neighbors import KNeighborsClassifier
from sklearn.tree import DecisionTreeClassifier

from imblearn.pipeline import Pipeline as ImbPipeline
from imblearn import FunctionSampler

# -----------------------------
# Your oversampler helper
# -----------------------------
from imblearn.over_sampling import SMOTE, BorderlineSMOTE, ADASYN, KMeansSMOTE
from imblearn.combine import SMOTETomek, SMOTEENN


def get_oversampler(name="SMOTE", y=None, n_splits=5, sampling_ratio=None, random_state=42):
    """
    Oversampler that auto-reduces k_neighbors / n_neighbors so it does not crash inside CV folds.

    Requirements:
    - pass y (labels) and n_splits (your CV folds count)
    """
    if y is None:
        raise ValueError("Pass y to get_oversampler so k_neighbors can be chosen safely.")

    y = np.asarray(y)
    classes, counts = np.unique(y, return_counts=True)
    min_count = counts.min()

    # minimum samples in the smallest class in a TRAINING fold:
    min_train_fold = int(np.floor(min_count * (n_splits - 1) / n_splits))

    # k_neighbors must be <= (min_train_fold - 1)
    safe_k = max(1, min(5, min_train_fold - 1))

    sampling_strategy = "not majority" if sampling_ratio is None else sampling_ratio
    name_l = str(name).lower()

    if name_l == "smote":
        return SMOTE(sampling_strategy=sampling_strategy, k_neighbors=safe_k, random_state=random_state)

    elif name_l == "borderlinesmote":
        return BorderlineSMOTE(sampling_strategy=sampling_strategy, k_neighbors=safe_k, random_state=random_state)

    elif name_l == "adasyn":
        return ADASYN(sampling_strategy=sampling_strategy, n_neighbors=safe_k, random_state=random_state)

    elif name_l in ("kmeans-smote", "kmeanssmote"):
        return KMeansSMOTE(sampling_strategy=sampling_strategy, k_neighbors=safe_k, random_state=random_state)

    elif name_l in ("smote-tomek", "smotetomek"):
        return SMOTETomek(
            sampling_strategy=sampling_strategy,
            smote=SMOTE(sampling_strategy=sampling_strategy, k_neighbors=safe_k, random_state=random_state),
            random_state=random_state
        )

    elif name_l in ("smote-enn", "smoteenn"):
        return SMOTEENN(
            sampling_strategy=sampling_strategy,
            smote=SMOTE(sampling_strategy=sampling_strategy, k_neighbors=safe_k, random_state=random_state),
            random_state=random_state
        )

    else:
        raise ValueError(f"Unknown oversampler '{name}'.")


# ======================================================================
# STEP 1: LOAD AND PREPARE DATA (REFERENCE + MULTI-KIT MONORAIL)
# ======================================================================

def load_data(model_path, monorail_paths):
    """
    Load and prepare reference (model) data and Monorail data (one or more kits),
    align common columns, and return a single combined DataFrame.

    Notes:
    - Reference (model.csv): label is derived from Malfunction codes.
    - Monorail kits: label typically missing -> remains NaN after merge.

    Returns
    -------
    df_base : pandas.DataFrame
        Combined DataFrame with aligned common columns and:
        - 'Source' column (kit ID or 0 for reference)
        - 'DataSource' column (0 = reference, 1 = Monorail)
        - 'label' column (0/1) for reference rows; NaN for unlabeled Monorail rows
        - 'WV_bin' derived from WV_MeanPressure
    """

    def load_Monorail(filepath: str) -> pd.DataFrame:
        df = pd.read_csv(filepath)

        # Extract numeric kit ID from filename, e.g. "TestBrakefinal_data_raw_Dati06.csv" -> 6
        match = re.search(r'Dati(\d+)', os.path.basename(filepath))
        source = int(match.group(1)) if match else -1
        df["Source"] = source

        # Optional: mark Malfunction as unknown (avoid implying "healthy")
        if "Malfunction" not in df.columns:
            df["Malfunction"] = np.nan

        # Convert "xx sec" string columns to float seconds where possible
        for col in df.select_dtypes(include="object"):
            try:
                df[col] = df[col].str.replace(" sec", "", regex=False).astype(float)
            except (AttributeError, ValueError):
                continue

        # Additional Monorail-only flags
        if "Brake_energy_pipe" in df.columns:
            df["Brake_energy_pipe"] = pd.to_numeric(df["Brake_energy_pipe"], errors="coerce")
            df["MBP_PhaseClassification_error"] = np.where(df["Brake_energy_pipe"] < 0.01, 1, 0)
        else:
            df["MBP_PhaseClassification_error"] = np.nan

        if "Buildup_timing_pipe" in df.columns:
            df["Buildup_timing_pipe"] = pd.to_numeric(df["Buildup_timing_pipe"], errors="coerce")
            df["MBP_buildup_timing_error"] = np.where(df["Buildup_timing_pipe"] > 180, 1, 0)
        else:
            df["MBP_buildup_timing_error"] = np.nan

        # Data-quality filtering (Monorail)
        if "Non_Standard_Braking" in df.columns and "BC_BadStart" in df.columns:
            df = df.loc[
                (df["Non_Standard_Braking"].eq(0)) &
                (df["BC_BadStart"].eq(0))
            ].copy()

        return df

    # ---- Reference data ----
    df_reference = pd.read_csv(model_path)
    df_reference["Malfunction"] = df_reference["Malfunction"].astype(str)

    leakage_codes = ["C", "D", "E", "F", "G"]
    df_reference["LeakageLabel"] = np.where(
        df_reference["Malfunction"].isin(leakage_codes),
        "Combined leakage",
        "Healthy"
    )
    df_reference["Source"] = 0

    # Aggregate delay and efficiency columns
    delay_eff_map = {
        "Total_timing_delay":      ["Brake_timing_delay_exp",      "Release_timing_delay_exp"],
        "Total_energy_delay":      ["Brake_energy_delay_exp",      "Release_energy_delay_exp"],
        "Total_power_delay":       ["Brake_power_delay_exp",       "Release_power_delay_exp"],
        "Total_power_efficiency":  ["Brake_power_efficiency_exp",  "Release_power_efficiency_exp"],
        "Total_energy_efficiency": ["Brake_energy_effiency_exp",   "Release_energy_efficiency_exp"],
    }

    for new_col, (c1, c2) in delay_eff_map.items():
        if c1 in df_reference.columns and c2 in df_reference.columns:
            df_reference[new_col] = df_reference[c1] + df_reference[c2]

    cols_to_drop = [c for pair in delay_eff_map.values() for c in pair if c in df_reference.columns]
    df_reference.drop(columns=cols_to_drop, inplace=True, errors="ignore")

    rename_map = {
        "Release_start_pressure_delay_exp": "Release_start_pressure_delay",
        "Buildup_end_pressure_delay_exp":  "Buildup_end_pressure_delay",
        "Weight":                          "WV_MeanPressure",
        "Brake_action":                    "EmergencyBrake_action",
    }
    df_reference.rename(columns=rename_map, inplace=True)

    # ---- Monorail data ----
    if isinstance(monorail_paths, str):
        monorail_paths = [monorail_paths]

    dfs_mono = [load_Monorail(fp) for fp in monorail_paths]
    df_data = pd.concat(dfs_mono, ignore_index=True)

    # ---- Align and combine ----
    df_reference["Source"] = df_reference["Source"].astype(int)
    df_data["Source"] = df_data["Source"].astype(int)

    common_cols = df_reference.columns.intersection(df_data.columns).tolist()

    df_reference_subset = df_reference[common_cols].copy()
    df_reference_subset["DataSource"] = 0

    df_data_subset = df_data[common_cols].copy()
    df_data_subset["DataSource"] = 1

    df_combined = pd.concat([df_reference_subset, df_data_subset], ignore_index=True)

    if "LeakageLabel" in df_combined.columns:
        df_combined.rename(columns={"LeakageLabel": "label"}, inplace=True)
        df_combined["label"] = df_combined["label"].map({"Healthy": 0, "Combined leakage": 1})

    # Convert any remaining "xx sec" string columns to float
    for col in df_combined.select_dtypes(include="object"):
        try:
            df_combined[col] = df_combined[col].str.replace(" sec", "", regex=False).astype(float)
        except (AttributeError, ValueError):
            continue

    # WV bin
    if "WV_MeanPressure" in df_combined.columns:
        df_combined["WV_bin"] = df_combined["WV_MeanPressure"].apply(
            lambda p: np.nan if pd.isna(p) else (0 if p < 2 else (2 if p > 3 else 1))
        )
    else:
        df_combined["WV_bin"] = np.nan

    return df_combined.copy()


# ======================================================================
# STEP 2: Split + basic checks (WV regime + labeled only)
# ======================================================================

def split_supervised_dataset(df, features, test_size=0.2, random_state=42, label_col="label"):
    df = df.copy()

    # Regime filtering
    df = df.loc[df["WV_bin"].eq(1)].copy()

    # Supervised training requires labels
    df = df.loc[df[label_col].notna()].copy()
    df[label_col] = df[label_col].astype(int)

    missing = [f for f in features if f not in df.columns]
    if missing:
        raise ValueError(f"Missing features: {missing}")

    X = df[features]
    y = df[label_col].values.astype(int)

    X_train, X_test, y_train, y_test = train_test_split(
        X, y,
        test_size=test_size,
        stratify=y,
        random_state=random_state
    )

    return X_train, X_test, y_train, y_test, df


# ======================================================================
# STEP 3: Healthy-only RNN cleaning (as an imblearn sampler via FunctionSampler)
# ======================================================================

def _rnn_clean_healthy_only(X, y, k=5):
    """
    Remove outliers from healthy class (y==0) using RNN-inspired rule:
    points with reverse-neighbor count == 0 are removed.
    Fault class samples (y!=0) are kept untouched.

    This function is used inside FunctionSampler, so it must return (X_res, y_res).
    """
    X = np.asarray(X)
    y = np.asarray(y)

    healthy_mask = (y == 0)
    fault_mask = ~healthy_mask

    X_h = X[healthy_mask]
    y_h = y[healthy_mask]

    # If too few healthy samples, do nothing
    if len(X_h) == 0 or len(X_h) <= k:
        return X, y

    # Compute reverse-neighbor counts within healthy class
    from sklearn.neighbors import NearestNeighbors

    n_h = len(X_h)
    reverse_neighbor_count = np.zeros(n_h, dtype=int)

    nbrs = NearestNeighbors(n_neighbors=min(k + 1, n_h))
    nbrs.fit(X_h)
    _, indices = nbrs.kneighbors(X_h)

    # Count how often each point appears in other points' neighbor lists
    for i, neighbors in enumerate(indices):
        for nb in neighbors[1:]:  # skip self
            reverse_neighbor_count[nb] += 1

    keep_h = reverse_neighbor_count > 0

    X_h_clean = X_h[keep_h]
    y_h_clean = y_h[keep_h]

    # Recombine healthy-clean + all faults
    X_res = np.vstack([X_h_clean, X[fault_mask]]) if X_h_clean.size else X[fault_mask]
    y_res = np.concatenate([y_h_clean, y[fault_mask]]) if y_h_clean.size else y[fault_mask]

    return X_res, y_res


def make_rnn_sampler(k=5):
    """
    Wrap healthy-only RNN cleaning as an imblearn sampler.
    FunctionSampler is intended for custom resampling functions. :contentReference[oaicite:2]{index=2}
    """
    return FunctionSampler(func=_rnn_clean_healthy_only, kw_args={"k": k})


# ======================================================================
# STEP 4: Model registry + grids (your exact grids)
# ======================================================================

def get_models_and_grids(random_state=42):
    models = {
        "RF (tuned)": RandomForestClassifier(random_state=random_state),
        "SVM (tuned)": SVC(kernel="rbf"),  # probability will be tuned to True via grid
        "KNN (tuned)": KNeighborsClassifier()
    }

    grids = {
        "RF (tuned)": {
            "n_estimators": [200, 300, 400, 500],
            "max_depth": [3, 4, 5],
            "min_samples_split": [2, 3, 4],
            "min_samples_leaf": [1, 2],
        },
        "SVM (tuned)": {
            "C": [0.1, 1],
            "gamma": ["scale", 0.1, 0.01],
            "probability": [True],
        },
        "KNN (tuned)": {
            "n_neighbors": [5, 7, 9, 11, 15],
            "weights": ["uniform", "distance"],
        }
    }

    return models, grids


# ======================================================================
# STEP 5: Build CV pipeline and tune
# ======================================================================

def tune_one_model(
    X_train,
    y_train,
    base_model,
    param_grid,
    *,
    oversampling_mode=2,          # 1=SMOTE, 2=ADASYN
    sampling_ratio=0.5,           # your preferred ratio for ADASYN; can also be used for SMOTE
    rnn_k=5,
    scoring="f1_macro",
    n_splits=5,
    random_state=42,
    verbose=1
):
    """
    GridSearchCV over a pipeline:
        preprocess -> RNN(healthy-only) -> oversampler -> classifier

    Oversampling is inside CV folds via imblearn Pipeline. :contentReference[oaicite:5]{index=5}
    best_estimator_ is refit on full training set by GridSearchCV. :contentReference[oaicite:6]{index=6}
    """
    X_train = np.asarray(X_train)
    y_train = np.asarray(y_train)

    classes, counts = np.unique(y_train, return_counts=True)
    min_count = counts.min()
    n_splits = min(int(n_splits), int(min_count))
    if n_splits < 2:
        raise ValueError(
            f"n_splits became {n_splits}. Need at least 2 samples per class. "
            f"Class distribution: {dict(zip(classes, counts))}"
        )
    n_repeats = 5  # or 10 if can afford runtime
    cv = RepeatedStratifiedKFold(
        n_splits=n_splits,
        n_repeats=n_repeats,
        random_state=random_state
    )
    # cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=random_state)

    # Oversampler selection
    if oversampling_mode == 1:
        overs_name = "SMOTE"
    elif oversampling_mode == 2:
        overs_name = "ADASYN"
    else:
        raise ValueError("oversampling_mode must be 1 (SMOTE) or 2 (ADASYN).")

    oversampler = get_oversampler(
        name=overs_name,
        y=y_train,
        n_splits=n_splits,
        sampling_ratio=sampling_ratio,
        random_state=random_state
    )

    pipe = ImbPipeline([
        ("imputer", SimpleImputer(strategy="median")),
        ("scaler", RobustScaler()),
        ("rnn_clean", make_rnn_sampler(k=rnn_k)),
        ("oversampler", oversampler),
        ("clf", clone(base_model)),
    ])

    # Prefix grid with clf__
    grid_prefixed = {f"clf__{k}": v for k, v in param_grid.items()}

    grid = GridSearchCV(
        estimator=pipe,
        param_grid=grid_prefixed,
        scoring=scoring,
        cv=cv,
        n_jobs=-1,
        verbose=verbose,
        error_score="raise",
        refit=True
    )

    grid.fit(X_train, y_train)

    return {
        "best_estimator": grid.best_estimator_,
        "best_params": grid.best_params_,
        "best_score": float(grid.best_score_),
        "cv_results": grid.cv_results_,
        "n_splits": n_splits,
        "oversampler": overs_name,
        "sampling_ratio": sampling_ratio,
        "rnn_k": rnn_k,
        "scoring": scoring,
    }


# ======================================================================
# STEP 6: Evaluate on split test set
# ======================================================================

def compute_far_from_cm(cm, labels):
    """
    FAR = FP/(FP+TN) for binary; assumes class 0 is healthy if present.
    """
    labels = np.asarray(labels)
    if len(labels) != 2:
        return np.nan, np.nan, np.nan

    neg_label = 0 if 0 in labels else labels[0]
    pos_label = 1 if 1 in labels else labels[1]

    neg_idx = np.where(labels == neg_label)[0][0]
    pos_idx = np.where(labels == pos_label)[0][0]

    tn = cm[neg_idx, neg_idx]
    fp = cm[neg_idx, pos_idx]
    denom = tn + fp
    far = fp / denom if denom > 0 else np.nan
    return far, fp, tn


def evaluate_on_test(models_dict, X_test, y_test, average="macro", verbose_reports=True):
    X_test = np.asarray(X_test)
    y_test = np.asarray(y_test)

    labels = np.unique(y_test)
    rows = []
    cms = {}

    for name, model in models_dict.items():
        y_pred = model.predict(X_test)
        cm = confusion_matrix(y_test, y_pred, labels=labels)
        cms[name] = cm

        far, fp, tn = compute_far_from_cm(cm, labels)

        rows.append({
            "Model": name,
            "BalancedAcc": balanced_accuracy_score(y_test, y_pred),
            "Precision": precision_score(y_test, y_pred, average=average, zero_division=0),
            "Recall": recall_score(y_test, y_pred, average=average, zero_division=0),
            "F1": f1_score(y_test, y_pred, average=average, zero_division=0),
            "FAR": far,
            "FP": fp,
            "TN": tn
        })

        if verbose_reports:
            print("\n" + "=" * 70)
            print(f"{name} — classification report (split test)")
            print("=" * 70)
            print(classification_report(y_test, y_pred, zero_division=0))

    df = pd.DataFrame(rows)

    # FAR-first ranking
    if len(labels) == 2:
        df = df.sort_values(["FAR", "FP", "Recall"], ascending=[True, True, False]).reset_index(drop=True)
    else:
        df = df.sort_values(["F1"], ascending=False).reset_index(drop=True)

    return df, cms

def make_inference_pipeline(fitted_imb_pipe):
    steps = fitted_imb_pipe.named_steps
    return SkPipeline([
        ("imputer", steps["imputer"]),
        ("scaler", steps["scaler"]),
        ("clf", steps["clf"]),
    ])

# ======================================================================
# STEP 7: Saving (timestamp prefix + save both clf-only and full pipeline)
# ======================================================================

def sanitize_name(s: str) -> str:
    return str(s).lower().replace(" ", "_").replace("(", "").replace(")", "")


def make_run_id() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def save_model_artifacts(
    tuned_models: dict,
    save_dir: str,
    run_id: str,
    experiment_tag: str,
    features: list,
    meta_base: dict
):
    """
    Saves per model:
      1) clf-only bundle (clf + imputer + scaler + features + meta)
      2) full fitted pipeline bundle (full pipeline + features + meta)

    Filenames:
      {RUNID}_{tag}_{model}_clf.joblib
      {RUNID}_{tag}_{model}_pipeline.joblib
    """
    save_path = Path(save_dir)
    save_path.mkdir(parents=True, exist_ok=True)

    for model_name, fitted_pipe in tuned_models.items():
        base = sanitize_name(model_name)
        prefix = f"{run_id}_{experiment_tag}_"

        clf_file = save_path / f"{prefix}{base}_clf.joblib"
        pipe_file = save_path / f"{prefix}{base}_pipeline.joblib"
        meta_file = save_path / f"{prefix}{base}_meta.json"
        infer_file = save_path / f"{prefix}{base}_inference_pipeline.joblib"


        # Extract parts
        if hasattr(fitted_pipe, "named_steps"):
            clf = fitted_pipe.named_steps.get("clf", None)
            imputer = fitted_pipe.named_steps.get("imputer", None)
            scaler = fitted_pipe.named_steps.get("scaler", None)
        else:
            clf = fitted_pipe
            imputer = None
            scaler = None


        imputer = None
        scaler = None
        
        meta = dict(meta_base)
        meta.update({
            "model_name": model_name,
            "saved_at": datetime.now().isoformat(timespec="seconds"),
            "features": features,
            "has_full_pipeline": True,
            "has_clf_only_bundle": True,
        })

        # 1) clf-only bundle
        joblib.dump(
            {
                "model": clf,
                "scaler": scaler,
                "imputer": imputer,
                "features": features,
                "meta": meta
            },
            clf_file
        )

        # 2) full pipeline bundle
        joblib.dump(
            {
                "pipeline": fitted_pipe,
                "features": features,
                "meta": meta
            },
            pipe_file
        )
        
        # ---------------------------------
        # 2) INFERENCE-ONLY PIPELINE (NEW)
        # ---------------------------------
        infer_pipe = make_inference_pipeline(fitted_pipe)

        joblib.dump(
            {
                "pipeline": infer_pipe,
                "features": features,
                "meta": meta_base,
            },
            infer_file
        )
        

        # Optional: metadata json for quick browsing
        with open(meta_file, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)

        print(f"[SAVED] {model_name}")
        print(f"  - clf bundle:      {clf_file.name}")
        print(f"  - pipeline bundle: {pipe_file.name}")
        print(f"  - meta json:       {meta_file.name}\n")


# ======================================================================
# MAIN
# ======================================================================

def main():
    # -------------------------
    # User configuration (yours)
    # -------------------------
    paths = project_paths()
    model_path = paths.external_data / "model.csv"
    monorail_paths = [
        paths.processed_data / "TestBrakefinal_data_raw_Dati01.csv",
        paths.processed_data / "TestBrakefinal_data_raw_Dati06.csv",
        paths.processed_data / "TestBrakefinal_data_raw_Dati27.csv",
    ]

    selected_features = ["Total_power_efficiency", "Std_delay_exp"]
    test_size = 0.2
    random_state = 42

    # Oversampling mode:
    #   1 = SMOTE
    #   2 = ADASYN
    oversampling_mode = 2
    sampling_ratio = 0.5  # used for both SMOTE/ADASYN here (float ratio or string)
    rnn_k = 5

    # GridSearchCV config
    scoring = "f1_macro"
    n_splits = 3
    verbose = 1

    # Saving
    SAVE_DIR = paths.models_dir
    EXPERIMENT_TAG = "feat2"  # change to whatever you like (no trailing underscore needed)

    # -------------------------
    # 1) Load
    # -------------------------
    df = load_data(model_path, monorail_paths)
    print(f"Loaded combined df: {df.shape}")
    print("DataSource counts:", df["DataSource"].value_counts(dropna=False).to_dict())

    # -------------------------
    # 2) Split supervised dataset
    # -------------------------
    X_train, X_test, y_train, y_test, df_used = split_supervised_dataset(
        df, selected_features, test_size=test_size, random_state=random_state, label_col="label"
    )
    print("\nSplit summary (WV_bin==1 & labeled rows only):")
    print(f"  Train: {len(y_train)}  (Healthy={(y_train==0).sum()}, Fault={(y_train==1).sum()})")
    print(f"  Test:  {len(y_test)}   (Healthy={(y_test==0).sum()}, Fault={(y_test==1).sum()})")

    # -------------------------
    # 3) Tune each model
    # -------------------------
    models, grids = get_models_and_grids(random_state=random_state)

    tuned_models = {}
    tuning_info = {}

    for model_name, base_model in models.items():
        print("\n" + "=" * 80)
        print(f"TUNING: {model_name}")
        print("=" * 80)

        res = tune_one_model(
            X_train, y_train,
            base_model=base_model,
            param_grid=grids[model_name],
            oversampling_mode=oversampling_mode,
            sampling_ratio=sampling_ratio,
            rnn_k=rnn_k,
            scoring=scoring,
            n_splits=n_splits,
            random_state=random_state,
            verbose=verbose
        )

        tuned_models[model_name] = res["best_estimator"]
        tuning_info[model_name] = {
            "best_params": res["best_params"],
            "best_score": res["best_score"],
            "n_splits": res["n_splits"],
            "oversampler": res["oversampler"],
            "sampling_ratio": res["sampling_ratio"],
            "rnn_k": res["rnn_k"],
            "scoring": res["scoring"],
        }

        print(f"\nBest score ({scoring}) = {res['best_score']:.4f}")
        print(f"Best params: {res['best_params']}")

    # -------------------------
    # 4) Evaluate on split test set
    # -------------------------
    print("\n" + "=" * 80)
    print("EVALUATION ON SPLIT TEST SET")
    print("=" * 80)
    eval_df, cms = evaluate_on_test(tuned_models, X_test, y_test, average="macro", verbose_reports=True)
    print("\nSummary (FAR-first ranking):")
    print(eval_df)

    # -------------------------
    # 5) Save both clf-only and full pipeline
    # -------------------------
    run_id = make_run_id()
    meta_base = {
        "run_id": run_id,
        "experiment_tag": EXPERIMENT_TAG,
        "wv_bin": 1,
        "test_size": test_size,
        "random_state": random_state,
        "oversampling_mode": oversampling_mode,
        "oversampling_mode_name": ("SMOTE" if oversampling_mode == 1 else "ADASYN"),
        "sampling_ratio": sampling_ratio,
        "rnn_k": rnn_k,
        "scoring": scoring,
        "n_splits": n_splits,
        "tuning_info": tuning_info,
    }
    
    save_model_artifacts(
        tuned_models=tuned_models,
        save_dir=SAVE_DIR,
        run_id=run_id,
        experiment_tag=EXPERIMENT_TAG,
        features=selected_features,
        meta_base=meta_base
    )

    # Optionally save evaluation table for record
    eval_csv = Path(SAVE_DIR) / f"{run_id}_{EXPERIMENT_TAG}_split_test_summary.csv"
    eval_df.to_csv(eval_csv, index=False)
    print(f"[SAVED] Split-test summary table: {eval_csv.name}")


if __name__ == "__main__":
    main()
