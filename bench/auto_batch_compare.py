#!/usr/bin/env python3
"""Measure planner-selected batch sizes against fixed batching and scalar SQL.

Uses an owned local PostgreSQL sandbox and the exact provider, with unique input
pairs and no retained result cache. Modes run in randomized paired rounds after
validation/warmup. LIMIT results are validated as qualifying occurrences without
assuming any output order. This does not measure external model parallelism.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics

from run import ROOT, Sandbox, command, digest, extension_sql_path, nodes


MODES = ("scalar", "fixed", "auto")
CASES = ("full_scan", "limit_1", "limit_4", "limit_16", "limit_64", "selective_index")


def configure(session, mode):
    session.query(f"""
SET jev.enable_custom_scan = {'off' if mode == 'scalar' else 'on'};
SET jev.force_custom_scan = off;
SET jev.auto_batch_size = {'on' if mode == 'auto' else 'off'};
SET jev.batch_size = 128;
SET jev.batch_memory_kb = 1024;
SET jev.result_cache_kb = 0;
SET jev.batch_call_cost = 100;
SET jev.batch_input_cost = 10;
""")


def row_limit(case):
    return int(case.split("_")[1]) if case.startswith("limit_") else None


def query(case, native=False, validation=False, unlimited=False):
    condition = ('left_text COLLATE "C" = right_text COLLATE "C"' if native else
                 "jev.semantic_match('exact',left_text,right_text)")
    projection = "jsonb_build_array(id,left_text,right_text)" if validation else "id"
    relational = "id = 1 AND " if case == "selective_index" else ""
    count = row_limit(case)
    limit = f" LIMIT {count}" if count is not None and not unlimited else ""
    return f"SELECT {projection} FROM ONLY bench_items WHERE {relational}{condition}{limit}"


def scans(plan):
    return [node for node in nodes(plan) if node.get("Relation Name") == "bench_items"]


def chosen_path(plan):
    return [node.get("Custom Plan Provider", node["Node Type"]) for node in scans(plan)]


def observed_scan(plan):
    selected = scans(plan)
    custom = next((node for node in selected
                   if node.get("Custom Plan Provider") == "JEVSemanticScan"), None)
    fields = {
        "batch_size": "Batch Size",
        "batch_selection": "Batch Size Selection",
        "planned_batch_size": "Planned Batch Size",
        "planned_batch_size_limit": "Planned Batch Size Limit",
        "kernel_calls": "Kernel Calls",
        "unique_inputs": "Unique Inputs",
        "candidate_rows": "Candidate Rows",
        "estimated_kernel_calls": "Estimated Kernel Calls",
    }
    # Missing counters for a native scan mean unavailable, never zero.
    return {name: custom.get(label) if custom is not None else None
            for name, label in fields.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=8192)
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--pg-config", default="pg_config")
    args = parser.parse_args()
    if args.rows < 65 or args.repeats < 1:
        parser.error("rows must be at least 65; repeats must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    library_name = "jev.dylib" if platform.system() == "Darwin" else "jev.so"
    library = Path(command([args.pg_config, "--pkglibdir"])) / library_name
    sql_path = extension_sql_path()
    installed_sql = Path(command([args.pg_config, "--sharedir"])) / "extension" / Path(sql_path).name
    if digest(library) != digest(ROOT / library_name) or digest(installed_sql) != digest(ROOT / sql_path):
        raise RuntimeError("Install the workspace build before benchmarking")
    source_paths = ("jev.control", "src/jev_planner.c", sql_path,
                    "bench/run.py", "bench/auto_batch_compare.py")
    metadata = dict(
        started_utc=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
        postgres=command([args.pg_config, "--version"]), seed=20261005,
        rows=args.rows, repeats=args.repeats, modes=MODES, cases=CASES,
        batch_size_limit=128, batch_memory_kb=1024, result_cache_kb=0,
        batch_call_cost=100, batch_input_cost=10, forced_custom_scan=False,
        methodology="Unique exact-provider pairs with NULL operands; warm validation; "
                    "randomized paired mode order; no result reuse across buffers; "
                    "LIMIT checks count and qualifying occurrences without output-order assumptions",
        source_sha256={path: digest(ROOT / path) for path in source_paths},
        library_sha256=digest(library), installed_sql_sha256=digest(installed_sql))
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    sandbox = Sandbox(args, output)
    success = False
    summaries = []
    rng = random.Random(metadata["seed"])
    try:
        session = sandbox.start()
        session.query(f"""
