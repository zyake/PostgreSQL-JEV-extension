\set ON_ERROR_STOP on
BEGIN;

-- Deliberately use assertions instead of depending on EXPLAIN/timing text.
CREATE FUNCTION pg_temp.expect_error(statement text, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        RETURN;
    END;
    RAISE EXCEPTION 'Expected an error: %', label;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(r) ORDER BY ordinal) INTO actual
    FROM jev.evaluate_batch('exact', ARRAY[
        ROW('duplicate-id', 'a', 'a')::jev.candidate,
        ROW('duplicate-id', 'a', 'a')::jev.candidate,
        ROW(NULL, 'a', 'b')::jev.candidate,
        ROW('left-null', NULL, 'a')::jev.candidate,
        ROW('right-null', 'a', NULL)::jev.candidate,
        NULL::jev.candidate,
        ROW('empty', '', '')::jev.candidate
    ], 2) AS r;
    ASSERT actual = '[
        {"ordinal":1,"row_id":"duplicate-id","decision":true,"confidence":1},
        {"ordinal":2,"row_id":"duplicate-id","decision":true,"confidence":1},
        {"ordinal":3,"row_id":null,"decision":false,"confidence":1},
        {"ordinal":4,"row_id":"left-null","decision":null,"confidence":null},
        {"ordinal":5,"row_id":"right-null","decision":null,"confidence":null},
        {"ordinal":6,"row_id":null,"decision":null,"confidence":null},
        {"ordinal":7,"row_id":"empty","decision":true,"confidence":1}
    ]'::jsonb, 'order, row IDs, duplicate multiplicity, or NULL semantics changed';

    ASSERT (SELECT count(*) = 0 FROM jev.evaluate_batch('exact', '{}'::jev.candidate[])),
        'empty batch must be empty';
    ASSERT jev.semantic_match('exact', 'x', 'x') IS TRUE;
    ASSERT jev.semantic_match('exact', 'x', 'y') IS FALSE;
    ASSERT jev.semantic_match('exact', NULL, 'y') IS NULL;
    ASSERT jev.semantic_match(NULL, 'x', 'x') IS NULL;
    ASSERT jev.semantic_match('missing-but-strict-null', 'x', NULL) IS NULL;
END
$$;

-- Array subscripts are not row ordinals; non-1 lower bounds remain valid.
DO $$
DECLARE input jev.candidate[]; actual bigint[];
BEGIN
    input := array_fill(ROW('same', 'x', 'x')::jev.candidate, ARRAY[3], ARRAY[-2]);
    SELECT array_agg(ordinal ORDER BY ordinal) INTO actual
    FROM jev.evaluate_batch('exact', input, 1);
    ASSERT actual = ARRAY[1,2,3]::bigint[], 'candidate lower bounds leaked into ordinal';
END
$$;

