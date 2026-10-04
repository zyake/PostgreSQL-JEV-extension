\set ON_ERROR_STOP on
\pset pager off
CREATE EXTENSION IF NOT EXISTS jev;
LOAD 'jev';
BEGIN;
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
SET LOCAL jev.result_cache_kb = 0; -- isolate batching; see optimization demo for scan reuse

CREATE TEMP TABLE jev_batch_demo(id integer, l text, r text, active boolean);
INSERT INTO jev_batch_demo VALUES
    (1, 'a', 'a', true), (2, 'a', 'a', true),
    (3, 'b', 'b', true), (4, 'b', 'c', true),
    (5, 'a', 'a', true), (6, 'a', 'a', true),
    (7, NULL, 'a', true), (8, 'a', NULL, true),
    (9, 'c', 'c', true), (10, 'c', 'c', true),
    (11, 'd', 'e', true), (12, 'ignored', 'ignored', false);

-- Same query and data: compare singleton dispatch with four-row buffers.
SET LOCAL jev.batch_size = 1;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM ONLY jev_batch_demo
WHERE active AND jev.semantic_match('exact', l, r);

SET LOCAL jev.batch_size = 4;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM ONLY jev_batch_demo
WHERE active AND jev.semantic_match('exact', l, r);

SELECT id FROM ONLY jev_batch_demo
WHERE active AND jev.semantic_match('exact', l, r)
ORDER BY id;
ROLLBACK;
