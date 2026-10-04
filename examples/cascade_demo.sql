\set ON_ERROR_STOP on
-- A mechanism demo with deliberately fabricated confidence values, not a
-- calibrated model or an LLM quality evaluation. All demo objects roll back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS jev;
CREATE FUNCTION public.jev_demo_fast(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE sql STABLE AS $$
    SELECT ARRAY(SELECT ROW(false, CASE WHEN l='boot' THEN 0.55 ELSE 0.99 END)::jev.prediction
                 FROM unnest($1,$2) WITH ORDINALITY AS p(l,r,n) ORDER BY n)
$$;
INSERT INTO jev.models(name,version,provider,score_kind) VALUES
    ('cascade-demo-fast','1','public.jev_demo_fast(text[],text[],jsonb,jsonb)'::regprocedure,
     'decision_confidence');
INSERT INTO jev.predicates(name,version,model_name,fallback_model_name,min_confidence) VALUES
    ('cascade-demo','1','cascade-demo-fast','exact-v1',0.9);

-- Deduplication produces two non-NULL pairs. Only the uncertain 'boot' pair
-- reaches fallback. Its decision is restored to both original occurrences.
SELECT * FROM jev.evaluate_batch('cascade-demo',ARRAY[
    ROW('1','boot','boot')::jev.candidate,
    ROW('1','boot','boot')::jev.candidate,
    ROW('2','shoe','boot')::jev.candidate,
    ROW('3',NULL,'boot')::jev.candidate
],128) ORDER BY ordinal;
-- ordinal | row_id | decision | confidence
--       1 | 1      | t        | 1
--       2 | 1      | t        | 1
--       3 | 2      | f        | 0.99
--       4 | 3      | NULL     | NULL
ROLLBACK;
