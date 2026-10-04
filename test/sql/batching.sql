\set ON_ERROR_STOP on
LOAD 'jev';
BEGIN;
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
SET LOCAL jev.batch_size = 4;
SET LOCAL jev.batch_memory_kb = 1024;
-- Test the original per-buffer behavior independently of the new scan cache.
SET LOCAL jev.result_cache_kb = 0;

CREATE FUNCTION pg_temp.jev_batch_plan(statement text, run_query boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF' ||
        CASE WHEN run_query THEN ', ANALYZE, TIMING OFF, SUMMARY OFF' ELSE '' END ||
        ') ' || statement INTO result;
    RETURN result;
END
$$;
CREATE FUNCTION pg_temp.jev_batch_node(plan jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_path_query_first($1,
        '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")')
$$;

-- A side-effect-free probe proves that the actual provider receives deduplicated
-- arrays, excludes NULLs, and sees a full chunk rather than scalar invocations.
-- EXPLAIN supplies call counts; the provider never writes SQL instrumentation.
CREATE FUNCTION public.jev_batch_probe(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT FROM unnest($1, $2) AS p(l, r)
               WHERE l IS NULL OR r IS NULL OR l = 'poison') THEN
        RAISE EXCEPTION 'provider received NULL or relationally excluded input';
    END IF;
    IF EXISTS (SELECT FROM unnest($1, $2) AS p(l, r)
               GROUP BY l COLLATE "C", r COLLATE "C" HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'provider received duplicate input pairs';
    END IF;
    IF $4 ? 'expected_unique'
       AND cardinality($1) <> ($4->>'expected_unique')::integer THEN
        RAISE EXCEPTION 'expected % unique inputs, received %',
            $4->>'expected_unique', cardinality($1);
    END IF;
    IF cardinality($1) > 4 THEN
        RAISE EXCEPTION 'provider exceeded the configured batch size';
    END IF;
    RETURN jev.exact_provider($1, $2, $3, $4);
END
$$;
INSERT INTO jev.models(name, version, provider, config) VALUES
    ('batch-probe', '1', 'public.jev_batch_probe(text[],text[],jsonb,jsonb)'::regprocedure,
     '{"expected_unique":2}'),
    ('batch-pruning', '1', 'public.jev_batch_probe(text[],text[],jsonb,jsonb)'::regprocedure, '{}');
INSERT INTO jev.predicates(name, version, model_name) VALUES
    ('batch-probe', '1', 'batch-probe'), ('batch-pruning', '1', 'batch-pruning');

CREATE TABLE public.jev_batch_pairs(id integer, l text, r text);
INSERT INTO public.jev_batch_pairs
SELECT n, ((n - 1) / 2)::text, ((n - 1) / 2)::text
FROM generate_series(1, 12) AS n;
ANALYZE public.jev_batch_pairs;

DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_pairs
           WHERE jev.semantic_match('batch-probe', l, r)$q$));
    ASSERT node->>'Semantic Evaluation' = 'batched', 'query did not use batched execution';
    ASSERT (node->>'Actual Rows')::integer = 12;
    ASSERT (node->>'Rows Read')::integer = 12;
    ASSERT (node->>'Candidate Rows')::integer = 12;
    ASSERT (node->>'Unique Inputs')::integer = 6;
    ASSERT (node->>'Reused Inputs')::integer = 6;
    ASSERT (node->>'Provider Calls')::integer = 3, 'expected one provider call per chunk';
    ASSERT (node->>'Batches')::integer = 3;
    ASSERT (node->>'Peak Buffered Rows')::integer = 4;
    ASSERT (node->>'Peak Buffered Bytes')::bigint > 0;
    ASSERT jsonb_typeof(node->'Kernel Time') = 'number';
    ASSERT (node->>'Kernel Time')::numeric >= 0;

    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_pairs
           WHERE jev.semantic_match('batch-probe', l, r) LIMIT 0$q$));
    ASSERT (node->>'Provider Calls')::integer = 0, 'LIMIT 0 called the provider';
    ASSERT (node->>'Rows Read')::integer = 0, 'LIMIT 0 read source rows';

    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_pairs
           WHERE jev.semantic_match('batch-probe', l, r) LIMIT 1$q$));
    ASSERT (node->>'Actual Rows')::integer = 1;
    ASSERT (node->>'Provider Calls')::integer = 1;
    ASSERT (node->>'Rows Read')::integer <= 4, 'LIMIT 1 consumed more than one source chunk';
    ASSERT (node->>'Peak Buffered Rows')::integer <= 4;
