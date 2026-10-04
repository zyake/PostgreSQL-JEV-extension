\set ON_ERROR_STOP on
\pset pager off
CREATE EXTENSION IF NOT EXISTS jev;
LOAD 'jev';
BEGIN;
CREATE TEMP TABLE switch_demo(id integer,l text,r text,active boolean);
INSERT INTO switch_demo SELECT i,'pair '||(i/8),'pair '||(i/8),i%10=0 FROM generate_series(1,2048) i;
ANALYZE switch_demo;
SET LOCAL jev.enable_custom_scan=on;
SET LOCAL jev.force_custom_scan=on; -- hold the access path fixed for this comparison
SET LOCAL jev.auto_batch_size=off;
SET LOCAL jev.batch_size=128;
SET LOCAL jev.enable_result_cache=off; -- isolate within-batch deduplication

SET LOCAL jev.enable_deduplication=off;
EXPLAIN (ANALYZE,TIMING OFF,COSTS OFF)
SELECT id FROM ONLY switch_demo WHERE jev.semantic_match('exact',l,r);
SET LOCAL jev.enable_deduplication=on;
EXPLAIN (ANALYZE,TIMING OFF,COSTS OFF)
SELECT id FROM ONLY switch_demo WHERE jev.semantic_match('exact',l,r);

-- Change only one switch per experiment. These are independent controls:
-- SET LOCAL jev.enable_batching = off;
-- SET LOCAL jev.enable_result_cache = off;
-- SET LOCAL jev.enable_relational_prefilter = off;
-- SET LOCAL jev.reuse_kernel_plan = off;
-- SET LOCAL jev.enable_selective_fallback = off;
-- SET LOCAL jev.enable_join_reduction = off;
-- Reduction affects explicit reduce_join_tree calls, not ordinary joins.
-- Fallback OFF evaluates all fallback inputs but retains the same decision policy.
ROLLBACK;
