\set ON_ERROR_STOP on
\pset pager off
\pset null '(NULL)'
CREATE EXTENSION IF NOT EXISTS jev;

-- Explicit exact reduction of the INNER equijoin tree A--B--C. Node numbers
-- refer to positions in the relations array; B (node 2) is this call's root.
-- The API performs both semijoin passes; it does not automatically rewrite
-- joins or infer a tree from SQL. No model is invoked by the reducer.
-- A transaction snapshot keeps all source copies consistent. The returned
-- private tables are ON COMMIT DROP: consume them before ending this transaction.
BEGIN ISOLATION LEVEL REPEATABLE READ;

CREATE TEMP TABLE jev_tree_a(a_id text, a_key integer) ON COMMIT DROP;
INSERT INTO jev_tree_a VALUES
    ('shop',1), ('shop',1), (NULL,2),
    ('dead-end',3), ('no-edge',4), ('null-key',NULL);

CREATE TEMP TABLE jev_tree_b(
    b_id text, a_key integer, c_key integer, left_text text, right_text text
) ON COMMIT DROP;
INSERT INTO jev_tree_b VALUES
    ('offer',1,10,'boots','boots'), ('offer',1,10,'boots','boots'),
    ('offer',2,20,'coat','coat'),
    ('mismatch',1,10,'boots','sandals'), ('null-text',2,20,NULL,'coat'),
    ('bottom-cut',3,99,'unused:no-c','unused:no-c'),
    ('top-cut',9,30,'unused:no-a','unused:no-a'),
    ('null-a',NULL,10,'unused:null-a','unused:null-a'),
    ('null-c',1,NULL,'unused:null-c','unused:null-c'),
    ('both-orphan',8,88,'unused:orphan','unused:orphan');

CREATE TEMP TABLE jev_tree_c(c_id text, c_key integer) ON COMMIT DROP;
INSERT INTO jev_tree_c VALUES
    ('stock',10), ('stock',10), (NULL,20),
    ('orphan-edge',30), ('no-edge',40), ('null-key',NULL);

-- Each edge specifies paired ordinary equality keys, supporting composite
-- keys through equally sized arrays. Equality does not match NULL keys.
CREATE TEMP TABLE jev_tree_metadata ON COMMIT DROP AS
SELECT * FROM jev.reduce_join_tree(
    ARRAY['jev_tree_a', 'jev_tree_b', 'jev_tree_c']::regclass[],
    ARRAY[
        ROW(1, ARRAY['a_key'], 2, ARRAY['a_key'])::jev.join_edge,
        ROW(2, ARRAY['c_key'], 3, ARRAY['c_key'])::jev.join_edge
    ],
    2
);

-- Expected counts: A 6 -> 3, B 10 -> 5, C 6 -> 3. All retained duplicate
-- occurrences remain present. The original tables have not been modified.
SELECT node, source_relation, input_rows, retained_rows
FROM jev_tree_metadata
ORDER BY node;

-- psql variables hold the returned relation identifiers for later statements.
-- regclass renders a properly quoted SQL relation name when quoting is needed.
SELECT reduced_relation AS a_ready FROM jev_tree_metadata WHERE node = 1 \gset
SELECT reduced_relation AS b_ready FROM jev_tree_metadata WHERE node = 2 \gset
SELECT reduced_relation AS c_ready FROM jev_tree_metadata WHERE node = 3 \gset

-- Business IDs are not occurrence keys: 'offer' occurs three times and two
-- rows are identical. Materialize a private occurrence key once so result
-- mapping preserves every duplicate. Its ordering is arbitrary.
CREATE TEMP TABLE jev_tree_inputs ON COMMIT DROP AS
SELECT row_number() OVER ()::text AS row_id, b.* FROM :b_ready AS b;

-- Only reduced B rows need semantic evaluation: the predicate uses B's texts.
-- The relation API reads bounded blocks and restores duplicate occurrences.
CREATE TEMP TABLE jev_tree_decisions ON COMMIT DROP AS
SELECT * FROM jev.evaluate_relation('exact', 'jev_tree_inputs'::regclass, 128);

CREATE TEMP TABLE jev_tree_result ON COMMIT DROP AS
SELECT a.a_id, b.b_id, c.c_id, b.left_text, b.right_text
FROM jev_tree_inputs AS b
JOIN jev_tree_decisions AS d ON d.row_id = b.row_id
JOIN :a_ready AS a ON a.a_key = b.a_key
JOIN :c_ready AS c ON c.c_key = b.c_key
WHERE d.decision IS TRUE;

-- Expected: 5 candidates, 4 non-NULL occurrences, 3 distinct non-NULL pairs.
-- The fifth candidate has NULL text and receives SQL NULL without inference.
SELECT count(*) AS candidate_occurrences,
       count(*) FILTER (WHERE left_text IS NOT NULL AND right_text IS NOT NULL)
           AS nonnull_occurrences,
       count(DISTINCT (left_text COLLATE "C", right_text COLLATE "C"))
           FILTER (WHERE left_text IS NOT NULL AND right_text IS NOT NULL)
           AS distinct_nonnull_pairs
FROM jev_tree_inputs;

-- Expected: 9 result rows. Duplicate sources multiply normally:
-- 2 A x 2 B x 2 C = 8 boots rows, plus 1 coat row with NULL business IDs.
SELECT count(*) AS semantic_result_rows FROM jev_tree_result;
SELECT a_id, b_id, c_id, left_text, right_text, count(*) AS multiplicity
FROM jev_tree_result
GROUP BY a_id, b_id, c_id, left_text, right_text
ORDER BY left_text;

-- Reference query over original inputs; compare bags, not just counts.
-- Validation makes additional exact-provider calls. The candidate counts
-- above describe only the reduced input, not this whole example's inference.
CREATE TEMP TABLE jev_tree_reference ON COMMIT DROP AS
SELECT a.a_id, b.b_id, c.c_id, b.left_text, b.right_text
FROM jev_tree_a AS a
JOIN jev_tree_b AS b ON b.a_key = a.a_key
JOIN jev_tree_c AS c ON c.c_key = b.c_key
WHERE jev.semantic_match('exact', b.left_text, b.right_text);

SELECT NOT EXISTS (
    (TABLE jev_tree_reference EXCEPT ALL TABLE jev_tree_result)
    UNION ALL
    (TABLE jev_tree_result EXCEPT ALL TABLE jev_tree_reference)
) AS result_bags_equal;

DO $$
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_tree_reference EXCEPT ALL TABLE jev_tree_result)
        UNION ALL
        (TABLE jev_tree_result EXCEPT ALL TABLE jev_tree_reference)
    ), 'join-tree reduction changed the result bag';
END
$$;

-- This exact tree API covers inner equijoins. Do not apply the same reduction
-- to outer/anti joins, cyclic graphs, or semantic conditions spanning tables.
ROLLBACK;