END
$$;

-- Reuse is local to a bounded chunk; identical pairs in later chunks must be
-- evaluated again, so no unbounded statement-wide cache can accumulate.
CREATE TABLE public.jev_batch_repeat(id integer, l text, r text);
INSERT INTO public.jev_batch_repeat SELECT n, 'same', 'same' FROM generate_series(1,12) AS n;
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_repeat WHERE jev.semantic_match('batch-pruning',l,r)$q$));
    ASSERT (node->>'Actual Rows')::integer = 12;
    ASSERT (node->>'Provider Calls')::integer = 3;
    ASSERT (node->>'Unique Inputs')::integer = 3, 'prediction reuse escaped its chunk boundary';
    ASSERT (node->>'Reused Inputs')::integer = 9;
END
$$;

-- Preserve row occurrences, strict NULL semantics, tuple identity, and normal
-- projections while moving only the eligible positive semantic filter.
CREATE TABLE public.jev_batch_mixed(id integer, l text, r text, keep boolean);
INSERT INTO public.jev_batch_mixed VALUES
    (1,'a','a',true), (1,'a','a',true), (2,'a','b',true),
    (3,NULL,'a',true), (4,'a',NULL,true), (5,NULL,NULL,true),
    (6,'','',true), (7,U&'\00E9',U&'e\0301',true),
    (8,'hidden','hidden',false), (9,'z','z',true);
SET LOCAL jev.enable_custom_scan = off;
CREATE TEMP TABLE jev_batch_native AS
SELECT id, l, r, upper(l) AS projected, ctid::text AS tid, tableoid::oid AS source_oid
FROM public.jev_batch_mixed WHERE keep AND jev.semantic_match('exact', l, r);
SET LOCAL jev.enable_custom_scan = on;
CREATE TEMP TABLE jev_batch_actual AS
SELECT id, l, r, upper(l) AS projected, ctid::text AS tid, tableoid::oid AS source_oid
FROM public.jev_batch_mixed WHERE keep AND jev.semantic_match('exact', l, r);
DO $$
DECLARE node jsonb;
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_batch_native EXCEPT ALL TABLE jev_batch_actual)
        UNION ALL (TABLE jev_batch_actual EXCEPT ALL TABLE jev_batch_native)
    ), 'batched execution changed duplicate/NULL/projection/system-column semantics';
    ASSERT (SELECT count(*) FROM jev_batch_actual WHERE id = 1) = 2;
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id, upper(l), ctid, tableoid FROM public.jev_batch_mixed
           WHERE keep AND jev.semantic_match('exact', l, r)$q$));
    ASSERT node->>'Semantic Evaluation' = 'batched';
    ASSERT (node->>'Candidate Rows')::integer = 9;

    -- With only NULL pairs even an unknown predicate must not be resolved.
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_mixed WHERE id BETWEEN 3 AND 5
           AND jev.semantic_match('unknown-strict-null', l, r)$q$));
    ASSERT node->>'Semantic Evaluation' = 'batched';
    ASSERT (node->>'Actual Rows')::integer = 0;
    ASSERT (node->>'Provider Calls')::integer = 0;
    ASSERT (node->>'Unique Inputs')::integer = 0;
END
$$;

-- Relational filtering happens before input collection; poison would make the
-- provider fail if a rejected row crossed that boundary.
CREATE TABLE public.jev_batch_prune(id integer, l text, r text, keep boolean);
INSERT INTO public.jev_batch_prune VALUES
    (0,'poison','poison',false), (1,'a','a',true), (2,'a','a',true),
    (3,'poison','poison',false), (4,'b','b',true), (5,'b','b',true),
    (6,'c','c',true), (7,'poison','poison',false), (8,'c','c',true);
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_prune
           WHERE keep AND jev.semantic_match('batch-pruning', l, r)$q$));
    ASSERT node->>'Semantic Evaluation' = 'batched';
    ASSERT (node->>'Rows Read')::integer = 9;
    ASSERT (node->>'Candidate Rows')::integer = 6;
    ASSERT (node->>'Actual Rows')::integer = 6;
    ASSERT (node->>'Provider Calls')::integer = 2;
    ASSERT (node->>'Unique Inputs')::integer = 3;
