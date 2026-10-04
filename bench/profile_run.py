#!/usr/bin/env python3
"""Profile the existing extension without changing its installed implementation.

PostgreSQL function statistics, temporary provider phase timers, and optional
separate macOS stack samples. Normal and instrumented trials are interleaved.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import time

from run import ROOT, Sandbox, command, configure, digest, extension_sql_path, literal, nodes, populate, query_for
from profile_adapter import render_sql


FUNCTION_STATS = """
SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY funcid), '[]'::jsonb)
FROM (SELECT funcid, schemaname, funcname, calls, total_time, self_time
      FROM pg_stat_xact_user_functions
      WHERE schemaname = 'jev' OR schemaname LIKE 'pg_temp_%') AS s
"""


def function_delta(before, after):
    old = {r["funcid"]: r for r in before}
    result = []
    for row in after:
        previous = old.get(row["funcid"], {})
        delta = {k: row[k] - previous.get(k, 0) for k in ("calls", "total_time", "self_time")}
        if delta["calls"]:
            result.append(dict(schemaname=row["schemaname"], funcname=row["funcname"], **delta))
    return result


def set_profile(session, suite, enabled, detailed=False):
    session.query("SET track_functions = " + ("'all'" if enabled else "'none'"))
    if suite == "ollama":
        provider = ("pg_temp.profile_ollama_provider" if enabled else "jev.ollama_embedding_provider")
        session.query(f"""
UPDATE jev.models SET provider = '{provider}(text[],text[],jsonb,jsonb)'::regprocedure
WHERE name = 'bench-ollama';
SELECT pg_temp.profile_reset({str(enabled).lower()}, {str(detailed).lower()});
""")


def measured(session, case, mode, enabled, expected_rows, detailed=False):
    configure(session, mode)
    set_profile(session, case["suite"], enabled, detailed)
    session.query("BEGIN")
    # Always use deltas: pending backend statistics can survive transaction
    # boundaries until the statistics collector publishes them.
    before = json.loads(session.query(FUNCTION_STATS))
    plan = json.loads(session.query("EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF, SUMMARY ON, BUFFERS ON) " +
                                   query_for(case["suite"], mode)))[0]
    after = json.loads(session.query(FUNCTION_STATS))
    adapter = json.loads(session.query("SELECT pg_temp.profile_read()")) if case["suite"] == "ollama" else None
    session.query("COMMIT")
    custom = [n for n in nodes(plan) if n.get("Custom Plan Provider") == "JEVSemanticScan"]
    if mode.startswith("batch_"):
        assert len(custom) == 1 and custom[0]["Semantic Evaluation"] == "batched", plan
    else:
        assert not custom, plan
    assert plan["Plan"]["Actual Rows"] == expected_rows, plan
    return dict(case=case["name"], mode=mode, profiling=enabled, detailed=detailed,
                execution_ms=plan["Execution Time"], planning_ms=plan["Planning Time"],
                functions=function_delta(before, after), adapter=adapter, plan=plan)


def run_case(session, case, rows, repeats, rng, output, raw):
    data = populate(session, case, rows)
    print(f"Profiling {case['name']}: {data}", flush=True)
    expected = None
    validation = []
    for mode in ["scalar", "batch_128"]:
        for enabled in [False, True]:
            configure(session, mode)
            set_profile(session, case["suite"], enabled)
            bag = sorted(session.query(query_for(case["suite"], mode, validation=True)).splitlines())
            if expected is None:
                expected = bag
            assert bag == expected, (case, mode, enabled)
            validation.append(dict(mode=mode, profiling=enabled, output_rows=len(bag),
                                   sha256=hashlib.sha256(json.dumps(bag).encode()).hexdigest()))
    records = []
    for repeat in range(repeats):
        jobs = [(mode, enabled) for mode in ["scalar", "batch_128"] for enabled in [False, True]]
        rng.shuffle(jobs)
        for mode, enabled in jobs:
            record = measured(session, case, mode, enabled, len(expected))
            record["repeat"] = repeat + 1
            records.append(record)
            raw.write(json.dumps(record) + "\n")
            raw.flush()
            print(f"  r{repeat+1} {mode} {'profiled' if enabled else 'normal'}: {record['execution_ms']:.3f} ms", flush=True)
    if case["suite"] == "ollama":
        for mode in ["scalar", "batch_128"]:
            record = measured(session, case, mode, True, len(expected), detailed=True)
            record["repeat"] = None
            (output / f"{case['name']}_{mode}_cprofile.json").write_text(json.dumps(record, indent=2) + "\n")
    result = dict(case=case, data=data, validation=validation, records=records)
    (output / f"{case['name']}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def stack_samples(session, output, rows):
    if not shutil.which("sample"):
        return {"status": "unavailable", "reason": "macOS sample is not installed"}
    case = dict(name="stack_unique", suite="kernel", duplicates=1, interleaved=False, select_every=1)
    populate(session, case, rows)
    session.query("SET track_functions = 'none'")
    pid = int(session.query("SELECT pg_backend_pid()"))
    results = []
    for mode in ["scalar", "batch_128"]:
        configure(session, mode)
        sql = query_for("kernel", mode).replace("SELECT id FROM", "SELECT count(*) FROM")
        warm_plan = json.loads(session.query("EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF) " + sql))[0]
        (output / f"stack_{mode}_plan.json").write_text(json.dumps(warm_plan, indent=2) + "\n")
        destination = output / f"stack_{mode}.txt"
        with (output / f"stack_{mode}_sampler.log").open("w") as log:
            sampler = subprocess.Popen(["sample", str(pid), "5", "1", "-file", str(destination)],
                                       stdout=log, stderr=subprocess.STDOUT)
            started = time.monotonic()
            calls = 0
            while sampler.poll() is None and time.monotonic() - started < 20:
                session.query(sql)
                calls += 1
            try:
                status = sampler.wait(timeout=5)
            except subprocess.TimeoutExpired:
                sampler.terminate()
                status = sampler.wait(timeout=5)
        result = dict(mode=mode, status=status, backend_pid=pid, repeated_queries=calls,
                      elapsed_seconds=time.monotonic()-started, file=destination.name)
        results.append(result)
        print(f"Stack sampling: {result}", flush=True)
    return results


def nested_sql_diagnostic(session, output):
    case = dict(name="nested_sql", suite="kernel", duplicates=1, interleaved=False, select_every=1)
    populate(session, case, 16)
    # This separate diagnostic is never included in latency measurements.
    session.query("""
