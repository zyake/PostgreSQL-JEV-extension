#!/usr/bin/env python3
"""Reproducible local benchmarks; creates and cleans up its own database/services.

Uses only Python's standard library, installed PostgreSQL/jev, and optionally an
already cached Ollama model. Never downloads models or connects to an existing DB.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import re
import shutil
import signal
import socket
import statistics
import subprocess
import tempfile
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def extension_sql_path():
    version = re.search(r"^default_version\s*=\s*'([^']+)'", (ROOT / "jev.control").read_text(), re.M)
    if not version:
        raise RuntimeError("Missing extension default_version")
    return "sql/jev--" + version.group(1) + ".sql"


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


class Session:
    def __init__(self, psql, env, error_log):
        self.error_log = Path(error_log)
        self.errors = self.error_log.open("w")
        self.process = subprocess.Popen(
            [str(psql), "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-P", "pager=off"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
            text=True, bufsize=1, env=env,
        )
        self.counter = 0

    def query(self, sql):
        self.counter += 1
        marker = f"__JEV_BENCH_END_{self.counter}__"
        self.process.stdin.write(sql.rstrip().rstrip(";") + ";\n\\echo " + marker + "\n")
        self.process.stdin.flush()
        lines = []
        for line in self.process.stdout:
            if line.rstrip("\r\n") == marker:
                return "".join(lines).strip()
            lines.append(line)
        raise RuntimeError("psql ended unexpectedly: " + self.error_log.read_text())

    def close(self):
        try:
            if self.process.poll() is None:
                try:
                    self.process.stdin.write("\\q\n")
                    self.process.stdin.flush()
                except (BrokenPipeError, OSError):
                    pass
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait(timeout=5)
        finally:
            self.errors.close()


class Sandbox:
    def __init__(self, args, output):
        self.args, self.output = args, output
        self.directory = Path(tempfile.mkdtemp(prefix="jev-benchmark-", dir="/private/tmp"))
        self.pg_bin = Path(command([args.pg_config, "--bindir"]))
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
        self.session = None
        self.started = False
        self.ollama = None
        self.ollama_log = None

    def start(self):
        socket_dir = self.directory / "socket"
        socket_dir.mkdir()
        with (self.output / "initdb.log").open("w") as log:
            subprocess.run([str(self.pg_bin / "initdb"), "-D", str(self.directory / "data"),
                            "-A", "trust", "-U", "jev_bench", "--no-locale", "-E", "UTF8"],
                           env=self.env, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (self.directory / "data/postgresql.conf").open("a") as config:
            config.write(f"""
listen_addresses = ''
unix_socket_directories = '{socket_dir}'
port = 65433
fsync = off
shared_buffers = '128MB'
jit = off
max_parallel_workers_per_gather = 0
synchronize_seqscans = off
""")
        # Set before starting so cleanup attempts a stop even after a startup error.
        self.started = True
        subprocess.run([str(self.pg_bin / "pg_ctl"), "-D", str(self.directory / "data"),
                        "-l", str(self.output / "postgres.log"), "-w", "start"],
                       env=self.env, stdout=subprocess.DEVNULL, check=True)
        self.env.update(PGHOST=str(socket_dir), PGPORT="65433", PGUSER="jev_bench", PGDATABASE="postgres")
        self.session = Session(self.pg_bin / "psql", self.env, self.output / "psql.log")
        self.session.query("""
