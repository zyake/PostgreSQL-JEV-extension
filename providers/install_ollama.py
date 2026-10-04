#!/usr/bin/env python3
"""Print self-contained provider SQL: python3 providers/install_ollama.py | psql.

An administrator must first CREATE EXTENSION jev and CREATE EXTENSION plpython3u.
The generated function is optional, outside the JEV extension, and not callable
by PUBLIC. Explicitly grant EXECUTE to intended inference callers after review.
"""

from pathlib import Path


def render_sql():
    source = Path(__file__).with_name("ollama_provider.py").read_text(encoding="utf-8")
    body = '''if "jev_ollama_adapter" not in SD:
    namespace = {}
    exec(compile(SOURCE_TEXT, "jev_ollama_provider", "exec"), namespace)
    SD["jev_ollama_adapter"] = namespace
adapter = SD["jev_ollama_adapter"]
try:
    return adapter["evaluate"](left_texts, right_texts, predicate_definition, model_config)
except adapter["ProviderError"] as exc:
    plpy.error(str(exc), sqlstate="38000")
'''.replace("SOURCE_TEXT", repr(source))
    delimiter = "$jev_ollama_python$"
    if delimiter in body:
        raise ValueError("SQL delimiter unexpectedly occurs in provider source")
    return '''-- Generated from providers/ollama_provider.py; no server-side module import.
-- Requires jev and plpython3u; execute this installation as a superuser.
BEGIN;
CREATE OR REPLACE FUNCTION jev.ollama_embedding_provider(
    left_texts text[], right_texts text[],
    predicate_definition jsonb, model_config jsonb
) RETURNS jev.prediction[]
LANGUAGE plpython3u STABLE STRICT PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS ''' + delimiter + "\n" + body + delimiter + ''';
REVOKE ALL ON FUNCTION jev.ollama_embedding_provider(text[],text[],jsonb,jsonb) FROM PUBLIC;
COMMENT ON FUNCTION jev.ollama_embedding_provider(text[],text[],jsonb,jsonb) IS
    'Optional local Ollama cosine similarity. Requires a digest-pinned immutable model tag. Confidence is (cosine+1)/2, not a probability.';
COMMIT;
'''


if __name__ == "__main__":
    print(render_sql(), end="")
