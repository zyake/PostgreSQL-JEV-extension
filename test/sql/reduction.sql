\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- This regression exercises an explicit SQL workflow, with no planner hooks.
CREATE TEMP TABLE jev_reduction_a(a_id text, a_key integer);
INSERT INTO jev_reduction_a VALUES
    ('shop',1), ('shop',1), (NULL,2),
    ('dead-end',3), ('no-edge',4), ('null-key',NULL);
CREATE TEMP TABLE jev_reduction_b(
    b_id text, a_key integer, c_key integer, left_text text, right_text text);
INSERT INTO jev_reduction_b VALUES
    ('offer',1,10,'boots','boots'), ('offer',1,10,'boots','boots'),
    ('offer',2,20,'coat','coat'),
    ('mismatch',1,10,'boots','sandals'), ('null-text',2,20,NULL,'coat'),
    ('bottom-cut',3,99,'poison:no-c','poison:no-c'),
    ('top-cut',9,30,'poison:no-a','poison:no-a'),
    ('null-a',NULL,10,'poison:null-a','poison:null-a'),
    ('null-c',1,NULL,'poison:null-c','poison:null-c'),
    ('both-orphan',8,88,'poison:orphan','poison:orphan');
CREATE TEMP TABLE jev_reduction_c(c_id text, c_key integer);
INSERT INTO jev_reduction_c VALUES
    ('stock',10), ('stock',10), (NULL,20),
    ('orphan-edge',30), ('no-edge',40), ('null-key',NULL);

-- Bottom-up C->B->A, followed by top-down A->B->C. Materialization fixes the
-- boundary before any provider call, and EXISTS preserves source multiplicity.
CREATE TEMP TABLE jev_reduction_b_up AS
SELECT b.* FROM jev_reduction_b AS b
WHERE EXISTS (SELECT FROM jev_reduction_c AS c WHERE c.c_key = b.c_key);
CREATE TEMP TABLE jev_reduction_a_ready AS
SELECT a.* FROM jev_reduction_a AS a
WHERE EXISTS (SELECT FROM jev_reduction_b_up AS b WHERE b.a_key = a.a_key);
CREATE TEMP TABLE jev_reduction_b_ready AS
SELECT b.* FROM jev_reduction_b_up AS b
WHERE EXISTS (SELECT FROM jev_reduction_a_ready AS a WHERE a.a_key = b.a_key);
CREATE TEMP TABLE jev_reduction_c_ready AS
SELECT c.* FROM jev_reduction_c AS c
WHERE EXISTS (SELECT FROM jev_reduction_b_ready AS b WHERE b.c_key = c.c_key);

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM jev_reduction_a) = 6;
    ASSERT (SELECT count(*) FROM jev_reduction_b) = 10;
    ASSERT (SELECT count(*) FROM jev_reduction_c) = 6;
    ASSERT (SELECT count(*) FROM jev_reduction_b_up) = 7, 'bottom-up B reduction incorrect';
    ASSERT (SELECT count(*) FROM jev_reduction_a_ready) = 3, 'bottom-up propagation to A failed';
    ASSERT (SELECT count(*) FROM jev_reduction_b_ready) = 5, 'top-down propagation to B failed';
    ASSERT (SELECT count(*) FROM jev_reduction_c_ready) = 3, 'top-down propagation to C failed';
    ASSERT NOT EXISTS (SELECT FROM jev_reduction_a_ready WHERE a_key IS NULL);
    ASSERT NOT EXISTS (SELECT FROM jev_reduction_b_ready WHERE a_key IS NULL OR c_key IS NULL);
    ASSERT NOT EXISTS (SELECT FROM jev_reduction_c_ready WHERE c_key IS NULL);
    ASSERT (SELECT count(*) FROM jev_reduction_b_ready WHERE b_id = 'offer') = 3,
        'business IDs must not be used as set or occurrence keys';
    ASSERT (SELECT count(*) FROM jev_reduction_b_ready WHERE left_text = 'boots' AND right_text = 'boots') = 2,
        'semijoin collapsed identical source rows';
END
$$;

-- First prove relational bag equivalence, before adding the semantic filter.
CREATE TEMP TABLE jev_reduction_full_join AS
SELECT a.a_id, b.b_id, c.c_id, b.left_text, b.right_text
FROM jev_reduction_a AS a
JOIN jev_reduction_b AS b ON b.a_key = a.a_key
JOIN jev_reduction_c AS c ON c.c_key = b.c_key;
CREATE TEMP TABLE jev_reduction_small_join AS
SELECT a.a_id, b.b_id, c.c_id, b.left_text, b.right_text
FROM jev_reduction_a_ready AS a
JOIN jev_reduction_b_ready AS b ON b.a_key = a.a_key
JOIN jev_reduction_c_ready AS c ON c.c_key = b.c_key;
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM jev_reduction_full_join) = 14;
    ASSERT NOT EXISTS (
        (TABLE jev_reduction_full_join EXCEPT ALL TABLE jev_reduction_small_join)
        UNION ALL
        (TABLE jev_reduction_small_join EXCEPT ALL TABLE jev_reduction_full_join)
    ), 'two-pass reduction changed the relational join bag';
