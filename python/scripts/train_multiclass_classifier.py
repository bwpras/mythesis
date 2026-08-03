# train_pipeline_multiclass.py
# Multiclass version:
#   0 = Healthy (incl. H and "0")
#   1 = Auxiliary leakage (A,B)
#   2 = Combined leakage (C,D,E,F,G)
#
# Oversampling:
#   mode 1 = SMOTE
#   mode 2 = ADASYN
# sampling_strategy = "not majority" (multiclass-safe)
#
# RNN cleaning: healthy-only (class 0)

import os
import re
import sys
import json
import joblib
import numpy as np
import pandas as pd
from pathlib import Path
from datetime import datetime

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "python" / "src"))
from braking_ml.utilities.paths import project_paths

from sklearn.model_selection import RepeatedStratifiedKFold, train_test_split, GridSearchCV, StratifiedKFold
from sklearn.metrics import (
    confusion_matrix,
    classification_report,
    balanced_accuracy_score,
    f1_score,
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
from imblearn.over_sampling import SMOTE, BorderlineSMOTE, ADASYN, KMeansSMOTE
from imblearn.combine import SMOTETomek, SMOTEENN


# -----------------------------
# Oversampler helper (yours)
# -----------------------------
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

    # minimum samples in the smallest class in a TRAINING fold
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
# STEP 1: LOAD AND PREPARE DATA (MULTICLASS)
#   0 = Healthy (everything else, incl. H and "0")
#   1 = Auxiliary leakage (A,B)
#   2 = Combined leakage (C,D,E,F,G)
# ======================================================================

def load_data(model_path, monorail_paths):
    def load_Monorail(filepath: str) -> pd.DataFrame:
        df = pd.read_csv(filepath)

        # Keep only standard braking and good BC acquisition start
        df = df[df["Non_Standard_Braking"] == 0]
        df = df[df["BC_BadStart"] == 0]

        # Extract numeric kit ID from filename, e.g. "TestBrakefinal_data_raw_Dati06.csv" -> 6
        match = re.search(r"Dati(\d+)", os.path.basename(filepath))
        source = int(match.group(1)) if match else -1
        df["Source"] = source

        # Placeholder and intentional (as you said)
        df["Malfunction"] = 0

        # Convert "xx sec" string columns to float seconds where possible
        for col in df.select_dtypes(include="object"):
            try:
                df[col] = df[col].str.replace(" sec", "", regex=False).astype(float)
            except (AttributeError, ValueError):
                continue

        return df

    # ---- Reference data ----
    df_reference = pd.read_csv(model_path)
    df_reference["Malfunction"] = df_reference["Malfunction"].astype(str)

    aux_codes = ["A", "B"]
    leakage_codes = ["C", "D", "E", "F", "G"]

    df_reference["LeakageLabel"] = np.select(
        [
            df_reference["Malfunction"].isin(aux_codes),
            df_reference["Malfunction"].isin(leakage_codes),
        ],
        [
            "Auxiliary leakage",
            "Combined leakage",
        ],
        default="Healthy"
    )

    df_reference["Source"] = 0

    # Aggregate delay and efficiency columns (as before)
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

    # Rename to canonical names
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

    # Encode label as 0/1/2 (Monorail stays NaN because it has no LeakageLabel)
    if "LeakageLabel" in df_combined.columns:
        df_combined.rename(columns={"LeakageLabel": "label"}, inplace=True)
        df_combined["label"] = df_combined["label"].map({
            "Healthy": 0,
            "Auxiliary leakage": 1,
            "Combined leakage": 2,
        })

    # Convert any remaining "xx sec" string columns to float
    for col in df_combined.select_dtypes(include="object"):
        try:
            df_combined[col] = df_combined[col].str.replace(" sec", "", regex=False).astype(float)
        except (AttributeError, ValueError):
            continue

    # WV bin
    df_combined["WV_bin"] = df_combined["WV_MeanPressure"].apply(
        lambda p: np.nan if pd.isna(p) else (0 if p < 2 else (2 if p > 3 else 1))
    )

    return df_combined.copy()


# ======================================================================
# STEP 2: Split (WV regime + labeled only for supervised training)
# ======================================================================

def split_supervised_dataset(df, features, test_size=0.2, random_state=42, label_col="label"):
    df = df.copy()

    # Regime filtering
    df = df.loc[df["WV_bin"].eq(1)].copy()

    # Supervised training requires labels (Monorail is NaN label)
    df = df.loc[df[label_col].notna()].copy()
    df[label_col] = df[label_col].astype(int)

    missing = [f for f in features if f not in df.columns]
    if missing:
        raise ValueError(f"Missing features: {missing}")

    X = df[features]  # keep as DataFrame (keeps feature names)
    y = df[label_col].values.astype(int)

    # Stratified split works for multiclass (as long as each class has enough samples)
    X_train, X_test, y_train, y_test = train_test_split(
        X, y,
        test_size=test_size,
        stratify=y,
        random_state=random_state
    )

    return X_train, X_test, y_train, y_test, df


# ======================================================================
# STEP 3: Healthy-only RNN cleaning (FunctionSampler)
# ======================================================================

def _rnn_clean_healthy_only(X, y, k=5):
    """
    Remove outliers from healthy class (y==0) only.
    Other classes are kept untouched.
    """
    X = np.asarray(X)
    y = np.asarray(y)

    healthy_mask = (y == 0)
    fault_mask = ~healthy_mask

    X_h = X[healthy_mask]
    y_h = y[healthy_mask]

    if len(X_h) == 0 or len(X_h) <= k:
        return X, y

    from sklearn.neighbors import NearestNeighbors

    n_h = len(X_h)
    reverse_neighbor_count = np.zeros(n_h, dtype=int)

    nbrs = NearestNeighbors(n_neighbors=min(k + 1, n_h))
    nbrs.fit(X_h)
    _, indices = nbrs.kneighbors(X_h)

    for neighbors in indices:
        for nb in neighbors[1:]:
            reverse_neighbor_count[nb] += 1

    keep_h = reverse_neighbor_count > 0

    X_h_clean = X_h[keep_h]
    y_h_clean = y_h[keep_h]

    X_res = np.vstack([X_h_clean, X[fault_mask]]) if X_h_clean.size else X[fault_mask]
    y_res = np.concatenate([y_h_clean, y[fault_mask]]) if y_h_clean.size else y[fault_mask]

    return X_res, y_res


def make_rnn_sampler(k=5):
    return FunctionSampler(func=_rnn_clean_healthy_only, kw_args={"k": k})


# ======================================================================
# STEP 4: Models + grids (same as binary)
# ======================================================================

def get_models_and_grids(random_state=42):
    models = {
        "RF (tuned)": RandomForestClassifier(random_state=random_state),
        "SVM (tuned)": SVC(kernel="rbf"),  # probability tuned via grid
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
        },
    }

    return models, grids


