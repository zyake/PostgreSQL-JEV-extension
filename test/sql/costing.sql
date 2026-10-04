\set ON_ERROR_STOP on
LOAD 'jev';
BEGIN;
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = off;
SET LOCAL jev.batch_size = 128;
SET LOCAL jev.batch_memory_kb = 1024;
SET LOCAL jev.result_cache_kb = 0;
SET LOCAL jev.batch_call_cost = 100;
SET LOCAL jev.batch_input_cost = 10;

DO $$
DECLARE setting_name text; invalid_value text; rejected boolean;
BEGIN
    FOREACH setting_name IN ARRAY ARRAY['jev.batch_call_cost','jev.batch_input_cost'] LOOP
        FOREACH invalid_value IN ARRAY ARRAY['-1','NaN','Infinity','-Infinity'] LOOP
            rejected := false;
            BEGIN
                PERFORM set_config(setting_name,invalid_value,true);
            EXCEPTION WHEN invalid_parameter_value THEN
                rejected := true;
            END;
            ASSERT rejected, format('%s accepted invalid cost %s',setting_name,invalid_value);
        END LOOP;
    END LOOP;
END
$$;

CREATE FUNCTION pg_temp.jev_cost_plan(statement text, run_query boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS ON' ||
        CASE WHEN run_query THEN ', ANALYZE, TIMING OFF, SUMMARY OFF' ELSE '' END ||
        ') ' || statement INTO result;
    RETURN result;
END
$$;
CREATE FUNCTION pg_temp.jev_cost_node(plan jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_path_query_first($1,
        '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")')
$$;

-- Enough analyzed rows to make fixed batch overhead worthwhile. Physical ids
-- support a selective competing index; business ids and semantic pairs repeat.
CREATE TABLE public.jev_cost_items(
    id integer PRIMARY KEY, business_id integer, l text, r text, active boolean
);
INSERT INTO public.jev_cost_items
SELECT n, CASE WHEN n % 29 = 0 THEN NULL ELSE n % 64 END,
       CASE WHEN n % 37 = 0 THEN NULL ELSE md5((n % 64)::text) END,
       CASE WHEN n % 41 = 0 THEN NULL
            WHEN n % 3 = 0 THEN md5('different')
            ELSE md5((n % 64)::text) END,
       n % 10 = 0
FROM generate_series(1,4096) AS n;
ANALYZE public.jev_cost_items;

-- Planning must use only statistics and explicit cost assumptions. Even a
-- registered provider that always fails must remain untouched by plain EXPLAIN.
CREATE FUNCTION public.jev_cost_never_infer(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    RAISE EXCEPTION 'costing invoked inference while planning';
END
$$;
INSERT INTO jev.models(name, version, provider)
VALUES ('cost-no-inference','1','public.jev_cost_never_infer(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name, version, model_name)
VALUES ('cost-no-inference','1','cost-no-inference');

DO $$
DECLARE node jsonb; plan jsonb;
BEGIN
    node := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items
           WHERE jev.semantic_match('cost-no-inference',l,r)$q$));
    ASSERT node IS NOT NULL, 'unforced large scan did not choose a custom path';
    ASSERT node->>'Cost Model' = 'batch-v1';
    ASSERT (node->>'Forced Custom Path')::boolean = false;
    ASSERT (node->>'Estimated Candidate Rows')::numeric = 4096;
    ASSERT (node->>'Estimated Semantic Selectivity')::numeric BETWEEN 0 AND 1;
    ASSERT (node->>'Estimated Batch Rows')::numeric = 128;
    ASSERT (node->>'Estimated Kernel Calls')::numeric = 32;
    ASSERT (node->>'Estimated Buffered Row Bytes')::numeric > 0;
    ASSERT (node->>'Estimated Batch Work Cost')::numeric > 0;
    ASSERT (node->>'Planned Batch Size')::integer = 128;
    ASSERT (node->>'Planned Batch Memory')::integer = 1024;
    ASSERT (node->>'Batch Call Cost')::numeric = 100;
    ASSERT (node->>'Batch Input Cost')::numeric = 10;
    ASSERT (node->>'Total Cost')::numeric < (node->>'Scalar Seq Scan Total Cost')::numeric;

    -- Preserve PostgreSQL's native cardinality estimate: this first model
    -- estimates execution work without inventing learned semantic selectivity.
    PERFORM set_config('jev.enable_custom_scan','off',true);
    plan := pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items
           WHERE jev.semantic_match('cost-no-inference',l,r)$q$);
    ASSERT (node->>'Plan Rows')::numeric = (plan #>> '{0,Plan,Plan Rows}')::numeric,
        'costing changed the native output cardinality estimate';
    PERFORM set_config('jev.enable_custom_scan','on',true);

    node := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE active
           AND jev.semantic_match('cost-no-inference',l,r)$q$));
    ASSERT node IS NOT NULL;
    ASSERT abs((node->>'Estimated Candidate Rows')::numeric - 409) <= 1,
        'ordinary relational selectivity did not reduce candidate work';

    -- Costing leaves cheaper PostgreSQL paths available.
    plan := pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE id=42
           AND jev.semantic_match('cost-no-inference',l,r)$q$);
    ASSERT pg_temp.jev_cost_node(plan) IS NULL, 'batch heap scan displaced a selective native index';
    ASSERT jsonb_path_exists(plan,
        '$.** ? (@."Node Type" == "Index Scan" || @."Node Type" == "Index Only Scan" || @."Node Type" == "Bitmap Index Scan")'),
        'selective index competition was not exercised';

    plan := pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items
           WHERE jev.semantic_match('cost-no-inference',l,r) LIMIT 1$q$);
    ASSERT pg_temp.jev_cost_node(plan) IS NULL,
        'LIMIT 1 failed to account for work needed before the first batch can return';

    PERFORM set_config('jev.batch_call_cost','100000000',true);
    plan := pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items
           WHERE jev.semantic_match('cost-no-inference',l,r)$q$);
    ASSERT pg_temp.jev_cost_node(plan) IS NULL,
        'expensive custom batch estimate did not let PostgreSQL choose the native scan';
    ASSERT plan #>> '{0,Plan,Node Type}' = 'Seq Scan';
    PERFORM set_config('jev.batch_call_cost','100',true);
