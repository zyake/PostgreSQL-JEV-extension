"""Opt-in smoke test against an already running local Ollama model.

Set JEV_OLLAMA_MODEL, JEV_OLLAMA_DIGEST, and JEV_OLLAMA_DIMENSIONS.
Optionally set JEV_OLLAMA_ENDPOINT (default http://127.0.0.1:11434).
This test never starts Ollama or downloads models.
"""

import importlib.util
import os
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "providers" / "ollama_provider.py"
SPEC = importlib.util.spec_from_file_location("jev_ollama_live", MODULE_PATH)
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)


@unittest.skipUnless(all(os.environ.get(key) for key in (
    "JEV_OLLAMA_MODEL", "JEV_OLLAMA_DIGEST", "JEV_OLLAMA_DIMENSIONS")), "opt-in live model is not configured")
class OllamaLiveTests(unittest.TestCase):
    def test_real_model_native_batch_and_pointwise_consistency(self):
        config = {
            "endpoint": os.environ.get("JEV_OLLAMA_ENDPOINT", "http://127.0.0.1:11434"),
            "model": os.environ["JEV_OLLAMA_MODEL"],
            "model_digest": os.environ["JEV_OLLAMA_DIGEST"],
            "expected_dimensions": int(os.environ["JEV_OLLAMA_DIMENSIONS"]),
            "timeout_seconds": 120,
        }
        definition = {"operation": "cosine_similarity", "threshold": 0.8}
        lefts = ["PostgreSQL is a relational database.", "A green tree grows in the garden."]
        rights = [lefts[0], "A plant is growing outdoors."]
        together = ADAPTER.evaluate(lefts, rights, definition, config)
        self.assertEqual(together[0], (True, 1.0))
        self.assertEqual(len(together), 2)
        for index in range(2):
            alone = ADAPTER.evaluate([lefts[index]], [rights[index]], definition, config)[0]
            self.assertEqual(together[index][0], alone[0])
            self.assertAlmostEqual(together[index][1], alone[1], places=5)
            self.assertGreaterEqual(alone[1], 0)
            self.assertLessEqual(alone[1], 1)


if __name__ == "__main__":
    unittest.main()
