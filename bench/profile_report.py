#!/usr/bin/env python3
"""Validate profiles and chart additive mean wall-time components."""

import argparse
import json
from pathlib import Path
import statistics


def summarize(directory):
    cases = json.loads((directory / "results.json").read_text())
    summaries = []
    for case in cases:
        assert len({v["sha256"] for v in case["validation"]}) == 1
        for mode in ["scalar", "batch_128"]:
            profiled = [r for r in case["records"] if r["mode"] == mode and r["profiling"]]
            normal = [r for r in case["records"] if r["mode"] == mode and not r["profiling"]]
            phases = []
            functions = []
            for r in profiled:
                f = {v["funcname"]: v for v in r["functions"]}
                expected = case["data"]["nonnull_candidates"] if mode == "scalar" else next(
                    n["Provider Calls"] for n in [r["plan"]["Plan"]] if "Provider Calls" in n)
                provider = "exact_provider" if case["case"]["suite"] == "kernel" else "profile_ollama_provider"
                assert f["evaluate_batch"]["calls"] == f[provider]["calls"] == expected
                assert f.get("semantic_match", {}).get("calls", 0) == (expected if mode == "scalar" else 0)
                sql_self = {name: values["self_time"] for name, values in f.items()}
                sql_self["unattributed_execution"] = r["execution_ms"] - sum(sql_self.values())
                assert min(sql_self.values()) >= -0.001
                functions.append(sql_self)
                if case["case"]["suite"] == "kernel":
                    parts = dict(kernel_sql=sql_self["evaluate_batch"], provider=sql_self[provider],
                                 scalar_wrapper=sql_self.get("semantic_match", 0),
                                 other_postgres=sql_self["unattributed_execution"])
                else:
                    a = r["adapter"]
                    assert a["provider_calls"] == expected and a["provider_errors"] == 0
                    assert a["http"]["/api/embed"]["calls"] == expected
                    assert a["http"]["/api/tags"]["calls"] == expected * 2
                    assert a["normalization"]["calls"] == a["http"]["/api/embed"]["input_texts"]
                    parts = dict(embedding_http=a["http"]["/api/embed"]["wall_ms"],
                                 tag_http=a["http"]["/api/tags"]["wall_ms"],
                                 adapter_local=a["adapter_local_residual_wall_ms"],
                                 other_postgres=r["execution_ms"]-a["adapter_wall_ms"])
                assert min(parts.values()) >= -0.001
                assert abs(sum(parts.values()) - r["execution_ms"]) < 0.00001
                phases.append(parts)
            mean_fields = lambda records: {k: statistics.mean(r.get(k, 0) for r in records)
                                          for k in sorted({k for r in records for k in r})}
            entry = dict(case=case["case"]["name"], mode=mode, data=case["data"],
                         normal_median_ms=statistics.median(r["execution_ms"] for r in normal),
                         normal_range_ms=[min(r["execution_ms"] for r in normal), max(r["execution_ms"] for r in normal)],
                         profiled_median_ms=statistics.median(r["execution_ms"] for r in profiled),
                         profiled_mean_ms=statistics.mean(r["execution_ms"] for r in profiled),
                         profiled_range_ms=[min(r["execution_ms"] for r in profiled), max(r["execution_ms"] for r in profiled)],
                         phase_means_ms=mean_fields(phases), function_self_means_ms=mean_fields(functions),
                         function_calls={r["funcname"]: r["calls"] for r in profiled[0]["functions"]})
            if case["case"]["suite"] == "ollama":
                a = profiled[0]["adapter"]
                entry["counts"] = dict(provider_calls=a["provider_calls"], pairs=a["input_pairs"],
                    embedding_requests=a["http"]["/api/embed"]["calls"],
                    tag_requests=a["http"]["/api/tags"]["calls"],
                    embedded_texts=a["http"]["/api/embed"]["input_texts"],
                    prompt_tokens=a["http"]["/api/embed"]["server"]["prompt_eval_count"]["sum"])
                entry["adapter_cpu_mean_ms"] = statistics.mean(r["adapter"]["adapter_process_cpu_ms"] for r in profiled)
                entry["normalization_mean_ms"] = statistics.mean(r["adapter"]["normalization"]["wall_ms"] for r in profiled)
                entry["server_means_ms"] = {k.removesuffix("_ns"): statistics.mean(
                    r["adapter"]["http"]["/api/embed"]["server"][k]["sum"] / 1e6 for r in profiled)
                    for k in ["total_duration_ns", "load_duration_ns"]}
            summaries.append(entry)
    (directory / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    return summaries


def plot(directory, summaries):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
        "axes.spines.top": False, "axes.spines.right": False, "axes.spines.left": False,
        "axes.edgecolor": "#CBD5E1", "text.color": "#172B4D", "axes.labelcolor": "#334155"})
    fig, axes = plt.subplots(1, 2, figsize=(14, 6.5))
    panels = [("kernel_unique", "Executor only · 8,192 rows", [
        ("kernel_sql", "Kernel SQL / orchestration", "#0891B2"),
        ("provider", "Exact test provider", "#A78BFA"),
        ("scalar_wrapper", "Scalar wrapper", "#F59E0B"),
        ("other_postgres", "Other PostgreSQL work", "#CBD5E1")]),
        ("ollama_unique", "Embedding model · 128 rows", [
        ("embedding_http", "Embedding HTTP (incl. server)", "#0891B2"),
        ("tag_http", "Model-tag HTTP checks", "#F59E0B"),
        ("adapter_local", "Local adapter work", "#A78BFA"),
        ("other_postgres", "Other PostgreSQL work", "#CBD5E1")])]
    for axis, (case, title, stages) in zip(axes, panels):
        rows = [next(s for s in summaries if s["case"] == case and s["mode"] == mode)
                for mode in ["scalar", "batch_128"]]
        for i, row in enumerate(rows):
            left = 0
            for key, label, color in stages:
                value = row["phase_means_ms"][key]
                axis.barh(i, value, left=left, height=0.4, color=color)
                left += value
            axis.text(left + rows[0]["profiled_mean_ms"]*0.025, i, f"{left:,.1f} ms", va="center", fontweight="bold")
        axis.set_yticks([0, 1], ["Scalar", "Batch 128"])
        axis.set_ylim(1.5, -0.5)
        axis.set_xlim(0, rows[0]["profiled_mean_ms"]*1.25)
        axis.set_title(title, loc="left", fontweight="bold", fontsize=13, pad=15)
        axis.set_xlabel("Mean profiled query time (ms)", labelpad=12)
        axis.tick_params(axis="y", length=0)
        axis.xaxis.grid(True, color="#E2E8F0")
        axis.set_axisbelow(True)
        axis.legend(handles=[Patch(color=c, label=l) for _, l, c in stages], loc="upper left",
                    bbox_to_anchor=(-0.025, -0.22), frameon=False, fontsize=10)
    fig.suptitle("Where the time goes", x=0.08, ha="left", y=0.97, fontsize=22, fontweight="bold")
    fig.text(0.08, 0.9, "Five instrumented warm trials · additive wall-time components · Apple M5 / PostgreSQL 17.10", fontsize=11)
    fig.text(0.08, 0.04, "HTTP includes server work, waiting, transfer and JSON processing. Server timings overlap it. "
             "Pure GPU execution time was not measured.", fontsize=9, color="#475569")
    fig.subplots_adjust(left=0.13, right=0.975, top=0.81, bottom=0.35, wspace=0.35)
    fig.savefig(directory / "profile.png", dpi=180, facecolor="white")
    fig.savefig(directory / "profile.svg", facecolor="white")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--no-plot", action="store_true")
    args = parser.parse_args()
    summaries = summarize(args.directory)
    if not args.no_plot:
        plot(args.directory, summaries)
    print(json.dumps([dict(case=s["case"], mode=s["mode"], phases=s["phase_means_ms"]) for s in summaries], indent=2))


if __name__ == "__main__":
    main()