END
$$;

-- Smaller buffers mean more estimated calls, not an unexplained discount. Force
-- only this diagnostic comparison so all three paths expose their estimates.
SET LOCAL jev.force_custom_scan = on;
DO $$
DECLARE normal jsonb; tiny_memory jsonb; scalar_sized jsonb; no_cache jsonb;
BEGIN
    normal := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE jev.semantic_match('cost-no-inference',l,r)$q$));
    ASSERT (normal->>'Forced Custom Path')::boolean;

    PERFORM set_config('jev.batch_memory_kb','1',true);
    tiny_memory := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE jev.semantic_match('cost-no-inference',l,r)$q$));
    ASSERT (tiny_memory->>'Estimated Batch Rows')::numeric < (normal->>'Estimated Batch Rows')::numeric;
    ASSERT (tiny_memory->>'Estimated Batch Rows')::numeric >= 1;
    ASSERT (tiny_memory->>'Estimated Kernel Calls')::numeric > (normal->>'Estimated Kernel Calls')::numeric;
    ASSERT (tiny_memory->>'Estimated Batch Work Cost')::numeric > (normal->>'Estimated Batch Work Cost')::numeric;
    PERFORM set_config('jev.batch_memory_kb','1024',true);

    PERFORM set_config('jev.batch_size','1',true);
    scalar_sized := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE jev.semantic_match('cost-no-inference',l,r)$q$));
    ASSERT (scalar_sized->>'Estimated Batch Rows')::numeric = 1;
    ASSERT (scalar_sized->>'Estimated Kernel Calls')::numeric = 4096;
    ASSERT (scalar_sized->>'Estimated Batch Work Cost')::numeric > (normal->>'Estimated Batch Work Cost')::numeric;
    PERFORM set_config('jev.batch_size','128',true);

    -- Cache capacity is not evidence of a hit rate. Changing it must not
    -- introduce an assumed result-cache or input-deduplication discount.
    PERFORM set_config('jev.result_cache_kb','4096',true);
    no_cache := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE jev.semantic_match('cost-no-inference',l,r)$q$));
    ASSERT no_cache->'Estimated Batch Work Cost' = normal->'Estimated Batch Work Cost';
    ASSERT no_cache->'Estimated Candidate Rows' = normal->'Estimated Candidate Rows';
    PERFORM set_config('jev.result_cache_kb','0',true);

    PERFORM set_config('jev.batch_call_cost','100000000',true);
    no_cache := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE jev.semantic_match('cost-no-inference',l,r)$q$));
    ASSERT no_cache IS NOT NULL, 'explicit force no longer overrides path cost';
    ASSERT (no_cache->>'Forced Custom Path')::boolean;
    ASSERT (no_cache->>'Total Cost')::numeric > (no_cache->>'Scalar Seq Scan Total Cost')::numeric;
    PERFORM set_config('jev.batch_call_cost','100',true);
