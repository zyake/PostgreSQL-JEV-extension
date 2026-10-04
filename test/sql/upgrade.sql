\set ON_ERROR_STOP on
BEGIN;
CREATE EXTENSION jev VERSION '0.1.0';
INSERT INTO jev.models(name,version,provider,config) VALUES
    ('upgrade-model','old','jev.exact_provider(text[],text[],jsonb,jsonb)'::regprocedure,'{"retained":true}');
INSERT INTO jev.predicates(name,version,model_name,definition) VALUES
    ('upgrade-predicate','old','upgrade-model','{"retained":true}');
ALTER EXTENSION jev UPDATE TO '0.2.0';
DO $$ BEGIN
    ASSERT (SELECT extversion='0.2.0' FROM pg_extension WHERE extname='jev');
    ASSERT (SELECT version='old' AND config='{"retained":true}'::jsonb
                   AND score_kind='uninterpreted' FROM jev.models WHERE name='upgrade-model');
    ASSERT (SELECT version='old' AND definition='{"retained":true}'::jsonb
                   AND fallback_model_name IS NULL AND min_confidence IS NULL
            FROM jev.predicates WHERE name='upgrade-predicate');
    ASSERT (SELECT score_kind='decision_confidence' FROM jev.models WHERE name='exact-v1');
    ASSERT jev.semantic_match('upgrade-predicate','same','same');
END $$;
CREATE TEMP TABLE upgrade_candidates(row_id text,left_text text,right_text text);
INSERT INTO upgrade_candidates VALUES ('1','x','x'),('1','x','x'),('2',NULL,'x');
DO $$ BEGIN
    ASSERT (SELECT count(*)=3 AND count(decision)=2
            FROM jev.evaluate_relation('upgrade-predicate','upgrade_candidates',1));
END $$;
ALTER EXTENSION jev UPDATE TO '0.3.0';
DO $$ BEGIN
    ASSERT (SELECT extversion='0.3.0' FROM pg_extension WHERE extname='jev');
    ASSERT to_regprocedure('jev.reduce_join_tree(regclass[],jev.join_edge[],integer)') IS NOT NULL;
    ASSERT jev.semantic_match('upgrade-predicate','same','same');
END $$;
ALTER EXTENSION jev UPDATE TO '0.4.0';
DO $$ BEGIN
 ASSERT (SELECT extversion='0.4.0' FROM pg_extension WHERE extname='jev');
 ASSERT jev.semantic_match('upgrade-predicate','same','same');
END $$;
ROLLBACK;

-- Also verify PostgreSQL discovers the chained 0.1.0 -> 0.2.0 -> 0.3.0 -> 0.4.0 path.
BEGIN ISOLATION LEVEL REPEATABLE READ;
CREATE EXTENSION jev VERSION '0.1.0';
ALTER EXTENSION jev UPDATE TO '0.4.0';
CREATE TEMP TABLE upgrade_tree_input(k integer);
INSERT INTO upgrade_tree_input VALUES (1),(1),(NULL);
DO $$ DECLARE r record; BEGIN
    SELECT * INTO STRICT r FROM jev.reduce_join_tree(
        ARRAY['upgrade_tree_input'::regclass], ARRAY[]::jev.join_edge[]);
    ASSERT r.input_rows = 3 AND r.retained_rows = 3;
END $$;
ROLLBACK;
