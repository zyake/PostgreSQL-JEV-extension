\set ON_ERROR_STOP on
\pset pager off
\pset null '(NULL)'
CREATE EXTENSION IF NOT EXISTS jev;

-- An explicit two-pass reduction of the acyclic INNER equijoin A--B--C.
-- The semantic predicate uses B's texts only. This is ordinary SQL, not a
-- planner transformation, learned pruning, or a general join optimizer.
-- Keep a consistent snapshot when adapting this workflow to shared tables.
BEGIN ISOLATION LEVEL REPEATABLE READ;

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
    ('bottom-cut',3,99,'unused:no-c','unused:no-c'),
    ('top-cut',9,30,'unused:no-a','unused:no-a'),
    ('null-a',NULL,10,'unused:null-a','unused:null-a'),
    ('null-c',1,NULL,'unused:null-c','unused:null-c'),
    ('both-orphan',8,88,'unused:orphan','unused:orphan');

CREATE TEMP TABLE jev_reduction_c(c_id text, c_key integer);
INSERT INTO jev_reduction_c VALUES
    ('stock',10), ('stock',10), (NULL,20),
    ('orphan-edge',30), ('no-edge',40), ('null-key',NULL);

-- Bottom-up: C reduces B, then the surviving B rows reduce A.
-- EXISTS tests support without multiplying or collapsing the retained rows.
CREATE TEMP TABLE jev_reduction_b_up AS
SELECT b.* FROM jev_reduction_b AS b
WHERE EXISTS (SELECT FROM jev_reduction_c AS c WHERE c.c_key = b.c_key);

CREATE TEMP TABLE jev_reduction_a_ready AS
SELECT a.* FROM jev_reduction_a AS a
WHERE EXISTS (SELECT FROM jev_reduction_b_up AS b WHERE b.a_key = a.a_key);

-- Top-down: reduced A reduces B; this B then reduces C.
CREATE TEMP TABLE jev_reduction_b_ready AS
SELECT b.* FROM jev_reduction_b_up AS b
WHERE EXISTS (SELECT FROM jev_reduction_a_ready AS a WHERE a.a_key = b.a_key);

CREATE TEMP TABLE jev_reduction_c_ready AS
SELECT c.* FROM jev_reduction_c AS c
WHERE EXISTS (SELECT FROM jev_reduction_b_ready AS b WHERE b.c_key = c.c_key);

-- Measured fixture counts: A 6->3, B 10->7->5, C 6->3.
SELECT 'A' AS relation, (SELECT count(*) FROM jev_reduction_a) AS original_rows,
       (SELECT count(*) FROM jev_reduction_a_ready) AS reduced_rows
UNION ALL
SELECT 'B', (SELECT count(*) FROM jev_reduction_b),
       (SELECT count(*) FROM jev_reduction_b_ready)
UNION ALL
SELECT 'C', (SELECT count(*) FROM jev_reduction_c),
       (SELECT count(*) FROM jev_reduction_c_ready);

-- Business IDs are not occurrence keys: 'offer' occurs three times and two
-- source rows are identical. Assign a private key once, in this materialized
-- table, so result mapping preserves every occurrence. Its ordering is arbitrary.
CREATE TEMP TABLE jev_reduction_inputs AS
SELECT row_number() OVER ()::text AS row_id, b.* FROM jev_reduction_b_ready AS b;

-- Inference starts only after both relational passes. The explicit relation API
-- reads bounded blocks; it uses only row_id, left_text, and right_text columns.
CREATE TEMP TABLE jev_reduction_decisions AS
SELECT * FROM jev.evaluate_relation('exact', 'jev_reduction_inputs'::regclass, 128);

CREATE TEMP TABLE jev_reduction_result AS
SELECT a.a_id, b.b_id, c.c_id, b.left_text, b.right_text
FROM jev_reduction_inputs AS b
JOIN jev_reduction_decisions AS d ON d.row_id = b.row_id
JOIN jev_reduction_a_ready AS a ON a.a_key = b.a_key
JOIN jev_reduction_c_ready AS c ON c.c_key = b.c_key
WHERE d.decision IS TRUE;

-- Four non-NULL candidate occurrences contain three byte-distinct pairs.
-- The fifth candidate has NULL text and gets SQL NULL without provider work.
SELECT count(*) AS candidate_occurrences,
       count(*) FILTER (WHERE left_text IS NOT NULL AND right_text IS NOT NULL)
           AS nonnull_occurrences,
       count(DISTINCT (left_text COLLATE "C", right_text COLLATE "C"))
           FILTER (WHERE left_text IS NOT NULL AND right_text IS NOT NULL)
           AS distinct_nonnull_pairs
FROM jev_reduction_inputs;

-- Duplicate source rows multiply normally: 2 A x 2 B x 2 C = 8 boots rows.
-- The coat match has NULL business IDs but non-NULL join keys and survives.
SELECT a_id, b_id, c_id, left_text, right_text, count(*) AS multiplicity
FROM jev_reduction_result
GROUP BY a_id, b_id, c_id, left_text, right_text
ORDER BY left_text;

-- Reference query over the unreduced inputs; compare bags, not just counts.
-- This validation makes additional exact-provider calls; the counts above
-- describe the reduced input, not total inference across this whole example.
CREATE TEMP TABLE jev_reduction_reference AS
SELECT a.a_id, b.b_id, c.c_id, b.left_text, b.right_text
FROM jev_reduction_a AS a
JOIN jev_reduction_b AS b ON b.a_key = a.a_key
JOIN jev_reduction_c AS c ON c.c_key = b.c_key
WHERE jev.semantic_match('exact', b.left_text, b.right_text);

DO $$
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_reduction_reference EXCEPT ALL TABLE jev_reduction_result)
        UNION ALL
        (TABLE jev_reduction_result EXCEPT ALL TABLE jev_reduction_reference)
    ), 'explicit reduction changed the result bag';
END
$$;

-- Equality predicates deliberately use =: NULL join keys do not match, even
-- against another NULL. Do not transfer this recipe unchanged to outer/anti
-- joins, cross-relation semantic predicates, or providers with side effects.
ROLLBACK;