CREATE EXTENSION jev;
LOAD 'jev';
SET statement_timeout = '120s';
SET jev.batch_memory_kb = 1024;
SET jev.result_cache_kb = 0;
CREATE TABLE bench_items(id integer, left_text text, right_text text, active boolean);
""")
        self.session.query(f"SET jev.result_cache_kb = {int(getattr(self.args, 'result_cache_kb', 0))}")
        return self.session

    def start_ollama(self):
        # Require a free dedicated port; do not reuse or stop another service.
        with socket.socket() as check:
            check.bind(("127.0.0.1", self.args.ollama_port))
        model_directory = Path(self.args.models).resolve()
        if not model_directory.is_dir():
            raise ValueError(f"Cached model directory does not exist: {model_directory}")
        endpoint = f"http://127.0.0.1:{self.args.ollama_port}"
        env = dict(os.environ, OLLAMA_HOST=f"127.0.0.1:{self.args.ollama_port}",
                   OLLAMA_MODELS=str(model_directory), OLLAMA_NO_CLOUD="1",
                   OLLAMA_KEEP_ALIVE="30m", OLLAMA_NUM_PARALLEL="1")
        self.ollama_log = (self.output / "ollama.log").open("w")
        self.ollama = subprocess.Popen(["ollama", "serve"], env=env, start_new_session=True,
                                       stdout=self.ollama_log, stderr=subprocess.STDOUT)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for attempt in range(120):
            if self.ollama.poll() is not None:
                raise RuntimeError("Benchmark Ollama stopped; see ollama.log")
            try:
                with opener.open(endpoint + "/api/tags", timeout=2) as response:
                    models = json.load(response)["models"]
                break
            except OSError:
                time.sleep(0.25)
        else:
            raise RuntimeError("Benchmark Ollama did not become ready")
        matches = [m for m in models if m["name"] == self.args.model]
        if len(matches) != 1:
            raise RuntimeError("Requested model is not cached; this runner will not download it")
        with opener.open(endpoint + "/api/version", timeout=5) as response:
            version = json.load(response)
        request = urllib.request.Request(endpoint + "/api/embed", data=json.dumps({
            "model": self.args.model, "input": ["warm waterproof winter boots"],
            "truncate": False}).encode(), headers={"Content-Type": "application/json"})
        with opener.open(request, timeout=120) as response:
            warm = json.load(response)
        config = dict(endpoint=endpoint, model=self.args.model, model_digest=matches[0]["digest"],
                      expected_dimensions=len(warm["embeddings"][0]))
        spec = importlib.util.spec_from_file_location("jev_benchmark_installer", ROOT / "providers/install_ollama.py")
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        self.session.query("CREATE EXTENSION plpython3u")
        self.session.query(installer.render_sql())
        self.session.query(f"""
INSERT INTO jev.models(name, version, provider, config)
VALUES ('bench-ollama', {literal(config['model_digest'])},
 'jev.ollama_embedding_provider(text[],text[],jsonb,jsonb)'::regprocedure,
 {literal(json.dumps(config))}::jsonb);
INSERT INTO jev.predicates(name, version, model_name, definition)
VALUES ('bench-similar', '1', 'bench-ollama',
 '{{"operation":"cosine_similarity","threshold":0.5}}');
""")
        return dict(config=config, version=version, warmup= {
            key: value for key, value in warm.items() if key != "embeddings"})

    def close(self, success):
        errors = []
        pg_stopped = not self.started
        try:
            if self.session:
                self.session.close()
        except Exception as exc:
            errors.append(f"psql cleanup: {exc}")
        try:
            if self.started:
                subprocess.run([str(self.pg_bin / "pg_ctl"), "-D", str(self.directory / "data"),
                                "-m", "immediate", "-w", "stop"], env=self.env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
                status = subprocess.run([str(self.pg_bin / "pg_ctl"), "-D", str(self.directory / "data"),
                                         "status"], env=self.env, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, timeout=5)
                pg_stopped = status.returncode == 3
                if not pg_stopped:
                    errors.append("PostgreSQL shutdown could not be verified")
        except Exception as exc:
            errors.append(f"PostgreSQL cleanup: {exc}")
        try:
            if self.ollama:
                if self.ollama.poll() is None:
                    os.killpg(self.ollama.pid, signal.SIGTERM)
                    try:
                        self.ollama.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(self.ollama.pid, signal.SIGKILL)
                        self.ollama.wait(timeout=5)
                self.ollama_log.close()
        except Exception as exc:
            errors.append(f"Ollama cleanup: {exc}")
        (self.output / "cleanup.json").write_text(json.dumps(dict(postgres_stopped=pg_stopped,
            ollama_stopped=self.ollama is None or self.ollama.poll() is not None, errors=errors), indent=2) + "\n")
        if success and pg_stopped and not errors:
            shutil.rmtree(self.directory)
        else:
            print(f"Retained failed database files: {self.directory}", flush=True)
        if errors:
            raise RuntimeError("; ".join(errors))


def populate(session, case, count):
    repeats = case["duplicates"]
    # Same logical rows in clustered/interleaved cases; only insertion order changes.
    ordering = f"(i - 1) % {repeats}, i" if case.get("interleaved") else "i"
    key = f"((i - 1) / {repeats})"
    if case["suite"] == "kernel":
        left = f"'record ' || k || ': ' || repeat('sample text ', 12)"
        right = f"CASE WHEN k % 4 = 0 THEN {left} ELSE 'other ' || k END"
        null_every = 97
    else:
        left = """CASE WHEN k % 2 = 0
            THEN 'Warm insulated waterproof snow boots suitable for winter hiking. Item number ' || k
            ELSE 'A PostgreSQL database query planner with join order optimization. Manual number ' || k END"""
        right = "'insulated snow boots'"
        null_every = 31
    # Select complete four-row blocks so selection does not retain only the
    # negative class (matching keys repeat every four kernel rows/two live rows).
    active = "true" if case["select_every"] == 1 else f"((i - 1) / 4) % {case['select_every']} = 0"
    session.query(f"""