END
$$;

-- Side-effect-free diagnostic: every surviving unique pair must arrive in one
-- provider block. Excluded rows would fail immediately if inference were moved
-- before the relational boundary. NULL pairs must never reach the provider.
CREATE FUNCTION pg_temp.jev_reduction_probe(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF cardinality($1) <> 3 OR cardinality($2) <> 3 THEN
        RAISE EXCEPTION 'expected exactly three reduced unique pairs';
    END IF;
    IF EXISTS (SELECT FROM unnest($1, $2) AS p(l, r)
               WHERE l IS NULL OR r IS NULL OR l LIKE 'poison:%') THEN
        RAISE EXCEPTION 'provider received NULL or relationally excluded input';
    END IF;
    IF EXISTS (SELECT FROM unnest($1, $2) AS p(l, r)
               GROUP BY l COLLATE "C", r COLLATE "C" HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'provider received duplicate pairs';
    END IF;
    RETURN jev.exact_provider($1, $2, $3, $4);
END
$$;
INSERT INTO jev.models(name, version, provider)
VALUES ('reduction-probe', '1', 'pg_temp.jev_reduction_probe(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name, version, model_name)
VALUES ('reduction-probe', '1', 'reduction-probe');

-- A generated private occurrence key makes duplicate/null business IDs safe.
CREATE TEMP TABLE jev_reduction_inputs AS
SELECT row_number() OVER ()::text AS row_id, b.* FROM jev_reduction_b_ready AS b;
CREATE TEMP TABLE jev_reduction_decisions AS
SELECT * FROM jev.evaluate_relation('reduction-probe', 'jev_reduction_inputs'::regclass, 128);
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM jev_reduction_decisions) = 5;
    ASSERT (SELECT count(DISTINCT row_id) FROM jev_reduction_decisions) = 5;
    ASSERT (SELECT count(*) FROM jev_reduction_decisions WHERE decision IS TRUE) = 3;
    ASSERT (SELECT count(*) FROM jev_reduction_decisions WHERE decision IS FALSE) = 1;
    ASSERT (SELECT count(*) FROM jev_reduction_decisions WHERE decision IS NULL AND confidence IS NULL) = 1,
        'strict NULL text result was lost';
END
$$;

CREATE TEMP TABLE jev_reduction_actual AS
SELECT a.a_id, b.b_id, c.c_id, b.left_text, b.right_text
FROM jev_reduction_inputs AS b
JOIN jev_reduction_decisions AS d ON d.row_id = b.row_id
JOIN jev_reduction_a_ready AS a ON a.a_key = b.a_key
JOIN jev_reduction_c_ready AS c ON c.c_key = b.c_key
WHERE d.decision IS TRUE;
CREATE TEMP TABLE jev_reduction_expected AS
SELECT * FROM jev_reduction_full_join
WHERE jev.semantic_match('exact', left_text, right_text);
DO $$
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_reduction_expected EXCEPT ALL TABLE jev_reduction_actual)
        UNION ALL
        (TABLE jev_reduction_actual EXCEPT ALL TABLE jev_reduction_expected)
    ), 'semantic reduction result differs from the full baseline bag';
    ASSERT (SELECT count(*) FROM jev_reduction_actual) = 9;
    ASSERT (SELECT count(*) FROM jev_reduction_actual
            WHERE a_id = 'shop' AND b_id = 'offer' AND c_id = 'stock') = 8,
        '2 x 2 x 2 source multiplicity was not preserved';
    ASSERT (SELECT count(*) FROM jev_reduction_actual
            WHERE a_id IS NULL AND b_id = 'offer' AND c_id IS NULL) = 1,
        'NULL business IDs were incorrectly treated as NULL join keys';
END
$$;

-- Empty root support propagates down both remaining edges. The diagnostic
-- provider rejects empty input, so success also proves zero provider dispatch.
CREATE TEMP TABLE jev_reduction_empty_a AS
SELECT * FROM jev_reduction_a_ready WHERE false;
CREATE TEMP TABLE jev_reduction_empty_b AS
SELECT b.* FROM jev_reduction_b_up AS b
WHERE EXISTS (SELECT FROM jev_reduction_empty_a AS a WHERE a.a_key = b.a_key);
CREATE TEMP TABLE jev_reduction_empty_c AS
SELECT c.* FROM jev_reduction_c AS c
WHERE EXISTS (SELECT FROM jev_reduction_empty_b AS b WHERE b.c_key = c.c_key);
CREATE TEMP TABLE jev_reduction_empty_inputs AS
SELECT row_number() OVER ()::text AS row_id, b.* FROM jev_reduction_empty_b AS b;
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM jev_reduction_empty_b) = 0;
    ASSERT (SELECT count(*) FROM jev_reduction_empty_c) = 0;
    ASSERT (SELECT count(*) FROM jev.evaluate_relation(
        'reduction-probe', 'jev_reduction_empty_inputs'::regclass, 128)) = 0;
END
$$;

ROLLBACK;
\echo 'explicit relational reduction assertions passed'
