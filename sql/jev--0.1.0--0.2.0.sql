-- Existing application models keep uninterpreted scores until their owner
-- explicitly declares a confidence contract. Existing predicates do not cascade.
ALTER TABLE jev.models ADD COLUMN score_kind text NOT NULL DEFAULT 'uninterpreted'
    CONSTRAINT models_score_kind_check CHECK (score_kind IN ('uninterpreted', 'decision_confidence', 'similarity'));
ALTER TABLE jev.predicates
    ADD COLUMN fallback_model_name text COLLATE pg_catalog."C" REFERENCES jev.models(name),
    ADD COLUMN min_confidence double precision
        CONSTRAINT predicates_min_confidence_check CHECK (min_confidence >= 0 AND min_confidence <= 1),
    ADD CONSTRAINT predicates_cascade_config_check
        CHECK ((fallback_model_name IS NULL) = (min_confidence IS NULL));
-- Do not automatically trust an application replacement of the reserved seed.
UPDATE jev.models SET score_kind = 'decision_confidence'
WHERE name = 'exact-v1'
  AND provider = 'jev.exact_provider(text[],text[],jsonb,jsonb)'::regprocedure;

CREATE OR REPLACE FUNCTION jev.evaluate_batch(
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
    provider_oids oid[];
    provider_names text[];
    provider_configs jsonb[];
    provider_statements text[] := ARRAY[]::text[];
    selected_definition jsonb;
    selected_fallback_name text;
    selected_min_confidence double precision;
    primary_score_kind text;
    fallback_score_kind text;
    provider_info record;
    stage integer;
    stage_count integer := 1;
    unique_lefts text[];
    unique_rights text[];
    stage_lefts text[];
    stage_rights text[];
    fallback_indices integer[];
    predictions jev.prediction[];
    batch_predictions jev.prediction[];
    prediction jev.prediction;
    unique_count integer;
    stage_input_count integer;
    batch_offset integer;
    batch_count integer;
    result_index integer;
    destination_index integer;
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

    -- Both stages use one metadata snapshot and the same predicate definition.
    -- The LEFT JOIN preserves a configured-but-RLS-hidden fallback as an error.
    SELECT ARRAY[m.provider::oid, f.provider::oid], ARRAY[m.name, f.name],
           ARRAY[m.config, f.config], p.definition,
           p.fallback_model_name, p.min_confidence, m.score_kind, f.score_kind
      INTO provider_oids, provider_names, provider_configs, selected_definition,
           selected_fallback_name, selected_min_confidence,
           primary_score_kind, fallback_score_kind
      FROM jev.predicates AS p
      JOIN jev.models AS m ON m.name = p.model_name
      LEFT JOIN jev.models AS f ON f.name = p.fallback_model_name
     WHERE p.name = predicate_name COLLATE pg_catalog."C";
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown JEV predicate: %', predicate_name
            USING ERRCODE = '42704';
    END IF;

    IF selected_fallback_name IS NOT NULL THEN
        IF provider_oids[2] IS NULL THEN
            RAISE EXCEPTION 'fallback model for JEV predicate % is unavailable', predicate_name
                USING ERRCODE = '42704';
        END IF;
        IF primary_score_kind <> 'decision_confidence'
           OR fallback_score_kind <> 'decision_confidence' THEN
            RAISE EXCEPTION 'JEV cascade requires decision_confidence scores from both models'
                USING ERRCODE = '22023',
                      DETAIL = 'Similarity and uninterpreted scores cannot be used as decision confidence. The declaration is a provider contract, not proof of calibration.';
        END IF;
        stage_count := 2;
    END IF;

    -- Validate both registered signatures before inference. Function and schema
    -- privileges remain normal SECURITY INVOKER checks at actual invocation;
    -- an unused fallback makes no call. No provider grants are added here.
    FOR stage IN 1..stage_count LOOP
        SELECT p.*, n.nspname INTO provider_info
          FROM pg_catalog.pg_proc AS p
          JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
         WHERE p.oid = provider_oids[stage];
        IF NOT FOUND THEN
            RAISE EXCEPTION 'provider for JEV model % no longer exists', provider_names[stage]
                USING ERRCODE = '42704';
        END IF;
        IF provider_info.prokind <> 'f'
           OR provider_info.proretset
           OR provider_info.provolatile NOT IN ('s', 'i')
           OR provider_info.pronargs <> 4
           OR provider_info.proargtypes[0] <> 'text[]'::regtype
           OR provider_info.proargtypes[1] <> 'text[]'::regtype
           OR provider_info.proargtypes[2] <> 'jsonb'::regtype
           OR provider_info.proargtypes[3] <> 'jsonb'::regtype
           OR provider_info.prorettype <> 'jev.prediction[]'::regtype THEN
            RAISE EXCEPTION 'invalid provider for JEV model %', provider_names[stage]
                USING ERRCODE = '22023',
                      DETAIL = 'Expected a STABLE or IMMUTABLE function (text[], text[], jsonb, jsonb) returning jev.prediction[].';
        END IF;
        provider_statements[stage] := format(
            'SELECT %I.%I($1::text[], $2::text[], $3::jsonb, $4::jsonb)',
            provider_info.nspname, provider_info.proname
        );
    END LOOP;

    -- Pair identity is byte-exact, independent of database/input collation.
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

    -- Exactly two possible stages. A fallback model is never interpreted as a
    -- predicate or recursively followed. Provider failures abort the statement.
    FOR stage IN 1..stage_count LOOP
        IF stage = 1 THEN
            stage_lefts := unique_lefts;
            stage_rights := unique_rights;
        ELSE
            -- Compact only low-confidence unique pairs after all primary
            -- batches. Threshold equality and confident FALSE stay primary.
            SELECT coalesce(array_agg(unique_lefts[p.i] ORDER BY p.i), ARRAY[]::text[]),
                   coalesce(array_agg(unique_rights[p.i] ORDER BY p.i), ARRAY[]::text[]),
                   coalesce(array_agg(p.i ORDER BY p.i), ARRAY[]::integer[])
              INTO stage_lefts, stage_rights, fallback_indices
              FROM generate_subscripts(predictions, 1) AS p(i)
             WHERE (predictions[p.i]).confidence < selected_min_confidence;
        END IF;
        stage_input_count := cardinality(stage_lefts);
        batch_offset := 1;
        WHILE batch_offset <= stage_input_count LOOP
            batch_count := least(batch_size, stage_input_count - batch_offset + 1);
            EXECUTE provider_statements[stage] INTO batch_predictions
              USING stage_lefts[batch_offset:batch_offset + batch_count - 1],
                    stage_rights[batch_offset:batch_offset + batch_count - 1],
                    selected_definition, provider_configs[stage];
            IF batch_predictions IS NULL
               OR array_ndims(batch_predictions) IS DISTINCT FROM 1
               OR cardinality(batch_predictions) <> batch_count THEN
                RAISE EXCEPTION 'invalid provider output for JEV model %', provider_names[stage]
                    USING ERRCODE = '22023',
                          DETAIL = 'Provider must return a one-dimensional prediction array with one result per input pair.';
            END IF;
            result_index := batch_offset;
            FOREACH prediction IN ARRAY batch_predictions LOOP
                IF prediction.decision IS NULL OR prediction.confidence IS NULL
                   OR NOT (prediction.confidence >= 0 AND prediction.confidence <= 1) THEN
                    RAISE EXCEPTION 'invalid provider prediction for JEV model %', provider_names[stage]
                        USING ERRCODE = '22023',
                              DETAIL = 'A non-NULL input pair requires a non-NULL decision and finite confidence in [0, 1].';
                END IF;
                destination_index := CASE WHEN stage = 1 THEN result_index
                                          ELSE fallback_indices[result_index] END;
                predictions[destination_index] := prediction;
                result_index := result_index + 1;
            END LOOP;
            batch_offset := batch_offset + batch_count;
        END LOOP;
    END LOOP;

    -- Restore every occurrence, including duplicate/NULL row IDs and NULL
    -- composites. Only the selected low-confidence predictions were replaced.
    RETURN QUERY
    SELECT c.ordinal, c.row_id,
           (predictions[p.ordinal::integer]).decision,
           (predictions[p.ordinal::integer]).confidence
      FROM unnest(candidates) WITH ORDINALITY AS c(row_id, left_text, right_text, ordinal)
      LEFT JOIN unnest(unique_lefts, unique_rights) WITH ORDINALITY AS p(left_text, right_text, ordinal)
        ON c.left_text COLLATE pg_catalog."C" = p.left_text COLLATE pg_catalog."C"
       AND c.right_text COLLATE pg_catalog."C" = p.right_text COLLATE pg_catalog."C"
     ORDER BY c.ordinal;
END
$$;

COMMENT ON COLUMN jev.models.score_kind IS
    'Declared score semantics. decision_confidence means confidence in the emitted true or false decision; this declaration does not prove calibration.';
COMMENT ON COLUMN jev.predicates.fallback_model_name IS
    'Optional terminal fallback model for low-confidence unique inputs; both models must declare decision_confidence.';
COMMENT ON COLUMN jev.predicates.min_confidence IS
    'Fallback runs only when primary confidence is strictly below this value. Provider errors do not trigger fallback.';
COMMENT ON FUNCTION jev.evaluate_batch(text, jev.candidate[], integer) IS
    'Deduplicate finite non-NULL pairs, batch primary inference and optional selective fallback, then restore every occurrence. Result reuse is invocation-local.';

-- A relation is an explicit candidate boundary: the caller prepares any joins
-- and reductions first. Each input block is evaluated with one statement snapshot.
CREATE FUNCTION jev.evaluate_relation(
    predicate_name text,
    candidates regclass,
    batch_size integer DEFAULT 128
) RETURNS TABLE(
    ordinal bigint,
    row_id text,
    decision boolean,
    confidence double precision
)
LANGUAGE plpgsql STABLE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    source_info record;
    source_row record;
    input_batch jev.candidate[] := ARRAY[]::jev.candidate[];
    ordinal_offset bigint := 0;
BEGIN
    IF predicate_name IS NULL OR candidates IS NULL OR batch_size IS NULL
       OR batch_size < 1 OR batch_size > 65536 THEN
        RAISE EXCEPTION 'predicate_name, candidate relation, and batch_size in [1, 65536] are required'
            USING ERRCODE = '22023';
    END IF;
    SELECT n.nspname, c.relname INTO source_info
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = candidates AND c.relkind IN ('r', 'p', 'v', 'm');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'candidates must be a table, partitioned table, view, or materialized view'
            USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_attribute a
         WHERE a.attrelid = candidates AND a.attnum > 0 AND NOT a.attisdropped
           AND a.attname IN ('row_id', 'left_text', 'right_text')
           AND a.atttypid = 'pg_catalog.text'::regtype) <> 3 THEN
        RAISE EXCEPTION 'candidate relation must expose row_id, left_text, right_text as text columns'
            USING ERRCODE = '22023';
    END IF;

    -- Identifiers are catalog-resolved and quoted. Normal SELECT privileges,
    -- column grants, views and RLS apply to this invoker-side cursor query.
    FOR source_row IN EXECUTE format(
        'SELECT row_id, left_text, right_text FROM %I.%I',
        source_info.nspname, source_info.relname)
    LOOP
        input_batch := array_append(input_batch,
            ROW(source_row.row_id, source_row.left_text, source_row.right_text)::jev.candidate);
        IF cardinality(input_batch) = batch_size THEN
            RETURN QUERY SELECT e.ordinal + ordinal_offset, e.row_id, e.decision, e.confidence
                FROM jev.evaluate_batch(predicate_name, input_batch, batch_size) e;
            ordinal_offset := ordinal_offset + cardinality(input_batch);
            input_batch := ARRAY[]::jev.candidate[];
        END IF;
    END LOOP;
    IF cardinality(input_batch) > 0 THEN
        RETURN QUERY SELECT e.ordinal + ordinal_offset, e.row_id, e.decision, e.confidence
            FROM jev.evaluate_batch(predicate_name, input_batch, batch_size) e;
    ELSIF ordinal_offset = 0 THEN
        -- Match evaluate_batch's metadata validation on empty candidate sets.
        PERFORM * FROM jev.evaluate_batch(predicate_name, input_batch, batch_size);
    END IF;
END
$$;

COMMENT ON FUNCTION jev.evaluate_relation(text, regclass, integer) IS
    'Evaluate a caller-prepared relation in bounded input blocks; ordinary SELECT/RLS permissions apply. '
    'Result ordinals identify scan occurrences, not a guaranteed relation order. '
    'Deduplication is per block; PL/pgSQL materializes output with PostgreSQL tuplestore spilling.';
