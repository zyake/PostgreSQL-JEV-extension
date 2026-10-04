#!/usr/bin/env python3
"""Generate temporary, session-local telemetry around the production provider.

Use render_sql() in a disposable PostgreSQL/PLPython session. The generated SQL
creates pg_temp.profile_ollama_provider, profile_reset(bool, bool DEFAULT false),
and profile_read() -> jsonb. It embeds the exact production adapter source and
never changes production functions or predictions. No inference runs here.
"""

import hashlib
from pathlib import Path


PROFILE_RUNTIME = r'''
import cProfile as _profile_cprofile
import pstats as _profile_pstats

_original_evaluate = evaluate
_original_request = _request
_original_normalize = _normalize_vector


def _new_profile_state(enabled, detailed):
    return {
        "enabled": enabled, "detailed": detailed,
        "provider_calls": 0, "provider_errors": 0, "input_pairs": 0,
        "adapter_wall_ms": 0.0, "adapter_process_cpu_ms": 0.0,
        "wrapper_bookkeeping_wall_ms": 0.0,
        "http": {},
        "normalization": {"calls": 0, "errors": 0, "components": 0,
                          "wall_ms": 0.0, "process_cpu_ms": 0.0},
        "profiler": _profile_cprofile.Profile() if detailed and enabled else None,
    }


def _profile_request(endpoint, path, payload, timeout, response_limit):
    state = _profile_state
    counter = state["http"].setdefault(path, {
        "calls": 0, "errors": 0, "input_texts": 0,
        "wall_ms": 0.0, "process_cpu_ms": 0.0,
        "server": {
            field: {"sum": 0, "samples": 0, "invalid_samples": 0}
            for field in ("total_duration_ns", "load_duration_ns", "prompt_eval_count")
        },
    })
    counter["calls"] += 1
    if path == "/api/embed" and isinstance(payload, dict):
        inputs = payload.get("input")
        counter["input_texts"] += len(inputs) if isinstance(inputs, list) else int(isinstance(inputs, str))
    successful = False
    response = None
    cpu_started = time.process_time()
    wall_started = time.perf_counter()
    try:
        response = _original_request(endpoint, path, payload, timeout, response_limit)
        successful = True
        return response
    finally:
        wall_finished = time.perf_counter()
        cpu_finished = time.process_time()
        counter["wall_ms"] += (wall_finished - wall_started) * 1000.0
        counter["process_cpu_ms"] += (cpu_finished - cpu_started) * 1000.0
        counter["errors"] += int(not successful)
        if path == "/api/embed" and successful and isinstance(response, dict):
            for source, destination in (
                ("total_duration", "total_duration_ns"),
                ("load_duration", "load_duration_ns"),
                ("prompt_eval_count", "prompt_eval_count"),
            ):
                metric = counter["server"][destination]
                value = response.get(source)
                if value is None:
                    continue
                # Optional telemetry must not alter production validation.
                try:
                    valid = (not isinstance(value, bool)
                             and isinstance(value, (int, float))
                             and math.isfinite(value) and value >= 0)
                except (OverflowError, TypeError, ValueError):
                    valid = False
                if valid:
                    metric["sum"] += value
                    metric["samples"] += 1
                else:
                    metric["invalid_samples"] += 1


def _profile_normalize(vector, dimensions):
    counter = _profile_state["normalization"]
    counter["calls"] += 1
    counter["components"] += len(vector) if isinstance(vector, list) else 0
    successful = False
    cpu_started = time.process_time()
    wall_started = time.perf_counter()
    try:
        result = _original_normalize(vector, dimensions)
        successful = True
        return result
    finally:
        wall_finished = time.perf_counter()
        cpu_finished = time.process_time()
        counter["wall_ms"] += (wall_finished - wall_started) * 1000.0
        counter["process_cpu_ms"] += (cpu_finished - cpu_started) * 1000.0
        counter["errors"] += int(not successful)


def _profile_reset(enabled, detailed=False):
    global _profile_state, _request, _normalize_vector
    if not isinstance(enabled, bool) or not isinstance(detailed, bool):
        raise ValueError("enabled and detailed must be non-NULL booleans")
    _profile_state = _new_profile_state(enabled, detailed)
    # Disabled evaluation follows the unwrapped production implementation.
    _request = _profile_request if enabled else _original_request
    _normalize_vector = _profile_normalize if enabled else _original_normalize


def _profile_evaluate(lefts, rights, definition, config):
    state = _profile_state
    if not state["enabled"]:
        return _original_evaluate(lefts, rights, definition, config)
    wrapper_started = time.perf_counter()
    state["provider_calls"] += 1
    state["input_pairs"] += len(lefts) if isinstance(lefts, (list, tuple)) else 0
    profiler = state["profiler"]
    if profiler is not None:
        profiler.enable()
    successful = False
    cpu_started = time.process_time()
    wall_started = time.perf_counter()
    try:
        result = _original_evaluate(lefts, rights, definition, config)
        successful = True
        return result
    finally:
        wall_finished = time.perf_counter()
        cpu_finished = time.process_time()
        if profiler is not None:
            profiler.disable()
        elapsed_ms = (wall_finished - wall_started) * 1000.0
        state["adapter_wall_ms"] += elapsed_ms
        state["adapter_process_cpu_ms"] += (cpu_finished - cpu_started) * 1000.0
        state["provider_errors"] += int(not successful)
        # This measures outer bookkeeping only. Inner timing hooks and cProfile
        # overhead are included in adapter timings and are not subtracted.
        state["wrapper_bookkeeping_wall_ms"] += max(
            0.0, (time.perf_counter() - wrapper_started) * 1000.0 - elapsed_ms)


def _profile_read():
    state = _profile_state
    report = {key: value for key, value in state.items() if key != "profiler"}
    # Copy nested structures before replacing unavailable sums with JSON null.
    report = json.loads(json.dumps(report, allow_nan=False))
    for request in report["http"].values():
        for metric in request["server"].values():
            if metric["samples"] == 0:
                metric["sum"] = None
    http_wall = sum(request["wall_ms"] for request in report["http"].values())
    report["http_wall_ms"] = http_wall
    report["adapter_local_residual_wall_ms"] = report["adapter_wall_ms"] - http_wall
    report["other_adapter_residual_wall_ms"] = (
        report["adapter_local_residual_wall_ms"] - report["normalization"]["wall_ms"])
    report["adapter_source_sha256"] = ADAPTER_SOURCE_SHA256
    report["timing_notes"] = {
        "http_wall_ms": "Inclusive production _request time: request encoding, connection, server wait, transfer and JSON decoding.",
        "server": "Ollama-reported durations overlap HTTP time; total_duration is not pure GPU execution time.",
        "adapter_local_residual_wall_ms": "Adapter wall minus inclusive HTTP wall; includes vector validation, cosine calculation, other local work and instrumentation.",
        "process_cpu_ms": "Database backend process CPU; excludes Ollama server CPU/GPU work and overlaps nested CPU measurements.",
        "wrapper_bookkeeping_wall_ms": "Outer evaluation wrapper bookkeeping estimate only; excludes SQL/PLPython boundary, inner timing hooks and cProfile overhead.",
    }
    report["cprofile"] = {"enabled": state["profiler"] is not None,
                          "timer": "wall_clock", "top_self_time_functions": []}
    if state["profiler"] is not None:
        statistics = _profile_pstats.Stats(state["profiler"]).stats
        ordered = sorted(statistics.items(), key=lambda item: item[1][2], reverse=True)
        report["cprofile"]["top_self_time_functions"] = [
            {"file": identity[0], "line": identity[1], "function": identity[2],
             "primitive_calls": values[0], "calls": values[1],
             "self_wall_ms": values[2] * 1000.0,
             "cumulative_wall_ms": values[3] * 1000.0}
            for identity, values in ordered[:20]
        ]
    return json.dumps(report, allow_nan=False)


_profile_reset(False)
'''