TRUNCATE bench_items;
INSERT INTO bench_items
SELECT ((i - 1) / 2 + 1)::integer,
       CASE WHEN i % {null_every} = 0 THEN NULL ELSE {left} END,
       {right}, {active}
FROM (SELECT i, {key} AS k FROM generate_series(1, {count}) AS t(i)) AS source
ORDER BY {ordering};
ANALYZE bench_items;
""")
    return json.loads(session.query("""
SELECT jsonb_build_object('rows', count(*),
 'candidates', count(*) FILTER (WHERE active),
 'nonnull_candidates', count(*) FILTER (WHERE active AND left_text IS NOT NULL AND right_text IS NOT NULL),
 'global_unique_pairs', count(DISTINCT (left_text COLLATE "C", right_text COLLATE "C"))
     FILTER (WHERE active AND left_text IS NOT NULL AND right_text IS NOT NULL),
 'heap_bytes', pg_relation_size('bench_items'),
 'avg_input_bytes', round(avg(coalesce(octet_length(left_text), 0) + octet_length(right_text)), 1))
FROM bench_items
"""))


def query_for(suite, mode, validation=False):
    predicate = "exact" if suite == "kernel" else "bench-similar"
    condition = 'left_text COLLATE "C" = right_text COLLATE "C"' if mode == "native" else (
        f"jev.semantic_match('{predicate}', left_text, right_text)")
    projection = "jsonb_build_array(id, left_text, right_text)" if validation else "id"
    return f"SELECT {projection} FROM ONLY bench_items WHERE active AND {condition}"


def configure(session, mode):
    batch = mode.startswith("batch_")
    session.query(f"""
