\set ON_ERROR_STOP on
LOAD 'jev';
BEGIN;

DO $$ BEGIN
    ASSERT NOT current_setting('jev.auto_batch_size')::boolean,
        'automatic batch sizing must remain opt in';
END $$;

SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = off;
SET LOCAL jev.auto_batch_size = on;
SET LOCAL jev.batch_size = 128;
SET LOCAL jev.batch_memory_kb = 1024;
SET LOCAL jev.result_cache_kb = 0;
SET LOCAL jev.batch_call_cost = 100;
SET LOCAL jev.batch_input_cost = 10;

CREATE FUNCTION pg_temp.jev_auto_plan(statement text, run_query boolean DEFAULT false,
                                      show_costs boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS ' || CASE WHEN show_costs THEN 'ON' ELSE 'OFF' END ||
        CASE WHEN run_query THEN ', ANALYZE, TIMING OFF, SUMMARY OFF' ELSE '' END ||
        ') ' || statement INTO result;
    RETURN result;
END
$$;
CREATE FUNCTION pg_temp.jev_auto_node(plan jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_path_query_first($1,
        '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")')
$$;

CREATE TABLE public.jev_auto_items(
    id integer PRIMARY KEY, business_id integer, l text, r text, active boolean
);
INSERT INTO public.jev_auto_items
SELECT n, CASE WHEN n % 29 = 0 THEN NULL ELSE n % 64 END,
       CASE WHEN n % 37 = 0 THEN NULL ELSE md5((n % 64)::text) END,
       CASE WHEN n % 41 = 0 THEN NULL
            WHEN n % 3 = 0 THEN md5('different')
            ELSE md5((n % 64)::text) END,
       n % 10 = 0
FROM generate_series(1,4096) AS n;
ANALYZE public.jev_auto_items;

-- Offering alternative paths must remain a planning-only operation. This
-- provider makes any accidental inference during plain EXPLAIN fail loudly.
CREATE FUNCTION public.jev_auto_never_infer(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    RAISE EXCEPTION 'automatic batch sizing invoked inference while planning';
END
$$;
INSERT INTO jev.models(name, version, provider)
VALUES ('auto-no-inference','1','public.jev_auto_never_infer(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name, version, model_name)
VALUES ('auto-no-inference','1','auto-no-inference');

DO $$
DECLARE node jsonb; plan jsonb; full_node jsonb; limit_rows integer; chosen integer;
BEGIN
    full_node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r)$q$));
    ASSERT full_node IS NOT NULL, 'automatic sizing did not offer an unforced full-scan path';
    ASSERT full_node->>'Batch Size Selection' = 'cost based';
    ASSERT full_node->>'Cost Model' = 'batch-v1';
    ASSERT (full_node->>'Forced Custom Path')::boolean = false;
    ASSERT (full_node->>'Planned Batch Size')::integer = 128;
    ASSERT (full_node->>'Planned Batch Size Limit')::integer = 128;
    ASSERT (full_node->>'Estimated Batch Rows')::numeric = 128;
    ASSERT (full_node->>'Estimated Kernel Calls')::numeric = 32;

    -- LIMIT changes the startup/total-cost tradeoff. Do not require a specific
    -- power of two: native page costs and row-width statistics affect the winner.
    FOREACH limit_rows IN ARRAY ARRAY[4,16] LOOP
        node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(format(
            'SELECT id FROM public.jev_auto_items WHERE jev.semantic_match(''auto-no-inference'',l,r) LIMIT %s',
            limit_rows)));
        ASSERT node IS NOT NULL, format('LIMIT %s did not choose batching',limit_rows);
        ASSERT node->>'Batch Size Selection' = 'cost based';
        chosen := (node->>'Planned Batch Size')::integer;
        ASSERT chosen BETWEEN 1 AND 127, 'small LIMIT did not select a smaller batch';
        ASSERT chosen = ANY(ARRAY[1,2,4,8,16,32,64]);
        ASSERT (node->>'Planned Batch Size Limit')::integer = 128;
        ASSERT (node->>'Startup Cost')::numeric < (full_node->>'Startup Cost')::numeric;
    END LOOP;

    -- PostgreSQL still accounts for upper nodes that must consume the whole
    -- scan. Merely seeing a LIMIT in SQL is not enough to favor small batches.
    plan := pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r)
           ORDER BY r,id LIMIT 4$q$);
    node := pg_temp.jev_auto_node(plan);
    ASSERT node IS NOT NULL;
    ASSERT (node->>'Planned Batch Size')::integer = 128;
    ASSERT jsonb_path_exists(plan,'$.** ? (@."Node Type" == "Sort")');
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT count(*) FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r) LIMIT 4$q$));
    ASSERT node IS NOT NULL;
    ASSERT (node->>'Planned Batch Size')::integer = 128;

    plan := pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r) LIMIT 1$q$);
    ASSERT pg_temp.jev_auto_node(plan) IS NULL,
        'automatic alternatives displaced the cheaper native LIMIT 1 scan';
    plan := pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items WHERE id=42
           AND jev.semantic_match('auto-no-inference',l,r)$q$);
    ASSERT pg_temp.jev_auto_node(plan) IS NULL,
        'automatic alternatives displaced a selective native index';
    ASSERT jsonb_path_exists(plan,
        '$.** ? (@."Node Type" == "Index Scan" || @."Node Type" == "Index Only Scan" || @."Node Type" == "Bitmap Index Scan")');

    -- The selection mode remains visible when cost diagnostics are suppressed.
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r)$q$,false,false));
    ASSERT node->>'Batch Size Selection' = 'cost based';
    ASSERT NOT (node ? 'Planned Batch Size');

    -- Opting out of custom scans still disables every automatic alternative.
    PERFORM set_config('jev.enable_custom_scan','off',true);
    ASSERT pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r)$q$)) IS NULL;
    PERFORM set_config('jev.enable_custom_scan','on',true);

    -- Include the precise cap even when it is not a power of two.
    PERFORM set_config('jev.batch_size','100',true);
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r)$q$));
    ASSERT node IS NOT NULL;
    ASSERT (node->>'Planned Batch Size')::integer = 100;
    ASSERT (node->>'Planned Batch Size Limit')::integer = 100;
    ASSERT (node->>'Estimated Kernel Calls')::numeric = 41;

    -- Exercise the upper endpoint of the bounded alternative loop as well.
    PERFORM set_config('jev.batch_size','65536',true);
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('auto-no-inference',l,r)$q$));
    ASSERT node IS NOT NULL;
    ASSERT (node->>'Planned Batch Size')::integer BETWEEN 1 AND 65536;
    ASSERT (node->>'Planned Batch Size Limit')::integer = 65536;

    -- A cap of one is a valid alternative set with no doubling-loop edge case.
    -- Lower explicit call cost so this test actually executes a custom path.
    PERFORM set_config('jev.batch_size','1',true);
    PERFORM set_config('jev.batch_call_cost','0',true);
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('exact',l,r)$q$,true));
    ASSERT node IS NOT NULL;
    ASSERT node->>'Batch Size Selection' = 'cost based';
    ASSERT (node->>'Planned Batch Size')::integer = 1;
    ASSERT (node->>'Planned Batch Size Limit')::integer = 1;
    ASSERT (node->>'Peak Buffered Rows')::integer = 1;
    PERFORM set_config('jev.batch_size','128',true);
    PERFORM set_config('jev.batch_call_cost','100',true);

    -- Width-based memory estimates bound effective batch work even if several
    -- row-count alternatives have identical costs under this small byte target.
    PERFORM set_config('jev.batch_memory_kb','1',true);
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('exact',l,r)$q$,true));
    ASSERT node IS NOT NULL;
    ASSERT node->>'Batch Size Selection' = 'cost based';
    ASSERT (node->>'Estimated Batch Rows')::numeric BETWEEN 1 AND 127;
    ASSERT (node->>'Peak Buffered Rows')::integer < 128;
    ASSERT (node->>'Peak Buffered Rows')::integer <= (node->>'Batch Size')::integer;
    ASSERT (node->>'Estimated Kernel Calls')::numeric > 32;
    PERFORM set_config('jev.batch_memory_kb','1024',true);

    -- Force is an explicit diagnostic override: keep its historical fixed
    -- batch size even while automatic alternatives are enabled.
    PERFORM set_config('jev.force_custom_scan','on',true);
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items
           WHERE jev.semantic_match('exact',l,r) LIMIT 4$q$,true));
    ASSERT node->>'Batch Size Selection' = 'fixed';
    ASSERT (node->>'Forced Custom Path')::boolean;
    ASSERT (node->>'Planned Batch Size')::integer = 128;
    ASSERT (node->>'Batch Size')::integer = 128;
    ASSERT (node->>'Peak Buffered Rows')::integer = 128;
    PERFORM set_config('jev.force_custom_scan','off',true);
