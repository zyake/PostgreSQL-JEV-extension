#!/usr/bin/env python3
"""Plot measured medians and min/max ranges; requires matplotlib."""

import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    args = parser.parse_args()
    cases = {item["case"]["name"]: item for item in json.loads((args.results / "summary.json").read_text())}
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "axes.spines.left": False, "axes.edgecolor": "#CBD5E1",
                         "text.color": "#172B4D", "axes.labelcolor": "#334155",
                         "xtick.color": "#475569", "ytick.color": "#334155"})
    fig, axes = plt.subplots(1, 2, figsize=(14, 6.8))
    fig.patch.set_facecolor("#FFFFFF")
    colors = {"scalar": "#94A3B8", "batch_128": "#127D8A"}
    panels = [
        (axes[0], "Executor only · 8,192 rows", [
            ("kernel_unique_all", "Unique inputs"),
            ("kernel_clustered_all", "Duplicates nearby"),
            ("kernel_interleaved_all", "Duplicates spread out"),
            ("kernel_unique_10pct", "Filter keeps ~10%")], 1, "Query execution time (ms)"),
        (axes[1], "Local embedding model · 128 rows", [
            ("ollama_unique_all", "Unique inputs"),
            ("ollama_clustered_all", "Duplicates nearby"),
            ("ollama_unique_25pct", "Filter keeps 25%")], 1000, "Query execution time (seconds)"),
    ]
    for axis, title, groups, divisor, xlabel in panels:
        maximum = max(r["max_ms"] / divisor for key, _ in groups for r in cases[key]["results"]
                      if r["mode"] in colors)
        for index, (key, _) in enumerate(groups):
            records = {r["mode"]: r for r in cases[key]["results"]}
            for mode, offset in [("scalar", -0.18), ("batch_128", 0.18)]:
                r = records[mode]
                median = r["median_ms"] / divisor
                low, high = r["min_ms"] / divisor, r["max_ms"] / divisor
                axis.barh(index + offset, median, height=0.28, color=colors[mode],
                          xerr=[[median-low], [high-median]], capsize=3,
                          error_kw={"elinewidth": 1, "ecolor": "#334155"})
                label = f"{median:.1f}" if divisor == 1 else f"{median:.3f}"
                axis.text(high + maximum*0.025, index + offset, label, va="center", fontsize=10)
        axis.set_yticks(range(len(groups)), [label for _, label in groups])
        axis.invert_yaxis()
        axis.set_xlim(0, maximum*1.21)
        axis.set_title(title, loc="left", fontsize=13, fontweight="bold", pad=20)
        axis.set_xlabel(xlabel, labelpad=12)
        axis.tick_params(axis="y", length=0)
        axis.xaxis.grid(True, color="#E2E8F0", linewidth=0.8)
        axis.set_axisbelow(True)
    fig.suptitle("Batching reduces query time in the current extension", x=0.07, ha="left",
                 y=0.98, fontsize=20, fontweight="bold")
    fig.text(0.07, 0.915, "Apple M5 · PostgreSQL 17.10 · Ollama all-minilm:22m · warm runs", fontsize=11)
    fig.legend(handles=[Patch(color=colors["scalar"], label="Scalar semantic_match"),
                        Patch(color=colors["batch_128"], label="CustomScan · batch size 128")],
               loc="lower left", bbox_to_anchor=(0.062, 0.058), ncols=2, frameon=False)
    fig.text(0.07, 0.033, "Median shown; whiskers are observed min–max. 5 executor trials / 3 model trials. "
             "All compared result bags matched.", fontsize=10, color="#475569")
    fig.subplots_adjust(left=0.18, right=0.965, top=0.82, bottom=0.22, wspace=0.73)
    fig.savefig(args.results / "performance.png", dpi=180, facecolor="white")
    fig.savefig(args.results / "performance.svg", facecolor="white")


if __name__ == "__main__":
    main()
