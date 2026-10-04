-- Explicit exact reduction of caller-specified inner-equijoin trees.
CREATE TYPE jev.join_edge AS (
    left_node integer,
    left_columns text[],
    right_node integer,
    right_columns text[]
);

CREATE FUNCTION jev.reduce_join_tree(
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

COMMENT ON TYPE jev.join_edge IS
    'An explicit inner equijoin edge between one-based relation positions, with paired key-column names.';
COMMENT ON FUNCTION jev.reduce_join_tree(regclass[], jev.join_edge[], integer) IS
    'Exact bottom-up/top-down semijoin reduction of a caller-specified tree. '
    'Requires a repeatable-read or serializable transaction; returns private ON COMMIT DROP tables. '
    'Preserves bags and ordinary equality NULL semantics; performs no inference or automatic join rewriting.';
