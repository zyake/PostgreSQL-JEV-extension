-- Session switches for result-preserving optimization comparisons.

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
    -- Missing custom GUCs mean ON, so the explicit SQL API works before LOAD.
    do_batching boolean := coalesce(nullif(current_setting('jev.enable_batching', true), ''), 'on')::boolean;
    do_deduplication boolean := coalesce(nullif(current_setting('jev.enable_deduplication', true), ''), 'on')::boolean;
    do_selective_fallback boolean := coalesce(nullif(current_setting('jev.enable_selective_fallback', true), ''), 'on')::boolean;
    effective_batch_size integer;
    input_ordinals bigint[];
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

    effective_batch_size := CASE WHEN do_batching THEN batch_size ELSE 1 END;

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

    IF do_deduplication THEN
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
    ELSE
        -- Retain non-NULL occurrences and their original positions. Pair joins
        -- would multiply duplicates when reuse is disabled.
        SELECT coalesce(array_agg(c.left_text ORDER BY c.ordinal), ARRAY[]::text[]),
               coalesce(array_agg(c.right_text ORDER BY c.ordinal), ARRAY[]::text[]),
               coalesce(array_agg(c.ordinal ORDER BY c.ordinal), ARRAY[]::bigint[])
          INTO unique_lefts, unique_rights, input_ordinals
          FROM unnest(candidates) WITH ORDINALITY AS c(row_id, left_text, right_text, ordinal)
         WHERE c.left_text IS NOT NULL AND c.right_text IS NOT NULL;
    END IF;
    unique_count := cardinality(unique_lefts);
    predictions := array_fill(NULL::jev.prediction, ARRAY[unique_count]);

    -- Exactly two possible stages. A fallback model is never interpreted as a
    -- predicate or recursively followed. Provider failures abort the statement.
    FOR stage IN 1..stage_count LOOP
        IF stage = 1 THEN
            stage_lefts := unique_lefts;
            stage_rights := unique_rights;
        ELSE
            -- Disabling selective fallback sends every input to the fallback
            -- for an ablation, but replaces only low-confidence primary results.
            -- Threshold equality and confident FALSE still stay primary.
            SELECT coalesce(array_agg(unique_lefts[p.i] ORDER BY p.i), ARRAY[]::text[]),
                   coalesce(array_agg(unique_rights[p.i] ORDER BY p.i), ARRAY[]::text[]),
                   coalesce(array_agg(p.i ORDER BY p.i), ARRAY[]::integer[])
              INTO stage_lefts, stage_rights, fallback_indices
              FROM generate_subscripts(predictions, 1) AS p(i)
             WHERE NOT do_selective_fallback
                OR (predictions[p.i]).confidence < selected_min_confidence;
        END IF;
        stage_input_count := cardinality(stage_lefts);
        batch_offset := 1;
        WHILE batch_offset <= stage_input_count LOOP
            batch_count := least(effective_batch_size, stage_input_count - batch_offset + 1);
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
                -- Validate even fallback outputs that this ablation ignores.
                IF stage = 1 OR (predictions[destination_index]).confidence < selected_min_confidence THEN
                    predictions[destination_index] := prediction;
                END IF;
                result_index := result_index + 1;
            END LOOP;
            batch_offset := batch_offset + batch_count;
        END LOOP;
    END LOOP;

    -- Restore every occurrence, including duplicate/NULL row IDs and NULL
    -- composites. Only the selected low-confidence predictions were replaced.
    IF do_deduplication THEN
        RETURN QUERY
        SELECT c.ordinal, c.row_id,
               (predictions[p.ordinal::integer]).decision,
               (predictions[p.ordinal::integer]).confidence
          FROM unnest(candidates) WITH ORDINALITY AS c(row_id, left_text, right_text, ordinal)
          LEFT JOIN unnest(unique_lefts, unique_rights) WITH ORDINALITY AS p(left_text, right_text, ordinal)
            ON c.left_text COLLATE pg_catalog."C" = p.left_text COLLATE pg_catalog."C"
           AND c.right_text COLLATE pg_catalog."C" = p.right_text COLLATE pg_catalog."C"
         ORDER BY c.ordinal;
    ELSE
        RETURN QUERY
        SELECT c.ordinal, c.row_id,
               (predictions[p.result_index::integer]).decision,
               (predictions[p.result_index::integer]).confidence
          FROM unnest(candidates) WITH ORDINALITY AS c(row_id, left_text, right_text, ordinal)
          LEFT JOIN unnest(input_ordinals) WITH ORDINALITY AS p(input_ordinal, result_index)
            ON c.ordinal = p.input_ordinal
         ORDER BY c.ordinal;
    END IF;
