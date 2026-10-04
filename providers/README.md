# Optional local Ollama embeddings

`ollama_embedding_provider` gives JEV a real, replaceable embedding provider.
It sends multiple texts in one Ollama `/api/embed` request, computes cosine
similarity for each pair, and compares that value with a predicate threshold.
It does not interpret arbitrary natural-language predicate instructions.

The base JEV extension works without this adapter. Installation requires
**Python 3.9 or later**, PostgreSQL 17's optional **PL/Python (`plpython3u`)**,
and an already running local Ollama service with an embedding model installed.
Install the PL/Python package that matches the PostgreSQL server, for example
`postgresql-plpython3-17` on distributions providing that package.

## Install and register

Run the SQL installation as a database superuser. PL/Python is an untrusted
language: its functions run Python with the database server's operating-system
permissions. The function itself uses SQL `SECURITY INVOKER`.

```sh
psql -X -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS jev; CREATE EXTENSION IF NOT EXISTS plpython3u;'
python3 providers/install_ollama.py > /tmp/jev-ollama-provider.sql
psql -X -v ON_ERROR_STOP=1 -f /tmp/jev-ollama-provider.sql
```

The generator embeds the tested Python adapter in the SQL function. No Python
package installation, Python search-path setting, or source-file access by the
database server is required. Re-run the generator and SQL installation after
updating the adapter source. The provider is installed separately from the
base extension; installing JEV alone does not enable HTTP inference.

Inspect the running service's `/api/tags` response to obtain the **exact model
name and SHA-256 digest**. Determine its native embedding dimensions with a
small `/api/embed` request. Do not guess these values. The adapter never starts
Ollama, downloads a model, or silently truncates oversized text.

```sql
-- Replace model tag, digest, and dimension placeholders with verified values.
INSERT INTO jev.models(name, version, provider, config, score_kind)
VALUES ('local-embeddings', 'verified-model-digest',
        'jev.ollama_embedding_provider(text[],text[],jsonb,jsonb)'::regprocedure,
        '{"endpoint":"http://127.0.0.1:11434",
          "model":"your-embedding-model:fixed-tag",
          "model_digest":"replace-with-64-hex-digest",
          "expected_dimensions":384}', 'similarity');

INSERT INTO jev.predicates(name, version, model_name, definition)
VALUES ('similar-text', '1', 'local-embeddings',
        '{"operation":"cosine_similarity","threshold":0.5}');

-- Substitute an existing application role. PUBLIC has no provider EXECUTE.
GRANT EXECUTE ON FUNCTION
    jev.ollama_embedding_provider(text[],text[],jsonb,jsonb) TO application_role;

SELECT * FROM jev.evaluate_batch('similar-text', ARRAY[
    ROW('1','warm waterproof boots','insulated snow boots')::jev.candidate,
    ROW('2','database query planner','insulated snow boots')::jev.candidate
]);
```

Use metadata names and versions that identify the actual deployed model and
predicate revision. Configuration is publicly readable under the default JEV
grants; put no credentials or secrets in it. Grant provider execution only to
intended inference callers. Those callers can also invoke the provider directly
with their own configuration, so this grant permits local HTTP inference calls.

The executable [Ollama SQL example](../examples/ollama_demo.sql) accepts verified
connection/model settings as `psql` variables and demonstrates both SQL APIs.

## Meaning and boundaries

| Value | Meaning |
| --- | --- |
| Predicate `threshold` | Inclusive cosine threshold, in `[-1, 1]` |
| `decision` | `cosine >= threshold` |
| Result `confidence` | Similarity score `(cosine + 1) / 2`, in `[0, 1]` |
| Threshold `0.5` | Equivalent score cutoff `0.75` |

The field named `confidence` by the shared SQL API is a similarity score here,
**not a calibrated probability of correctness**. Choose a threshold using
examples from the intended application. This adapter provides no automatic
calibration, learned pruning, or LLM fallback. The kernel's optional confidence
cascade rejects similarity scores; do not declare this model as decision_confidence.

Every call checks `/api/tags` before and after inference and rejects an absent
model, digest mismatch, or observed tag change. Ollama's embedding response
contains a model name rather than an atomic digest pin. Administrators must
therefore keep the registered tag immutable; a concurrent tag swap and swap-back
cannot be ruled out by these checks. Register a new metadata version when
changing the model or predicate.

One native embedding request covers the byte-distinct texts on both sides of a
provider batch. Pair order and multiplicity are restored afterward. Embeddings
and predictions are not cached across calls. JEV's kernel excludes NULL text
pairs before invoking the provider. For a fixed model, each pair is evaluated
independently of neighboring pairs; small floating-point differences between
native model batches can still affect decisions exactly at a threshold.

The adapter rejects malformed JSON, missing/extra embeddings, wrong dimensions,
non-finite components, and zero-norm vectors. It uses `truncate: false`, so an
input exceeding the model context window causes an error. Provider failures
fail the SQL statement and are never converted to false decisions.

| Model configuration | Default / accepted values |
| --- | --- |
| `model` | Required exact installed tag |
| `model_digest` | Required 64-hex SHA-256, optional `sha256:` prefix |
| `expected_dimensions` | Required native dimension count, `1..65536` |
| `endpoint` | `http://127.0.0.1:11434`; HTTP loopback only |
| `timeout_seconds` | `30`; absolute deadline per HTTP request, `0.01..120` |
| `max_response_bytes` | `4194304`; `128..67108864` |

Endpoint credentials, non-loopback hosts, redirects, proxies, and endpoint paths
are unsupported. `localhost` is mapped directly to `127.0.0.1`; IPv6 loopback is
also supported. Each provider call normally makes two tag requests and one
embedding request, each with its own deadline. Embedding request bodies are
limited to 8 MiB. These bounds do not impose a total PostgreSQL process-memory
limit. Model serving itself is an external effect and is not rolled back when
a SQL transaction aborts.

## Tests

Fake HTTP tests exercise actual local requests, native batching, digest checks,
malformed outputs, size limits, slow-response deadlines, and generated wrapper
code. No model is required:

```sh
python3 -m unittest discover -s test -p 'provider*.py' -v
```

The SQL wrapper test is optional because it needs PL/Python. It runs against the
disposable PostgreSQL cluster created by the project test runner, checking the
explicit kernel, a real batched `CustomScan`, request counts, duplicates/NULLs,
and propagated provider errors:

```sh
JEV_TEST_SQL_PROVIDER=1 make PG_CONFIG=/path/to/postgresql17/bin/pg_config check-local
```

For a real model already running locally, opt in with its verified settings:

```sh
JEV_OLLAMA_ENDPOINT=http://127.0.0.1:11434 \
JEV_OLLAMA_MODEL=your-embedding-model:fixed-tag \
JEV_OLLAMA_DIGEST=your-verified-64-hex-digest \
JEV_OLLAMA_DIMENSIONS=384 \
python3 -m unittest discover -s test -p 'provider_ollama_live.py' -v
```

The live test checks real model output and compares grouped versus individual
pair evaluation. It never starts a service or downloads a model. Use the SQL
example to inspect application-specific similarity results.

The adapter follows Ollama's official [embedding endpoint](https://docs.ollama.com/api/embed)
and [model-list endpoint](https://docs.ollama.com/api/tags), and PostgreSQL's
[PL/Python installation and privilege model](https://www.postgresql.org/docs/17/plpython.html).
