\set ON_ERROR_STOP on
LOAD 'jev';
BEGIN;
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
SET LOCAL jev.batch_size = 4;
SET LOCAL jev.batch_memory_kb = 1024;
SET LOCAL jev.result_cache_kb = 4096;

CREATE FUNCTION pg_temp.jev_cache_plan(statement text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, COSTS OFF, TIMING OFF, SUMMARY OFF) '
        || statement INTO result;
    RETURN jsonb_path_query_first(result,
        '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")');
END
$$;

CREATE TABLE public.jev_cache_pairs(id integer, l text, r text);
INSERT INTO public.jev_cache_pairs VALUES
    (1,'a','a'), (2,'a','a'), (3,'b','c'), (4,'b','c'),
    (5,'a','a'), (6,'a','a'), (7,'b','c'), (8,'b','c'),
    (9,'d','d'), (10,'d','d'), (11,'a','a'), (12,NULL,'a');

-- True and false decisions both survive buffer boundaries. The completely
-- cached second chunk does not dispatch the SQL kernel at all.
DO $$
DECLARE node jsonb; again jsonb;
BEGIN
    node := pg_temp.jev_cache_plan(
        $q$SELECT id FROM public.jev_cache_pairs WHERE jev.semantic_match('exact',l,r)$q$);
    ASSERT node->>'Semantic Evaluation' = 'batched';
    ASSERT (node->>'Actual Rows')::integer = 7;
    ASSERT (node->>'Candidate Rows')::integer = 12;
    ASSERT (node->>'Batches')::integer = 3;
    ASSERT (node->>'Kernel Calls')::integer = 2;
    ASSERT (node->>'Unique Inputs')::integer = 3;
    ASSERT (node->>'Reused Inputs')::integer = 8;
    ASSERT (node->>'Cache Hits')::integer = 5;
    ASSERT (node->>'Cache Entries')::integer = 3;
    ASSERT (node->>'Cache Admission Skips')::integer = 0;
    ASSERT (node->>'Cache Allocated Bytes')::integer = 4096 * 1024;
    ASSERT (node->>'Cache Used Bytes')::integer > 0;
    ASSERT (node->>'Cache Used Bytes')::integer <= (node->>'Cache Allocated Bytes')::integer;

    -- A new executor state cannot inherit this execution's decisions.
    again := pg_temp.jev_cache_plan(
        $q$SELECT id FROM public.jev_cache_pairs WHERE jev.semantic_match('exact',l,r)$q$);
    ASSERT (again->>'Kernel Calls')::integer = 2;
    ASSERT (again->>'Unique Inputs')::integer = 3;

    node := pg_temp.jev_cache_plan(
        $q$SELECT id FROM public.jev_cache_pairs WHERE jev.semantic_match('exact',l,r) LIMIT 0$q$);
    ASSERT (node->>'Kernel Calls')::integer = 0;
    ASSERT (node->>'Cache Allocated Bytes')::integer = 0;

    node := pg_temp.jev_cache_plan(
        $q$SELECT id FROM public.jev_cache_pairs WHERE l IS NULL
             AND jev.semantic_match('missing-null-predicate',l,r)$q$);
    ASSERT (node->>'Kernel Calls')::integer = 0;
    ASSERT (node->>'Cache Entries')::integer = 0;
    ASSERT (node->>'Cache Allocated Bytes')::integer = 0;
END
$$;

SET LOCAL jev.result_cache_kb = 0;
CREATE TEMP TABLE jev_cache_disabled AS
SELECT id,l,r,ctid::text AS tid,tableoid::oid AS source_oid
FROM public.jev_cache_pairs WHERE jev.semantic_match('exact',l,r);
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_cache_plan(
        $q$SELECT id FROM public.jev_cache_pairs WHERE jev.semantic_match('exact',l,r)$q$);
    ASSERT (node->>'Kernel Calls')::integer = 3;
    ASSERT (node->>'Unique Inputs')::integer = 6;
    ASSERT (node->>'Reused Inputs')::integer = 5;
    ASSERT (node->>'Cache Hits')::integer = 0;
    ASSERT (node->>'Cache Entries')::integer = 0;
    ASSERT (node->>'Cache Allocated Bytes')::integer = 0;
    ASSERT (node->>'Cache Admission Skips')::integer = 0;
