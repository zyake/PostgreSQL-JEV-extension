"""Opt-in SQL wrapper integration in the test runner's disposable cluster."""

import json
import os
from pathlib import Path
import subprocess
import unittest

from provider_ollama import DEFINITION, fake_ollama, installer


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


@unittest.skipUnless(os.environ.get("JEV_TEST_SQL_PROVIDER") == "1",
                     "optional PL/Python SQL integration is not enabled")
class OllamaSQLTests(unittest.TestCase):
    def test_installed_wrapper_kernel_and_batched_scan(self):
        pg_config = os.environ.get("PG_CONFIG", "pg_config")
        bindir = subprocess.check_output([pg_config, "--bindir"], text=True).strip()
        psql = str(Path(bindir) / "psql")

        def sql(statement, succeeds=True):
            result = subprocess.run(
                [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose"],
                input=statement, text=True, capture_output=True, timeout=30,
            )
            if succeeds:
                self.assertEqual(result.returncode, 0, result.stderr)
            return result

        sql("CREATE EXTENSION IF NOT EXISTS jev; CREATE EXTENSION IF NOT EXISTS plpython3u;")
        sql(installer.render_sql())
        try:
            with fake_ollama() as (state, config):
                statement = """
BEGIN;
INSERT INTO jev.models(name, version, provider, config)
VALUES ('test-sql-ollama', '1',
        'jev.ollama_embedding_provider(text[],text[],jsonb,jsonb)'::regprocedure, CONFIG::jsonb);
INSERT INTO jev.predicates(name, version, model_name, definition)
VALUES ('test-sql-ollama', '1', 'test-sql-ollama', DEFINITION::jsonb);
SELECT 'kernel:' || jsonb_agg(to_jsonb(r) ORDER BY ordinal)::text
FROM jev.evaluate_batch('test-sql-ollama', ARRAY[
    ROW('duplicate', 'a', 'a')::jev.candidate,
    ROW('duplicate', 'a', 'a')::jev.candidate,
    ROW('different', 'a', 'b')::jev.candidate,
    ROW('null', NULL, 'a')::jev.candidate
], 8) AS r;
CREATE TEMP TABLE jev_provider_sql_items(id integer, description text);
INSERT INTO jev_provider_sql_items VALUES (1,'a'),(1,'a'),(2,'b'),(3,NULL);
LOAD 'jev';
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
SET LOCAL jev.batch_size = 8;
CREATE FUNCTION pg_temp.provider_plan() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE plan jsonb;
BEGIN
    EXECUTE $q$EXPLAIN (ANALYZE, FORMAT JSON, COSTS OFF, TIMING OFF)
        SELECT id FROM ONLY jev_provider_sql_items
        WHERE jev.semantic_match('test-sql-ollama', description, 'a')$q$ INTO plan;
    RETURN plan;
END
$$;
SELECT 'plan:' || pg_temp.provider_plan()::text;
SELECT 'scan:' || jsonb_agg(id ORDER BY id)::text FROM ONLY jev_provider_sql_items
WHERE jev.semantic_match('test-sql-ollama', description, 'a');
COMMIT;
""".replace("CONFIG", literal(json.dumps(config))).replace("DEFINITION", literal(json.dumps(DEFINITION)))
                output = sql(statement).stdout
                records = {line.split(":", 1)[0]: json.loads(line.split(":", 1)[1])
                           for line in output.splitlines() if line.startswith(("kernel:", "plan:", "scan:"))}
                expected = [
                    {"ordinal": 1, "row_id": "duplicate", "decision": True, "confidence": 1},
                    {"ordinal": 2, "row_id": "duplicate", "decision": True, "confidence": 1},
                    {"ordinal": 3, "row_id": "different", "decision": False, "confidence": 0.5},
                    {"ordinal": 4, "row_id": "null", "decision": None, "confidence": None},
                ]
                self.assertEqual(records["kernel"], expected)
                self.assertEqual(records["scan"], [1, 1])
                scans = [node for node in nodes(records["plan"])
                         if node.get("Custom Plan Provider") == "JEVSemanticScan"]
                self.assertEqual(len(scans), 1)
                self.assertEqual(scans[0]["Semantic Evaluation"], "batched")
                self.assertEqual(scans[0]["Candidate Rows"], 4)
                self.assertEqual(scans[0]["Unique Inputs"], 2)
                self.assertEqual(scans[0]["Reused Inputs"], 1)
                self.assertEqual(scans[0]["Provider Calls"], 1)
                self.assertEqual(len([item for item in state["requests"] if item[1] == "/api/embed"]), 3)

                state["mode"] = "short-output"
                failure = sql("SELECT jev.semantic_match('test-sql-ollama','a','b');", succeeds=False)
                self.assertNotEqual(failure.returncode, 0)
                self.assertIn("38000", failure.stderr)
                self.assertIn("one embedding per input text", failure.stderr)
                self.assertEqual(len([item for item in state["requests"] if item[1] == "/api/embed"]), 4)
        finally:
            sql("DELETE FROM jev.predicates WHERE name='test-sql-ollama'; "
                "DELETE FROM jev.models WHERE name='test-sql-ollama';")


if __name__ == "__main__":
    unittest.main()
