\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- A branching tree: A--B--C, B--D--E. D--E has a composite key.
-- Duplicate source rows and NULL business IDs are deliberately meaningful.
CREATE TEMP TABLE jev_tree_a (a_id text, a_key integer);
INSERT INTO jev_tree_a VALUES
    ('shop',1), ('shop',1), (NULL,2), ('bottom-cut',3),
    ('no-edge',4), ('null-key',NULL);
CREATE TEMP TABLE jev_tree_b (
    b_id text, a_key integer, c_key integer, d_key integer,
    left_text text, right_text text);
INSERT INTO jev_tree_b VALUES
    ('offer',1,10,100,'boots','boots'), ('offer',1,10,100,'boots','boots'),
    ('offer',2,20,200,'coat','coat'),
    ('mismatch',1,10,100,'boots','sandals'), ('null-text',2,20,200,NULL,'coat'),
    ('bottom-cut',3,30,300,'poison:no-e','poison:no-e'),
    ('top-cut',9,90,900,'poison:no-a','poison:no-a'),
    ('null-a',NULL,10,100,'poison:null-a','poison:null-a'),
    ('null-c',1,NULL,100,'poison:null-c','poison:null-c'),
    ('null-d',1,10,NULL,'poison:null-d','poison:null-d');
CREATE TEMP TABLE jev_tree_c (c_id text, c_key integer);
INSERT INTO jev_tree_c VALUES
    ('stock',10), ('stock',10), (NULL,20), ('bottom-cut',30),
    ('top-cut',90), ('no-edge',40), ('null-key',NULL);
CREATE TEMP TABLE jev_tree_d (d_id text, d_key integer, e_text text COLLATE "C", e_number integer);
INSERT INTO jev_tree_d VALUES
    ('warehouse',100,'x',1), ('warehouse',200,'y',2),
    ('composite-miss',300,'x',9), ('top-cut',900,'z',9),
    ('null-d',NULL,'x',1), ('null-text',400,NULL,1), ('null-number',500,'x',NULL);
CREATE TEMP TABLE jev_tree_e (e_id text, e_text text COLLATE "C", e_number integer);
INSERT INTO jev_tree_e VALUES
    ('region','x',1), ('region','x',1), (NULL,'y',2),
    ('partial-key','x',8), ('top-cut','z',9),
    ('null-text',NULL,1), ('null-number','x',NULL);

CREATE TEMP TABLE jev_tree_baseline AS
SELECT a.a_id, b.b_id, c.c_id, d.d_id, e.e_id, b.left_text, b.right_text
FROM jev_tree_a a
JOIN jev_tree_b b ON a.a_key = b.a_key
JOIN jev_tree_c c ON b.c_key = c.c_key
JOIN jev_tree_d d ON b.d_key = d.d_key
JOIN jev_tree_e e ON d.e_text = e.e_text AND d.e_number = e.e_number;

CREATE FUNCTION pg_temp.tree_expect_error(statement text, expected_state text)
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

CREATE TEMP TABLE jev_tree_outputs (
    node integer, source_relation regclass, reduced_relation regclass,
    input_rows bigint, retained_rows bigint);