SET track_functions = 'none';
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_nested_statements = on;
SET auto_explain.log_analyze = on;
SET auto_explain.log_timing = off;
SET auto_explain.log_buffers = on;
SET auto_explain.log_format = 'json';
SET auto_explain.log_parameter_max_length = 0;
""")
    offsets = []
    for mode in ["scalar", "batch_128"]:
        configure(session, mode)
        start = (output / "postgres.log").stat().st_size
        session.query(query_for("kernel", mode))
        end = (output / "postgres.log").stat().st_size
        offsets.append(dict(mode=mode, start_byte=start, end_byte=end))
    session.query("SET auto_explain.log_min_duration = -1")
    (output / "nested_sql_offsets.json").write_text(json.dumps(offsets, indent=2) + "\n")
    return offsets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kernel-rows", type=int, default=8192)
    parser.add_argument("--live-rows", type=int, default=128)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--no-sampling", action="store_true")
    parser.add_argument("--pg-config", default="pg_config")
    parser.add_argument("--models", default="/private/tmp/jev-ollama-models")
    parser.add_argument("--model", default="all-minilm:22m")
    parser.add_argument("--ollama-port", type=int, default=11439)
    args = parser.parse_args()
    if min(args.kernel_rows, args.live_rows, args.repeats) < 1:
        parser.error("row counts and repeats must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    metadata = dict(started_utc=datetime.now(timezone.utc).isoformat(), postgres=command([args.pg_config, "--version"]),
                    seed=20261004, arguments={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                    source_sha256={str(p): digest(ROOT / p) for p in ["src/jev_planner.c", extension_sql_path(),
                        "providers/ollama_provider.py", "bench/run.py", "bench/profile_run.py", "bench/profile_adapter.py"]})
    installed_sql = Path(command([args.pg_config, "--sharedir"])) / "extension" / Path(extension_sql_path()).name
    library = Path(command([args.pg_config, "--pkglibdir"])) / "jev.dylib"
    assert digest(installed_sql) == digest(ROOT / extension_sql_path())
    assert digest(library) == digest(ROOT / "jev.dylib")
    sandbox = Sandbox(args, output)
    success = False
    results = []
    try:
        session = sandbox.start()
        rng = random.Random(metadata["seed"])
        with (output / "raw.jsonl").open("w") as raw:
            for name, duplicates in [("unique", 1), ("duplicates", 8)]:
                case = dict(name="kernel_" + name, suite="kernel", duplicates=duplicates, select_every=1)
                results.append(run_case(session, case, args.kernel_rows, args.repeats, rng, output, raw))
            metadata["ollama"] = sandbox.start_ollama()
            session.query(render_sql())
            for name, duplicates in [("unique", 1), ("duplicates", 4)]:
                case = dict(name="ollama_" + name, suite="ollama", duplicates=duplicates, select_every=1)
                results.append(run_case(session, case, args.live_rows, args.repeats, rng, output, raw))
        if not args.no_sampling:
            metadata["stack_sampling"] = stack_samples(session, output, args.kernel_rows)
        metadata["nested_sql_diagnostic"] = nested_sql_diagnostic(session, output)
        metadata["finished_utc"] = datetime.now(timezone.utc).isoformat()
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        success = True
        print(f"Profile complete: {output}", flush=True)
    finally:
        sandbox.close(success)


if __name__ == "__main__":
    main()
