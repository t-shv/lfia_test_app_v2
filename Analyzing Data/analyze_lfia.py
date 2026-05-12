from pathlib import Path
import re

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# --------------------------------------------------
# 1. CONFIG
# --------------------------------------------------
XLSX_FILE = "LFIA Positive Strip Validation.xlsx"
POS_CONC = [1000, 500, 250, 125]          # ng/mL groups to keep

# Workbook layout: (positive sheet, negative sheet)
SHEETS = {
    "No‑flash":      ("Pos_NoFlash",           "Neg_NoFlash"),
    "Flash":         ("Pos_Flash",             "Neg_Flash"),
    "No‑flash‑125":  ("Pos_NoFlash_125model",  "Neg_NoFlash_125model"),
}

OUT_DIR = Path(".")
PRED_PREFIX = "prediction"                 # header prefix for photo columns
# --------------------------------------------------


def load_and_melt(sheet: str, condition: str, pos_or_neg: str) -> pd.DataFrame:
    """Return a long‑format DF for one sheet."""
    df = pd.read_excel(XLSX_FILE, sheet_name=sheet, engine="openpyxl")
    df.columns = df.columns.str.strip().str.replace("\n", " ")

    df = df.rename(columns={df.columns[0]: "strip_id",
                            df.columns[1]: "concentration",
                            df.columns[2]: "truth"})

    pred_cols = [c for c in df.columns if str(c).lower().startswith(PRED_PREFIX)]
    if not pred_cols:
        raise ValueError(f"No prediction columns in sheet '{sheet}'.")

    # order Prediction1, Prediction 2, …
    pred_cols.sort(key=lambda c: int(re.search(r"(\d+)", str(c)).group(1)))

    df_long = df.melt(id_vars=["strip_id", "concentration", "truth"],
                      value_vars=pred_cols,
                      var_name="photo_idx",
                      value_name="pred")
    df_long["condition"] = condition
    df_long["set"] = pos_or_neg
    return df_long


def preprocess() -> pd.DataFrame:
    """Load all six sheets, clean, filter."""
    frames = []
    for cond, (pos_s, neg_s) in SHEETS.items():
        frames.append(load_and_melt(pos_s, cond, "pos"))
        frames.append(load_and_melt(neg_s, cond, "neg"))

    data = pd.concat(frames, ignore_index=True)
    data = data[data["pred"].isin(["p", "n"])]
    data = data[
        (data["truth"].isin(["P", "N"])) &
        ((data["truth"] == "N") | data["concentration"].isin(POS_CONC))
    ]
    return data