-- This provider exposes its input chunk size without external side effects.
CREATE FUNCTION public.jev_test_chunk_provider(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE sql IMMUTABLE AS $$
    SELECT array_agg(ROW(l = r, cardinality($1)::float8 / 10)::jev.prediction ORDER BY n)
    FROM unnest($1, $2) WITH ORDINALITY AS u(l, r, n)
$$;
INSERT INTO jev.models(name, version, provider)
VALUES ('test-chunks', '1', 'public.jev_test_chunk_provider(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name, version, model_name)
VALUES ('test-chunks', '1', 'test-chunks');
DO $$
DECLARE actual float8[];
BEGIN
    SELECT array_agg(confidence ORDER BY ordinal) INTO actual
    FROM jev.evaluate_batch('test-chunks', ARRAY[
        ROW('1', 'x', 'x')::jev.candidate,
        ROW('2', 'x', 'x')::jev.candidate,
        ROW('3', 'y', 'z')::jev.candidate,
        ROW('4', 'x', 'x')::jev.candidate,
        ROW('5', 'z', 'z')::jev.candidate,
        ROW('6', 'y', 'z')::jev.candidate,
        ROW('7', NULL, 'x')::jev.candidate
    ], 2);
    ASSERT actual = ARRAY[0.2,0.2,0.2,0.2,0.1,0.2,NULL]::float8[],
        'deduplication must span the whole call and exclude NULL pairs';
END
$$;

-- Exact-byte identity preserves case and distinct Unicode encodings. The
-- chunk probe also proves these pairs are not merged before evaluation.
DO $$
DECLARE input jev.candidate[];
BEGIN
    input := ARRAY[
        ROW('upper', 'A', 'A')::jev.candidate,
        ROW('lower', 'a', 'A')::jev.candidate,
        ROW('composed', U&'\00E9', U&'\00E9')::jev.candidate,
        ROW('decomposed', U&'e\0301', U&'\00E9')::jev.candidate,
        ROW('upper-again', 'A', 'A')::jev.candidate
    ];
    ASSERT (SELECT array_agg(decision ORDER BY ordinal)
            FROM jev.evaluate_batch('exact', input)) = ARRAY[true,false,true,false,true],
        'exact provider normalized case or Unicode';
    ASSERT (SELECT array_agg(confidence ORDER BY ordinal)
            FROM jev.evaluate_batch('test-chunks', input)) = ARRAY[0.4,0.4,0.4,0.4,0.4]::float8[],
        'deduplication merged byte-distinct case or Unicode pairs';
END
$$;

CREATE FUNCTION public.jev_test_config_provider(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE sql STABLE AS $$
    SELECT array_agg(ROW(
        CASE WHEN coalesce(($4->>'invert')::boolean, false) THEN l <> r ELSE l = r END,
        ($3->>'confidence')::float8
    )::jev.prediction ORDER BY n)
    FROM unnest($1, $2) WITH ORDINALITY AS u(l, r, n)
$$;
INSERT INTO jev.models(name, version, provider, config)
VALUES ('test-config', '1', 'public.jev_test_config_provider(text[],text[],jsonb,jsonb)'::regprocedure, '{"invert":false}');
INSERT INTO jev.predicates(name, version, model_name, definition)
VALUES ('test-config', '1', 'test-config', '{"confidence":0.9}');
DO $$
BEGIN
    ASSERT (SELECT decision AND confidence = 0.9
            FROM jev.evaluate_batch('test-config', ARRAY[ROW('a','x','x')::jev.candidate]));
END
$$;
UPDATE jev.models SET version = '2', config = '{"invert":true}' WHERE name = 'test-config';
UPDATE jev.predicates SET version = '2', definition = '{"confidence":0.7}' WHERE name = 'test-config';
DO $$
BEGIN
    ASSERT (SELECT NOT decision AND confidence = 0.7
            FROM jev.evaluate_batch('test-config', ARRAY[ROW('a','x','x')::jev.candidate])),
        'model/predicate metadata was stale across calls';
END
$$;

-- Batching is observationally invisible for a deterministic pointwise provider.
DO $$
DECLARE candidates jev.candidate[];
BEGIN
    SELECT array_agg(ROW(n::text, (n % 7)::text, (n % 3)::text)::jev.candidate ORDER BY n)
    INTO candidates FROM generate_series(1, 53) AS n;
    ASSERT NOT EXISTS (
        (SELECT * FROM jev.evaluate_batch('exact', candidates, 1)
         EXCEPT ALL SELECT * FROM jev.evaluate_batch('exact', candidates, 11))
        UNION ALL
        (SELECT * FROM jev.evaluate_batch('exact', candidates, 11)
         EXCEPT ALL SELECT * FROM jev.evaluate_batch('exact', candidates, 1))
    ), 'batch size changed deterministic results or duplicate multiplicities';
END
$$;

SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('absent', '{}'::jev.candidate[])$q$, 'unknown predicate');
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch(NULL, '{}'::jev.candidate[])$q$, 'NULL predicate');
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('exact', NULL::jev.candidate[])$q$, 'NULL whole batch');
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('exact', '{}'::jev.candidate[], 0)$q$, 'zero batch size');
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('exact', '{}'::jev.candidate[], -1)$q$, 'negative batch size');
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('exact', '{}'::jev.candidate[], NULL)$q$, 'NULL batch size');
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('exact', ARRAY[[ROW('a','x','x')::jev.candidate]])$q$, 'multidimensional input');

