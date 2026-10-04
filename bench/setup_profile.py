#!/usr/bin/env python3
"""Profile current JEV SQL setup, with no external model or code replacement.

Function self times, nested SQL planning/execution and native samples are
separate experiments. All data and configuration live in an owned sandbox.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import random
import subprocess

from run import ROOT, Sandbox, Session, command, configure, digest, extension_sql_path, nodes, query_for
from profile_run import FUNCTION_STATS, function_delta, run_case, stack_samples


STATEMENTS = """
SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY total_plan_time + total_exec_time DESC), '[]'::jsonb)
FROM (SELECT queryid, toplevel, query, calls, plans, total_plan_time, total_exec_time, rows
      FROM pg_stat_statements WHERE calls > 0 OR plans > 0) AS s
"""


class StatementSandbox(Sandbox):
    def start(self):
        # The common sandbox creates its own database and schema. Restart only
        # that owned instance to load the statistics module in shared memory.
        super().start()
        self.session.close()
        self.session = None
        subprocess.run([str(self.pg_bin / "pg_ctl"), "-D", str(self.directory / "data"),
                        "-m", "fast", "-w", "stop"], env=self.env,
                       stdout=subprocess.DEVNULL, check=True)
        with (self.directory / "data/postgresql.conf").open("a") as config:
            config.write("\nshared_preload_libraries = 'pg_stat_statements'\n"
                         "pg_stat_statements.track = 'none'\n"
                         "pg_stat_statements.track_planning = off\n"
                         "pg_stat_statements.track_utility = off\n")
        subprocess.run([str(self.pg_bin / "pg_ctl"), "-D", str(self.directory / "data"),
                        "-l", str(self.output / "postgres.log"), "-w", "start"],
                       env=self.env, stdout=subprocess.DEVNULL, check=True)
        self.session = Session(self.pg_bin / "psql", self.env, self.output / "profile_psql.log")
        self.session.query("""
CREATE EXTENSION pg_stat_statements;
LOAD 'jev';
SET statement_timeout = '120s';
SET jev.batch_memory_kb = 1024;
SET jev.result_cache_kb = 0;
SET jev.auto_batch_size = off;
""")
        return self.session


def statement_diagnostics(session, expected_rows, repeats, rng):
    records = []
    session.query("""
SET track_functions = 'all';
SET pg_stat_statements.track = 'all';
SET pg_stat_statements.track_planning = on;
""")
    # Warm both shapes with the detailed instrumentation before resetting only
    # the statistics of this private cluster (never a shared server).
    for mode in ("scalar", "batch_128"):
        configure(session, mode)
        session.query(query_for("kernel", mode))
    for repeat in range(repeats):
        modes = ["scalar", "batch_128"]
        rng.shuffle(modes)
        for mode in modes:
            configure(session, mode)
            session.query("SELECT pg_stat_statements_reset()")
            session.query("BEGIN")
            before = json.loads(session.query(FUNCTION_STATS))
            plan = json.loads(session.query(
                "EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF, BUFFERS ON) " +
                query_for("kernel", mode)))[0]
            after = json.loads(session.query(FUNCTION_STATS))
            statements = json.loads(session.query(STATEMENTS))
            session.query("COMMIT")
            assert plan["Plan"]["Actual Rows"] == expected_rows
            custom = [n for n in nodes(plan) if n.get("Custom Plan Provider") == "JEVSemanticScan"]
            assert bool(custom) == (mode == "batch_128")
            if custom:
                assert custom[0]["Batch Size"] == 128 and custom[0]["Cache Hits"] == 0
                assert custom[0]["Reused Inputs"] == 0
            records.append(dict(mode=mode, repeat=repeat+1, execution_ms=plan["Execution Time"],
                                functions=function_delta(before, after), statements=statements, plan=plan))
    session.query("""
SET track_functions = 'none';
SET pg_stat_statements.track = 'none';
SET pg_stat_statements.track_planning = off;
""")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=8192)
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--statement-repeats", type=int, default=3)
    parser.add_argument("--no-sampling", action="store_true")
    parser.add_argument("--pg-config", default="pg_config")
    args = parser.parse_args()
    if min(args.rows, args.repeats, args.statement_repeats) < 1:
        parser.error("row counts and repeats must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sql_path = extension_sql_path()
    library_name = "jev.dylib" if platform.system() == "Darwin" else "jev.so"
    library = Path(command([args.pg_config, "--pkglibdir"])) / library_name
    installed_sql = Path(command([args.pg_config, "--sharedir"])) / "extension" / Path(sql_path).name
    if digest(library) != digest(ROOT / library_name) or digest(installed_sql) != digest(ROOT / sql_path):
        raise RuntimeError("Install the workspace build before profiling")
    sources = ["jev.control", "src/jev_planner.c", sql_path, "bench/run.py",
               "bench/profile_run.py", "bench/profile_adapter.py", "bench/setup_profile.py"]
    metadata = dict(started_utc=datetime.now(timezone.utc).isoformat(),
        platform=platform.platform(), postgres=command([args.pg_config, "--version"]),
        rows=args.rows, repeats=args.repeats, statement_repeats=args.statement_repeats,
        seed=20261004, batch_size=128, result_cache_kb=0, external_model=False,
        library_sha256=digest(library), installed_sql_sha256=digest(installed_sql),
        source_sha256={p: digest(ROOT / p) for p in sources},
        methodology="Unique input pairs; full result-bag validation; randomized normal/function-profile trials; "
                    "separate nested-SQL planning/execution diagnostic and optional native samples. "
                    "pg_stat_statements is preloaded but tracking disabled in normal/function-profile trials.")
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2)+"\n")
    sandbox = StatementSandbox(args, output)
    success = False
    try:
        session = sandbox.start()
        rng = random.Random(metadata["seed"])
        case = dict(name="kernel_unique", suite="kernel", duplicates=1, interleaved=False, select_every=1)
        with (output / "raw.jsonl").open("w") as raw:
            result = run_case(session, case, args.rows, args.repeats, rng, output, raw)
        # Validate the reference independently from the extension.
        configure(session, "native")
        expected = sorted(session.query(query_for("kernel", "native", validation=True)).splitlines())
        configure(session, "batch_128")
        actual = sorted(session.query(query_for("kernel", "batch_128", validation=True)).splitlines())
        assert actual == expected
        (output / "results.json").write_text(json.dumps([result], indent=2)+"\n")
        detailed = statement_diagnostics(session, len(expected), args.statement_repeats, rng)
        (output / "statements.json").write_text(json.dumps(detailed, indent=2)+"\n")
        if not args.no_sampling:
            metadata["stack_sampling"] = stack_samples(session, output, args.rows)
        metadata["final_source_sha256"] = {p: digest(ROOT / p) for p in sources}
        assert metadata["final_source_sha256"] == metadata["source_sha256"], "Sources changed during profile"
        assert digest(library) == digest(ROOT / library_name) == metadata["library_sha256"]
        assert digest(installed_sql) == metadata["installed_sql_sha256"]
        metadata["source_and_build_unchanged"] = True
        metadata["finished_utc"] = datetime.now(timezone.utc).isoformat()
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2)+"\n")
        success = True
        print(f"Setup profile complete: {output}", flush=True)
    finally:
        sandbox.close(success)


if __name__ == "__main__":
    main()