def compute_metrics(df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for cond, grp in df.groupby("condition"):
        neg = grp[grp["truth"] == "N"]
        fp, tn = (neg["pred"] == "p").sum(), (neg["pred"] == "n").sum()

        for conc in POS_CONC:
            pos = grp[(grp["truth"] == "P") & (grp["concentration"] == conc)]
            tp, fn = (pos["pred"] == "p").sum(), (pos["pred"] == "n").sum()

            recall = tp / (tp + fn) if tp + fn else np.nan
            precision = tp / (tp + fp) if tp + fp else np.nan
            accuracy = (tp + tn) / (tp + fn + fp + tn) if (tp + fn + fp + tn) else np.nan
            specificity = tn / (tn + fp) if tn + fp else np.nan
            f1 = 2 * precision * recall / (precision + recall) if precision and recall else np.nan
            error_rate = fn / (tp + fn) if tp + fn else np.nan

            rows.append({
                "condition": cond,
                "concentration": conc,
                "TP": tp, "FN": fn, "FP": fp, "TN": tn,
                "recall": recall,
                "precision": precision,
                "accuracy": accuracy,
                "specificity": specificity,
                "f1": f1,
                "error_rate": error_rate,
            })
    return pd.DataFrame(rows)


# ---------------------- plotting helpers ----------------------
def plot_main(metrics: pd.DataFrame) -> None:
    """Recall · Accuracy · Precision vs concentration (3 panels)."""
    fig, axes = plt.subplots(1, 3, figsize=(13, 4), sharey=True)
    for ax, (cond, sub) in zip(axes, metrics.groupby("condition")):
        sub = sub.sort_values("concentration")
        x = sub["concentration"]

        ax.plot(x, sub["recall"],     marker="o", label="Recall")
        ax.plot(x, sub["accuracy"],   marker="^", label="Accuracy")
        ax.plot(x, sub["precision"],  marker="d", linestyle="--", alpha=0.6, label="Precision")

        ax.set_title(cond)
        ax.set_xlabel("Concentration (ng/mL)")
        ax.set_xticks(x)
        ax.grid(True, alpha=0.3)

    axes[0].set_ylabel("Score")
    axes[0].legend(loc="lower left", fontsize=8)
    fig.tight_layout()
    fp = OUT_DIR / "main_metrics.png"
    fig.savefig(fp, dpi=300)
    print(f"Saved → {fp}")


def plot_f1_only(metrics: pd.DataFrame) -> None:
    """Three‑panel F1 vs concentration."""
    fig, axes = plt.subplots(1, 3, figsize=(13, 4), sharey=True)
    for ax, (cond, sub) in zip(axes, metrics.groupby("condition")):
        sub = sub.sort_values("concentration")
        ax.plot(sub["concentration"], sub["f1"], marker="s", color="#ff7f0e")
        ax.set_title(cond)
        ax.set_xlabel("Concentration (ng/mL)")
        ax.set_xticks(POS_CONC)
        ax.grid(True, alpha=0.3)

    axes[0].set_ylabel("F1 score")
    fig.tight_layout()
    fp = OUT_DIR / "f1_scores.png"
    fig.savefig(fp, dpi=300)
    print(f"Saved → {fp}")


def plot_error_scatter(metrics: pd.DataFrame) -> None:
    fig, axes = plt.subplots(1, 3, figsize=(13, 4), sharey=True)
    for ax, (cond, sub) in zip(axes, metrics.groupby("condition")):
        ax.scatter(sub["concentration"], sub["error_rate"] * 100, s=60)
        ax.set_title(cond)
        ax.set_xlabel("Concentration (ng/mL)")
        ax.set_xticks(POS_CONC)
        ax.grid(True, alpha=0.3)

    axes[0].set_ylabel("Error rate (%)")
    fig.tight_layout()
    fp = OUT_DIR / "error_rate_scatter.png"
    fig.savefig(fp, dpi=300)
    print(f"Saved → {fp}")


def plot_two_condition_comparison(metrics: pd.DataFrame) -> None:
    compare = ["No‑flash", "No‑flash‑125"]
    metric_names = {"accuracy": "Accuracy", "recall": "Recall",
                    "f1": "F1 score", "precision": "Precision"}

    sub = metrics[metrics["condition"].isin(compare)]
    for key, nice in metric_names.items():
        fig, ax = plt.subplots(figsize=(5, 4))
        for cond in compare:
            s = sub[sub["condition"] == cond].sort_values("concentration")
            ax.plot(s["concentration"], s[key], marker="o", label=cond)
        ax.set_xlabel("Concentration (ng/mL)")
        ax.set_ylabel(nice)
        ax.set_title(f"{nice} vs concentration")
        ax.set_xticks(POS_CONC)
        ax.grid(True, alpha=0.3)
        ax.legend()
        fp = OUT_DIR / f"compare_{key}.png"
        fig.tight_layout()
        fig.savefig(fp, dpi=300)
        print(f"Saved → {fp}")


# --------------------------- main -----------------------------
def main() -> None:
    df = preprocess()
    metrics = compute_metrics(df)

    metrics.to_csv(OUT_DIR / "metrics_by_concentration.csv", index=False)
    print("Saved → metrics_by_concentration.csv")

    plot_main(metrics)
    plot_f1_only(metrics)
    plot_error_scatter(metrics)
    plot_two_condition_comparison(metrics)


if __name__ == "__main__":
    main()