CREATE FUNCTION public.jev_test_bad_provider(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    CASE $4->>'mode'
        WHEN 'short' THEN RETURN '{}'::jev.prediction[];
        WHEN 'long' THEN RETURN ARRAY[ROW(true,1)::jev.prediction, ROW(true,1)::jev.prediction];
        WHEN 'null-array' THEN RETURN NULL;
        WHEN 'null-entry' THEN RETURN ARRAY[NULL::jev.prediction];
        WHEN 'null-decision' THEN RETURN ARRAY[ROW(NULL,1)::jev.prediction];
        WHEN 'null-confidence' THEN RETURN ARRAY[ROW(true,NULL)::jev.prediction];
        WHEN 'high' THEN RETURN ARRAY[ROW(true,1.1)::jev.prediction];
        WHEN 'low' THEN RETURN ARRAY[ROW(true,-0.1)::jev.prediction];
        WHEN 'nan' THEN RETURN ARRAY[ROW(true,'NaN'::float8)::jev.prediction];
        WHEN 'infinity' THEN RETURN ARRAY[ROW(true,'Infinity'::float8)::jev.prediction];
        WHEN 'multidimensional' THEN RETURN ARRAY[[ROW(true,1)::jev.prediction]];
        WHEN 'lower-bound' THEN RETURN array_fill(ROW(true,1)::jev.prediction, ARRAY[cardinality($1)], ARRAY[-3]);
        ELSE RAISE EXCEPTION 'Unexpected test provider mode';
    END CASE;
END
$$;
INSERT INTO jev.models(name, version, provider)
VALUES ('test-bad', '1', 'public.jev_test_bad_provider(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name, version, model_name) VALUES ('test-bad', '1', 'test-bad');
DO $$
DECLARE mode text;
BEGIN
    FOREACH mode IN ARRAY ARRAY['short','long','null-array','null-entry','null-decision',
        'null-confidence','high','low','nan','infinity','multidimensional'] LOOP
        UPDATE jev.models SET config = jsonb_build_object('mode', mode) WHERE name = 'test-bad';
        PERFORM pg_temp.expect_error(
            $q$SELECT * FROM jev.evaluate_batch('test-bad', ARRAY[ROW('a','x','x')::jev.candidate])$q$,
            'invalid provider output: ' || mode);
    END LOOP;
END
$$;
UPDATE jev.models SET config = '{"mode":"lower-bound"}' WHERE name = 'test-bad';
DO $$
BEGIN
    ASSERT (SELECT decision AND confidence = 1 FROM jev.evaluate_batch('test-bad', ARRAY[ROW('a','x','x')::jev.candidate])),
        'provider lower bounds must not affect positional correspondence';
END
$$;
UPDATE jev.models SET provider = 'pg_catalog.length(text)'::regprocedure WHERE name = 'test-bad';
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('test-bad', ARRAY[ROW('a','x','x')::jev.candidate])$q$, 'invalid provider signature');

CREATE FUNCTION public.jev_test_volatile_provider(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE sql VOLATILE AS $$
    SELECT ARRAY[ROW(true,1)::jev.prediction]
$$;
UPDATE jev.models SET provider = 'public.jev_test_volatile_provider(text[],text[],jsonb,jsonb)'::regprocedure WHERE name = 'test-bad';
SELECT pg_temp.expect_error($q$SELECT * FROM jev.evaluate_batch('test-bad', ARRAY[ROW('a','x','x')::jev.candidate])$q$, 'volatile provider');

-- Metadata regprocedure values intentionally do not create dependencies.
-- A dropped provider must fail clearly; changing its registry entry recovers.
CREATE FUNCTION public.jev_test_dropped_provider(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE sql STABLE AS $$
    SELECT jev.exact_provider($1, $2, $3, $4)
$$;
INSERT INTO jev.models(name, version, provider)
VALUES ('test-dropped', '1', 'public.jev_test_dropped_provider(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name, version, model_name)
VALUES ('test-dropped', '1', 'test-dropped');
DO $$
BEGIN
    ASSERT jev.semantic_match('test-dropped', 'x', 'x') IS TRUE;
END
$$;
DROP FUNCTION public.jev_test_dropped_provider(text[], text[], jsonb, jsonb);
DO $$
DECLARE missing boolean := false;
BEGIN
    BEGIN
        PERFORM jev.semantic_match('test-dropped', 'x', 'x');
    EXCEPTION WHEN undefined_object THEN missing := true;
    END;
    ASSERT missing, 'dropped provider retained a stale callable or cached result';
END
$$;
UPDATE jev.models
SET version = '2', provider = 'jev.exact_provider(text[],text[],jsonb,jsonb)'::regprocedure
WHERE name = 'test-dropped';
DO $$
BEGIN
    ASSERT jev.semantic_match('test-dropped', 'x', 'x') IS TRUE,
        'provider registry correction did not restore evaluation';
    ASSERT jev.semantic_match('test-dropped', 'x', 'y') IS FALSE;
END
$$;

-- A provider call must use the caller's EXECUTE privileges.
CREATE ROLE jev_test_kernel_reader NOLOGIN;
GRANT USAGE ON SCHEMA jev, public TO jev_test_kernel_reader;
GRANT SELECT ON jev.models, jev.predicates TO jev_test_kernel_reader;
REVOKE ALL ON FUNCTION public.jev_test_config_provider(text[],text[],jsonb,jsonb) FROM PUBLIC;
SET LOCAL ROLE jev_test_kernel_reader;
DO $$
DECLARE denied boolean := false;
BEGIN
    BEGIN
        PERFORM * FROM jev.evaluate_batch('test-config', ARRAY[ROW('a','x','x')::jev.candidate]);
    EXCEPTION WHEN insufficient_privilege THEN denied := true;
    END;
    ASSERT denied, 'provider EXECUTE permissions bypassed';
END
$$;
RESET ROLE;
GRANT EXECUTE ON FUNCTION public.jev_test_config_provider(text[],text[],jsonb,jsonb) TO jev_test_kernel_reader;

-- Metadata lookup must also honor the caller's row visibility.
ALTER TABLE jev.predicates ENABLE ROW LEVEL SECURITY;
CREATE POLICY jev_test_metadata_visibility ON jev.predicates USING (name <> 'exact');
SET LOCAL ROLE jev_test_kernel_reader;
DO $$
DECLARE hidden boolean := false;
BEGIN
    ASSERT (SELECT count(*) = 0 FROM jev.predicates WHERE name = 'exact');
    ASSERT jev.semantic_match('test-config', 'x', 'x') IS FALSE;
    BEGIN
        PERFORM jev.semantic_match('exact', 'x', 'x');
    EXCEPTION WHEN undefined_object THEN hidden := true;
    END;
    ASSERT hidden, 'metadata lookup bypassed caller RLS';
END
$$;
RESET ROLE;

ROLLBACK;
\echo 'kernel assertions passed'
