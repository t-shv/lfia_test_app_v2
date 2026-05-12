import pandas as pd
from sklearn.metrics import (
    confusion_matrix,
    ConfusionMatrixDisplay,
    accuracy_score,
    precision_score,
    recall_score,
)
import matplotlib.pyplot as plt

def load_and_flatten(path, pos_sheet, neg_sheet, pos_rows=None):
    """
    Grab the positive & negative sheets, keep only the first `pos_rows`
    of the positive sheet if specified, normalise labels to uppercase,
    flatten five predictions per strip, and return y_true / y_pred lists.
    """
    df_pos = pd.read_excel(path, sheet_name=pos_sheet)
    df_neg = pd.read_excel(path, sheet_name=neg_sheet)

    if pos_rows is not None:
        df_pos = df_pos.iloc[:pos_rows]

    # make everything uppercase so we get a 2×2 matrix
    for df in (df_pos, df_neg):
        df.iloc[:, 2] = df.iloc[:, 2].astype(str).str.upper().str.strip()
        df.iloc[:, 3:8] = (
            df.iloc[:, 3:8]
              .astype(str)
              .applymap(lambda x: x.upper().strip())
        )

    y_true, y_pred = [], []
    for df in (df_pos, df_neg):
        true_labels = df.iloc[:, 2].tolist()
        preds = df.iloc[:, 3:8]
        for i, row in preds.iterrows():
            y_true.extend([true_labels[i]] * len(row))
            y_pred.extend(row.tolist())

    return y_true, y_pred


def plot_cm_and_metrics(y_true, y_pred, title, outfile):
    labels = ["N", "P"]
    cm = confusion_matrix(y_true, y_pred, labels=labels)

    # heat‑map
    disp = ConfusionMatrixDisplay(cm, display_labels=labels)
    fig, ax = plt.subplots(figsize=(6, 6))
    disp.plot(ax=ax, cmap=plt.cm.Blues, colorbar=True)
    ax.set_title(title)
    plt.tight_layout()
    plt.savefig(outfile, dpi=300)
    plt.close(fig)

    # metrics
    acc  = accuracy_score(y_true, y_pred)
    prec = precision_score(y_true, y_pred, pos_label="P")
    rec  = recall_score(y_true, y_pred, pos_label="P")
    print(f"\n{title}")
    print(f"  Accuracy : {acc*100:5.2f}%")
    print(f"  Precision: {prec*100:5.2f}% (P positive)")
    print(f"  Recall   : {rec*100:5.2f}% (P positive)")
    print(f"  Saved PNG: {outfile}")


if __name__ == "__main__":
    wb = r"C:\dev\LFIA Positive Strip Validation.xlsx"

    # 1) No‑flash (rows ≤ 37)
    y_nf37_t, y_nf37_p = load_and_flatten(
        wb, "Pos_NoFlash", "Neg_NoFlash", pos_rows=37
    )
    plot_cm_and_metrics(
        y_nf37_t, y_nf37_p,
        title="No-Flash Confusion Matrix",
        outfile="confusion_no_flash.png"
    )

    # 2) Flash (rows ≤ 37)
    y_f37_t, y_f37_p = load_and_flatten(
        wb, "Pos_Flash", "Neg_Flash", pos_rows=37
    )
    plot_cm_and_metrics(
        y_f37_t, y_f37_p,
        title="Flash Confusion Matrix",
        outfile="confusion_flash.png"
    )

    # 3) No‑flash incl. testing 125 ng/mL (rows ≤ 47)
    y_nf47_t, y_nf47_p = load_and_flatten(
        wb, "Pos_NoFlash", "Neg_NoFlash", pos_rows=47
    )
    plot_cm_and_metrics(
        y_nf47_t, y_nf47_p,
        title="No-Flash Including Testing 125 ng/mL",
        outfile="confusion_no_flash_125ng.png"
    )

    # 4) 125-model (rows ≤ 47)
    y_125_t, y_125_p = load_and_flatten(
        wb, "Pos_noflash_125model", "Neg_NoFlash_125model", pos_rows=47
    )
    plot_cm_and_metrics(
        y_125_t, y_125_p,
        title="No-Flash 125-Model Confusion Matrix",
        outfile="confusion_no_flash_125model.png"
    )
