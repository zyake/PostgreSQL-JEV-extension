-- Install providers/install_ollama.py's generated SQL first (see providers/README.md).
-- Pass model_digest from the running service's /api/tags; never guess it.
-- Example psql flags: -v endpoint=http://127.0.0.1:11434 -v model=all-minilm:22m
--                    -v model_digest=<64-hex-digest> -v dimensions=384
\set ON_ERROR_STOP on
\pset pager off
\pset null '(NULL)'
BEGIN;
INSERT INTO jev.models(name, version, provider, config)
VALUES ('demo-embeddings', :'model_digest',
        'jev.ollama_embedding_provider(text[],text[],jsonb,jsonb)'::regprocedure,
        jsonb_build_object('endpoint', :'endpoint', 'model', :'model',
                           'model_digest', :'model_digest',
                           'expected_dimensions', :dimensions));
INSERT INTO jev.predicates(name, version, model_name, definition)
VALUES ('demo-similar', '1', 'demo-embeddings',
        '{"operation":"cosine_similarity","threshold":0.5}');

SELECT ordinal, row_id, decision, round(confidence::numeric, 4) AS similarity_score
FROM jev.evaluate_batch('demo-similar', ARRAY[
    ROW('1', 'warm waterproof boots for winter', 'insulated snow boots')::jev.candidate,
    ROW('1', 'warm waterproof boots for winter', 'insulated snow boots')::jev.candidate,
    ROW('2', 'a SQL database query planner', 'insulated snow boots')::jev.candidate,
    ROW('3', NULL, 'insulated snow boots')::jev.candidate,
    ROW('4', 'insulated snow boots', 'insulated snow boots')::jev.candidate
], 8) ORDER BY ordinal;

CREATE TEMP TABLE jev_real_products(id integer, description text);
INSERT INTO jev_real_products VALUES
    (1, 'warm waterproof boots for winter'),
    (1, 'warm waterproof boots for winter'),
    (2, 'a SQL database query planner'),
    (3, NULL),
    (4, 'insulated snow boots');
LOAD 'jev';
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
SET LOCAL jev.batch_size = 8;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id, description FROM ONLY jev_real_products
WHERE jev.semantic_match('demo-similar', description, 'insulated snow boots');
SELECT id, description FROM ONLY jev_real_products
WHERE jev.semantic_match('demo-similar', description, 'insulated snow boots')
ORDER BY id;
ROLLBACK;
