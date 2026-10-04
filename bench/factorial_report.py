#!/usr/bin/env python3
"""Summarize a recorded seven-switch factorial benchmark; never runs SQL.

The feature effects compare round-paired OFF/ON times in each of the 64
otherwise identical switch settings. Their geometric mean describes this particular
workload and configuration grid; it is not a universal speedup or a confidence
interval. All measurements come from summary.json, with metadata.json optional.
"""

import argparse
import csv
import itertools
import json
import math
import statistics
from pathlib import Path


FLAGS = [
    "enable_batching",
    "enable_deduplication",
    "enable_result_cache",
    "enable_relational_prefilter",
    "reuse_kernel_plan",
    "enable_join_reduction",
    "enable_selective_fallback",
]
SHORT = ["B", "D", "C", "P", "R", "J", "F"]
LABELS = [
    "Batching", "Deduplication", "Scan cache", "Relational prefilter",
    "Kernel plan reuse", "Join reduction", "Selective fallback",
]


def bit_string(mask):
    """The first character represents bit zero, matching FLAGS order."""
    return "".join(str((mask >> bit) & 1) for bit in range(len(FLAGS)))


def geometric_mean(values):
    return math.exp(statistics.fmean(math.log(value) for value in values))


def ratio_summary(values):
    values = sorted(values)
    # Interpolated empirical quantiles, also valid for small input sets.
    def quantile(fraction):
        position = fraction * (len(values) - 1)
        low = math.floor(position)
        high = math.ceil(position)
        return values[low] + (values[high] - values[low]) * (position - low)

    return {
        "contexts": len(values),
        "geometric_mean_off_over_on": geometric_mean(values),
        "median_off_over_on": statistics.median(values),
        "min_off_over_on": values[0],
        "max_off_over_on": values[-1],
        "p25_off_over_on": quantile(0.25),
        "p75_off_over_on": quantile(0.75),
        "contexts_on_faster": sum(value > 1 for value in values),
        "contexts_on_slower": sum(value < 1 for value in values),
        "contexts_equal": sum(value == 1 for value in values),
    }


def read_results(directory):
    data = json.loads((directory / "summary.json").read_text())
    if not isinstance(data, list) or len(data) != 128:
        raise ValueError("summary.json must contain all 128 configurations")
    by_mask = {}
    sample_count = None
    result_rows = None
    for row in data:
        mask = row["mask"]
        if type(mask) is not int or not 0 <= mask < 128 or mask in by_mask:
            raise ValueError(f"invalid or duplicate mask: {mask!r}")
        if row["bits"] != bit_string(mask):
            raise ValueError(f"bits disagree with mask {mask}")
        for index, flag in enumerate(FLAGS):
            if row["settings"].get(flag) is not bool(mask & (1 << index)):
                raise ValueError(f"settings disagree with mask {mask}: {flag}")
        samples = row["samples_ms"]
        if not samples or any(not math.isfinite(v) or v <= 0 for v in samples):
            raise ValueError(f"invalid elapsed samples for mask {mask}")
        if sample_count is None:
            sample_count = len(samples)
        if len(samples) != sample_count:
            raise ValueError("all configurations must have the same trial count")
        expected = {
            "median_ms": statistics.median(samples),
            "min_ms": min(samples),
            "max_ms": max(samples),
        }
        for key, value in expected.items():
            if not math.isclose(row[key], value, rel_tol=1e-5, abs_tol=1e-6):
                raise ValueError(f"{key} does not match samples for mask {mask}")
        for stage in ("reduction", "semantic", "join"):
            value = row["median_stage_ms"][stage]
            if not math.isfinite(value) or value < 0:
                raise ValueError(f"invalid stage time for mask {mask}: {stage}")
        if result_rows is None:
            result_rows = row["result_rows"]
        if row["result_rows"] != result_rows:
            raise ValueError("configurations returned different result row counts")
        by_mask[mask] = row
    metadata_path = directory / "metadata.json"
    metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else {}
    if "flags" in metadata and metadata["flags"] != FLAGS:
        raise ValueError("metadata flags do not match this report's bit order")
    return by_mask, metadata


