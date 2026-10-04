\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE public.jev_relation_input(row_id text, left_text text, right_text text, tenant text);
INSERT INTO public.jev_relation_input VALUES
    ('same','a','a','reader'), ('same','a','a','reader'),
    (NULL,'b','c','reader'), ('null',NULL,'a','reader'),
    ('other','private','private','other');

CREATE FUNCTION pg_temp.relation_expect_error(statement text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE failed boolean := false;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> expected_state THEN RAISE; END IF;
        failed := true;
    END;
    ASSERT failed, 'expected error: ' || statement;
END
$$;

-- Compare full bags; row IDs are intentionally duplicated and NULL.
DO $$
DECLARE size integer;
BEGIN
    FOREACH size IN ARRAY ARRAY[1,2,3,128] LOOP
        ASSERT NOT EXISTS (
            (SELECT row_id, decision, confidence
             FROM jev.evaluate_relation('exact','public.jev_relation_input',size)
             EXCEPT ALL
             SELECT row_id, left_text = right_text,
                    CASE WHEN left_text IS NULL OR right_text IS NULL THEN NULL::float8 ELSE 1::float8 END
             FROM public.jev_relation_input)
            UNION ALL
            (SELECT row_id, left_text = right_text,
                    CASE WHEN left_text IS NULL OR right_text IS NULL THEN NULL::float8 ELSE 1::float8 END
             FROM public.jev_relation_input
             EXCEPT ALL
             SELECT row_id, decision, confidence
             FROM jev.evaluate_relation('exact','public.jev_relation_input',size))
        ), 'relation API changed bag semantics';
        ASSERT (SELECT array_agg(ordinal ORDER BY ordinal) = ARRAY[1,2,3,4,5]::bigint[]
                FROM jev.evaluate_relation('exact','public.jev_relation_input',size)),
               'block ordinals were not globally contiguous';
    END LOOP;
END
$$;

-- Catalog-derived names must survive unusual identifiers without interpolation.
CREATE TEMP TABLE "jev quoted; relation" (row_id text, left_text text, right_text text);
INSERT INTO "jev quoted; relation" VALUES ('quote','x','x');
DO $$ BEGIN
    ASSERT (SELECT decision FROM jev.evaluate_relation('exact','"jev quoted; relation"',1));
END $$;
CREATE TEMP TABLE jev_relation_empty (row_id text, left_text text, right_text text);
DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM jev.evaluate_relation('exact','jev_relation_empty'));
END $$;
SELECT pg_temp.relation_expect_error(
    $q$SELECT * FROM jev.evaluate_relation('missing','jev_relation_empty')$q$, '42704');
SELECT pg_temp.relation_expect_error(
    $q$SELECT * FROM jev.evaluate_relation('exact','jev_relation_input',0)$q$, '22023');
SELECT pg_temp.relation_expect_error(
    $q$SELECT * FROM jev.evaluate_relation('exact','jev_relation_input',65537)$q$, '22023');
SELECT pg_temp.relation_expect_error(
    $q$SELECT * FROM jev.evaluate_relation(NULL,'jev_relation_input')$q$, '22023');
CREATE TEMP TABLE jev_relation_bad (row_id int, left_text text, right_text text);
SELECT pg_temp.relation_expect_error(
    $q$SELECT * FROM jev.evaluate_relation('exact','jev_relation_bad')$q$, '22023');

-- The cursor must enforce both relation privileges and RLS before inference.
CREATE ROLE jev_relation_reader;
GRANT USAGE ON SCHEMA public, jev TO jev_relation_reader;
GRANT SELECT(row_id,left_text,right_text) ON public.jev_relation_input TO jev_relation_reader;
ALTER TABLE public.jev_relation_input ENABLE ROW LEVEL SECURITY;
CREATE POLICY relation_reader_policy ON public.jev_relation_input
    TO jev_relation_reader USING (tenant = 'reader');
CREATE VIEW public.jev_relation_view WITH (security_invoker=true) AS
SELECT row_id,left_text,right_text FROM public.jev_relation_input;
GRANT SELECT ON public.jev_relation_view TO jev_relation_reader;
CREATE FUNCTION public.jev_relation_guard(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF 'private' = ANY($1) THEN RAISE EXCEPTION 'RLS row leaked into inference'; END IF;
    IF cardinality($1) > 2 THEN RAISE EXCEPTION 'input block bound exceeded'; END IF;
    RETURN jev.exact_provider($1,$2,$3,$4);
END
$$;
INSERT INTO jev.models(name,version,provider) VALUES
    ('relation-guard','1','public.jev_relation_guard(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name,version,model_name) VALUES ('relation-guard','1','relation-guard');
SET LOCAL ROLE jev_relation_reader;
DO $$ BEGIN
    ASSERT (SELECT count(*) = 4 FROM jev.evaluate_relation('relation-guard','public.jev_relation_input',2));
    ASSERT (SELECT count(*) = 4 FROM jev.evaluate_relation('relation-guard','public.jev_relation_view',2));
END $$;
RESET ROLE;
REVOKE SELECT(row_id,left_text,right_text) ON public.jev_relation_input FROM jev_relation_reader;
SET LOCAL ROLE jev_relation_reader;
SELECT pg_temp.relation_expect_error(
    $q$SELECT * FROM jev.evaluate_relation('relation-guard','public.jev_relation_input',2)$q$, '42501');
RESET ROLE;
GRANT SELECT(row_id,left_text,right_text) ON public.jev_relation_input TO jev_relation_reader;
REVOKE EXECUTE ON FUNCTION public.jev_relation_guard(text[],text[],jsonb,jsonb) FROM PUBLIC;
SET LOCAL ROLE jev_relation_reader;
SELECT pg_temp.relation_expect_error(
    $q$SELECT * FROM jev.evaluate_relation('relation-guard','public.jev_relation_input',2)$q$, '42501');
RESET ROLE;

ROLLBACK;
