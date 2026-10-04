\set ON_ERROR_STOP on
LOAD 'jev';
BEGIN;

DO $$
BEGIN
    ASSERT current_setting('jev.enable_custom_scan') = 'off', 'custom scan must default to off';
    ASSERT current_setting('jev.force_custom_scan') = 'off', 'forced planning must default to off';
END
$$;

CREATE FUNCTION pg_temp.jev_explain(statement text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) ' || statement INTO result;
    RETURN result;
END
$$;
CREATE FUNCTION pg_temp.jev_has_custom(plan jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_path_exists($1, '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")')
$$;

CREATE TABLE public.jev_test_items(id integer, l text, r text, enabled boolean);
INSERT INTO public.jev_test_items VALUES
    (1, 'a', 'a', false), (1, 'a', 'a', false),
    (2, 'a', 'b', true), (3, NULL, 'b', true),
    (4, 'a', NULL, false), (5, NULL, NULL, NULL),
    (6, '', '', false), (7, 'long text', 'long text', NULL),
    (8, 'x', 'y', false), (9, 'outside', 'outside', true);
ANALYZE public.jev_test_items;

SET LOCAL jev.enable_custom_scan = off;
SET LOCAL jev.force_custom_scan = off;
DO $$
BEGIN
    ASSERT NOT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT * FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r)$q$)),
        'custom scan must be disabled by default';
END
$$;

CREATE TEMP TABLE jev_baseline AS
SELECT id, l, r, upper(l) AS projected, jev.semantic_match('exact', l, r) AS matched
FROM public.jev_test_items
WHERE (jev.semantic_match('exact', l, r) OR enabled) AND id <= 8;
CREATE TEMP TABLE jev_baseline_not AS
SELECT id, l, r FROM public.jev_test_items WHERE NOT jev.semantic_match('exact', l, r);
CREATE TEMP TABLE jev_baseline_null AS
SELECT id, l, r FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r) IS NULL;

SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
DO $$
DECLARE plan jsonb;
BEGIN
    plan := pg_temp.jev_explain(
        $q$SELECT * FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r)$q$);
    ASSERT pg_temp.jev_has_custom(plan), 'eligible predicate did not produce CustomScan';
    ASSERT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT id, upper(l) FROM public.jev_test_items WHERE (jev.semantic_match('exact', l, r) OR enabled) AND id <= 8$q$)),
        'semantic predicate nested under OR was not detected';
    ASSERT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT id FROM public.jev_test_items WHERE NOT jev.semantic_match('exact', l, r)$q$)),
        'semantic predicate nested under NOT was not detected';
    ASSERT NOT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT * FROM public.jev_test_items WHERE id = 1$q$)),
        'ordinary relational predicate became semantic';
    ASSERT NOT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT jev.semantic_match('exact', l, r) FROM public.jev_test_items$q$)),
        'projection-only semantic expression became a semantic filter';
END
$$;

CREATE TEMP TABLE jev_custom AS
SELECT id, l, r, upper(l) AS projected, jev.semantic_match('exact', l, r) AS matched
FROM public.jev_test_items
WHERE (jev.semantic_match('exact', l, r) OR enabled) AND id <= 8;
CREATE TEMP TABLE jev_custom_not AS
SELECT id, l, r FROM public.jev_test_items WHERE NOT jev.semantic_match('exact', l, r);
CREATE TEMP TABLE jev_custom_null AS
SELECT id, l, r FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r) IS NULL;
DO $$
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_baseline EXCEPT ALL TABLE jev_custom)
        UNION ALL (TABLE jev_custom EXCEPT ALL TABLE jev_baseline)
    ), 'custom scan changed duplicates, NULLs, OR, or projection';
    ASSERT NOT EXISTS (
        (TABLE jev_baseline_not EXCEPT ALL TABLE jev_custom_not)
        UNION ALL (TABLE jev_custom_not EXCEPT ALL TABLE jev_baseline_not)
    ), 'custom scan changed NOT semantics';
    ASSERT NOT EXISTS (
        (TABLE jev_baseline_null EXCEPT ALL TABLE jev_custom_null)
        UNION ALL (TABLE jev_custom_null EXCEPT ALL TABLE jev_baseline_null)
    ), 'custom scan changed IS NULL semantics';
    ASSERT (SELECT count(*) FROM jev_custom WHERE id = 1) = 2,
        'custom scan collapsed duplicate source rows';
END
$$;