END
$$;

-- Automatic execution preserves the full bag, including repeated projected
-- rows and NULL business values. No assertion assumes an unordered LIMIT's
-- selected membership stays identical between legal PostgreSQL plans.
SET LOCAL jev.enable_custom_scan = off;
CREATE TEMP TABLE jev_auto_native AS
SELECT business_id,l,r FROM public.jev_auto_items WHERE jev.semantic_match('exact',l,r);
SET LOCAL jev.enable_custom_scan = on;
CREATE TEMP TABLE jev_auto_actual AS
SELECT business_id,l,r FROM public.jev_auto_items WHERE jev.semantic_match('exact',l,r);
DO $$
DECLARE node jsonb; expected_matches integer; limit_rows integer;
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_auto_native EXCEPT ALL TABLE jev_auto_actual)
        UNION ALL (TABLE jev_auto_actual EXCEPT ALL TABLE jev_auto_native)
    ), 'automatic batch sizing changed duplicate or strict NULL semantics';
    ASSERT EXISTS (SELECT FROM jev_auto_actual GROUP BY business_id,l,r HAVING count(*) > 1);
    ASSERT EXISTS (SELECT FROM jev_auto_actual WHERE business_id IS NULL);
    SELECT count(*) INTO expected_matches FROM public.jev_auto_items
    WHERE l COLLATE "C" = r COLLATE "C";
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT business_id,l,r FROM public.jev_auto_items
           WHERE jev.semantic_match('exact',l,r)$q$,true));
    ASSERT node IS NOT NULL;
    ASSERT (node->>'Actual Rows')::integer = expected_matches;
    ASSERT (node->>'Candidate Rows')::integer = 4096;
    ASSERT (node->>'Peak Buffered Rows')::integer = 128;
    ASSERT (node->>'Unique Inputs')::integer < 4096;

    FOREACH limit_rows IN ARRAY ARRAY[4,16] LOOP
        node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(format(
            'SELECT id FROM public.jev_auto_items WHERE jev.semantic_match(''exact'',l,r) LIMIT %s',
            limit_rows),true));
        ASSERT node IS NOT NULL;
        ASSERT (node->>'Actual Rows')::integer = limit_rows;
        ASSERT (node->>'Batch Size')::integer = (node->>'Planned Batch Size')::integer;
        ASSERT (node->>'Peak Buffered Rows')::integer = (node->>'Planned Batch Size')::integer;
        ASSERT (node->>'Candidate Rows')::integer < 128;
    END LOOP;
