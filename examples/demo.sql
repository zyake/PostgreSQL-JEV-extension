\set ON_ERROR_STOP on
\pset null '(NULL)'
\pset pager off

CREATE EXTENSION IF NOT EXISTS jev;
BEGIN;

-- Installed predicate/model metadata.
SELECT p.name AS predicate, p.version AS predicate_version,
       m.name AS model, m.version AS model_version, m.provider
FROM jev.predicates p JOIN jev.models m ON m.name = p.model_name
WHERE p.name = 'exact';

-- Four occurrences, two unique non-NULL pairs, one provider call of size two.
SELECT * FROM jev.evaluate_batch(
    'exact',
    ARRAY[
        ROW('42', 'winter boot', 'winter boot')::jev.candidate,
        ROW('42', 'winter boot', 'winter boot')::jev.candidate,
        ROW('43', 'summer shoe', 'winter boot')::jev.candidate,
        ROW('99', NULL, 'winter boot')::jev.candidate
    ],
    2
) ORDER BY ordinal;

CREATE TEMP TABLE jev_demo_products(product_id integer, description text);
INSERT INTO jev_demo_products VALUES
    (42, 'winter boot'),
    (42, 'winter boot'),
    (43, 'summer shoe'),
    (99, NULL);

LOAD 'jev';
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT product_id, description
FROM ONLY jev_demo_products
WHERE jev.semantic_match('exact', description, 'winter boot');

SELECT product_id, description
FROM ONLY jev_demo_products
WHERE jev.semantic_match('exact', description, 'winter boot')
ORDER BY product_id;

ROLLBACK;
