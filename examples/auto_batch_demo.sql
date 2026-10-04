\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS jev;
LOAD 'jev';
BEGIN;
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = off;
SET LOCAL jev.batch_size = 128;
SET LOCAL jev.batch_memory_kb = 1024;
SET LOCAL jev.result_cache_kb = 0;
SET LOCAL jev.batch_call_cost = 100;
SET LOCAL jev.batch_input_cost = 10;
SET LOCAL max_parallel_workers_per_gather = 0;
SET LOCAL jit = off;

CREATE TEMP TABLE jev_auto_batch_demo(id integer, left_text text, right_text text);
INSERT INTO jev_auto_batch_demo
SELECT i, CASE WHEN i % 97 = 0 THEN NULL ELSE 'item ' || i END, 'item ' || i
FROM generate_series(1,8192) AS i;
CREATE INDEX ON jev_auto_batch_demo(id);
ANALYZE jev_auto_batch_demo;

-- Fixed mode offers one batched strategy, capped at 128 candidate occurrences.
-- PostgreSQL may prefer an ordinary scan for a small LIMIT because the custom
-- scan must prepare its first buffer before returning any match.
SET LOCAL jev.auto_batch_size = off;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_auto_batch_demo
WHERE jev.semantic_match('exact',left_text,right_text)
LIMIT 16;

-- Automatic mode offers several sizes up to the same cap. A smaller selected
-- buffer can reduce initial work for LIMIT while sharing one kernel dispatch
-- across several pairs. Inspect Batch Size and Batch Size Selection.
-- The matching ids are unspecified without ORDER BY in both queries.
SET LOCAL jev.auto_batch_size = on;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_auto_batch_demo
WHERE jev.semantic_match('exact',left_text,right_text)
LIMIT 16;

-- Reading every match normally favors larger buffers and fewer dispatches.
-- NULL operands remain SQL NULL and are excluded by WHERE; all other pairs in
-- this fixture are unique, so the observed work does not rely on deduplication.
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_auto_batch_demo
WHERE jev.semantic_match('exact',left_text,right_text);

-- Native index paths still compete. A one-row index lookup should stay cheaper
-- than reading the whole heap, regardless of the offered semantic batch sizes.
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_auto_batch_demo
WHERE id = 1 AND jev.semantic_match('exact',left_text,right_text);
ROLLBACK;