SET jev.enable_custom_scan = {'on' if batch else 'off'};
SET jev.force_custom_scan = {'on' if batch else 'off'};
SET jev.batch_size = {int(mode.split('_')[1]) if batch else 128};
""")


def run_case(session, case, count, repeats, output, raw_file, rng):
    info = populate(session, case, count)
    print(f"Starting {case['name']}: {info}", flush=True)
    modes = ["native", "scalar", "batch_1", "batch_16", "batch_128", "batch_512"] if case["suite"] == "kernel" else [
        "scalar", "batch_1", "batch_16", "batch_128"]
    expected = None
    validation = {}
    # Each mode gets one full result-producing warmup. Preserve duplicate IDs.
    for mode in modes:
        configure(session, mode)
        values = session.query(query_for(case["suite"], mode, validation=True))
        # Full input rows detect decisions attributed to the wrong occurrence;
        # duplicate IDs alone would miss swaps between different text pairs.
        bag = sorted(values.splitlines())
        if expected is None:
            expected = bag
        if bag != expected:
            raise AssertionError(f"Output bag mismatch: {case['name']} {mode}")
        validation[mode] = dict(rows=len(bag), sha256=hashlib.sha256(json.dumps(bag).encode()).hexdigest())
    results = []
    for repeat in range(repeats):
        order = modes[:]
        rng.shuffle(order)
        for mode in order:
            configure(session, mode)
            before = time.perf_counter()
            plan = json.loads(session.query(
                "EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF, SUMMARY ON, BUFFERS ON) " +
                query_for(case["suite"], mode)))[0]
            elapsed = (time.perf_counter() - before) * 1000
            custom = [n for n in nodes(plan) if n.get("Custom Plan Provider") == "JEVSemanticScan"]
            if mode.startswith("batch_"):
                if len(custom) != 1 or custom[0].get("Semantic Evaluation") != "batched":
                    raise AssertionError(f"Expected batched CustomScan: {case['name']} {mode}: {plan}")
            elif custom:
                raise AssertionError("Baseline unexpectedly used CustomScan")
            if plan["Plan"]["Actual Rows"] != len(expected):
                raise AssertionError("Timed query output count changed")
            record = dict(case=case["name"], suite=case["suite"], mode=mode, repeat=repeat + 1,
                          execution_ms=plan["Execution Time"], planning_ms=plan["Planning Time"],
                          client_explain_ms=elapsed, output_rows=len(expected), plan=plan)
            results.append(record)
            raw_file.write(json.dumps(record) + "\n")
            raw_file.flush()
            print(f"  {case['name']} r{repeat+1} {mode}: {record['execution_ms']:.3f} ms", flush=True)
    summaries = []
    for mode in modes:
        selected = [r for r in results if r["mode"] == mode]
        times = [r["execution_ms"] for r in selected]
        summary = dict(mode=mode, median_ms=statistics.median(times), min_ms=min(times), max_ms=max(times),
                       samples_ms=times, median_planning_ms=statistics.median(r["planning_ms"] for r in selected))
        customs = [n for n in nodes(selected[0]["plan"]) if n.get("Custom Plan Provider") == "JEVSemanticScan"]
        if customs:
            summary["counters"] = {k: customs[0][k] for k in ["Rows Read", "Candidate Rows", "Unique Inputs",
                "Reused Inputs", "Kernel Calls", "Provider Calls", "Batches", "Peak Buffered Rows", "Peak Buffered Bytes",
                "Cache Hits", "Cache Entries", "Cache Used Bytes", "Cache Allocated Bytes", "Cache Admission Skips"] if k in customs[0]}
        summaries.append(summary)
    result = dict(case=case, data=info, validation=validation, results=summaries)
    (output / f"{case['name']}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["all", "kernel", "ollama"], default="all")
    parser.add_argument("--kernel-rows", type=int, default=8192)
    parser.add_argument("--live-rows", type=int, default=128)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--live-repeats", type=int, default=3)
    parser.add_argument("--pg-config", default="pg_config")
    parser.add_argument("--result-cache-kb", type=int, default=0,
                        help="per-scan result reuse budget; 0 isolates batching as in the original benchmark")
    parser.add_argument("--models", default="/private/tmp/jev-ollama-models")
    parser.add_argument("--model", default="all-minilm:22m")
    parser.add_argument("--ollama-port", type=int, default=11439)
    parser.add_argument("--output", type=Path, default=ROOT / "bench/results" / datetime.now().strftime("%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    if min(args.kernel_rows, args.live_rows, args.repeats, args.live_repeats) < 1:
        parser.error("Row counts and repeat counts must be positive")
    if not 0 <= args.result_cache_kb <= 1048575:
        parser.error("result-cache-kb must be in [0, 1048575]")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    metadata = dict(started_utc=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
                    postgres=command([args.pg_config, "--version"]), seed=20261003,
                    settings=dict(jit="off", max_parallel_workers_per_gather=0, synchronize_seqscans="off",
                                  shared_buffers="128MB", batch_memory_kb=1024, result_cache_kb=args.result_cache_kb, fsync="off"),
                    arguments={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                    source_sha256={p: digest(ROOT / p) for p in ["src/jev_planner.c", extension_sql_path(),
                        "providers/ollama_provider.py", "bench/run.py"]})
    library = Path(command([args.pg_config, "--pkglibdir"])) / ("jev.dylib" if platform.system() == "Darwin" else "jev.so")
    installed_sql = Path(command([args.pg_config, "--sharedir"])) / "extension" / Path(extension_sql_path()).name
    if digest(library) != digest(ROOT / library.name) or digest(installed_sql) != digest(ROOT / extension_sql_path()):
        raise RuntimeError("Installed extension differs from the workspace build; install the current build first")
    metadata["installed_library_sha256"] = digest(library)
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    sandbox = Sandbox(args, output)
    success = False
    results = []
    rng = random.Random(metadata["seed"])
    try:
        session = sandbox.start()
        with (output / "raw.jsonl").open("w") as raw:
            if args.suite in ("all", "kernel"):
                for name, duplicates, interleaved, select in [
                    ("unique_all", 1, False, 1), ("clustered_all", 8, False, 1),
                    ("interleaved_all", 8, True, 1), ("unique_10pct", 1, False, 10)]:
                    case = dict(name="kernel_" + name, suite="kernel", duplicates=duplicates,
                                interleaved=interleaved, select_every=select)
                    results.append(run_case(session, case, args.kernel_rows, args.repeats, output, raw, rng))
            if args.suite in ("all", "ollama"):
                metadata["ollama"] = sandbox.start_ollama()
                (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
                for name, duplicates, select in [("unique_all", 1, 1), ("clustered_all", 4, 1), ("unique_25pct", 1, 4)]:
                    case = dict(name="ollama_" + name, suite="ollama", duplicates=duplicates, select_every=select)
                    results.append(run_case(session, case, args.live_rows, args.live_repeats, output, raw, rng))
        success = True
        (output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
        metadata["finished_utc"] = datetime.now(timezone.utc).isoformat()
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(f"Benchmark complete: {output}", flush=True)
    finally:
        sandbox.close(success)


if __name__ == "__main__":
    main()