def render_sql():
    source = (Path(__file__).resolve().parents[1] / "providers" / "ollama_provider.py").read_text(encoding="utf-8")
    source_digest = hashlib.sha256(source.encode("utf-8")).hexdigest()
    runtime_digest = hashlib.sha256((source + PROFILE_RUNTIME).encode("utf-8")).hexdigest()[:16]
    cache_key = "jev_bench_profile_" + runtime_digest
    initializer = (
        "if " + repr(cache_key) + " not in GD:\n"
        "    namespace = {\"ADAPTER_SOURCE_SHA256\": " + repr(source_digest) + "}\n"
        "    exec(compile(" + repr(source) + ", \"jev_production_ollama_adapter\", \"exec\"), namespace)\n"
        "    exec(compile(" + repr(PROFILE_RUNTIME) + ", \"jev_profile_instrumentation\", \"exec\"), namespace)\n"
        "    GD[" + repr(cache_key) + "] = namespace\n"
        "adapter = GD[" + repr(cache_key) + "]\n"
    )
    bodies = {
        "provider": initializer + '''try:
    return adapter["_profile_evaluate"](left_texts, right_texts, predicate_definition, model_config)
except adapter["ProviderError"] as exc:
    plpy.error(str(exc), sqlstate="38000")
''',
        "reset": initializer + 'adapter["_profile_reset"](enabled, detailed)\n',
        "read": initializer + 'return adapter["_profile_read"]()\n',
    }

    def function(name, arguments, result, attributes, body):
        delimiter = "$jev_profile_python$"
        if delimiter in body:
            raise ValueError("Unexpected SQL delimiter in embedded source")
        return (
            "CREATE OR REPLACE FUNCTION pg_temp." + name + "(" + arguments + ") RETURNS " + result + "\n"
            "LANGUAGE plpython3u " + attributes + " PARALLEL UNSAFE SECURITY INVOKER\n"
            "SET search_path = pg_catalog, pg_temp\n"
            "AS " + delimiter + "\n" + body + delimiter + ";\n"
        )

    return (
        "-- Temporary profiling only; requires existing jev and plpython3u extensions.\n"
        + function("profile_ollama_provider", "left_texts text[], right_texts text[], predicate_definition jsonb, model_config jsonb",
                   "jev.prediction[]", "STABLE STRICT", bodies["provider"])
        + function("profile_reset", "enabled boolean, detailed boolean DEFAULT false", "void", "VOLATILE", bodies["reset"])
        + function("profile_read", "", "jsonb", "VOLATILE", bodies["read"])
        + "REVOKE ALL ON FUNCTION pg_temp.profile_ollama_provider(text[],text[],jsonb,jsonb) FROM PUBLIC;\n"
        + "REVOKE ALL ON FUNCTION pg_temp.profile_reset(boolean,boolean) FROM PUBLIC;\n"
        + "REVOKE ALL ON FUNCTION pg_temp.profile_read() FROM PUBLIC;\n"
    )


if __name__ == "__main__":
    print(render_sql(), end="")
