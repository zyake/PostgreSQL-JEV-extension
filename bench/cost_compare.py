#!/usr/bin/env python3
"""Compare scalar, automatic, and forced batching in an owned local database.

No external model is used. Randomize all three modes in each measurement round;
validate full result bags against native equality before timing. LIMIT validates
one qualifying occurrence, since its identity is unspecified without ORDER BY.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics

from run import ROOT, Sandbox, command, digest, extension_sql_path, nodes


MODES = ("scalar", "auto", "forced")
CASES = ("full_scan", "selective_index", "limit_one")


def configure(session, mode):
    session.query(f"""
SET jev.enable_custom_scan = {'off' if mode == 'scalar' else 'on'};
SET jev.force_custom_scan = {'on' if mode == 'forced' else 'off'};
SET jev.batch_size = 128;
SET jev.result_cache_kb = 0;
SET jev.batch_call_cost = 100;
SET jev.batch_input_cost = 10;
""")


def query(case, native=False, validation=False, unlimited=False):
    condition = ('left_text COLLATE "C" = right_text COLLATE "C"' if native else
                 "jev.semantic_match('exact',left_text,right_text)")
    projection = "jsonb_build_array(id,left_text,right_text)" if validation else "id"
    relational = "id = 1 AND " if case == "selective_index" else ""
    limit = " LIMIT 1" if case == "limit_one" and not unlimited else ""
    return f"SELECT {projection} FROM ONLY bench_items WHERE {relational}{condition}{limit}"


def scans(plan):
    return [n for n in nodes(plan) if n.get("Relation Name") == "bench_items"]


def chosen_path(plan):
    return [n.get("Custom Plan Provider", n["Node Type"]) for n in scans(plan)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=8192)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--duplicates", type=int, choices=(1, 2), default=1,
                        help="Occurrences per pair; default 1 isolates batching from deduplication")
    parser.add_argument("--pg-config", default="pg_config")
    args = parser.parse_args()
    if args.rows < 2 or args.repeats < 1:
        parser.error("rows must be at least two; repeats must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    library_name = "jev.dylib" if platform.system() == "Darwin" else "jev.so"
    library = Path(command([args.pg_config, "--pkglibdir"])) / library_name
    sql_path = extension_sql_path()
    installed_sql = Path(command([args.pg_config, "--sharedir"])) / "extension" / Path(sql_path).name
    if digest(library) != digest(ROOT / library_name) or digest(installed_sql) != digest(ROOT / sql_path):
        raise RuntimeError("Install the workspace build before benchmarking")
    metadata = dict(
        started_utc=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
        postgres=command([args.pg_config, "--version"]), seed=20261004,
        rows=args.rows, repeats=args.repeats, duplicates=args.duplicates, modes=MODES, cases=CASES,
        batch_size=128, result_cache_kb=0, batch_call_cost=100, batch_input_cost=10,
        methodology="Warm validation; randomized paired mode order; exact provider only; no cache across buffers",
        source_sha256={p: digest(ROOT / p) for p in
                       ["src/jev_planner.c", sql_path, "bench/run.py", "bench/cost_compare.py"]},
        library_sha256=digest(library))
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    sandbox = Sandbox(args, output)
    success = False
    summaries = []
    rng = random.Random(metadata["seed"])
    try:
        session = sandbox.start()
        # Unique pairs isolate batching; optional adjacent repeats exercise
        # bag semantics and reuse. NULL operands never match.
        session.query(f"""
INSERT INTO bench_items
SELECT k, CASE WHEN i % 97 = 0 THEN NULL ELSE 'item ' || k END,
       'item ' || k, true
FROM (SELECT i, ((i-1)/{args.duplicates}+1)::integer AS k FROM generate_series(1,{args.rows}) i) source
ORDER BY i;
CREATE INDEX bench_items_id_idx ON bench_items(id);
ANALYZE bench_items;
""")
        with (output / "raw.jsonl").open("w") as raw:
            for case in CASES:
                configure(session, "scalar")
                expected = sorted(session.query(query(case, native=True, validation=True,
                                                       unlimited=True)).splitlines())
                expected_rows = 1 if case == "limit_one" else len(expected)
                validation = {}
                for mode in MODES:
                    configure(session, mode)
                    actual = sorted(session.query(query(case, validation=True)).splitlines())
                    if case == "limit_one":
                        assert len(actual) == 1 and actual[0] in expected, (case, mode, "qualifying occurrence")
                    else:
                        assert actual == expected, (case, mode, "result bag")
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
                        if mode == "forced":
                            assert selected == ["JEVSemanticScan"], (case, mode, selected)
                            assert scans(plan)[0]["Semantic Evaluation"] == "batched"
                        elif mode == "scalar":
                            assert "JEVSemanticScan" not in selected, (case, mode, selected)
                        record = dict(case=case, mode=mode, repeat=repeat+1,
                            execution_ms=plan["Execution Time"], planning_ms=plan["Planning Time"],
                            chosen_path=selected, plan=plan)
                        records.append(record)
                        raw.write(json.dumps(record) + "\n")
                        raw.flush()
                summary = dict(case=case, validation=validation, results=[])
                for mode in MODES:
                    selected = [r for r in records if r["mode"] == mode]
                    assert all(r["chosen_path"] == selected[0]["chosen_path"] for r in selected)
                    times = [r["execution_ms"] for r in selected]
                    summary["results"].append(dict(mode=mode,
                        chosen_path=selected[0]["chosen_path"], median_ms=statistics.median(times),
                        min_ms=min(times), max_ms=max(times), samples_ms=times,
                        median_planning_ms=statistics.median(r["planning_ms"] for r in selected),
                        representative_scan=scans(selected[0]["plan"])))
                summaries.append(summary)
                print(json.dumps(summary), flush=True)
        # Other agents may edit or install concurrently. Do not publish a
        # successful measurement whose source/build identity changed mid-run.
        if any(digest(ROOT / path) != expected_digest
               for path, expected_digest in metadata["source_sha256"].items()):
            raise RuntimeError("Benchmark source changed during measurement; rerun the installed build")
        if (digest(library) != metadata["library_sha256"] or
                digest(ROOT / library_name) != metadata["library_sha256"] or
                digest(installed_sql) != metadata["source_sha256"][sql_path]):
            raise RuntimeError("Benchmark build changed during measurement; rerun the installed build")
        metadata["completed_utc"] = datetime.now(timezone.utc).isoformat()
        metadata["source_and_build_unchanged"] = True
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (output / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
        success = True
    finally:
        sandbox.close(success)


if __name__ == "__main__":
    main()