END
$$;

-- A reused generic plan owns its selected size/mode. GUC changes do not replan
-- it, but a lower execution-time cap must still be honored. Raising the cap
-- again must not silently replace the stored choice with the larger setting.
SET LOCAL plan_cache_mode = force_generic_plan;
PREPARE jev_auto_prepared AS
SELECT id FROM public.jev_auto_items WHERE jev.semantic_match('exact',l,r);
DO $$
DECLARE before_node jsonb; after_node jsonb;
BEGIN
    before_node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan('EXECUTE jev_auto_prepared'));
    ASSERT before_node->>'Batch Size Selection' = 'cost based';
    ASSERT (before_node->>'Planned Batch Size')::integer = 128;
    PERFORM set_config('jev.auto_batch_size','off',true);
    PERFORM set_config('jev.batch_size','1',true);
    after_node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan('EXECUTE jev_auto_prepared',true));
    ASSERT after_node->>'Batch Size Selection' = 'cost based';
    ASSERT after_node->'Planned Batch Size' = before_node->'Planned Batch Size';
    ASSERT after_node->'Planned Batch Size Limit' = before_node->'Planned Batch Size Limit';
    ASSERT (after_node->>'Batch Size')::integer = 1;
    ASSERT (after_node->>'Peak Buffered Rows')::integer = 1;
    PERFORM set_config('jev.batch_size','256',true);
    after_node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan('EXECUTE jev_auto_prepared',true));
    ASSERT after_node->>'Batch Size Selection' = 'cost based';
    ASSERT (after_node->>'Planned Batch Size')::integer = 128;
    ASSERT (after_node->>'Batch Size')::integer = 128;
    ASSERT (after_node->>'Peak Buffered Rows')::integer = 128;
END
$$;
DEALLOCATE jev_auto_prepared;

-- New plans follow the current fixed-mode setting.
DO $$
DECLARE node jsonb;
BEGIN
    node := pg_temp.jev_auto_node(pg_temp.jev_auto_plan(
        $q$SELECT id FROM public.jev_auto_items WHERE jev.semantic_match('exact',l,r)$q$));
    ASSERT node->>'Batch Size Selection' = 'fixed';
    ASSERT (node->>'Planned Batch Size')::integer = 256;
END
$$;

ROLLBACK;