# ======================================================================
# STEP 5: CV-safe tuning pipeline (multiclass)
# ======================================================================

def tune_one_model(
    X_train,
    y_train,
    base_model,
    param_grid,
    *,
    oversampling_mode=2,          # 1=SMOTE, 2=ADASYN
    sampling_ratio="not majority",
    rnn_k=5,
    scoring="f1_macro",
    n_splits=3,
    random_state=42,
    verbose=1
):
    """
    GridSearchCV over an imblearn pipeline:
        imputer -> scaler -> RNN(healthy-only) -> oversampler -> classifier
    """
    y_train = np.asarray(y_train)

    classes, counts = np.unique(y_train, return_counts=True)
    min_count = counts.min()

    n_splits = min(int(n_splits), int(min_count))
    if n_splits < 2:
        raise ValueError(
            f"n_splits became {n_splits}. Need at least 2 samples per class. "
            f"Class distribution: {dict(zip(classes, counts))}"
        )
    n_repeats = 5  # or 10 if you can afford runtime
    cv = RepeatedStratifiedKFold(
        n_splits=n_splits,
        n_repeats=n_repeats,
        random_state=random_state
    )
    # cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=random_state)

    overs_name = "SMOTE" if oversampling_mode == 1 else "ADASYN"
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

    grid_prefixed = {f"clf__{k}": v for k, v in param_grid.items()}

    grid = GridSearchCV(
        estimator=pipe,
        param_grid=grid_prefixed,
        scoring=scoring,     # multiclass macro-F1
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
# STEP 6: Multiclass evaluation on split test set
# ======================================================================

def evaluate_on_test_multiclass(
    models_dict,
    X_test,
    y_test,
    labels=(0, 1, 2),
    target_names=("Healthy", "Aux leakage", "Combined leakage"),
    verbose_reports=True
):
    X_test = X_test  # keep DataFrame OK
    y_test = np.asarray(y_test)

    rows = []
    cms = {}

    for name, model in models_dict.items():
        y_pred = model.predict(X_test)

        cm = confusion_matrix(y_test, y_pred, labels=list(labels))
        cms[name] = cm

        macro_f1 = f1_score(y_test, y_pred, average="macro", zero_division=0)
        bal_acc = balanced_accuracy_score(y_test, y_pred)

        rows.append({
            "Model": name,
            "MacroF1": macro_f1,
            "BalancedAcc": bal_acc,
        })

        if verbose_reports:
            print("\n" + "=" * 70)
            print(f"{name} — classification report (multiclass split test)")
            print("=" * 70)
            print(classification_report(
                y_test, y_pred,
                labels=list(labels),
                target_names=list(target_names),
                zero_division=0
            ))
            print("Confusion matrix (rows=true, cols=pred):")
            print(cm)

    df = pd.DataFrame(rows).sort_values(
        by=["MacroF1", "BalancedAcc"],
        ascending=[False, False]
    ).reset_index(drop=True)

    return df, cms


# ======================================================================
# STEP 7: Saving (timestamp prefix + save both clf-only and pipeline)
# ======================================================================

def sanitize_name(s: str) -> str:
    return str(s).lower().replace(" ", "_").replace("(", "").replace(")", "")


def make_run_id() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def make_inference_pipeline(fitted_imb_pipeline):
    """
    Prediction-only pipeline (portable):
      imputer -> scaler -> clf
    """
    steps = fitted_imb_pipeline.named_steps
    return SkPipeline([
        ("imputer", steps["imputer"]),
        ("scaler", steps["scaler"]),
        ("clf", steps["clf"]),
    ])


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
      2) full training pipeline bundle (imputer+scaler+RNN+oversampler+clf)
      3) inference pipeline bundle (imputer+scaler+clf)  [recommended for deployment]
    """
    save_path = Path(save_dir)
    save_path.mkdir(parents=True, exist_ok=True)

    for model_name, fitted_pipe in tuned_models.items():
        base = sanitize_name(model_name)
        prefix = f"{run_id}_{experiment_tag}_"

        # Fix filename prefix line (typo-safe)
        clf_file = save_path / f"{prefix}{base}_clf.joblib"
        train_pipe_file = save_path / f"{prefix}{base}_training_pipeline.joblib"
        infer_pipe_file = save_path / f"{prefix}{base}_inference_pipeline.joblib"
        meta_file = save_path / f"{prefix}{base}_meta.json"

        # Extract parts
        if hasattr(fitted_pipe, "named_steps"):
            clf = fitted_pipe.named_steps.get("clf", None)
            imputer = fitted_pipe.named_steps.get("imputer", None)
            scaler = fitted_pipe.named_steps.get("scaler", None)
        else:
            clf, imputer, scaler = fitted_pipe, None, None

        infer_pipe = make_inference_pipeline(fitted_pipe)

        meta = dict(meta_base)
        meta.update({
            "model_name": model_name,
            "saved_at": datetime.now().isoformat(timespec="seconds"),
            "features": features,
            "artifacts": {
                "clf_bundle": clf_file.name,
                "training_pipeline": train_pipe_file.name,
                "inference_pipeline": infer_pipe_file.name,
            }
        })

        # 1) clf-only bundle
        joblib.dump(
            {"model": clf, "scaler": scaler, "imputer": imputer, "features": features, "meta": meta},
            clf_file
        )

        # 2) full training pipeline bundle
        joblib.dump(
            {"pipeline": fitted_pipe, "features": features, "meta": meta},
            train_pipe_file
        )

        # 3) inference pipeline bundle (portable)
        joblib.dump(
            {"pipeline": infer_pipe, "features": features, "meta": meta},
            infer_pipe_file
        )

        with open(meta_file, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)

        print(f"[SAVED] {model_name}")
        print(f"  - clf bundle:           {clf_file.name}")
        print(f"  - training pipeline:    {train_pipe_file.name}")
        print(f"  - inference pipeline:   {infer_pipe_file.name}")
        print(f"  - meta json:            {meta_file.name}\n")


# ======================================================================
# MAIN
# ======================================================================

def main():
    # -------------------------
    # User configuration
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

    # Multiclass-safe sampling strategy
    sampling_ratio = "not majority"

    # RNN
    rnn_k = 5

    # GridSearchCV config
    scoring = "f1_macro"
    n_splits = 3
    verbose = 1

    # Saving
    SAVE_DIR = paths.models_dir
    EXPERIMENT_TAG = "feat2_multiclass"

    # Class map for metadata/reporting
    class_map = {
        "0": "Healthy",
        "1": "Auxiliary leakage (A,B)",
        "2": "Combined leakage (C–G)",
    }

    # -------------------------
    # 1) Load
    # -------------------------
    df = load_data(model_path, monorail_paths)
    print(f"Loaded combined df: {df.shape}")
    print("DataSource counts:", df["DataSource"].value_counts(dropna=False).to_dict())

    # -------------------------
    # 2) Split supervised dataset (WV_bin==1 & labeled only)
    # -------------------------
    X_train, X_test, y_train, y_test, df_used = split_supervised_dataset(
        df, selected_features, test_size=test_size, random_state=random_state, label_col="label"
    )

    print("\nSplit summary (WV_bin==1 & labeled rows only):")
    cls, cnt = np.unique(y_train, return_counts=True)
    print("  Train dist:", dict(zip(cls, cnt)))
    cls, cnt = np.unique(y_test, return_counts=True)
    print("  Test  dist:", dict(zip(cls, cnt)))

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
    # 4) Evaluate on split test set (multiclass)
    # -------------------------
    print("\n" + "=" * 80)
    print("EVALUATION ON SPLIT TEST SET (MULTICLASS)")
    print("=" * 80)

    eval_df, cms = evaluate_on_test_multiclass(
        tuned_models,
        X_test,
        y_test,
        labels=(0, 1, 2),
        target_names=(class_map["0"], class_map["1"], class_map["2"]),
        verbose_reports=True
    )

    print("\nSummary (sorted by MacroF1, BalancedAcc):")
    print(eval_df)

    # -------------------------
    # 5) Save artifacts
    # -------------------------
    run_id = make_run_id()

    meta_base = {
        "run_id": run_id,
        "experiment_tag": EXPERIMENT_TAG,
        "problem_type": "multiclass_3",
        "class_map": class_map,
        "wv_bin": 1,
        "test_size": test_size,
        "random_state": random_state,
        "oversampling_mode": oversampling_mode,
        "oversampling_mode_name": ("SMOTE" if oversampling_mode == 1 else "ADASYN"),
        "sampling_strategy": sampling_ratio,
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

    # Save evaluation table
    eval_csv = Path(SAVE_DIR) / f"{run_id}_{EXPERIMENT_TAG}_split_test_summary.csv"
    eval_df.to_csv(eval_csv, index=False)
    print(f"[SAVED] Split-test summary table: {eval_csv.name}")


if __name__ == "__main__":
    main()