END
$$;

-- An oversized single row is permitted by the soft memory target, but must
-- stop collection before another row is added. Keep values inline to ensure
-- that this exercises actual buffered data rather than small TOAST pointers.
CREATE TABLE public.jev_batch_wide(id integer, l text, r text);
ALTER TABLE public.jev_batch_wide ALTER COLUMN l SET STORAGE PLAIN;
ALTER TABLE public.jev_batch_wide ALTER COLUMN r SET STORAGE PLAIN;
INSERT INTO public.jev_batch_wide
SELECT n, repeat(md5(n::text),40), repeat(md5(n::text),40)
FROM generate_series(1,8) AS n;
SET LOCAL jev.batch_memory_kb = 1;
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_wide WHERE jev.semantic_match('exact', l, r)$q$));
    ASSERT (node->>'Actual Rows')::integer = 8, 'memory bound lost oversized source rows';
    ASSERT (node->>'Peak Buffered Rows')::integer = 1, 'memory target did not bound buffering';
    ASSERT (node->>'Peak Buffered Bytes')::bigint > 1024, 'test did not exercise an oversized row';
    ASSERT (node->>'Provider Calls')::integer = 8;
END
$$;
SET LOCAL jev.batch_memory_kb = 1024;

-- Generic parameters must be reevaluated, and SCROLL must be backed by
-- Materialize or a semantics-preserving fallback, never stale batch state.
SET LOCAL plan_cache_mode = force_generic_plan;
PREPARE jev_batch_prepared(integer) AS
SELECT id FROM public.jev_batch_pairs
WHERE id <= $1 AND jev.semantic_match('exact', l, r);
DO $$
DECLARE node jsonb; row record; first_row record; prior_row record;
        seen integer := 0; c refcursor := 'jev_batch_scroll';
BEGIN
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan('EXECUTE jev_batch_prepared(3)'));
    ASSERT node->>'Semantic Evaluation' = 'batched';
    ASSERT (node->>'Actual Rows')::integer = 3;
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan('EXECUTE jev_batch_prepared(12)'));
    ASSERT (node->>'Actual Rows')::integer = 12, 'prepared execution reused stale batch results';
    OPEN c SCROLL FOR SELECT id FROM public.jev_batch_pairs
        WHERE jev.semantic_match('exact', l, r);
    FETCH NEXT FROM c INTO first_row;
    FETCH NEXT FROM c INTO row;
    FETCH PRIOR FROM c INTO prior_row;
    ASSERT first_row IS NOT DISTINCT FROM prior_row, 'SCROLL backward returned a different row';
    MOVE ABSOLUTE 0 FROM c;
    LOOP
        FETCH NEXT FROM c INTO row;
        EXIT WHEN NOT FOUND;
        seen := seen + 1;
    END LOOP;
    ASSERT seen = 12, 'SCROLL rewind lost or duplicated rows';
    CLOSE c;
END
$$;
DEALLOCATE jev_batch_prepared;

-- Unsupported boolean/expression shapes keep the original scalar expression.
DO $$
DECLARE statement text; node jsonb; seen integer := 0; row record;
BEGIN
    FOREACH statement IN ARRAY ARRAY[
        $q$SELECT id FROM public.jev_batch_mixed WHERE jev.semantic_match('exact',l,r) OR keep$q$,
        $q$SELECT id FROM public.jev_batch_mixed WHERE NOT jev.semantic_match('exact',l,r)$q$,
        $q$SELECT id FROM public.jev_batch_mixed WHERE jev.semantic_match('exact',l,r)
            AND jev.semantic_match('exact',l,'a')$q$,
        $q$SELECT id FROM public.jev_batch_mixed WHERE jev.semantic_match('exact',l,r) AND random() >= 0$q$,
        $q$SELECT random() FROM public.jev_batch_mixed WHERE jev.semantic_match('exact',l,r)$q$,
        $q$SELECT jev.semantic_match('exact',l,r) FROM public.jev_batch_mixed
            WHERE jev.semantic_match('exact',l,r)$q$
    ] LOOP
        node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan(statement, false));
        ASSERT node->>'Semantic Evaluation' = 'scalar (planner scaffold)',
            'unsupported expression shape must keep scalar semantics: ' || statement;
    END LOOP;
    FOR row IN EXECUTE $q$SELECT id FROM public.jev_batch_pairs
        WHERE jev.semantic_match(NULL::text,l,r)$q$ LOOP seen := seen + 1; END LOOP;
    ASSERT seen = 0, 'NULL predicate changed STRICT semantics';
