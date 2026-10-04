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

CREATE TEMP TABLE jev_cost_demo(id integer, left_text text, right_text text);
INSERT INTO jev_cost_demo
SELECT i, 'item ' || i, 'item ' || i FROM generate_series(1,8192) i;
CREATE INDEX ON jev_cost_demo(id);
ANALYZE jev_cost_demo;

-- All rows require evaluation. With the default estimates, PostgreSQL should
-- choose JEVSemanticScan without force_custom_scan. Inspect estimated work and
-- actual counters together; planner costs are arbitrary units, not milliseconds.
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_cost_demo
WHERE jev.semantic_match('exact',left_text,right_text);

-- An ordinary index narrows the input to one row. The native index scan should
-- be cheaper than the custom path, which currently scans the whole heap.
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_cost_demo
WHERE id = 4096 AND jev.semantic_match('exact',left_text,right_text);

-- Batching must fill its first buffer before returning a row. A native scan can
-- stop after the first match, so this LIMIT should favor its low startup cost.
-- Without ORDER BY, the particular matching id returned is unspecified.
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_cost_demo
WHERE jev.semantic_match('exact',left_text,right_text)
LIMIT 1;

-- This deliberately pessimistic estimate demonstrates planner choice, not an
-- observed provider slowdown. Both cost settings use cpu_operator_cost units.
SET LOCAL jev.batch_call_cost = 1000000;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT id FROM ONLY jev_cost_demo
WHERE jev.semantic_match('exact',left_text,right_text);
ROLLBACK;