-- LIMIT and cursor rescans must retain ordinary executor behavior.
DO $$
DECLARE first_row record; previous_row record; seen integer := 0; c refcursor := 'jev_test_cursor';
BEGIN
    OPEN c SCROLL FOR
        SELECT id, l, r FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r);
    FETCH NEXT FROM c INTO first_row;
    ASSERT first_row.id = 1;
    FETCH NEXT FROM c INTO previous_row;
    FETCH PRIOR FROM c INTO previous_row;
    ASSERT previous_row IS NOT DISTINCT FROM first_row, 'backward cursor scan changed the row';
    MOVE ABSOLUTE 0 FROM c;
    LOOP
        FETCH NEXT FROM c INTO previous_row;
        EXIT WHEN NOT FOUND;
        seen := seen + 1;
    END LOOP;
    ASSERT seen = 5, 'cursor rewind/rescan lost rows';
    CLOSE c;
    ASSERT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT id FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r) LIMIT 1$q$));
    seen := 0;
    FOR previous_row IN EXECUTE
        $q$SELECT id FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r) LIMIT 1$q$
    LOOP
        seen := seen + 1;
    END LOOP;
    ASSERT seen = 1, 'LIMIT did not stop normally';
END
$$;

-- A prepared statement remains correct when its arguments change.
SET LOCAL plan_cache_mode = force_generic_plan;
PREPARE jev_test_prepared(integer) AS
    SELECT id, l, r FROM public.jev_test_items
    WHERE jev.semantic_match('exact', l, r) AND id <= $1;
DO $$
DECLARE seen integer := 0; row record;
BEGIN
    ASSERT pg_temp.jev_has_custom(pg_temp.jev_explain('EXECUTE jev_test_prepared(9)')),
        'generic prepared plan lacks CustomScan';
    FOR row IN EXECUTE 'EXECUTE jev_test_prepared(1)' LOOP seen := seen + 1; END LOOP;
    ASSERT seen = 2, 'generic plan first parameter execution wrong';
    seen := 0;
    FOR row IN EXECUTE 'EXECUTE jev_test_prepared(9)' LOOP seen := seen + 1; END LOOP;
    ASSERT seen = 5, 'generic plan reused stale parameter/result';
END
$$;
DEALLOCATE jev_test_prepared;

-- A same-named user function is not the extension predicate.
CREATE FUNCTION public.semantic_match(text, text, text)
RETURNS boolean LANGUAGE plpgsql STABLE STRICT AS $$ BEGIN RETURN $2 = $3; END $$;
DO $$
BEGIN
    ASSERT NOT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT * FROM public.jev_test_items WHERE public.semantic_match('exact', l, r)$q$)),
        'predicate detection used a name instead of extension function identity';
    ASSERT NOT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT * FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r) FOR UPDATE$q$)),
        'row-locking query must use the native planner';
    ASSERT NOT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$UPDATE public.jev_test_items SET enabled = true WHERE jev.semantic_match('exact', l, r)$q$)),
        'DML query must use the native planner';
    ASSERT NOT pg_temp.jev_has_custom(pg_temp.jev_explain(
        $q$SELECT a.id FROM public.jev_test_items a JOIN public.jev_test_items b USING (id)
           WHERE jev.semantic_match('exact', a.l, a.r)$q$)),
        'join query must remain outside the first planner scaffold';
END
$$;

-- Enabling a planner hook must not demand JEV access for ordinary SQL.
CREATE ROLE jev_test_no_schema_access NOLOGIN;
GRANT USAGE ON SCHEMA public TO jev_test_no_schema_access;
GRANT SELECT ON public.jev_test_items TO jev_test_no_schema_access;
REVOKE USAGE ON SCHEMA jev FROM PUBLIC;
SET LOCAL ROLE jev_test_no_schema_access;
DO $$
DECLARE plan jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT id FROM public.jev_test_items' INTO plan;
    ASSERT NOT jsonb_path_exists(plan, '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")'),
        'ordinary query without JEV privileges acquired a custom path';
    ASSERT (SELECT count(*) FROM public.jev_test_items) = 10,
        'JEV hook interfered with unrelated authorized SQL';
END
$$;
RESET ROLE;
GRANT USAGE ON SCHEMA jev TO PUBLIC;

-- RLS remains authoritative, and its predicates are not moved into a custom path.
CREATE ROLE jev_test_planner_reader NOLOGIN;
GRANT USAGE ON SCHEMA public, jev TO jev_test_planner_reader;
GRANT SELECT ON public.jev_test_items, jev.models, jev.predicates TO jev_test_planner_reader;
ALTER TABLE public.jev_test_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY jev_test_row_visibility ON public.jev_test_items USING (id <= 2);
SET LOCAL ROLE jev_test_planner_reader;
DO $$
DECLARE plan jsonb;
BEGIN
    EXECUTE $q$EXPLAIN (FORMAT JSON, COSTS OFF)
        SELECT * FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r)$q$ INTO plan;
    ASSERT NOT jsonb_path_exists(plan, '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")'),
        'RLS query must fall back to native paths';
    ASSERT (SELECT count(*) FROM public.jev_test_items WHERE jev.semantic_match('exact', l, r)) = 2,
        'RLS source visibility changed';
END
$$;
RESET ROLE;

ROLLBACK;
\echo 'planner assertions passed'