END
$$;
SET LOCAL jev.result_cache_kb = 4096;
CREATE TEMP TABLE jev_cache_enabled AS
SELECT id,l,r,ctid::text AS tid,tableoid::oid AS source_oid
FROM public.jev_cache_pairs WHERE jev.semantic_match('exact',l,r);
DO $$
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_cache_disabled EXCEPT ALL TABLE jev_cache_enabled)
        UNION ALL (TABLE jev_cache_enabled EXCEPT ALL TABLE jev_cache_disabled)
    ), 'cache changed NULL/duplicate/system-column semantics';
END
$$;

-- Oversized entries are evaluated every time, without allocating an arena.
SET LOCAL jev.result_cache_kb = 1;
SET LOCAL jev.batch_size = 1;
CREATE TABLE public.jev_cache_wide(id integer, l text, r text);
INSERT INTO public.jev_cache_wide
SELECT n,repeat('x',1200),repeat('x',1200) FROM generate_series(1,3) n;
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_cache_plan(
        $q$SELECT id FROM public.jev_cache_wide WHERE jev.semantic_match('exact',l,r)$q$);
    ASSERT (node->>'Actual Rows')::integer = 3;
    ASSERT (node->>'Kernel Calls')::integer = 3;
    ASSERT (node->>'Cache Hits')::integer = 0;
    ASSERT (node->>'Cache Entries')::integer = 0;
    ASSERT (node->>'Cache Allocated Bytes')::integer = 0;
    ASSERT (node->>'Cache Admission Skips')::integer = 3;
END
$$;

-- Saturation stops admission, retains the first entries, and never loses rows.
CREATE TABLE public.jev_cache_saturated(id integer, l text, r text);
INSERT INTO public.jev_cache_saturated
SELECT n,md5(n::text),md5(n::text) FROM generate_series(1,40) n;
INSERT INTO public.jev_cache_saturated VALUES (41,md5('1'),md5('1'));
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_cache_plan(
        $q$SELECT id FROM public.jev_cache_saturated WHERE jev.semantic_match('exact',l,r)$q$);
    ASSERT (node->>'Actual Rows')::integer = 41;
    ASSERT (node->>'Kernel Calls')::integer = 40;
    ASSERT (node->>'Cache Hits')::integer = 1;
    ASSERT (node->>'Cache Entries')::integer > 0;
    ASSERT (node->>'Cache Entries')::integer < 40;
    ASSERT (node->>'Cache Admission Skips')::integer > 0;
    ASSERT (node->>'Cache Allocated Bytes')::integer = 1024;
    ASSERT (node->>'Cache Used Bytes')::integer <= 1024;
END
$$;