def compact(row):
    return {key: row[key] for key in (
        "mask", "bits", "settings", "median_ms", "min_ms", "max_ms",
        "median_stage_ms", "work", "result_rows",
    )}


def matched_effect(by_mask, bit, condition=None):
    pairs = []
    for off_mask in range(128):
        if off_mask & (1 << bit):
            continue
        if condition is not None:
            other_bit, enabled = condition
            if bool(off_mask & (1 << other_bit)) != enabled:
                continue
        on_mask = off_mask | (1 << bit)
        off = by_mask[off_mask]
        on = by_mask[on_mask]
        round_ratios = [left / right for left, right in zip(off["samples_ms"], on["samples_ms"])]
        pairs.append({
            "off_mask": off_mask,
            "on_mask": on_mask,
            "off_ms": off["median_ms"],
            "on_ms": on["median_ms"],
            "off_over_on": off["median_ms"] / on["median_ms"],
            "paired_round_off_over_on": round_ratios,
            "paired_round_geometric_mean_off_over_on": geometric_mean(round_ratios),
        })
    return {
        **ratio_summary([pair["paired_round_geometric_mean_off_over_on"] for pair in pairs]),
        "paired_trial_comparisons": sum(len(pair["paired_round_off_over_on"]) for pair in pairs),
        "ratio_of_medians_effect": ratio_summary([pair["off_over_on"] for pair in pairs]),
        "pairs": pairs,
    }


def analyze(by_mask):
    ranked = sorted(by_mask.values(), key=lambda row: (row["median_ms"], row["mask"]))
    rank_by_mask = {row["mask"]: rank for rank, row in enumerate(ranked, 1)}
    effects = []
    one_off = []
    one_on = []
    for bit, flag in enumerate(FLAGS):
        effects.append({"flag": flag, "label": LABELS[bit], **matched_effect(by_mask, bit)})
        disabled = by_mask[127 ^ (1 << bit)]
        enabled = by_mask[1 << bit]
        one_off.append({
            "disabled_flag": flag,
            "configuration": compact(disabled),
            "off_over_all_on": disabled["median_ms"] / by_mask[127]["median_ms"],
        })
        one_on.append({
            "enabled_flag": flag,
            "configuration": compact(enabled),
            "all_off_over_on": by_mask[0]["median_ms"] / enabled["median_ms"],
        })
    conditional = {}
    for flag_bit, other_bit in ((0, 2), (2, 0)):
        for enabled in (False, True):
            key = f"{FLAGS[flag_bit]}_when_{FLAGS[other_bit]}_{'on' if enabled else 'off'}"
            conditional[key] = {
                "flag": FLAGS[flag_bit], "condition_flag": FLAGS[other_bit],
                "condition_enabled": enabled,
                **matched_effect(by_mask, flag_bit, (other_bit, enabled)),
            }
    return {
        "method": {
            "flags_in_bit_order": FLAGS,
            "bit_string_order": "leftmost character is bit 0 (batching)",
            "configurations": 128,
            "trials_per_configuration": len(by_mask[0]["samples_ms"]),
            "timing": "end-to-end sum of reduction/copy/analyze, semantic CTAS, and final join; validation excluded",
            "feature_effect": "geometric mean of round-paired OFF/ON times across 64 otherwise identical configurations and all rounds",
            "context_range": "min/max and quartiles of each context's geometric mean across paired rounds",
            "secondary_effect": "ratio_of_medians_effect separately summarizes median(OFF)/median(ON)",
            "ratio_direction": "greater than 1 means ON was faster",
            "ranges": "observed min/max across contexts, not confidence intervals",
            "limitations": "single fixed workload; deterministic providers with synthetic confidence; no network or real LLM; feature effects are not additive",
        },
        "all_off": {**compact(by_mask[0]), "rank": rank_by_mask[0]},
        "all_on": {**compact(by_mask[127]), "rank": rank_by_mask[127]},
        "all_off_over_all_on": by_mask[0]["median_ms"] / by_mask[127]["median_ms"],
        "all_off_over_all_on_paired_geometric_mean": geometric_mean([
            left / right for left, right in zip(by_mask[0]["samples_ms"], by_mask[127]["samples_ms"])
        ]),
        "normalized_elapsed_by_round": [
            {
                "round": index + 1,
                "geometric_mean_elapsed_over_configuration_median": geometric_mean([
                    row["samples_ms"][index] / row["median_ms"] for row in by_mask.values()
                ]),
            }
            for index in range(len(by_mask[0]["samples_ms"]))
        ],
        "fastest": compact(ranked[0]),
        "slowest": compact(ranked[-1]),
        "fastest_10": [compact(row) for row in ranked[:10]],
        "slowest_10": [compact(row) for row in reversed(ranked[-10:])],
        "rankings": [{"rank": rank_by_mask[row["mask"]], **compact(row)} for row in ranked],
        "one_disabled_from_all_on": one_off,
        "one_enabled_from_all_off": one_on,
        "feature_effects": effects,
        "conditional_batching_cache_effects": conditional,
    }


