-- The extension control file creates the fixed, non-relocatable jev schema.
-- Provider configuration is metadata, not a credential store.

CREATE TYPE jev.candidate AS (
    row_id text,
    left_text text,
    right_text text
);

CREATE TYPE jev.prediction AS (
    decision boolean,
    confidence double precision
);

CREATE TABLE jev.models (
    name text COLLATE pg_catalog."C" PRIMARY KEY CHECK (name <> ''),
    version text NOT NULL CHECK (version <> ''),
    provider regprocedure NOT NULL,
    config jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE jev.predicates (
    name text COLLATE pg_catalog."C" PRIMARY KEY CHECK (name <> ''),
    version text NOT NULL CHECK (version <> ''),
    model_name text COLLATE pg_catalog."C" NOT NULL REFERENCES jev.models(name),
    definition jsonb NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE jev.models IS
    'Named, versioned providers. Configuration is public metadata; keep credentials outside this table.';
COMMENT ON TABLE jev.predicates IS
    'Named, versioned semantic predicates, resolved together with model metadata once per batch call.';

-- A deterministic demonstration provider. Its confidence of 1 is only a
-- convention for exact equality, and is not a calibrated model probability.
CREATE FUNCTION jev.exact_provider(
    left_texts text[],
    right_texts text[],
    predicate_definition jsonb,
    model_config jsonb
) RETURNS jev.prediction[]
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF cardinality(left_texts) <> cardinality(right_texts)
       OR coalesce(array_ndims(left_texts), 1) <> 1
       OR coalesce(array_ndims(right_texts), 1) <> 1 THEN
        RAISE EXCEPTION 'provider inputs must be equally sized one-dimensional arrays'
            USING ERRCODE = '22023';
    END IF;

    RETURN ARRAY(
        SELECT ROW(
            p.left_text COLLATE pg_catalog."C" = p.right_text COLLATE pg_catalog."C",
            CASE WHEN p.left_text IS NULL OR p.right_text IS NULL
                 THEN NULL::double precision ELSE 1::double precision END
        )::jev.prediction
        FROM unnest(left_texts, right_texts) WITH ORDINALITY
            AS p(left_text, right_text, ordinal)
        ORDER BY p.ordinal
    );
END
$$;

INSERT INTO jev.models(name, version, provider)
VALUES ('exact-v1', '1', 'jev.exact_provider(text[],text[],jsonb,jsonb)'::regprocedure);

INSERT INTO jev.predicates(name, version, model_name, definition)
VALUES ('exact', '1', 'exact-v1', '{"operation":"bytewise_equality","demo":true}'::jsonb);

-- These built-in names are reserved defaults. Register a separately named
-- model/predicate instead of modifying a seed if it must survive pg_dump.
SELECT pg_catalog.pg_extension_config_dump('jev.models', 'WHERE name <> ''exact-v1''');
SELECT pg_catalog.pg_extension_config_dump('jev.predicates', 'WHERE name <> ''exact''');

CREATE FUNCTION jev.evaluate_batch(
    predicate_name text,
    candidates jev.candidate[],
    batch_size integer DEFAULT 128
) RETURNS TABLE(
    ordinal bigint,
    row_id text,
    decision boolean,
    confidence double precision
)
LANGUAGE plpgsql STABLE PARALLEL UNSAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    selected_provider oid;
    selected_definition jsonb;
    selected_config jsonb;
    provider_info record;
    provider_sql text;
    unique_lefts text[];
    unique_rights text[];
    predictions jev.prediction[];
    batch_predictions jev.prediction[];
    prediction jev.prediction;
    unique_count integer;
    batch_offset integer := 1;
    batch_count integer;
    result_index integer;
BEGIN
    IF predicate_name IS NULL OR candidates IS NULL OR batch_size IS NULL
       OR batch_size <= 0 THEN
        RAISE EXCEPTION 'predicate_name, candidates and a positive batch_size are required'
            USING ERRCODE = '22023';
    END IF;

    IF coalesce(array_ndims(candidates), 1) <> 1 THEN
        RAISE EXCEPTION 'candidates must be a one-dimensional array'
            USING ERRCODE = '22023';
    END IF;

    -- One statement snapshot fixes the predicate/model/configuration boundary
    -- for this invocation. No prediction is retained across invocations.
    SELECT m.provider::oid, p.definition, m.config
      INTO selected_provider, selected_definition, selected_config
      FROM jev.predicates AS p
      JOIN jev.models AS m ON m.name = p.model_name
     WHERE p.name = predicate_name COLLATE pg_catalog."C";

    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown JEV predicate: %', predicate_name
            USING ERRCODE = '42704';
    END IF;

    SELECT p.*, n.nspname
      INTO provider_info
      FROM pg_catalog.pg_proc AS p
      JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
     WHERE p.oid = selected_provider;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'provider for JEV predicate % no longer exists', predicate_name
            USING ERRCODE = '42704';
    END IF;

    -- Volatility is a provider contract: a provider must have no SQL side
    -- effects and must be stable for the duration of a statement. PostgreSQL
    -- cannot verify the behavior of an external service behind that contract.
    IF provider_info.prokind <> 'f'
       OR provider_info.proretset
       OR provider_info.provolatile NOT IN ('s', 'i')
       OR provider_info.pronargs <> 4
       OR provider_info.proargtypes[0] <> 'text[]'::regtype
       OR provider_info.proargtypes[1] <> 'text[]'::regtype
       OR provider_info.proargtypes[2] <> 'jsonb'::regtype
       OR provider_info.proargtypes[3] <> 'jsonb'::regtype
       OR provider_info.prorettype <> 'jev.prediction[]'::regtype THEN
        RAISE EXCEPTION 'invalid provider for JEV predicate %', predicate_name
            USING ERRCODE = '22023',
                  DETAIL = 'Expected a STABLE or IMMUTABLE function (text[], text[], jsonb, jsonb) returning jev.prediction[].';
    END IF;

    -- Use a qualified catalog-resolved identifier and bound arguments. This is
    -- SECURITY INVOKER: normal schema USAGE and function EXECUTE checks apply.
    provider_sql := format(
        'SELECT %I.%I($1::text[], $2::text[], $3::jsonb, $4::jsonb)',
        provider_info.nspname, provider_info.proname
    );

    -- C collation makes both deduplication and result mapping byte-exact even
    -- when the database or input expressions use a nondeterministic collation.
    SELECT coalesce(array_agg(p.left_text ORDER BY p.left_text COLLATE pg_catalog."C",
                                                    p.right_text COLLATE pg_catalog."C"), ARRAY[]::text[]),
           coalesce(array_agg(p.right_text ORDER BY p.left_text COLLATE pg_catalog."C",
                                                     p.right_text COLLATE pg_catalog."C"), ARRAY[]::text[])
      INTO unique_lefts, unique_rights
      FROM (
          SELECT DISTINCT c.left_text COLLATE pg_catalog."C" AS left_text,
                          c.right_text COLLATE pg_catalog."C" AS right_text
            FROM unnest(candidates) AS c
           WHERE c.left_text IS NOT NULL AND c.right_text IS NOT NULL
      ) AS p;

    unique_count := cardinality(unique_lefts);
    predictions := array_fill(NULL::jev.prediction, ARRAY[unique_count]);

    WHILE batch_offset <= unique_count LOOP
        batch_count := least(batch_size, unique_count - batch_offset + 1);

        EXECUTE provider_sql
           INTO batch_predictions
          USING unique_lefts[batch_offset:batch_offset + batch_count - 1],
                unique_rights[batch_offset:batch_offset + batch_count - 1],
                selected_definition,
                selected_config;

        IF batch_predictions IS NULL
           OR array_ndims(batch_predictions) IS DISTINCT FROM 1
           OR cardinality(batch_predictions) <> batch_count THEN
            RAISE EXCEPTION 'invalid provider output for JEV predicate %', predicate_name
                USING ERRCODE = '22023',
                      DETAIL = 'Provider must return a one-dimensional prediction array with one result per input pair.';
        END IF;

        result_index := batch_offset;
        FOREACH prediction IN ARRAY batch_predictions LOOP
            IF prediction.decision IS NULL OR prediction.confidence IS NULL
               OR NOT (prediction.confidence >= 0 AND prediction.confidence <= 1) THEN
                RAISE EXCEPTION 'invalid provider prediction for JEV predicate %', predicate_name
                    USING ERRCODE = '22023',
                          DETAIL = 'A non-NULL input pair requires a non-NULL decision and finite confidence in [0, 1].';
            END IF;
            predictions[result_index] := prediction;
            result_index := result_index + 1;
        END LOOP;

        batch_offset := batch_offset + batch_count;
    END LOOP;

    -- Ordinality, not the caller's row_id, identifies an occurrence. Duplicate
    -- row IDs, duplicate pairs, NULL row IDs and NULL composites all survive.
    RETURN QUERY
    SELECT c.ordinal,
           c.row_id,
           (predictions[p.ordinal::integer]).decision,
           (predictions[p.ordinal::integer]).confidence
      FROM unnest(candidates) WITH ORDINALITY AS c(row_id, left_text, right_text, ordinal)
      LEFT JOIN unnest(unique_lefts, unique_rights) WITH ORDINALITY AS p(left_text, right_text, ordinal)
        ON c.left_text COLLATE pg_catalog."C" = p.left_text COLLATE pg_catalog."C"
       AND c.right_text COLLATE pg_catalog."C" = p.right_text COLLATE pg_catalog."C"
     ORDER BY c.ordinal;
END
$$;

CREATE FUNCTION jev.semantic_match(
    predicate_name text,
    left_text text,
    right_text text
) RETURNS boolean
LANGUAGE plpgsql STABLE STRICT PARALLEL UNSAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    matched boolean;
BEGIN
    SELECT r.decision INTO matched
      FROM jev.evaluate_batch(
          predicate_name,
          ARRAY[ROW(NULL::text, left_text, right_text)::jev.candidate],
          1
      ) AS r;
    RETURN matched;
END
$$;

COMMENT ON FUNCTION jev.evaluate_batch(text, jev.candidate[], integer) IS
    'Materialize finite candidates, deduplicate byte-exact non-NULL pairs, call a replaceable provider in chunks, and restore every occurrence. Cache scope is one invocation.';
COMMENT ON FUNCTION jev.semantic_match(text, text, text) IS
    'Strict scalar semantic predicate using the same provider boundary as evaluate_batch; NULL input returns NULL.';

GRANT USAGE ON SCHEMA jev TO PUBLIC;
GRANT SELECT ON jev.models, jev.predicates TO PUBLIC;
