#!/usr/bin/env python3
"""Paired cache on/off measurement, fixed batch size, no external inference."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics

from run import ROOT, Sandbox, command, configure, digest, extension_sql_path, nodes, populate, query_for


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=8192)
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--pg-config", default="pg_config")
    args = parser.parse_args()
    if min(args.rows, args.repeats) < 1:
        parser.error("rows and repeats must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    library_name = "jev.dylib" if platform.system() == "Darwin" else "jev.so"
    installed_library = Path(command([args.pg_config, "--pkglibdir"])) / library_name
    installed_sql = Path(command([args.pg_config, "--sharedir"])) / "extension" / Path(extension_sql_path()).name
    if digest(installed_library) != digest(ROOT / library_name) or digest(installed_sql) != digest(ROOT / extension_sql_path()):
        raise RuntimeError("Install the workspace build before benchmarking")
    metadata = dict(started_utc=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
                    postgres=command([args.pg_config, "--version"]), seed=20261004,
                    rows=args.rows, repeats=args.repeats, batch_size=128, cache_budgets_kb=[0,4096],
                    methodology="Warm full-bag validation; paired randomized cache order in every round; exact provider only",
                    source_sha256={p: digest(ROOT / p) for p in ["src/jev_planner.c", extension_sql_path(),
                        "bench/run.py", "bench/cache_compare.py"]}, library_sha256=digest(installed_library))
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    sandbox = Sandbox(args, output)
    success = False
    summaries = []
    rng = random.Random(metadata["seed"])
    try:
        session = sandbox.start()
        with (output / "raw.jsonl").open("w") as raw:
            for name, duplicates, interleaved, select in [
                    ("unique",1,False,1), ("nearby_repeats",8,False,1),
                    ("interleaved_repeats",8,True,1), ("unique_10pct",1,False,10)]:
                case = dict(name=name,suite="kernel",duplicates=duplicates,
                            interleaved=interleaved,select_every=select)
                data = populate(session, case, args.rows)
                configure(session, "native")
                expected = sorted(session.query(query_for("kernel","native",validation=True)).splitlines())
                configure(session, "batch_128")
                for budget in [0,4096]:
                    session.query(f"SET jev.result_cache_kb={budget}")
                    actual = sorted(session.query(query_for("kernel","batch_128",validation=True)).splitlines())
                    assert actual == expected, (name,budget,"result bag")
                records = []
                for repeat in range(args.repeats):
                    budgets = [0,4096]
                    rng.shuffle(budgets)
                    for budget in budgets:
                        session.query(f"SET jev.result_cache_kb={budget}")
                        plan = json.loads(session.query(
                            "EXPLAIN (ANALYZE,FORMAT JSON,TIMING OFF,BUFFERS ON) " +
                            query_for("kernel","batch_128")))[0]
                        custom = [n for n in nodes(plan) if n.get("Custom Plan Provider")=="JEVSemanticScan"]
                        assert len(custom)==1 and custom[0]["Semantic Evaluation"]=="batched"
                        assert plan["Plan"]["Actual Rows"]==len(expected)
                        scan = custom[0]
                        assert scan["Unique Inputs"] + scan["Reused Inputs"] == data["nonnull_candidates"]
                        assert scan["Cache Used Bytes"] <= scan["Cache Allocated Bytes"] <= budget*1024
                        record = dict(case=name,repeat=repeat+1,cache_kb=budget,
                                      execution_ms=plan["Execution Time"],plan=plan)
                        records.append(record)
                        raw.write(json.dumps(record)+"\n")
                        raw.flush()
                summary = dict(case=name,data=data,validation_rows=len(expected),
                    validation_sha256=hashlib.sha256(json.dumps(expected).encode()).hexdigest(),results=[])
                for budget in [0,4096]:
                    chosen = [r for r in records if r["cache_kb"]==budget]
                    scans = [next(n for n in nodes(r["plan"]) if n.get("Custom Plan Provider")=="JEVSemanticScan") for r in chosen]
                    keys = ["Unique Inputs","Kernel Calls","Cache Hits","Cache Entries","Cache Admission Skips","Cache Used Bytes"]
                    counters = {k:scans[0][k] for k in keys}
                    assert all({k:s[k] for k in keys} == counters for s in scans)
                    times = [r["execution_ms"] for r in chosen]
                    summary["results"].append(dict(cache_kb=budget,median_ms=statistics.median(times),
                        min_ms=min(times),max_ms=max(times),samples_ms=times,counters=counters))
                summaries.append(summary)
                print(json.dumps(summary), flush=True)
        (output / "summary.json").write_text(json.dumps(summaries,indent=2)+"\n")
        success = True
    finally:
        sandbox.close(success)


if __name__ == "__main__":
    main()