INSERT INTO bench_items
SELECT i, CASE WHEN i % 97 = 0 THEN NULL ELSE 'item ' || i END,
       'item ' || i, true
FROM generate_series(1,{args.rows}) AS i;
CREATE INDEX bench_items_id_idx ON bench_items(id);
ANALYZE bench_items;
""")
        with (output / "raw.jsonl").open("w") as raw:
            for case in CASES:
                configure(session, "scalar")
                expected = sorted(session.query(query(case, native=True, validation=True,
                                                       unlimited=True)).splitlines())
                expected_bag = Counter(expected)
                limit = row_limit(case)
                expected_rows = min(limit, len(expected)) if limit is not None else len(expected)
                validation = {}
                for mode in MODES:
                    configure(session, mode)
                    actual = sorted(session.query(query(case, validation=True)).splitlines())
                    assert len(actual) == expected_rows, (case, mode, "output count")
                    if limit is not None:
                        assert not (Counter(actual) - expected_bag), (case, mode, "qualifying occurrences")
                    else:
                        assert actual == expected, (case, mode, "full result bag")
                    validation[mode] = dict(rows=len(actual),
                        sha256=hashlib.sha256(json.dumps(actual).encode()).hexdigest())
                records = []
                for repeat in range(args.repeats):
                    modes = list(MODES)
                    rng.shuffle(modes)
                    for mode in modes:
                        configure(session, mode)
                        plan = json.loads(session.query(
                            "EXPLAIN (ANALYZE,FORMAT JSON,TIMING OFF,BUFFERS ON) " + query(case)))[0]
                        selected = chosen_path(plan)
                        assert plan["Plan"]["Actual Rows"] == expected_rows, (case, mode, "output count")
                        if mode == "scalar":
                            assert "JEVSemanticScan" not in selected, (case, mode, selected)
                        for node in scans(plan):
                            if node.get("Custom Plan Provider") == "JEVSemanticScan":
                                assert node["Semantic Evaluation"] == "batched", (case, mode, node)
                                assert node["Forced Custom Path"] is False, (case, mode, node)
                                assert 1 <= node["Batch Size"] <= 128, (case, mode, node)
                                assert node["Batch Size Selection"] == ("cost based" if mode == "auto" else "fixed")
                        record = dict(case=case, mode=mode, repeat=repeat + 1,
                            execution_ms=plan["Execution Time"], planning_ms=plan["Planning Time"],
                            chosen_path=selected, observed=observed_scan(plan), plan=plan)
                        records.append(record)
                        raw.write(json.dumps(record) + "\n")
                        raw.flush()
                summary = dict(case=case, validation=validation, results=[])
                for mode in MODES:
                    selected = [record for record in records if record["mode"] == mode]
                    assert all(record["chosen_path"] == selected[0]["chosen_path"] and
                               record["observed"] == selected[0]["observed"] for record in selected), \
                        (case, mode, "unstable plan or counters")
                    times = [record["execution_ms"] for record in selected]
                    summary["results"].append(dict(mode=mode,
                        chosen_path=selected[0]["chosen_path"], observed=selected[0]["observed"],
                        median_ms=statistics.median(times), min_ms=min(times), max_ms=max(times),
                        samples_ms=times,
                        median_planning_ms=statistics.median(record["planning_ms"] for record in selected),
                        representative_scan=scans(selected[0]["plan"])))
                summaries.append(summary)
                print(json.dumps(summary), flush=True)
        # Refuse to publish measurements from a concurrently changed source or
        # installed build; keep both endpoint identities in the output record.
        metadata["final_source_sha256"] = {path: digest(ROOT / path) for path in source_paths}
        metadata["final_library_sha256"] = digest(library)
        metadata["final_workspace_library_sha256"] = digest(ROOT / library_name)
        metadata["final_installed_sql_sha256"] = digest(installed_sql)
        if (metadata["final_source_sha256"] != metadata["source_sha256"] or
                metadata["final_library_sha256"] != metadata["library_sha256"] or
                metadata["final_workspace_library_sha256"] != metadata["library_sha256"] or
                metadata["final_installed_sql_sha256"] != metadata["installed_sql_sha256"]):
            (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
            raise RuntimeError("Benchmark source/build changed during measurement; rerun the installed build")
        metadata["completed_utc"] = datetime.now(timezone.utc).isoformat()
        metadata["source_and_build_unchanged"] = True
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (output / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
        success = True
    finally:
        sandbox.close(success)


if __name__ == "__main__":
    main()
