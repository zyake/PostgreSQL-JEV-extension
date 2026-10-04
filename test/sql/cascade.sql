\set ON_ERROR_STOP on
BEGIN;
SET LOCAL track_functions = 'all';

CREATE FUNCTION pg_temp.cascade_expect_error(statement text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual_state text;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
        ASSERT actual_state = expected_state,
            format('expected SQLSTATE %s, got %s for %s', expected_state, actual_state, statement);
        RETURN;
    END;
    RAISE EXCEPTION 'Expected SQLSTATE % for %', expected_state, statement;
END
$$;

-- The probes have no SQL side effects. Their decisions/scores are pointwise,
-- while guards reject NULLs, duplicates, oversized calls or wrong metadata.
CREATE FUNCTION public.jev_cascade_primary(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    ASSERT $3 = '{"meaning":"cascade-fixture"}'::jsonb;
    ASSERT $4->>'stage' = 'primary';
    ASSERT cardinality($1) BETWEEN 1 AND 2;
    ASSERT cardinality($1) = cardinality($2);
    ASSERT NOT EXISTS (SELECT FROM unnest($1, $2) AS p(l,r) WHERE l IS NULL OR r IS NULL);
    ASSERT NOT EXISTS (SELECT FROM unnest($1, $2) AS p(l,r)
        GROUP BY l COLLATE "C", r COLLATE "C" HAVING count(*) > 1);
    RETURN ARRAY(
        SELECT CASE l
            WHEN 'H_TRUE' THEN ROW(true,0.95)::jev.prediction
            WHEN 'H_FALSE' THEN ROW(false,0.99)::jev.prediction
            WHEN 'EDGE' THEN ROW(false,0.8)::jev.prediction
            WHEN 'L_TRUE' THEN ROW(true,0.2)::jev.prediction
            WHEN 'L_FALSE' THEN ROW(false,0.1)::jev.prediction
            WHEN 'L_LAST' THEN ROW(false,0.3)::jev.prediction
            ELSE ROW(NULL,NULL)::jev.prediction
        END
        FROM unnest($1) WITH ORDINALITY AS p(l,n) ORDER BY n
    );
END
$$;

CREATE FUNCTION public.jev_cascade_fallback(text[], text[], jsonb, jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    ASSERT $3 = '{"meaning":"cascade-fixture"}'::jsonb;
    ASSERT $4->>'stage' = 'fallback';
    ASSERT cardinality($1) BETWEEN 1 AND 2;
    ASSERT cardinality($1) = cardinality($2);
    ASSERT NOT EXISTS (SELECT FROM unnest($1, $2) AS p(l,r)
        WHERE l IS NULL OR r IS NULL OR l NOT IN ('L_TRUE','L_FALSE','L_LAST')),
        'fallback received a confident, threshold-equal, or NULL input';
    ASSERT NOT EXISTS (SELECT FROM unnest($1, $2) AS p(l,r)
        GROUP BY l COLLATE "C", r COLLATE "C" HAVING count(*) > 1);
    RETURN ARRAY(
        SELECT CASE l
            -- Both directions can change; confidence concerns the emitted
            -- decision, rather than being a probability of the TRUE label.
            WHEN 'L_TRUE' THEN ROW(false,0.7)::jev.prediction
            WHEN 'L_FALSE' THEN ROW(true,0.9)::jev.prediction
            WHEN 'L_LAST' THEN ROW(true,0.85)::jev.prediction
        END
        FROM unnest($1) WITH ORDINALITY AS p(l,n) ORDER BY n
    );
END
$$;

INSERT INTO jev.models(name, version, provider, config, score_kind) VALUES
    ('cascade-primary','1','public.jev_cascade_primary(text[],text[],jsonb,jsonb)'::regprocedure,
     '{"stage":"primary"}','decision_confidence'),
    ('cascade-fallback','1','public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure,
     '{"stage":"fallback"}','decision_confidence');
INSERT INTO jev.predicates(name, version, model_name, definition, fallback_model_name, min_confidence)
VALUES ('cascade','1','cascade-primary','{"meaning":"cascade-fixture"}','cascade-fallback',0.8);
INSERT INTO jev.predicates(name, version, model_name, definition)
VALUES ('cascade-disabled','1','cascade-primary','{"meaning":"cascade-fixture"}');

DO $$
DECLARE actual jsonb; primary_before bigint; fallback_before bigint; input jev.candidate[];
BEGIN
    input := ARRAY[
        ROW('duplicate-id','L_FALSE','x')::jev.candidate,
        ROW('duplicate-id','H_FALSE','x')::jev.candidate,
        ROW(NULL,'L_TRUE','x')::jev.candidate,
        ROW('edge','EDGE','x')::jev.candidate,
        ROW('repeat-low-false','L_FALSE','x')::jev.candidate,
        ROW('last','L_LAST','x')::jev.candidate,
        ROW('high','H_TRUE','x')::jev.candidate,
        ROW('null-left',NULL,'x')::jev.candidate,
        NULL::jev.candidate,
        ROW('repeat-low-true','L_TRUE','x')::jev.candidate
    ];
    SELECT coalesce((SELECT calls FROM pg_stat_xact_user_functions
        WHERE funcid='public.jev_cascade_primary(text[],text[],jsonb,jsonb)'::regprocedure),0)
        INTO primary_before;
    SELECT coalesce((SELECT calls FROM pg_stat_xact_user_functions
        WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure),0)
        INTO fallback_before;
    SELECT jsonb_agg(to_jsonb(r) ORDER BY ordinal) INTO actual
    FROM jev.evaluate_batch('cascade', input, 2) AS r;
    ASSERT actual = '[
        {"ordinal":1,"row_id":"duplicate-id","decision":true,"confidence":0.9},
        {"ordinal":2,"row_id":"duplicate-id","decision":false,"confidence":0.99},
        {"ordinal":3,"row_id":null,"decision":false,"confidence":0.7},
        {"ordinal":4,"row_id":"edge","decision":false,"confidence":0.8},
        {"ordinal":5,"row_id":"repeat-low-false","decision":true,"confidence":0.9},
        {"ordinal":6,"row_id":"last","decision":true,"confidence":0.85},
        {"ordinal":7,"row_id":"high","decision":true,"confidence":0.95},
        {"ordinal":8,"row_id":"null-left","decision":null,"confidence":null},
        {"ordinal":9,"row_id":null,"decision":null,"confidence":null},
        {"ordinal":10,"row_id":"repeat-low-true","decision":false,"confidence":0.7}
    ]'::jsonb, 'cascade changed confident decisions, threshold equality, NULLs, or duplicate mapping';
    ASSERT (SELECT calls-primary_before FROM pg_stat_xact_user_functions
        WHERE funcid='public.jev_cascade_primary(text[],text[],jsonb,jsonb)'::regprocedure)=3,
        'six unique primary inputs require three batches of two';
    ASSERT (SELECT calls-fallback_before FROM pg_stat_xact_user_functions
        WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure)=2,
        'three uncertain unique inputs require two fallback batches';
    ASSERT NOT EXISTS (
        (SELECT * FROM jev.evaluate_batch('cascade',input,1)
         EXCEPT ALL SELECT * FROM jev.evaluate_batch('cascade',input,2))
        UNION ALL
        (SELECT * FROM jev.evaluate_batch('cascade',input,2)
         EXCEPT ALL SELECT * FROM jev.evaluate_batch('cascade',input,1))
    ), 'cascade predictions depend on batch grouping';
END
$$;

-- No configured fallback, no low-confidence pairs, and NULL-only input all
-- avoid fallback inference. Its own below-threshold output is terminal.
DO $$
DECLARE fallback_before bigint;
BEGIN
    SELECT calls INTO fallback_before FROM pg_stat_xact_user_functions
    WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure;
    ASSERT (SELECT decision AND confidence=0.2 FROM jev.evaluate_batch('cascade-disabled',
        ARRAY[ROW('low','L_TRUE','x')::jev.candidate],2));
    ASSERT jev.semantic_match('cascade','H_FALSE','x') IS FALSE;
    ASSERT jev.semantic_match('cascade','EDGE','x') IS FALSE;
    ASSERT jev.semantic_match('cascade','H_TRUE','x') IS TRUE;
    ASSERT jev.semantic_match('cascade',NULL,'x') IS NULL;
    ASSERT (SELECT count(*)=0 FROM jev.evaluate_batch('cascade','{}'::jev.candidate[],2));
    ASSERT (SELECT decision IS NULL AND confidence IS NULL FROM jev.evaluate_batch('cascade',
        ARRAY[ROW('null','x',NULL)::jev.candidate],2));
    ASSERT (SELECT calls FROM pg_stat_xact_user_functions
        WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure)=fallback_before;
    ASSERT jev.semantic_match('cascade','L_TRUE','x') IS FALSE;
    ASSERT jev.semantic_match('cascade','L_FALSE','x') IS TRUE;
END
$$;

-- New metadata defaults preserve the pre-cascade opt-in behavior. The separate
-- upgrade suite verifies these defaults on actual 0.1 metadata migration.
INSERT INTO jev.models(name,version,provider)
VALUES ('cascade-default','1','jev.exact_provider(text[],text[],jsonb,jsonb)'::regprocedure);
DO $$
BEGIN
    ASSERT (SELECT score_kind='uninterpreted' FROM jev.models WHERE name='cascade-default');
    ASSERT (SELECT score_kind='decision_confidence' FROM jev.models WHERE name='exact-v1');
    ASSERT (SELECT fallback_model_name IS NULL AND min_confidence IS NULL
        FROM jev.predicates WHERE name='cascade-disabled');
END
$$;
SELECT pg_temp.cascade_expect_error(
    $q$UPDATE jev.models SET score_kind='probability_of_true' WHERE name='cascade-primary'$q$, '23514');
SELECT pg_temp.cascade_expect_error(
    $q$UPDATE jev.predicates SET min_confidence=NULL WHERE name='cascade'$q$, '23514');
SELECT pg_temp.cascade_expect_error(
    $q$UPDATE jev.predicates SET fallback_model_name=NULL WHERE name='cascade'$q$, '23514');
SELECT pg_temp.cascade_expect_error(
    $q$UPDATE jev.predicates SET fallback_model_name='missing-model' WHERE name='cascade'$q$, '23503');
DO $$
DECLARE value text; model text; kind text;
BEGIN
    FOREACH value IN ARRAY ARRAY['-0.1','1.1','NaN','Infinity','-Infinity'] LOOP
        PERFORM pg_temp.cascade_expect_error(format(
            'UPDATE jev.predicates SET min_confidence=%L::float8 WHERE name=''cascade''',value),'23514');
    END LOOP;
    FOREACH model IN ARRAY ARRAY['cascade-primary','cascade-fallback'] LOOP
        FOREACH kind IN ARRAY ARRAY['similarity','uninterpreted'] LOOP
            UPDATE jev.models SET score_kind=kind WHERE name=model;
            PERFORM pg_temp.cascade_expect_error(
                $q$SELECT jev.semantic_match('cascade','L_TRUE','x')$q$,'22023');
            UPDATE jev.models SET score_kind='decision_confidence' WHERE name=model;
        END LOOP;
    END LOOP;
END
$$;

CREATE FUNCTION public.jev_cascade_bad(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    CASE $4->>'mode'
        WHEN 'error' THEN RAISE EXCEPTION 'fixture provider failure' USING ERRCODE='38000';
        WHEN 'short' THEN RETURN '{}'::jev.prediction[];
        WHEN 'null-array' THEN RETURN NULL;
        WHEN 'null-confidence' THEN RETURN ARRAY[ROW(true,NULL)::jev.prediction];
        WHEN 'null-decision' THEN RETURN ARRAY[ROW(NULL,0.5)::jev.prediction];
        WHEN 'nan' THEN RETURN ARRAY[ROW(true,'NaN'::float8)::jev.prediction];
        WHEN 'infinity' THEN RETURN ARRAY[ROW(true,'Infinity'::float8)::jev.prediction];
        WHEN 'negative-infinity' THEN RETURN ARRAY[ROW(true,'-Infinity'::float8)::jev.prediction];
        ELSE RAISE EXCEPTION 'unexpected bad-provider fixture mode';
    END CASE;
END
$$;

-- Both stages apply the same signature/output validation. Primary failures
-- propagate directly; they are never treated as uncertain predictions.
DO $$
DECLARE model text; mode text; fallback_before bigint;
BEGIN
    FOREACH model IN ARRAY ARRAY['cascade-primary','cascade-fallback'] LOOP
        UPDATE jev.models SET provider='pg_catalog.length(text)'::regprocedure WHERE name=model;
        PERFORM pg_temp.cascade_expect_error(
            $q$SELECT * FROM jev.evaluate_batch('cascade','{}'::jev.candidate[])$q$,'22023');
        UPDATE jev.models SET provider='public.jev_cascade_bad(text[],text[],jsonb,jsonb)'::regprocedure
        WHERE name=model;
        FOREACH mode IN ARRAY ARRAY['error','short','null-array','null-confidence','null-decision',
                                   'nan','infinity','negative-infinity'] LOOP
            UPDATE jev.models SET config=jsonb_build_object('mode',mode) WHERE name=model;
            SELECT calls INTO fallback_before FROM pg_stat_xact_user_functions
            WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure;
            PERFORM pg_temp.cascade_expect_error(
                $q$SELECT jev.semantic_match('cascade','L_TRUE','x')$q$,
                CASE WHEN mode='error' THEN '38000' ELSE '22023' END);
            IF model='cascade-primary' THEN
                ASSERT (SELECT calls FROM pg_stat_xact_user_functions
                    WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure)=fallback_before,
                    'primary error invoked fallback';
            END IF;
        END LOOP;
        UPDATE jev.models
        SET provider=CASE WHEN model='cascade-primary'
            THEN 'public.jev_cascade_primary(text[],text[],jsonb,jsonb)'::regprocedure
            ELSE 'public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure END,
            config=jsonb_build_object('stage',CASE WHEN model='cascade-primary' THEN 'primary' ELSE 'fallback' END)
        WHERE name=model;
    END LOOP;
END
$$;

-- The scan cache must keep the final cascade decision, including FALSE, across
-- buffers. Physical primary/fallback calls exceed the kernel-dispatch counter.
LOAD 'jev';
SET LOCAL jev.enable_custom_scan = off;
CREATE TABLE public.jev_cascade_pairs(id integer,l text,r text);
INSERT INTO public.jev_cascade_pairs VALUES
    (1,'L_FALSE','x'),(2,'H_FALSE','x'),(3,'L_TRUE','x'),(4,'H_TRUE','x'),
    (1,'L_FALSE','x'),(2,'H_FALSE','x'),(3,'L_TRUE','x'),(4,'H_TRUE','x');
CREATE TEMP TABLE jev_cascade_scalar AS
SELECT * FROM public.jev_cascade_pairs WHERE jev.semantic_match('cascade',l,r);
SET LOCAL jev.enable_custom_scan = on;
SET LOCAL jev.force_custom_scan = on;
SET LOCAL jev.batch_size = 2;
SET LOCAL jev.batch_memory_kb = 1024;
SET LOCAL jev.result_cache_kb = 4096;
DO $$
DECLARE result jsonb; node jsonb; primary_before bigint; fallback_before bigint;
BEGIN
    SELECT calls INTO primary_before FROM pg_stat_xact_user_functions
    WHERE funcid='public.jev_cascade_primary(text[],text[],jsonb,jsonb)'::regprocedure;
    SELECT calls INTO fallback_before FROM pg_stat_xact_user_functions
    WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure;
    EXECUTE $q$EXPLAIN (ANALYZE, FORMAT JSON, COSTS OFF, TIMING OFF, SUMMARY OFF)
        SELECT * FROM public.jev_cascade_pairs WHERE jev.semantic_match('cascade',l,r)$q$
        INTO result;
    node := jsonb_path_query_first(result,
        '$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")');
    ASSERT node IS NOT NULL, 'cascade fixture did not use the custom scan';
    ASSERT (node->>'Actual Rows')::integer=4;
    ASSERT (node->>'Unique Inputs')::integer=4;
    ASSERT (node->>'Cache Hits')::integer=4;
    ASSERT (node->>'Kernel Calls')::integer=2;
    ASSERT (node->>'Provider Calls')::integer=2,
        'the deprecated Provider Calls alias should still report kernel dispatches';
    ASSERT (SELECT calls-primary_before FROM pg_stat_xact_user_functions
        WHERE funcid='public.jev_cascade_primary(text[],text[],jsonb,jsonb)'::regprocedure)=2;
    ASSERT (SELECT calls-fallback_before FROM pg_stat_xact_user_functions
        WHERE funcid='public.jev_cascade_fallback(text[],text[],jsonb,jsonb)'::regprocedure)=2,
        'cached final decisions should not invoke either provider again';
END
$$;
CREATE TEMP TABLE jev_cascade_batched AS
SELECT * FROM public.jev_cascade_pairs WHERE jev.semantic_match('cascade',l,r);
DO $$
BEGIN
    ASSERT NOT EXISTS (
        (TABLE jev_cascade_scalar EXCEPT ALL TABLE jev_cascade_batched)
        UNION ALL (TABLE jev_cascade_batched EXCEPT ALL TABLE jev_cascade_scalar)
    ), 'custom scan caching changed the final cascade result bag';
END
$$;
SET LOCAL jev.enable_custom_scan = off;

CREATE ROLE jev_cascade_reader NOLOGIN;
GRANT USAGE ON SCHEMA jev,public TO jev_cascade_reader;
REVOKE ALL ON FUNCTION public.jev_cascade_primary(text[],text[],jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.jev_cascade_fallback(text[],text[],jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jev_cascade_primary(text[],text[],jsonb,jsonb) TO jev_cascade_reader;
SET LOCAL ROLE jev_cascade_reader;
DO $$
DECLARE denied boolean:=false;
BEGIN
    ASSERT jev.semantic_match('cascade','H_FALSE','x') IS FALSE,
        'unused fallback should make no invocation';
    BEGIN
        PERFORM jev.semantic_match('cascade','L_FALSE','x');
    EXCEPTION WHEN insufficient_privilege THEN denied:=true;
    END;
    ASSERT denied,'fallback EXECUTE privileges were bypassed';
END
$$;
RESET ROLE;
GRANT EXECUTE ON FUNCTION public.jev_cascade_fallback(text[],text[],jsonb,jsonb) TO jev_cascade_reader;
SET LOCAL ROLE jev_cascade_reader;
DO $$ BEGIN ASSERT jev.semantic_match('cascade','L_FALSE','x') IS TRUE; END $$;
RESET ROLE;
REVOKE EXECUTE ON FUNCTION public.jev_cascade_primary(text[],text[],jsonb,jsonb) FROM jev_cascade_reader;
SET LOCAL ROLE jev_cascade_reader;
DO $$
DECLARE denied boolean:=false;
BEGIN
    BEGIN
        PERFORM jev.semantic_match('cascade','H_FALSE','x');
    EXCEPTION WHEN insufficient_privilege THEN denied:=true;
    END;
    ASSERT denied,'primary EXECUTE privileges were bypassed';
END
$$;
RESET ROLE;

-- A configured fallback hidden by metadata RLS cannot silently disable itself.
GRANT EXECUTE ON FUNCTION public.jev_cascade_primary(text[],text[],jsonb,jsonb) TO jev_cascade_reader;
ALTER TABLE jev.models ENABLE ROW LEVEL SECURITY;
CREATE POLICY jev_cascade_model_visibility ON jev.models USING (name<>'cascade-fallback');
SET LOCAL ROLE jev_cascade_reader;
DO $$
DECLARE hidden boolean:=false;
BEGIN
    BEGIN
        PERFORM jev.semantic_match('cascade','L_FALSE','x');
    EXCEPTION WHEN undefined_object THEN hidden:=true;
    END;
    ASSERT hidden,'metadata RLS was bypassed or a hidden fallback silently disabled';
END
$$;
RESET ROLE;

ROLLBACK;
\echo 'cascade assertions passed'
