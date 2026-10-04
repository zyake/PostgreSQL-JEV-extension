"""Standard-library HTTP contract tests; no model or PostgreSQL required."""

import contextlib
import http.server
import importlib.util
import json
from pathlib import Path
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load_module("jev_ollama", ROOT / "providers" / "ollama_provider.py")
installer = load_module("jev_ollama_installer", ROOT / "providers" / "install_ollama.py")
DIGEST = "a" * 64
MODEL = "test-embedding:fixed"
DEFINITION = {"operation": "cosine_similarity", "threshold": 0.5}
VECTORS = {"a": [1, 0], "b": [0, 1], "opposite": [-1, 0], "similar": [1, 1], "": [1, 0]}


@contextlib.contextmanager
def fake_ollama():
    state = {"requests": [], "digest": DIGEST, "mode": None, "embedded": False}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.respond(None)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.respond(json.loads(body))

        def respond(self, payload):
            state["requests"].append((self.command, self.path, payload))
            mode = state["mode"]
            status = 200
            if self.path == "/api/tags":
                digest = ("b" * 64) if mode == "changed-tag" and state["embedded"] else state["digest"]
                result = {"models": [{"name": MODEL, "digest": digest}]}
                if mode == "missing-model":
                    result = {"models": []}
                if mode == "duplicate-model":
                    result["models"] *= 2
                if mode == "bad-tags":
                    result = {"models": {}}
            elif self.path == "/api/embed":
                state["embedded"] = True
                result = {"model": MODEL, "embeddings": [VECTORS[text] for text in payload["input"]]}
                if mode == "short-output":
                    result["embeddings"] = []
                if mode == "extra-output":
                    result["embeddings"].append([1, 0])
                if mode == "wrong-model":
                    result["model"] = "other:fixed"
                if mode == "wrong-dimensions":
                    result["embeddings"][0] = [1]
                if mode == "zero-vector":
                    result["embeddings"][0] = [0, 0]
                if mode == "nan":
                    result["embeddings"][0] = [float("nan"), 1]
                if mode == "infinity":
                    result["embeddings"][0] = [float("inf"), 1]
                if mode == "boolean":
                    result["embeddings"][0] = [True, 0]
                if mode == "string-component":
                    result["embeddings"][0] = ["1", "0"]
                if mode == "error-field":
                    result = {"error": "model error"}
            else:
                status, result = 404, {"error": "unexpected path"}
            if mode == "http-error":
                status = 503
            if mode == "redirect":
                status = 302
            body = json.dumps(result).encode()
            if mode == "invalid-json":
                body = b"not json"
            if mode in ("large-response", "large-stream"):
                body = b" " * 1024
            if mode == "slow-response":
                time.sleep(0.1)
            try:
                self.send_response(status)
                if mode == "redirect":
                    self.send_header("Location", "http://192.0.2.1/api/tags")
                if mode != "large-stream":
                    self.send_header("Content-Length", str(len(body) + (5 if mode == "truncated-body" else 0)))
                self.end_headers()
                if mode == "slow-trickle":
                    for byte in body:
                        self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                        time.sleep(0.01)
                else:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield state, {
            "endpoint": "http://127.0.0.1:" + str(server.server_port),
            "model": MODEL, "model_digest": DIGEST, "expected_dimensions": 2,
        }
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class OllamaProviderTests(unittest.TestCase):
    def test_native_batch_deduplicates_texts_and_restores_pairs(self):
        with fake_ollama() as (state, config):
            actual = adapter.evaluate(["a", "a", "b", "a"], ["a", "b", "a", "opposite"], DEFINITION, config)
            self.assertEqual(actual, [(True, 1), (False, 0.5), (False, 0.5), (False, 0)])
            self.assertEqual([request[:2] for request in state["requests"]], [
                ("GET", "/api/tags"), ("POST", "/api/embed"), ("GET", "/api/tags")])
            self.assertEqual(state["requests"][1][2], {
                "model": MODEL, "input": ["a", "b", "opposite"], "truncate": False})

    def test_pointwise_batch_invariance_and_jsonb_strings(self):
        with fake_ollama() as (_, config):
            together = adapter.evaluate(["a", "a"], ["similar", "b"], DEFINITION, config)
            separate = [adapter.evaluate(["a"], [text], json.dumps(DEFINITION), json.dumps(config))[0]
                        for text in ["similar", "b"]]
            self.assertEqual(together, separate)
            self.assertTrue(together[0][0])
            self.assertAlmostEqual(together[0][1], (1 + 2 ** -0.5) / 2)

    def test_threshold_is_inclusive_and_score_is_similarity(self):
        with fake_ollama() as (_, config):
            definition = {"operation": "cosine_similarity", "threshold": 0}
            self.assertEqual(adapter.evaluate(["a"], ["b"], definition, config), [(True, 0.5)])

    def test_empty_batch_does_not_contact_server(self):
        with fake_ollama() as (state, config):
            self.assertEqual(adapter.evaluate([], [], DEFINITION, config), [])
            self.assertEqual(state["requests"], [])

    def test_invalid_responses_fail_instead_of_negative_decisions(self):
        modes = ["short-output", "extra-output", "wrong-model", "wrong-dimensions", "zero-vector",
                 "nan", "infinity", "boolean", "string-component", "error-field", "bad-tags",
                 "missing-model", "duplicate-model", "changed-tag", "http-error", "redirect", "invalid-json",
                 "truncated-body"]
        for mode in modes:
            with self.subTest(mode=mode), fake_ollama() as (state, config):
                state["mode"] = mode
                with self.assertRaises(adapter.ProviderError):
                    adapter.evaluate(["a"], ["b"], DEFINITION, config)

    def test_digest_mismatch_fails_before_inference(self):
        with fake_ollama() as (state, config):
            state["digest"] = "c" * 64
            with self.assertRaisesRegex(adapter.ProviderError, "model_digest"):
                adapter.evaluate(["a"], ["b"], DEFINITION, config)
            self.assertEqual([item[1] for item in state["requests"]], ["/api/tags"])

    def test_response_size_limits_with_and_without_content_length(self):
        for mode in ["large-response", "large-stream"]:
            with self.subTest(mode=mode), fake_ollama() as (state, config):
                state["mode"] = mode
                config["max_response_bytes"] = 128
                with self.assertRaisesRegex(adapter.ProviderError, "max_response_bytes"):
                    adapter.evaluate(["a"], ["b"], DEFINITION, config)

    def test_deadline_includes_a_slow_trickle(self):
        for mode in ["slow-response", "slow-trickle"]:
            with self.subTest(mode=mode), fake_ollama() as (state, config):
                state["mode"] = mode
                config["timeout_seconds"] = 0.03
                started = time.monotonic()
                with self.assertRaisesRegex(adapter.ProviderError, "timeout_seconds"):
                    adapter.evaluate(["a"], ["b"], DEFINITION, config)
                self.assertLess(time.monotonic() - started, 0.5)

    def test_bad_metadata_and_inputs_make_no_requests(self):
        with fake_ollama() as (state, config):
            for key, value in [
                ("model_digest", "unpinned"), ("expected_dimensions", True),
                ("timeout_seconds", float("nan")), ("max_response_bytes", 0),
                ("model", ""), ("endpoint", "https://127.0.0.1:11434"),
                ("endpoint", "http://example.com"), ("endpoint", "http://127.0.0.1/extra"),
                ("endpoint", "http://127.0.0.1:0"),
                ("endpoint", "http://user:pass@127.0.0.1"), ("endpoint", "http://127.0.0.1/?q=secret"),
            ]:
                with self.subTest(key=key, value=value), self.assertRaises(adapter.ProviderError):
                    adapter.evaluate(["a"], ["b"], DEFINITION, dict(config, **{key: value}))
            for definition in [None, {}, {"instruction": "follow this prompt"},
                               {"operation": "cosine_similarity", "threshold": 1.1},
                               {"operation": "cosine_similarity", "threshold": True}]:
                with self.subTest(definition=definition), self.assertRaises(adapter.ProviderError):
                    adapter.evaluate(["a"], ["b"], definition, config)
            for lefts, rights in [(None, []), (["a"], []), ([None], ["a"]), ([1], ["a"]), ("a", "b")]:
                with self.subTest(inputs=(lefts, rights)), self.assertRaises(adapter.ProviderError):
                    adapter.evaluate(lefts, rights, DEFINITION, config)
            self.assertEqual(state["requests"], [])

    def test_installer_embeds_exact_tested_source(self):
        sql = installer.render_sql()
        body = sql.split("$jev_ollama_python$")[1]
        source = (ROOT / "providers" / "ollama_provider.py").read_text()
        self.assertIn(repr(source), body)
        self.assertIn("STABLE STRICT PARALLEL UNSAFE SECURITY INVOKER", sql)
        self.assertIn("FROM PUBLIC", sql)
        namespace = {}
        exec("def invoke(left_texts, right_texts, predicate_definition, model_config, SD, plpy):\n"
             + "\n".join("    " + line for line in body.splitlines()), namespace)
        with fake_ollama() as (_, config):
            self.assertEqual(namespace["invoke"](["a"], ["a"], json.dumps(DEFINITION), json.dumps(config), {}, None),
                             [(True, 1.0)])


if __name__ == "__main__":
    unittest.main()