END
$$;
PREPARE jev_batch_predicate(text) AS SELECT id FROM public.jev_batch_pairs
WHERE jev.semantic_match($1,l,r);
DO $$
DECLARE node jsonb; row record; seen integer := 0;
BEGIN
    node := pg_temp.jev_batch_node(pg_temp.jev_batch_plan('EXECUTE jev_batch_predicate(''exact'')', false));
    ASSERT node->>'Semantic Evaluation' = 'scalar (planner scaffold)';
    FOR row IN EXECUTE 'EXECUTE jev_batch_predicate(NULL)' LOOP seen := seen + 1; END LOOP;
    ASSERT seen = 0, 'generic NULL predicate invoked metadata/provider lookup';
END
$$;
DEALLOCATE jev_batch_predicate;

-- Removing the marker from the row qualification must never remove its ACL
-- check. The replaceable provider must also execute with caller privileges.
CREATE ROLE jev_batch_reader NOLOGIN;
GRANT USAGE ON SCHEMA public, jev TO jev_batch_reader;
GRANT SELECT ON public.jev_batch_pairs TO jev_batch_reader;
REVOKE EXECUTE ON FUNCTION jev.semantic_match(text,text,text) FROM PUBLIC;
SET LOCAL ROLE jev_batch_reader;
DO $$
DECLARE denied boolean := false;
BEGIN
    BEGIN
        EXECUTE $q$SELECT id FROM public.jev_batch_pairs WHERE jev.semantic_match('exact',l,r)$q$;
    EXCEPTION WHEN insufficient_privilege THEN denied := true;
    END;
    ASSERT denied, 'batched scan bypassed semantic_match EXECUTE privilege';
END
$$;
RESET ROLE;
GRANT EXECUTE ON FUNCTION jev.semantic_match(text,text,text) TO PUBLIC;
REVOKE EXECUTE ON FUNCTION public.jev_batch_probe(text[],text[],jsonb,jsonb) FROM PUBLIC;
SET LOCAL ROLE jev_batch_reader;
DO $$
DECLARE denied boolean := false;
BEGIN
    BEGIN
        EXECUTE $q$SELECT id FROM public.jev_batch_pairs WHERE jev.semantic_match('batch-probe',l,r)$q$;
    EXCEPTION WHEN insufficient_privilege THEN denied := true;
    END;
    ASSERT denied, 'batched scan bypassed provider EXECUTE privilege';
END
$$;
RESET ROLE;
GRANT EXECUTE ON FUNCTION public.jev_batch_probe(text[],text[],jsonb,jsonb) TO PUBLIC;

CREATE FUNCTION public.jev_batch_bad_provider(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE sql STABLE AS $$ SELECT '{}'::jev.prediction[] $$;
INSERT INTO jev.models(name,version,provider) VALUES
    ('batch-bad','1','public.jev_batch_bad_provider(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name,version,model_name) VALUES ('batch-bad','1','batch-bad');
DO $$
DECLARE rejected boolean := false;
BEGIN
    BEGIN
        EXECUTE $q$SELECT id FROM public.jev_batch_pairs WHERE jev.semantic_match('batch-bad',l,r)$q$;
    EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
    END;
    ASSERT rejected, 'batched scan hid an invalid provider response';
    ASSERT (pg_temp.jev_batch_node(pg_temp.jev_batch_plan(
        $q$SELECT id FROM public.jev_batch_pairs WHERE jev.semantic_match('exact',l,r)$q$))
        ->>'Actual Rows')::integer = 12, 'provider error damaged subsequent scan state';
END
$$;

ROLLBACK;
\echo 'batched CustomScan assertions passed'
