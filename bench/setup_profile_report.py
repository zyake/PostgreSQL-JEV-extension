#!/usr/bin/env python3
"""Report exact-provider function costs and separate nested SQL diagnostics.

Function self times form an additive breakdown. Nested SQL planning/execution
times are inclusive diagnostics and must not be summed across categories.
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import statistics

from profile_report import summarize


CATEGORY_LABELS = {
    "metadata": "Predicate/model metadata lookup",
    "provider_catalog": "Provider catalog lookup",
    "dedup": "Pair deduplication and input arrays",
    "restoration": "Duplicate/NULL restoration and ordering",
    "provider_dispatch": "Dynamic provider dispatch (includes provider)",
    "provider_body": "Exact-provider array construction",
    "scalar_wrapper_sql": "Scalar wrapper SQL (includes kernel)",
    "C_kernel_sql": "C scan kernel SQL (includes kernel)",
    "parent_query": "Parent query (includes nested statements)",
    "instrumentation": "Profiling reads/resets (outside measured query)",
    "other": "Other/unclassified statement",
}
STAT_FIELDS = ("calls", "plans", "total_plan_time", "total_exec_time", "rows")


def classify(query, toplevel=False):
    """Classify unchanged kernel SQL by its distinctive source fragments."""
    sql = re.sub(r"\s+", " ", query).strip().lower()
    if "pg_stat_xact_user_functions" in sql or "pg_stat_statements" in sql:
        return "instrumentation"
    if "from only bench_items" in sql:
        return "parent_query"
    if "from jev.predicates" in sql:
        return "metadata"
    if "from pg_catalog.pg_proc" in sql:
        return "provider_catalog"
    if "select distinct c.left_text" in sql:
        return "dedup"
    if "from unnest(candidates) with ordinality" in sql:
        return "restoration"
    if re.search(r"select\s+jev\.exact_provider\s*\(", sql):
        return "provider_dispatch"
    if re.search(r"select\s+row\s*\(", sql) and "from unnest(left_texts" in sql:
        return "provider_body"
    if "select r.decision" in sql and "jev.evaluate_batch" in sql:
        return "scalar_wrapper_sql"
    if re.search(r"select ordinal\s*,\s*decision from jev\.evaluate_batch", sql):
        return "C_kernel_sql"
    return "other"


def mean_metrics(records):
    means = {field: statistics.mean(record.get(field, 0) for record in records)
             for field in STAT_FIELDS}
    means["plan_plus_exec_ms"] = means["total_plan_time"] + means["total_exec_time"]
    return means


def statement_summary(directory):
    diagnostics = json.loads((directory / "statements.json").read_text())
    by_mode = defaultdict(list)
    for diagnostic in diagnostics:
        by_mode[diagnostic["mode"]].append(diagnostic)
    output = {
        "timing_scope": (
            "Separate instrumented diagnostics. Statement planning and execution "
            "times include nested work; categories are not additive. An IMMUTABLE "
            "provider can run during planning of its dispatch statement."
        ),
        "units": "milliseconds, except calls/plans/rows",
        "modes": [],
    }
    for mode, records in sorted(by_mode.items()):
        queries = {}
        per_record_queries = []
        per_record_categories = []
        for record in records:
            grouped_queries = defaultdict(lambda: defaultdict(float))
            grouped_categories = defaultdict(lambda: defaultdict(float))
            for statement in record["statements"]:
                category = classify(statement["query"], statement["toplevel"])
                key = (str(statement["queryid"]), statement["toplevel"])
                previous = queries.get(key)
                if previous is not None:
                    assert previous["category"] == category, (previous, statement)
                else:
                    queries[key] = dict(queryid=statement["queryid"],
                                        toplevel=statement["toplevel"],
                                        query=statement["query"], category=category)
                for field in STAT_FIELDS:
                    value = statement.get(field, 0)
                    assert value >= 0, (field, value, statement)
                    grouped_queries[key][field] += value
                    grouped_categories[category][field] += value
            kernel_calls = next(function["calls"] for function in record["functions"]
                                if function["funcname"] == "evaluate_batch")
            # This runner has one exact-provider stage and no repeated pairs.
            # Check that SQL counters agree with the independent function trace.
            for category in ("metadata", "provider_catalog", "dedup", "restoration",
                             "provider_dispatch", "provider_body"):
                assert grouped_categories[category]["calls"] == kernel_calls, (mode, category)
            assert grouped_categories["provider_dispatch"]["plans"] == kernel_calls
            per_record_queries.append(grouped_queries)
            per_record_categories.append(grouped_categories)
        query_rows = [dict(info, mean_per_diagnostic=mean_metrics(
            [group.get(key, {}) for group in per_record_queries]))
            for key, info in queries.items()]
        query_rows.sort(key=lambda row: row["mean_per_diagnostic"]["plan_plus_exec_ms"], reverse=True)
        categories = {row["category"] for row in query_rows}
        category_rows = [dict(category=category, label=CATEGORY_LABELS[category],
                              mean_per_diagnostic=mean_metrics(
                                  [group.get(category, {}) for group in per_record_categories]))
                         for category in categories]
        category_rows.sort(key=lambda row: row["mean_per_diagnostic"]["plan_plus_exec_ms"], reverse=True)
        output["modes"].append(dict(
            mode=mode, diagnostics=len(records),
            execution_mean_ms=statistics.mean(row["execution_ms"] for row in records),
            execution_median_ms=statistics.median(row["execution_ms"] for row in records),
            categories=category_rows, queries=query_rows,
        ))
    (directory / "statement_summary.json").write_text(json.dumps(output, indent=2) + "\n")
    return output


def native_summary(directory):
    """Read sample's separate leaf-frame table, never inclusive call totals."""
    result = []
    for mode in ("scalar", "batch_128"):
        path = directory / f"stack_{mode}.txt"
        if not path.exists():
            continue
        text = path.read_text()
        match = re.search(r"Call graph:\n\s+(\d+) Thread_", text)
        marker = "Sort by top of stack, same collapsed (when >= 5):"
        if not match or marker not in text:
            result.append(dict(mode=mode, status="unrecognized sample format", file=path.name))
            continue
        samples = int(match[1])
        table = text.split(marker, 1)[1].split("Binary Images:", 1)[0]
        entries = []
        for line in table.splitlines():
            entry = re.match(r"\s+(.+?)\s+\(in (.*?)\)\s+(\d+)\s*$", line)
            if entry:
                count = int(entry[3])
                entries.append(dict(function=entry[1], module=entry[2],
                                    top_of_stack_samples=count, sample_share_pct=count * 100 / samples))
        result.append(dict(mode=mode, thread_samples=samples, top_of_stack=entries,
            interpretation="Periodic top-of-stack observations including possible waits; "
                           "not measured self milliseconds or exact CPU percentages. "
                           "Counts below five omitted by sample."))
    (directory / "native_sample_summary.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def plot(directory, summaries):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch

    rows = [next(row for row in summaries if row["case"] == "kernel_unique" and row["mode"] == mode)
            for mode in ("scalar", "batch_128")]
    stages = [
        ("kernel_sql", "evaluate_batch self time", "#0786A8"),
        ("provider", "exact_provider self time", "#9270CC"),
        ("scalar_wrapper", "semantic_match self time", "#DC940D"),
        ("other_postgres", "Other PostgreSQL execution", "#B6C3D3"),
    ]
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "axes.spines.left": False, "text.color": "#172B4D",
                         "axes.labelcolor": "#334155", "axes.edgecolor": "#CBD5E1"})
    fig, axes = plt.subplots(1, 2, figsize=(13, 5.8), gridspec_kw={"width_ratios": [1.25, 1]})
    labels = [f"{'Scalar' if row['mode'] == 'scalar' else 'Batch 128'}\n"
              f"{row['function_calls']['evaluate_batch']:,} kernel calls" for row in rows]
    for axis, percent in zip(axes, (False, True)):
        for i, row in enumerate(rows):
            left = 0
            for key, label, color in stages:
                value = max(0, row["phase_means_ms"][key])
                if percent:
                    value = value / row["profiled_mean_ms"] * 100
                axis.barh(i, value, left=left, height=0.38, color=color)
                if percent and value >= 10:
                    axis.text(left + value / 2, i, f"{value:.0f}%", color="white",
                              ha="center", va="center", fontsize=10, fontweight="bold")
                left += value
            if not percent:
                axis.text(left + max(r["profiled_mean_ms"] for r in rows) * .025,
                          i, f"{row['profiled_mean_ms']:,.2f} ms", va="center", fontweight="bold")
        axis.set_yticks(range(2), labels if not percent else ["Scalar", "Batch 128"])
        axis.tick_params(axis="y", length=0)
        axis.set_ylim(1.55, -.6)
        axis.set_xlim(0, 100 if percent else max(r["profiled_mean_ms"] for r in rows) * 1.28)
        axis.xaxis.grid(True, color="#E2E8F0")
        axis.set_axisbelow(True)
        axis.set_xlabel("Share of profiled execution (%)" if percent else "Mean profiled execution (ms)", labelpad=10)
        axis.set_title("Time within each mode" if percent else "Same work, fewer calls", loc="left",
                       fontsize=13, fontweight="bold", pad=15)
    fig.suptitle("Which function costs the most?", x=.05, ha="left", y=.96, fontsize=21, fontweight="bold")
    fig.text(.05, .87, f"{rows[0]['data']['rows']:,} rows · {rows[0]['data']['nonnull_candidates']:,} unique non-NULL pairs · "
             "exact-match provider · cache disabled", fontsize=11)
    fig.legend(handles=[Patch(color=color, label=label) for _, label, color in stages],
               loc="lower left", bbox_to_anchor=(.04, .12), frameon=False, ncol=2, fontsize=10)
    fig.text(.05, .045, "Self times exclude tracked child functions. Kernel self time includes SQL/SPI, array handling and orchestration.\n"
             "Mean components are additive; the separate nested-statement diagnostic is not part of this chart.",
             fontsize=9, color="#475569")
    fig.subplots_adjust(left=.16, right=.965, top=.76, bottom=.32, wspace=.32)
    fig.savefig(directory / "setup_profile.png", dpi=180, facecolor="white")
    fig.savefig(directory / "setup_profile.svg", facecolor="white")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--no-plot", action="store_true")
    args = parser.parse_args()
    summaries = summarize(args.directory)
    sql = statement_summary(args.directory)
    native_summary(args.directory)
    if not args.no_plot:
        plot(args.directory, summaries)
    print(json.dumps({
        "functions": [dict(mode=row["mode"], normal_median_ms=row["normal_median_ms"],
                           profiled_mean_ms=row["profiled_mean_ms"],
                           self_means_ms=row["function_self_means_ms"], calls=row["function_calls"])
                      for row in summaries],
        "nested_sql": [dict(mode=row["mode"], categories=row["categories"]) for row in sql["modes"]]
    }, indent=2))


if __name__ == "__main__":
    main()
