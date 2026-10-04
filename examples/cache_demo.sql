\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS jev;
LOAD 'jev';
BEGIN;
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
SET LOCAL jev.batch_size = 8;
CREATE TEMP TABLE jev_cache_demo(id integer, left_text text, right_text text);
INSERT INTO jev_cache_demo
SELECT i, (i % 32)::text, (i % 32)::text FROM generate_series(1,256) i;

-- Inputs repeat only after four buffers, so per-buffer deduplication cannot help.
SET LOCAL jev.result_cache_kb = 0;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM ONLY jev_cache_demo
WHERE jev.semantic_match('exact',left_text,right_text);

SET LOCAL jev.result_cache_kb = 4096;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM ONLY jev_cache_demo
WHERE jev.semantic_match('exact',left_text,right_text);
-- Expected: 256 rows in either case; unique evaluations 256->32,
-- kernel calls 32->4, and 224 cache hits in the enabled run.
ROLLBACK;