END
$$;


CREATE OR REPLACE FUNCTION jev.reduce_join_tree(
    relations regclass[],
    edges jev.join_edge[],
    root_node integer DEFAULT 1
) RETURNS TABLE(
    node integer,
    source_relation regclass,
    reduced_relation regclass,
    input_rows bigint,
    retained_rows bigint
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    do_reduction boolean := coalesce(nullif(current_setting('jev.enable_join_reduction', true), ''), 'on')::boolean;
    sources regclass[];
    tree_edges jev.join_edge[];
    source_names text[] := ARRAY[]::text[];
    temp_names text[] := ARRAY[]::text[];
    temp_oids regclass[] := ARRAY[]::regclass[];
    original_counts bigint[] := ARRAY[]::bigint[];
    live_counts bigint[] := ARRAY[]::bigint[];
    conditions text[] := ARRAY[]::text[];
    parents integer[];
    parent_edges integer[];
    traversal integer[];
    edge jev.join_edge;
    left_keys text[];
    right_keys text[];
    left_attr record;
    right_attr record;
    source_info record;
    relation_count integer;
    edge_count integer;
    current_node integer;
    neighbor integer;
    parent_node integer;
    edge_number integer;
    target_alias text;
    support_alias text;
    copy_name text;
    affected bigint;
    i integer;
    j integer;
    k integer;
BEGIN
    -- This function creates private tables and therefore cannot be STABLE.
    -- A transaction snapshot keeps its separate SQL commands consistent.
    IF current_setting('transaction_isolation') NOT IN ('repeatable read', 'serializable') THEN
        RAISE EXCEPTION 'reduce_join_tree requires REPEATABLE READ or SERIALIZABLE isolation'
            USING ERRCODE = '22023',
                  HINT = 'Begin an explicit transaction at that isolation level; results are dropped at commit.';
    END IF;
    IF relations IS NULL OR array_ndims(relations) IS DISTINCT FROM 1
       OR cardinality(relations) NOT BETWEEN 1 AND 64
       OR edges IS NULL OR (cardinality(edges) > 0 AND array_ndims(edges) <> 1)
       OR root_node IS NULL OR root_node NOT BETWEEN 1 AND cardinality(relations) THEN
        RAISE EXCEPTION 'provide 1..64 relations, a one-dimensional edge array, and a valid root node'
            USING ERRCODE = '22023';
    END IF;
    -- Node numbers denote array positions, independent of SQL array bounds.
    sources := ARRAY(SELECT r FROM unnest(relations) AS r);
    tree_edges := ARRAY(SELECT e FROM unnest(edges) AS e);
    relation_count := cardinality(sources);
    edge_count := cardinality(tree_edges);
    IF edge_count <> relation_count - 1 THEN
        RAISE EXCEPTION 'a join tree requires exactly one fewer edge than relations'
            USING ERRCODE = '22023';
    END IF;

    FOR i IN 1..relation_count LOOP
        SELECT n.nspname, c.relname INTO source_info
          FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
         WHERE c.oid = sources[i] AND c.relkind IN ('r', 'p', 'm');
        IF NOT FOUND THEN
            RAISE EXCEPTION 'node % must reference a table, partitioned table, or materialized view', i
                USING ERRCODE = '22023';
        END IF;
        source_names[i] := format('%I.%I', source_info.nspname, source_info.relname);
        FOR j IN 1..2 LOOP
            -- Check before SELECT planning, which could otherwise contact an
            -- FDW even with LIMIT 0, and again once the relations are locked.
            IF EXISTS (
                WITH RECURSIVE descendants(oid) AS (
                    SELECT sources[i]::oid
                    UNION
                    SELECT inh.inhrelid FROM pg_inherits AS inh
                    JOIN descendants AS d ON d.oid = inh.inhparent
                )
                SELECT FROM descendants AS d JOIN pg_class AS c ON c.oid = d.oid
                WHERE c.relkind = 'f'
            ) THEN
                RAISE EXCEPTION 'node % includes a foreign table; materialize it locally first', i
                    USING ERRCODE = '22023';
            END IF;
            IF j = 1 THEN
                -- Acquire ordinary SELECT locks/privileges before inspecting keys.
                -- ONLY is absent: normal inheritance/partition scans apply.
                EXECUTE format('SELECT * FROM %s LIMIT 0', source_names[i]);
                IF to_regclass(source_names[i]) IS DISTINCT FROM sources[i] THEN
                    RAISE EXCEPTION 'source relation changed while locking node %; retry', i
                        USING ERRCODE = '40001';
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    FOR i IN 1..edge_count LOOP
        edge := tree_edges[i];
        IF edge.left_node IS NULL OR edge.right_node IS NULL
           OR edge.left_node NOT BETWEEN 1 AND relation_count
           OR edge.right_node NOT BETWEEN 1 AND relation_count
           OR edge.left_node = edge.right_node
           OR edge.left_columns IS NULL OR edge.right_columns IS NULL
           OR array_ndims(edge.left_columns) IS DISTINCT FROM 1
           OR array_ndims(edge.right_columns) IS DISTINCT FROM 1
           OR cardinality(edge.left_columns) <> cardinality(edge.right_columns) THEN
            RAISE EXCEPTION 'edge % requires two distinct valid nodes and nonempty equally-sized key arrays', i
                USING ERRCODE = '22023';
        END IF;
        left_keys := ARRAY(SELECT v FROM unnest(edge.left_columns) AS v);
        right_keys := ARRAY(SELECT v FROM unnest(edge.right_columns) AS v);
        conditions[i] := '';
        FOR j IN 1..cardinality(left_keys) LOOP
            SELECT a.atttypid, a.atttypmod, a.attcollation INTO left_attr
              FROM pg_attribute AS a
             WHERE a.attrelid = sources[edge.left_node] AND a.attname = left_keys[j]
               AND a.attnum > 0 AND NOT a.attisdropped;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'edge % has an invalid left key column', i USING ERRCODE = '22023';
            END IF;
            SELECT a.atttypid, a.atttypmod, a.attcollation INTO right_attr
              FROM pg_attribute AS a
             WHERE a.attrelid = sources[edge.right_node] AND a.attname = right_keys[j]
               AND a.attnum > 0 AND NOT a.attisdropped;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'edge % has an invalid right key column', i USING ERRCODE = '22023';
            END IF;
            IF left_attr.atttypid <> right_attr.atttypid
               OR left_attr.atttypmod <> right_attr.atttypmod
               OR left_attr.attcollation <> right_attr.attcollation
               OR left_attr.atttypid <> ALL (ARRAY[
                   'int2'::regtype, 'int4'::regtype, 'int8'::regtype, 'text'::regtype,
                   'uuid'::regtype, 'date'::regtype, 'timestamp'::regtype,
                   'timestamptz'::regtype, 'numeric'::regtype, 'bool'::regtype]) THEN
                RAISE EXCEPTION 'edge % keys must have matching supported built-in types, modifiers, and collations', i
                    USING ERRCODE = '22023';
            END IF;
            conditions[i] := conditions[i] || CASE WHEN j > 1 THEN ' AND ' ELSE '' END
                || format('l.%I OPERATOR(pg_catalog.=) r.%I', left_keys[j], right_keys[j]);
        END LOOP;
    END LOOP;

    parents := array_fill(0, ARRAY[relation_count]);
    parent_edges := array_fill(0, ARRAY[relation_count]);
    parents[root_node] := -1;
    traversal := ARRAY[root_node];
    k := 1;
    WHILE k <= cardinality(traversal) LOOP
        current_node := traversal[k];
        FOR i IN 1..edge_count LOOP
            edge := tree_edges[i];
            IF edge.left_node = current_node THEN
                neighbor := edge.right_node;
            ELSIF edge.right_node = current_node THEN
                neighbor := edge.left_node;
            ELSE
                CONTINUE;
            END IF;
            IF parents[neighbor] = 0 THEN
                parents[neighbor] := current_node;
                parent_edges[neighbor] := i;
                traversal := array_append(traversal, neighbor);
            END IF;
        END LOOP;
        k := k + 1;
    END LOOP;
    -- A connected undirected graph with N-1 edges is a tree. This also rejects
    -- parallel/reversed duplicate edges and cycles without special cases.
    IF cardinality(traversal) <> relation_count THEN
        RAISE EXCEPTION 'edges must form one connected, acyclic join tree'
            USING ERRCODE = '22023';
    END IF;

    FOR i IN 1..relation_count LOOP
        copy_name := '_jev_reduce_' || pg_backend_pid() || '_' || md5(random()::text);
        temp_names[i] := format('pg_temp.%I', copy_name);
        -- No IF NOT EXISTS or DROP: a collision fails without touching any table.
        -- CTAS carries values, types and collations, but not constraints, grants,
        -- triggers, indexes or RLS policies. Source RLS is enforced by SELECT.
        EXECUTE format('CREATE TEMP TABLE %s ON COMMIT DROP AS SELECT * FROM %s',
                       temp_names[i], source_names[i]);
        GET DIAGNOSTICS affected = ROW_COUNT;
        original_counts[i] := affected;
        live_counts[i] := affected;
        temp_oids[i] := to_regclass(temp_names[i]);
        EXECUTE format('ANALYZE %s', temp_names[i]);
    END LOOP;

    -- OFF retains the same validation, snapshot, permissions and private
    -- copy boundary. Only the two semijoin passes are omitted.
    IF do_reduction THEN
        -- Reverse breadth-first order is a valid bottom-up order for a tree.
        FOR k IN REVERSE relation_count..2 LOOP
            current_node := traversal[k];
            parent_node := parents[current_node];
            edge_number := parent_edges[current_node];
            edge := tree_edges[edge_number];
            target_alias := CASE WHEN edge.left_node = parent_node THEN 'l' ELSE 'r' END;
            support_alias := CASE WHEN target_alias = 'l' THEN 'r' ELSE 'l' END;
            EXECUTE format('DELETE FROM %s AS %s WHERE NOT EXISTS (SELECT FROM %s AS %s WHERE %s)',
                           temp_names[parent_node], target_alias,
                           temp_names[current_node], support_alias, conditions[edge_number]);
            GET DIAGNOSTICS affected = ROW_COUNT;
            live_counts[parent_node] := live_counts[parent_node] - affected;
            EXECUTE format('ANALYZE %s', temp_names[parent_node]);
        END LOOP;

        FOR k IN 2..relation_count LOOP
            current_node := traversal[k];
            parent_node := parents[current_node];
            edge_number := parent_edges[current_node];
            edge := tree_edges[edge_number];
            target_alias := CASE WHEN edge.left_node = current_node THEN 'l' ELSE 'r' END;
            support_alias := CASE WHEN target_alias = 'l' THEN 'r' ELSE 'l' END;
            EXECUTE format('DELETE FROM %s AS %s WHERE NOT EXISTS (SELECT FROM %s AS %s WHERE %s)',
                           temp_names[current_node], target_alias,
                           temp_names[parent_node], support_alias, conditions[edge_number]);
            GET DIAGNOSTICS affected = ROW_COUNT;
            live_counts[current_node] := live_counts[current_node] - affected;
            EXECUTE format('ANALYZE %s', temp_names[current_node]);
        END LOOP;
    END IF;

    FOR i IN 1..relation_count LOOP
        node := i;
        source_relation := sources[i];
        reduced_relation := temp_oids[i];
        input_rows := original_counts[i];
        retained_rows := live_counts[i];
        RETURN NEXT;
    END LOOP;
END
$$;


COMMENT ON FUNCTION jev.evaluate_batch(text, jev.candidate[], integer) IS
    'Evaluate finite non-NULL pairs and restore every occurrence. '
    'Batching, deduplication and selective fallback have session switches for controlled comparisons; '
    'disabling selective fallback still preserves the configured decision policy.';
COMMENT ON COLUMN jev.predicates.min_confidence IS
    'Fallback decisions replace primary decisions strictly below this confidence. '
    'Disabling selective fallback evaluates all fallback inputs but retains high-confidence primary decisions. '
    'Provider errors do not trigger fallback.';
COMMENT ON FUNCTION jev.reduce_join_tree(regclass[], jev.join_edge[], integer) IS
    'Exact bottom-up/top-down semijoin reduction of a caller-specified tree. '
    'Requires a repeatable-read or serializable transaction; returns private ON COMMIT DROP tables. '
    'The join-reduction switch omits reduction passes while retaining validation and private copies. '
    'Preserves bags and ordinary equality NULL semantics; performs no inference or automatic join rewriting.';