-- A prepared query starts a fresh cache on every execution, so a changed
-- predicate definition cannot inherit decisions from the preceding execution.
CREATE FUNCTION public.jev_cache_config_provider(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE sql STABLE AS $$
    SELECT ARRAY(SELECT ROW(coalesce(($3->>'decision')::boolean,true),1.0)::jev.prediction
                 FROM unnest($1))
$$;
INSERT INTO jev.models(name,version,provider) VALUES
    ('cache-config','1','public.jev_cache_config_provider(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name,version,model_name,definition) VALUES
    ('cache-config','1','cache-config','{"decision":true}');
SET LOCAL jev.result_cache_kb = 4096;
SET LOCAL plan_cache_mode = force_generic_plan;
PREPARE jev_cache_prepared AS
SELECT id FROM public.jev_cache_pairs WHERE jev.semantic_match('cache-config',l,r);
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_cache_plan('EXECUTE jev_cache_prepared');
    ASSERT (node->>'Actual Rows')::integer = 11;
    ASSERT (node->>'Kernel Calls')::integer = 3;
END
$$;
UPDATE jev.predicates SET definition = '{"decision":false}', version = '2'
WHERE name = 'cache-config';
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_cache_plan('EXECUTE jev_cache_prepared');
    ASSERT (node->>'Actual Rows')::integer = 0;
    ASSERT (node->>'Kernel Calls')::integer = 3;
END
$$;

-- Cached results and saved SPI plans cannot carry provider privileges from a
-- prior execution. Reuse the generic prepared statement across a role/ACL change.
CREATE ROLE jev_cache_reader NOLOGIN;
GRANT USAGE ON SCHEMA public,jev TO jev_cache_reader;
GRANT SELECT ON public.jev_cache_pairs TO jev_cache_reader;
REVOKE EXECUTE ON FUNCTION public.jev_cache_config_provider(text[],text[],jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jev_cache_config_provider(text[],text[],jsonb,jsonb) TO jev_cache_reader;
SET LOCAL ROLE jev_cache_reader;
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_cache_plan('EXECUTE jev_cache_prepared');
    ASSERT (node->>'Kernel Calls')::integer = 3;
    ASSERT (node->>'Cache Hits')::integer = 8;
END
$$;
RESET ROLE;
REVOKE EXECUTE ON FUNCTION public.jev_cache_config_provider(text[],text[],jsonb,jsonb) FROM jev_cache_reader;
SET LOCAL ROLE jev_cache_reader;
DO $$
DECLARE denied boolean := false;
BEGIN
    BEGIN
        EXECUTE 'EXECUTE jev_cache_prepared';
    EXCEPTION WHEN insufficient_privilege THEN denied := true;
    END;
    ASSERT denied, 'a previous execution cache bypassed revoked provider EXECUTE';
END
$$;
RESET ROLE;
DEALLOCATE jev_cache_prepared;

-- A live cursor owns one scan execution across FETCH statements. Repeated
-- pairs exercise reuse across buffers without a Sort or Materialize above it.
CREATE TABLE public.jev_cache_cursor_pairs(id integer, l text, r text);
INSERT INTO public.jev_cache_cursor_pairs
SELECT n,'same','same' FROM generate_series(1,6) n;
GRANT SELECT ON public.jev_cache_cursor_pairs TO jev_cache_reader;
GRANT EXECUTE ON FUNCTION jev.semantic_match(text,text,text),
    jev.evaluate_batch(text,jev.candidate[],integer),
    jev.exact_provider(text[],text[],jsonb,jsonb) TO jev_cache_reader;
SET LOCAL jev.batch_size = 2;
DO $$
DECLARE c refcursor; item integer; observed integer[] := ARRAY[]::integer[];
BEGIN
    OPEN c NO SCROLL FOR
        SELECT id FROM public.jev_cache_cursor_pairs
        WHERE jev.semantic_match('exact',l,r);
    LOOP
        FETCH NEXT FROM c INTO item;
        EXIT WHEN NOT FOUND;
        observed := array_append(observed,item);
    END LOOP;
    CLOSE c;
    ASSERT (SELECT array_agg(value ORDER BY value) FROM unnest(observed) AS u(value))
           = ARRAY[1,2,3,4,5,6], 'same-role cursor FETCH lost or duplicated rows';
END
$$;

-- Reject role changes before either a pending buffered row (batch size 4) or
-- the next all-hit buffer (batch size 1) can bypass the execution-role guard.
-- The reader has table and provider access, so only the explicit guard rejects.
DO $$
DECLARE c refcursor; item integer; size integer; denied boolean;
BEGIN
    FOREACH size IN ARRAY ARRAY[4,1] LOOP
        PERFORM set_config('jev.batch_size',size::text,true);
        OPEN c NO SCROLL FOR
            SELECT id FROM public.jev_cache_cursor_pairs
            WHERE jev.semantic_match('exact',l,r);
        FETCH NEXT FROM c INTO item;
        ASSERT FOUND, 'cursor did not establish its first batch';
        EXECUTE 'SET LOCAL ROLE jev_cache_reader';
        denied := false;
        BEGIN
            FETCH NEXT FROM c INTO item;
        EXCEPTION WHEN insufficient_privilege THEN
            IF SQLERRM <> 'cannot change role during a batched JEV scan' THEN
                RAISE;
            END IF;
            denied := true;
        END;
        EXECUTE 'RESET ROLE';
        ASSERT denied, 'cursor reused a buffered or cached decision after a role change';
        -- An executor error can already have closed or failed its portal.
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_cursors WHERE name = c::text) THEN
            CLOSE c;
        END IF;
    END LOOP;
END
$$;

ROLLBACK;
\echo 'bounded scan-result cache assertions passed'