END
$$;
SET LOCAL jev.force_custom_scan = off;

-- Exercise the chosen unforced executor and compare full bags, including
-- duplicate output rows and NULL business values, against ordinary execution.
SET LOCAL jev.enable_custom_scan = off;
CREATE TEMP TABLE jev_cost_native AS
SELECT business_id, l, r FROM public.jev_cost_items
WHERE jev.semantic_match('exact',l,r);
SET LOCAL jev.enable_custom_scan = on;
CREATE TEMP TABLE jev_cost_actual AS
SELECT business_id, l, r FROM public.jev_cost_items
WHERE jev.semantic_match('exact',l,r);
DO $$
DECLARE node jsonb; expected_matches integer;
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_cost_native EXCEPT ALL TABLE jev_cost_actual)
        UNION ALL (TABLE jev_cost_actual EXCEPT ALL TABLE jev_cost_native)
    ), 'unforced custom path changed duplicate or strict NULL semantics';
    ASSERT EXISTS (SELECT FROM jev_cost_actual GROUP BY business_id,l,r HAVING count(*) > 1),
        'fixture did not exercise duplicate output rows';
    ASSERT EXISTS (SELECT FROM jev_cost_actual WHERE business_id IS NULL),
        'fixture did not exercise NULL projected values';
    SELECT count(*) INTO expected_matches FROM public.jev_cost_items
    WHERE l COLLATE "C" = r COLLATE "C";
    node := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT business_id,l,r FROM public.jev_cost_items WHERE jev.semantic_match('exact',l,r)$q$, true));
    ASSERT node IS NOT NULL, 'execution test did not exercise the unforced custom path';
    ASSERT (node->>'Candidate Rows')::integer = 4096;
    ASSERT (node->>'Actual Rows')::integer = expected_matches;
    ASSERT (node->>'Evaluated Match Rows')::integer = expected_matches;
    ASSERT abs((node->>'Observed Match Fraction')::numeric - expected_matches::numeric / 4096) < 0.001;
    ASSERT (node->>'Unique Inputs')::integer < 4096,
        'fixture did not exercise NULL exclusion or input deduplication';

    -- A batch can decide more matches than LIMIT delivers. Instrumentation
    -- reports the decisions observed, not just rows requested by the parent.
    PERFORM set_config('jev.force_custom_scan','on',true);
    node := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items WHERE jev.semantic_match('exact',l,r) LIMIT 1$q$, true));
    ASSERT (node->>'Actual Rows')::integer = 1;
    ASSERT (node->>'Evaluated Match Rows')::integer > 1;
    ASSERT (node->>'Candidate Rows')::integer = 128;
    ASSERT (node->>'Evaluated Match Rows')::integer <= (node->>'Candidate Rows')::integer;

    node := pg_temp.jev_cost_node(pg_temp.jev_cost_plan(
        $q$SELECT id FROM public.jev_cost_items
           WHERE jev.semantic_match('cost-no-inference',l,r) LIMIT 0$q$, true));
    ASSERT (node->>'Candidate Rows')::integer = 0;
    ASSERT (node->>'Evaluated Match Rows')::integer = 0;
    ASSERT NOT (node ? 'Observed Match Fraction'), 'empty observations invented a match fraction';
    ASSERT (node->>'Kernel Calls')::integer = 0;
END
$$;

ROLLBACK;