def write_csv(directory, by_mask, analysis):
    work_keys = sorted({key for row in by_mask.values() for key in row["work"]})
    repeats = len(by_mask[0]["samples_ms"])
    fields = ["mask", "bits", "rank", *FLAGS, "median_ms", "min_ms", "max_ms",
              "reduction_ms", "semantic_ms", "join_ms", "result_rows",
              *work_keys, *[f"round_{i + 1}_ms" for i in range(repeats)]]
    ranks = {row["mask"]: row["rank"] for row in analysis["rankings"]}
    with (directory / "all_combinations.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for mask, row in sorted(by_mask.items()):
            output = {key: row[key] for key in (
                "mask", "bits", "median_ms", "min_ms", "max_ms", "result_rows",
            )}
            output.update({flag: int(row["settings"][flag]) for flag in FLAGS})
            output.update({f"{stage}_ms": value for stage, value in row["median_stage_ms"].items()})
            output.update(row["work"])
            output.update({f"round_{i + 1}_ms": value for i, value in enumerate(row["samples_ms"])})
            output["rank"] = ranks[mask]
            writer.writerow(output)


def draw_figures(directory, by_mask, metadata, analysis):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import LogNorm
    from matplotlib.patches import Rectangle
    from matplotlib.ticker import FuncFormatter, LogLocator, NullFormatter, NullLocator

    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 11,
        "axes.spines.top": False, "axes.spines.right": False,
        "figure.facecolor": "#f6f8fb", "axes.facecolor": "#f6f8fb",
        "text.color": "#152b42", "axes.labelcolor": "#152b42",
        "xtick.color": "#152b42", "ytick.color": "#152b42",
    })
    row_bits = list(itertools.product((0, 1), repeat=3))
    column_bits = list(itertools.product((0, 1), repeat=4))
    masks = [[sum(value << bit for bit, value in enumerate(row + col))
              for col in column_bits] for row in row_bits]
    values = [[by_mask[mask]["median_ms"] for mask in row] for row in masks]
    flat = [value for row in values for value in row]
    vmin, vmax = min(flat), max(flat)
    # A degenerate run is still renderable, without pretending to have variation.
    norm = LogNorm(vmin=vmin if vmin < vmax else vmin / 1.001,
                   vmax=vmax if vmin < vmax else vmax * 1.001)
    cmap = plt.get_cmap("viridis_r")
    fig, ax = plt.subplots(figsize=(20, 11))
    fig.subplots_adjust(left=0.115, right=0.92, bottom=0.21, top=0.76)
    view = ax.imshow(values, cmap=cmap, norm=norm, aspect="auto")
    ax.set_xticks(range(16), [f"P{p} R{r}\nJ{j} F{f}" for p, r, j, f in column_bits])
    ax.set_yticks(range(8), [f"B{b}  D{d}  C{c}" for b, d, c in row_bits])
    ax.xaxis.tick_top()
    ax.tick_params(axis="both", which="both", length=0, pad=10)
    ax.set_xticks([i - 0.5 for i in range(17)], minor=True)
    ax.set_yticks([i - 0.5 for i in range(9)], minor=True)
    ax.grid(which="minor", color="white", linewidth=1.3)
    for y, row in enumerate(masks):
        for x, mask in enumerate(row):
            value = by_mask[mask]["median_ms"]
            rgba = cmap(norm(value))
            luminance = 0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2]
            color = "#12283d" if luminance > 0.48 else "white"
            ax.text(x, y - 0.10, f"{value:.2f}" if value < 100 else f"{value:.1f}",
                    ha="center", va="center", color=color, fontsize=10, fontweight="bold")
            label = "ALL OFF" if mask == 0 else "ALL ON" if mask == 127 else f"#{mask:03d}"
            ax.text(x, y + 0.19, label, ha="center", va="center", color=color, fontsize=8)
            if mask in (0, 127):
                ax.add_patch(Rectangle((x - 0.46, y - 0.44), 0.92, 0.88,
                                       fill=False, edgecolor="#ffb74d", linewidth=2.5))
    bar = fig.colorbar(view, ax=ax, fraction=0.025, pad=0.018)
    bar.set_label("Median milliseconds · log color scale", labelpad=14)
    bar.set_ticks([math.exp(math.log(vmin) + step * (math.log(vmax) - math.log(vmin)) / 4) for step in range(5)])
    bar.ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:.3g}"))
    bar.ax.yaxis.set_minor_locator(NullLocator())
    fig.text(0.04, 0.95, "Every combination of the seven optimization switches", fontsize=23, weight="bold")
    repeats = len(by_mask[0]["samples_ms"])
    rows = metadata.get("rows", metadata.get("row_count"))
    workload = f"{rows:,} input rows · " if isinstance(rows, int) else ""
    fig.text(0.04, 0.905, f"128 configurations · {workload}{repeats} trials each · same workload · median elapsed time (lower is better)", fontsize=13)
    fig.text(0.04, 0.855, "1 = ON   0 = OFF     B batching   D deduplication   C scan cache", fontsize=12)
    fig.text(0.04, 0.82, "P relational prefilter   R kernel plan reuse   J join reduction   F selective fallback", fontsize=12)
    off, on = by_mask[0]["median_ms"], by_mask[127]["median_ms"]
    fastest = analysis["fastest"]
    fig.text(0.115, 0.155,
             f"All OFF: {off:.2f} ms     All ON: {on:.2f} ms     OFF / ON: {off / on:.2f}×     "
             f"Fastest observed: #{fastest['mask']:03d}, {fastest['median_ms']:.2f} ms", fontsize=13, weight="bold")
    fig.text(0.115, 0.102, "Times include copying/analyzing/reducing candidates, semantic result materialization, and the final join.\n"
             "Correctness checks run after timing. Each # identifies the complete settings in all_combinations.csv.", fontsize=11, linespacing=1.6)
    fig.text(0.115, 0.041, "Deterministic providers with synthetic confidence; no network or real LLM. One workload: effects depend on data and provider cost.", fontsize=10)
    for suffix in ("png", "svg"):
        fig.savefig(directory / f"factorial_matrix.{suffix}", dpi=160, bbox_inches="tight")
    plt.close(fig)

    effects = analysis["feature_effects"]
    fig, ax = plt.subplots(figsize=(12.6, 7.9))
    fig.subplots_adjust(left=0.205, right=0.78, top=0.76, bottom=0.31)
    ax.axvline(1, color="#63788d", linewidth=1.4, linestyle="--")
    for y, effect in enumerate(effects):
        low, high = effect["min_off_over_on"], effect["max_off_over_on"]
        q1, q3 = effect["p25_off_over_on"], effect["p75_off_over_on"]
        mean = effect["geometric_mean_off_over_on"]
        color = "#137b68" if mean >= 1 else "#ab5f16"
        ax.plot([low, high], [y, y], color="#a7b8c5", linewidth=2, zorder=1)
        ax.plot([q1, q3], [y, y], color=color, linewidth=7, alpha=0.28, solid_capstyle="round", zorder=2)
        ax.plot(mean, y, "o", color=color, markersize=9, zorder=3)
        ax.text(1.035, y, f"{mean:.2f}×", transform=ax.get_yaxis_transform(), va="center", weight="bold", fontsize=12)
        ax.text(1.18, y, f"{effect['contexts_on_faster']}/64", transform=ax.get_yaxis_transform(), va="center", fontsize=11)
    ax.set_yticks(range(7), LABELS)
    ax.invert_yaxis()
    ax.set_ylim(6.6, -0.6)
    ax.set_xscale("log")
    ax.xaxis.set_major_locator(LogLocator(base=10, subs=(1, 2, 5)))
    ax.xaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:g}×"))
    ax.xaxis.set_minor_formatter(NullFormatter())
    ax.grid(axis="x", color="#cbd5df", alpha=0.5)
    ax.set_xlabel("OFF / ON elapsed time — greater than 1 means ON was faster", labelpad=12)
    ax.text(1.035, 1.06, "Geo. mean", transform=ax.transAxes, fontsize=10)
    ax.text(1.18, 1.06, "ON faster", transform=ax.transAxes, fontsize=10)
    fig.text(0.045, 0.945, "How each switch behaves across the other 64 settings", fontsize=21, weight="bold")
    fig.text(0.045, 0.887, "OFF and ON are paired within each trial round; the other six switch settings stay identical.", fontsize=12)
    fig.text(0.045, 0.841, "Dot = geometric mean of all paired ratios   Segments = middle 50% / full range of context means", fontsize=11)
    conditional = analysis["conditional_batching_cache_effects"]
    batch_off = conditional["enable_batching_when_enable_result_cache_off"]["geometric_mean_off_over_on"]
    batch_on = conditional["enable_batching_when_enable_result_cache_on"]["geometric_mean_off_over_on"]
    cache_off = conditional["enable_result_cache_when_enable_batching_off"]["geometric_mean_off_over_on"]
    cache_on = conditional["enable_result_cache_when_enable_batching_on"]["geometric_mean_off_over_on"]
    fig.text(0.205, 0.14, f"Batching effect: cache OFF {batch_off:.2f}× · cache ON {batch_on:.2f}×\n"
             f"Cache effect: batching OFF {cache_off:.2f}× · batching ON {cache_on:.2f}×", fontsize=11, linespacing=1.7)
    fig.text(0.045, 0.045, "Ranges describe different switch contexts, not confidence intervals. Each context uses the geometric mean of paired rounds.\n"
             "One workload with deterministic providers and synthetic confidence; these effects cannot be added or multiplied together.", fontsize=10, linespacing=1.6)
    for suffix in ("png", "svg"):
        fig.savefig(directory / f"factorial_effects.{suffix}", dpi=180, bbox_inches="tight")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    parser.add_argument("--no-plots", action="store_true", help="write analysis and CSV without importing matplotlib")
    args = parser.parse_args()
    by_mask, metadata = read_results(args.results)
    analysis = analyze(by_mask)
    (args.results / "analysis.json").write_text(json.dumps(analysis, indent=2) + "\n")
    write_csv(args.results, by_mask, analysis)
    if not args.no_plots:
        draw_figures(args.results, by_mask, metadata, analysis)
    print(json.dumps({
        "configurations": 128,
        "all_off_ms": analysis["all_off"]["median_ms"],
        "all_on_ms": analysis["all_on"]["median_ms"],
        "all_off_over_all_on": analysis["all_off_over_all_on"],
        "fastest_mask": analysis["fastest"]["mask"],
        "fastest_ms": analysis["fastest"]["median_ms"],
        "output_directory": str(args.results),
    }, indent=2))


if __name__ == "__main__":
    main()