INSERT INTO jev_tree_outputs
SELECT * FROM jev.reduce_join_tree(
    ARRAY['jev_tree_a','jev_tree_b','jev_tree_c','jev_tree_d','jev_tree_e']::regclass[],
    ARRAY[
        (5,ARRAY['e_text','e_number'],4,ARRAY['e_text','e_number'])::jev.join_edge,
        (3,ARRAY['c_key'],2,ARRAY['c_key'])::jev.join_edge,
        (1,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge,
        (4,ARRAY['d_key'],2,ARRAY['d_key'])::jev.join_edge
    ]);

DO $$
DECLARE rels regclass[];
BEGIN
    ASSERT (SELECT count(*) = 26 FROM jev_tree_baseline);
    ASSERT (SELECT array_agg(node ORDER BY node) = ARRAY[1,2,3,4,5] FROM jev_tree_outputs);
    ASSERT (SELECT array_agg(input_rows ORDER BY node) = ARRAY[6,10,7,7,7]::bigint[] FROM jev_tree_outputs);
    ASSERT (SELECT array_agg(retained_rows ORDER BY node) = ARRAY[3,5,3,2,3]::bigint[] FROM jev_tree_outputs),
        'two passes did not propagate support through all branches';
    ASSERT (SELECT count(DISTINCT reduced_relation) = 5 FROM jev_tree_outputs);
    ASSERT NOT EXISTS (
        SELECT FROM jev_tree_outputs o JOIN pg_class c ON c.oid = o.reduced_relation
        WHERE c.relpersistence <> 't' OR c.relnamespace <> pg_my_temp_schema()
    ), 'reduced relations are not session-local temporary tables';
    SELECT array_agg(reduced_relation ORDER BY node) INTO rels FROM jev_tree_outputs;
    EXECUTE format($q$
        CREATE TEMP TABLE jev_tree_actual AS
        SELECT a.a_id, b.b_id, c.c_id, d.d_id, e.e_id, b.left_text, b.right_text
        FROM %s a JOIN %s b ON a.a_key = b.a_key
        JOIN %s c ON b.c_key = c.c_key JOIN %s d ON b.d_key = d.d_key
        JOIN %s e ON d.e_text = e.e_text AND d.e_number = e.e_number
    $q$, rels[1],rels[2],rels[3],rels[4],rels[5]);
    ASSERT NOT EXISTS (
        (TABLE jev_tree_baseline EXCEPT ALL TABLE jev_tree_actual)
        UNION ALL (TABLE jev_tree_actual EXCEPT ALL TABLE jev_tree_baseline)
    ), 'reduction changed the relational join bag';
    EXECUTE format('CREATE TEMP TABLE jev_tree_candidates AS SELECT row_number() OVER ()::text AS row_id, b.* FROM %s b', rels[2]);
END
$$;

-- Only the three surviving unique non-NULL pairs may reach inference.
CREATE FUNCTION pg_temp.tree_probe(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF cardinality($1) <> 3 OR cardinality($2) <> 3 THEN
        RAISE EXCEPTION 'expected exactly three reduced unique pairs';
    END IF;
    IF EXISTS (SELECT FROM unnest($1,$2) p(l,r)
               WHERE l IS NULL OR r IS NULL OR l LIKE 'poison:%') THEN
        RAISE EXCEPTION 'relationally impossible or NULL input reached provider';
    END IF;
    RETURN jev.exact_provider($1,$2,$3,$4);
END
$$;
INSERT INTO jev.models(name,version,provider)
VALUES ('tree-probe','1','pg_temp.tree_probe(text[],text[],jsonb,jsonb)'::regprocedure);
INSERT INTO jev.predicates(name,version,model_name) VALUES ('tree-probe','1','tree-probe');
CREATE TEMP TABLE jev_tree_decisions AS
SELECT * FROM jev.evaluate_relation('tree-probe','jev_tree_candidates',128);
DO $$
DECLARE rels regclass[];
BEGIN
    ASSERT (SELECT count(*) = 5 FROM jev_tree_decisions);
    ASSERT (SELECT count(*) = 3 FROM jev_tree_decisions WHERE decision IS TRUE);
    ASSERT (SELECT count(*) = 1 FROM jev_tree_decisions WHERE decision IS FALSE);
    ASSERT (SELECT count(*) = 1 FROM jev_tree_decisions WHERE decision IS NULL AND confidence IS NULL);
    SELECT array_agg(reduced_relation ORDER BY node) INTO rels FROM jev_tree_outputs;
    EXECUTE format($q$
        CREATE TEMP TABLE jev_tree_semantic_actual AS
        SELECT a.a_id, b.b_id, c.c_id, d.d_id, e.e_id, b.left_text, b.right_text
        FROM jev_tree_candidates b JOIN jev_tree_decisions result USING (row_id)
        JOIN %s a ON a.a_key = b.a_key JOIN %s c ON b.c_key = c.c_key
        JOIN %s d ON b.d_key = d.d_key
        JOIN %s e ON d.e_text = e.e_text AND d.e_number = e.e_number
        WHERE result.decision IS TRUE
    $q$, rels[1],rels[3],rels[4],rels[5]);
    ASSERT NOT EXISTS (
        (SELECT * FROM jev_tree_baseline WHERE jev.semantic_match('exact',left_text,right_text)
         EXCEPT ALL TABLE jev_tree_semantic_actual)
        UNION ALL
        (TABLE jev_tree_semantic_actual EXCEPT ALL
         SELECT * FROM jev_tree_baseline WHERE jev.semantic_match('exact',left_text,right_text))
    ), 'semantic result changed the full baseline bag';
    ASSERT (SELECT count(*) = 17 FROM jev_tree_semantic_actual);
    ASSERT (SELECT count(*) = 16 FROM jev_tree_semantic_actual WHERE left_text = 'boots'),
        'source multiplicity (2 x 2 x 2 x 1 x 2) was lost';
    ASSERT (SELECT count(*) = 1 FROM jev_tree_semantic_actual WHERE a_id IS NULL AND c_id IS NULL AND e_id IS NULL),
        'NULL business IDs were treated as NULL join keys';
END
$$;

-- Every root must yield the same source bags, even with permuted/reversed edges.
DO $$
DECLARE root integer; item record; original regclass; changed boolean;
BEGIN
    FOR root IN 1..5 LOOP
        FOR item IN SELECT * FROM jev.reduce_join_tree(
            ARRAY['jev_tree_a','jev_tree_b','jev_tree_c','jev_tree_d','jev_tree_e']::regclass[],
            ARRAY[
                (2,ARRAY['d_key'],4,ARRAY['d_key'])::jev.join_edge,
                (2,ARRAY['a_key'],1,ARRAY['a_key'])::jev.join_edge,
                (4,ARRAY['e_text','e_number'],5,ARRAY['e_text','e_number'])::jev.join_edge,
                (2,ARRAY['c_key'],3,ARRAY['c_key'])::jev.join_edge
            ], root)
        LOOP
            SELECT reduced_relation INTO STRICT original FROM jev_tree_outputs WHERE node = item.node;
            EXECUTE format('SELECT EXISTS ((TABLE %s EXCEPT ALL TABLE %s) UNION ALL (TABLE %s EXCEPT ALL TABLE %s))',
                           original,item.reduced_relation,item.reduced_relation,original) INTO changed;
            ASSERT NOT changed, 'root or edge orientation changed reduced bag';
        END LOOP;
    END LOOP;
END
$$;

-- A singleton retains its whole bag; aliases of one source remain distinct nodes.
DO $$
DECLARE result record; actual bigint; rels regclass[]; edges jev.join_edge[];
BEGIN
    SELECT * INTO STRICT result FROM jev.reduce_join_tree(ARRAY['jev_tree_a']::regclass[],ARRAY[]::jev.join_edge[]);
    ASSERT result.node = 1 AND result.input_rows = 6 AND result.retained_rows = 6;
    EXECUTE format('SELECT count(*) FROM %s WHERE a_key IS NULL',result.reduced_relation) INTO actual;
    ASSERT actual = 1, 'singleton removed a NULL key without a join';
    FOR result IN SELECT * FROM jev.reduce_join_tree(
        ARRAY['jev_tree_a','jev_tree_a']::regclass[],
        ARRAY[(1,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge])
    LOOP
        ASSERT result.input_rows = 6 AND result.retained_rows = 5, 'self-alias reduction changed multiplicity';
    END LOOP;
    -- Array subscripts are normalized to public node numbers 1..N.
    rels := '[0:1]={jev_tree_a,jev_tree_a}'::regclass[];
    edges := array_fill(NULL::jev.join_edge, ARRAY[1], ARRAY[-3]);
    edges[-3] := (1,'[0:0]={a_key}'::text[],2,'[-5:-5]={a_key}'::text[])::jev.join_edge;
    ASSERT (SELECT count(*) = 2 FROM jev.reduce_join_tree(rels,edges));
END
$$;

CREATE TEMP TABLE "jev tree quoted; source" ("key;--" integer, "value space" text);
INSERT INTO "jev tree quoted; source" VALUES (1,'safe'), (1,'safe'), (NULL,'strict');
DO $$
DECLARE item record;
BEGIN
    FOR item IN SELECT * FROM jev.reduce_join_tree(
        ARRAY['"jev tree quoted; source"','"jev tree quoted; source"']::regclass[],
        ARRAY[(1,ARRAY['key;--'],2,ARRAY['key;--'])::jev.join_edge])
    LOOP
        ASSERT item.input_rows = 3 AND item.retained_rows = 2, 'identifier quoting failed';
    END LOOP;
END
$$;

-- Other supported table kinds retain normal partition scan semantics.
CREATE TABLE public.jev_tree_partitioned (key integer, payload text) PARTITION BY RANGE (key);
CREATE TABLE public.jev_tree_partition_default PARTITION OF public.jev_tree_partitioned DEFAULT;
INSERT INTO public.jev_tree_partitioned VALUES (1,'same'), (1,'same'), (NULL,'null-key');
CREATE MATERIALIZED VIEW public.jev_tree_materialized AS SELECT * FROM public.jev_tree_partitioned;
DO $$
DECLARE item record;
BEGIN
    FOR item IN SELECT * FROM jev.reduce_join_tree(
        ARRAY['public.jev_tree_partitioned','public.jev_tree_materialized']::regclass[],
        ARRAY[(1,ARRAY['key'],2,ARRAY['key'])::jev.join_edge])
    LOOP
        ASSERT item.input_rows = 3 AND item.retained_rows = 2,
            'partitioned or materialized source changed bag/NULL semantics';
    END LOOP;
END
$$;

-- Every supported equality type can participate in a composite edge.
CREATE TEMP TABLE jev_tree_builtin_keys (
    small_key smallint, big_key bigint, uuid_key uuid, date_key date,
    timestamp_key timestamp, timestamptz_key timestamptz,
    numeric_key numeric(8,2), bool_key boolean);
INSERT INTO jev_tree_builtin_keys VALUES
    (1,1,'00000000-0000-0000-0000-000000000001','2026-10-04','2026-10-04 12:00:00','2026-10-04 12:00:00+00',1.25,true),
    (1,1,'00000000-0000-0000-0000-000000000001','2026-10-04','2026-10-04 12:00:00','2026-10-04 12:00:00+00',1.25,true),
    (2,2,'00000000-0000-0000-0000-000000000002','infinity','infinity','infinity','NaN',false),
    (1,1,'00000000-0000-0000-0000-000000000001','2026-10-04','2026-10-04 12:00:00','2026-10-04 12:00:00+00',1.25,NULL);
DO $$
DECLARE keys text[] := ARRAY['small_key','big_key','uuid_key','date_key','timestamp_key','timestamptz_key','numeric_key','bool_key'];
        item record;
BEGIN
    FOR item IN SELECT * FROM jev.reduce_join_tree(
        ARRAY['jev_tree_builtin_keys','jev_tree_builtin_keys']::regclass[],
        ARRAY[(1,keys,2,keys)::jev.join_edge])
    LOOP
        ASSERT item.input_rows = 4 AND item.retained_rows = 3,
            'built-in equality (including numeric NaN and date infinity) changed';
    END LOOP;
END
$$;

-- An empty leaf must empty every branch, irrespective of root position.
CREATE TEMP TABLE jev_tree_empty (LIKE jev_tree_e);
DO $$
BEGIN
    ASSERT NOT EXISTS (SELECT FROM jev.reduce_join_tree(
        ARRAY['jev_tree_a','jev_tree_b','jev_tree_c','jev_tree_d','jev_tree_empty']::regclass[],
        ARRAY[
            (1,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge,
            (2,ARRAY['c_key'],3,ARRAY['c_key'])::jev.join_edge,
            (2,ARRAY['d_key'],4,ARRAY['d_key'])::jev.join_edge,
            (4,ARRAY['e_text','e_number'],5,ARRAY['e_text','e_number'])::jev.join_edge
        ], 3) WHERE retained_rows <> 0), 'empty support did not reach every branch';
END
$$;

-- Reject invalid graph, shape, source, and key metadata before execution.
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(NULL,ARRAY[]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY[]::regclass[],ARRAY[]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY[NULL]::regclass[],ARRAY[]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY[['jev_tree_a']]::regclass[],ARRAY[]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(array_fill('jev_tree_a'::regclass,ARRAY[65]),ARRAY[]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a']::regclass[],NULL)$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a']::regclass[],ARRAY[]::jev.join_edge[],NULL)$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a']::regclass[],ARRAY[]::jev.join_edge[],0)$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a']::regclass[],ARRAY[]::jev.join_edge[],2)$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[NULL]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[[(1,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge]])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(0,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,ARRAY['a_key'],3,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,ARRAY['a_key'],1,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b','jev_tree_a']::regclass[],ARRAY[(1,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge,(2,ARRAY['a_key'],1,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_a','jev_tree_a','jev_tree_a']::regclass[],ARRAY[(1,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge,(2,ARRAY['a_key'],3,ARRAY['a_key'])::jev.join_edge,(3,ARRAY['a_key'],1,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(NULL,ARRAY['a_key'],2,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,NULL,2,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,ARRAY[]::text[],2,ARRAY[]::text[])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,ARRAY[NULL]::text[],2,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,ARRAY['missing'],2,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,ARRAY['a_key'],2,ARRAY['a_key','c_key'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_a','jev_tree_b']::regclass[],ARRAY[(1,ARRAY[['a_key']],2,ARRAY['a_key'])::jev.join_edge])$q$,'22023');
CREATE TEMP VIEW jev_tree_view AS SELECT * FROM jev_tree_a;
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_view']::regclass[],ARRAY[]::jev.join_edge[])$q$,'22023');
-- No FDW handler or connection is needed: reject foreign inputs before planning
-- a source SELECT, including a foreign descendant of an ordinary parent.
CREATE FOREIGN DATA WRAPPER jev_tree_fdw NO HANDLER;
CREATE SERVER jev_tree_server FOREIGN DATA WRAPPER jev_tree_fdw;
CREATE TABLE public.jev_tree_foreign_parent(key integer);
CREATE FOREIGN TABLE public.jev_tree_foreign_child ()
    INHERITS (public.jev_tree_foreign_parent) SERVER jev_tree_server;
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['public.jev_tree_foreign_child']::regclass[],ARRAY[]::jev.join_edge[])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['public.jev_tree_foreign_parent']::regclass[],ARRAY[]::jev.join_edge[])$q$,'22023');
CREATE TEMP TABLE jev_tree_bad_types (small smallint, big bigint, payload jsonb, default_text text, c_text text COLLATE "C", n1 numeric(8,2), n2 numeric(9,2));
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_bad_types','jev_tree_bad_types']::regclass[],ARRAY[(1,ARRAY['small'],2,ARRAY['big'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_bad_types','jev_tree_bad_types']::regclass[],ARRAY[(1,ARRAY['payload'],2,ARRAY['payload'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_bad_types','jev_tree_bad_types']::regclass[],ARRAY[(1,ARRAY['default_text'],2,ARRAY['c_text'])::jev.join_edge])$q$,'22023');
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['jev_tree_bad_types','jev_tree_bad_types']::regclass[],ARRAY[(1,ARRAY['n1'],2,ARRAY['n2'])::jev.join_edge])$q$,'22023');

-- Normal invoker SELECT permissions and RLS apply before temporary materialization.
CREATE TABLE public.jev_tree_rls (key integer, tenant text, payload text);
INSERT INTO public.jev_tree_rls VALUES (1,'visible','safe'), (1,'visible','safe'), (2,'hidden','private');
CREATE ROLE jev_tree_reader;
GRANT USAGE ON SCHEMA public,jev TO jev_tree_reader;
GRANT SELECT ON public.jev_tree_rls TO jev_tree_reader;
ALTER TABLE public.jev_tree_rls ENABLE ROW LEVEL SECURITY;
CREATE POLICY tree_reader_policy ON public.jev_tree_rls TO jev_tree_reader USING (tenant = 'visible');
SET LOCAL ROLE jev_tree_reader;
DO $$
DECLARE item record; actual bigint;
BEGIN
    FOR item IN SELECT * FROM jev.reduce_join_tree(
        ARRAY['public.jev_tree_rls','public.jev_tree_rls']::regclass[],
        ARRAY[(1,ARRAY['key'],2,ARRAY['key'])::jev.join_edge])
    LOOP
        ASSERT item.input_rows = 2 AND item.retained_rows = 2, 'RLS source count leaked hidden rows';
        EXECUTE format('SELECT count(*) FROM %s WHERE payload = ''private''',item.reduced_relation) INTO actual;
        ASSERT actual = 0, 'RLS hidden row leaked into temporary output';
    END LOOP;
END
$$;
RESET ROLE;
REVOKE SELECT ON public.jev_tree_rls FROM jev_tree_reader;
GRANT SELECT(key,tenant) ON public.jev_tree_rls TO jev_tree_reader;
SET LOCAL ROLE jev_tree_reader;
SELECT pg_temp.tree_expect_error($q$SELECT * FROM jev.reduce_join_tree(ARRAY['public.jev_tree_rls']::regclass[],ARRAY[]::jev.join_edge[])$q$,'42501');
RESET ROLE;
GRANT SELECT(payload) ON public.jev_tree_rls TO jev_tree_reader;
SET LOCAL ROLE jev_tree_reader;
DO $$ BEGIN
    ASSERT (SELECT retained_rows = 2 FROM jev.reduce_join_tree(ARRAY['public.jev_tree_rls']::regclass[],ARRAY[]::jev.join_edge[])),
        'complete column grants should permit materialization';
END $$;
RESET ROLE;
DO $$ BEGIN
    ASSERT (SELECT count(*) = 6 FROM jev_tree_a);
    ASSERT (SELECT count(*) = 10 FROM jev_tree_b);
    ASSERT (SELECT count(*) = 7 FROM jev_tree_c);
    ASSERT (SELECT count(*) = 7 FROM jev_tree_d);
    ASSERT (SELECT count(*) = 7 FROM jev_tree_e);
    ASSERT (SELECT count(*) = 3 FROM public.jev_tree_rls),
        'reduction must never modify its source relations';
END $$;
ROLLBACK;

-- The function's multiple statements require one source snapshot.
BEGIN ISOLATION LEVEL READ COMMITTED;
CREATE TEMP TABLE jev_tree_snapshot_source (key integer);
DO $$
DECLARE failed boolean := false;
BEGIN
    BEGIN
        PERFORM * FROM jev.reduce_join_tree(ARRAY['jev_tree_snapshot_source']::regclass[],ARRAY[]::jev.join_edge[]);
    EXCEPTION WHEN invalid_parameter_value THEN failed := true;
    END;
    ASSERT failed, 'READ COMMITTED should require an explicit stable snapshot';
END
$$;
ROLLBACK;

-- Returned relations are usable through the transaction, then ON COMMIT DROP.
BEGIN ISOLATION LEVEL SERIALIZABLE;
CREATE TEMP TABLE jev_tree_lifetime_source (key integer);
INSERT INTO jev_tree_lifetime_source VALUES (1);
SELECT reduced_relation::oid AS jev_tree_output_oid
FROM jev.reduce_join_tree(ARRAY['jev_tree_lifetime_source']::regclass[],ARRAY[]::jev.join_edge[]) \gset
COMMIT;
SELECT NOT EXISTS (SELECT FROM pg_class WHERE oid = :jev_tree_output_oid) AS jev_tree_output_dropped \gset
\if :jev_tree_output_dropped
\else
    \echo 'reduced temporary relation survived COMMIT'
    \quit 1
\endif
DROP TABLE jev_tree_lifetime_source;
\echo 'join tree reduction assertions passed'
