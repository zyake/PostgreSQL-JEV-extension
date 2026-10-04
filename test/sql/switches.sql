\set ON_ERROR_STOP on
BEGIN;
-- Explicit SQL calls work before LOAD; unset switch placeholders default to on.
CREATE FUNCTION pg_temp.switch_probe(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
    ASSERT cardinality($1) = ($4->>'count')::integer, 'unexpected provider input count';
    RETURN jev.exact_provider($1,$2,$3,$4);
END $$;
INSERT INTO jev.models(name,version,provider,config) VALUES
 ('switch-probe','1','pg_temp.switch_probe(text[],text[],jsonb,jsonb)'::regprocedure,'{"count":3}');
INSERT INTO jev.predicates(name,version,model_name) VALUES ('switch-probe','1','switch-probe');
CREATE TEMP TABLE switch_candidates AS SELECT ARRAY[
 ('dup','a','a')::jev.candidate,('dup','a','a')::jev.candidate,
 ('b','b','c')::jev.candidate,('null',NULL,'a')::jev.candidate,
 NULL::jev.candidate,(NULL,'d','d')::jev.candidate,('dup','a','a')::jev.candidate
] AS inputs;
CREATE TEMP TABLE switch_expected AS
SELECT e.* FROM switch_candidates CROSS JOIN LATERAL jev.evaluate_batch('switch-probe',inputs) e;
DO $$ BEGIN
 ASSERT (SELECT count(*)=7 AND count(decision)=5 AND count(*) FILTER(WHERE decision)=4 FROM switch_expected);
END $$;
SET LOCAL jev.enable_deduplication = off;
UPDATE jev.models SET config='{"count":5}' WHERE name='switch-probe';
DO $$ BEGIN
 ASSERT NOT EXISTS (
  (SELECT e.* FROM switch_candidates CROSS JOIN LATERAL jev.evaluate_batch('switch-probe',inputs) e EXCEPT ALL TABLE switch_expected)
  UNION ALL
  (TABLE switch_expected EXCEPT ALL SELECT e.* FROM switch_candidates CROSS JOIN LATERAL jev.evaluate_batch('switch-probe',inputs) e)
 ), 'dedup off changed occurrence mapping';
END $$;
SET LOCAL jev.enable_batching = off;
UPDATE jev.models SET config='{"count":1}' WHERE name='switch-probe';
DO $$ DECLARE a jev.candidate[]; i integer; result_count bigint; BEGIN
 a := array_fill(NULL::jev.candidate,ARRAY[7],ARRAY[-2]);
 FOR i IN 1..7 LOOP a[i-3] := (SELECT inputs[i] FROM switch_candidates); END LOOP;
 ASSERT NOT EXISTS (
  (SELECT * FROM jev.evaluate_batch('switch-probe',a) EXCEPT ALL TABLE switch_expected)
  UNION ALL (TABLE switch_expected EXCEPT ALL SELECT * FROM jev.evaluate_batch('switch-probe',a))
 ), 'batch off/lower array bound changed results';
 ASSERT (SELECT count(*)=0 FROM jev.evaluate_batch('switch-probe',ARRAY[]::jev.candidate[]));
END $$;
LOAD 'jev';
SET LOCAL jev.enable_batching = on;
SET LOCAL jev.enable_deduplication = on;

-- Nonselective fallback does extra work but keeps confident primary decisions.
CREATE FUNCTION pg_temp.switch_primary(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE sql STABLE AS $$
 SELECT array_agg(ROW(l <> 'low', CASE WHEN l='low' THEN 0.2 ELSE 0.99 END)::jev.prediction ORDER BY i)
 FROM unnest($1) WITH ORDINALITY AS x(l,i)
$$;
CREATE FUNCTION pg_temp.switch_fallback(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE plpgsql STABLE AS $$
BEGIN
 ASSERT cardinality($1)=($4->>'count')::integer, 'selective fallback did not change dispatched work';
 RETURN ARRAY(SELECT ROW(l='low',0.8)::jev.prediction FROM unnest($1) AS x(l));
END $$;
INSERT INTO jev.models(name,version,provider,config,score_kind) VALUES
 ('switch-primary','1','pg_temp.switch_primary(text[],text[],jsonb,jsonb)'::regprocedure,'{}','decision_confidence'),
 ('switch-fallback','1','pg_temp.switch_fallback(text[],text[],jsonb,jsonb)'::regprocedure,'{"count":1}','decision_confidence');
INSERT INTO jev.predicates(name,version,model_name,fallback_model_name,min_confidence)
 VALUES ('switch-cascade','1','switch-primary','switch-fallback',0.9);
CREATE TEMP TABLE switch_cascade_inputs AS SELECT ARRAY[
 ('h1','high1','x')::jev.candidate,('l','low','x')::jev.candidate,
 ('h2','high2','x')::jev.candidate,('n',NULL,'x')::jev.candidate] AS inputs;
CREATE TEMP TABLE switch_cascade_expected AS
 SELECT e.* FROM switch_cascade_inputs CROSS JOIN LATERAL jev.evaluate_batch('switch-cascade',inputs) e;
SET LOCAL jev.enable_selective_fallback = off;
UPDATE jev.models SET config='{"count":3}' WHERE name='switch-fallback';
DO $$ BEGIN
 ASSERT NOT EXISTS (
  (SELECT e.* FROM switch_cascade_inputs CROSS JOIN LATERAL jev.evaluate_batch('switch-cascade',inputs) e EXCEPT ALL TABLE switch_cascade_expected)
  UNION ALL (TABLE switch_cascade_expected EXCEPT ALL SELECT e.* FROM switch_cascade_inputs CROSS JOIN LATERAL jev.evaluate_batch('switch-cascade',inputs) e)
 ), 'nonselective fallback changed decision policy';
 ASSERT (SELECT count(*) FILTER(WHERE decision)=3 FROM switch_cascade_expected);
 ASSERT (SELECT confidence=0.99 FROM switch_cascade_expected WHERE row_id='h1');
END $$;
SET LOCAL jev.enable_selective_fallback = on;

CREATE TABLE public.switch_scan(id integer,l text,r text,active boolean);
INSERT INTO public.switch_scan VALUES
 (1,'a','a',true),(1,'a','a',true),(2,'b','c',true),(3,NULL,'a',true),
 (4,'a','a',true),(5,'a','a',false),(6,'b','c',false),(7,'d','d',NULL),
 (8,'d','d',true),(9,'d','d',true),(10,'d','d',true),(11,NULL,NULL,false);
SET LOCAL jev.enable_custom_scan=on;
SET LOCAL jev.force_custom_scan=on;
SET LOCAL jev.auto_batch_size=off;
SET LOCAL jev.batch_size=4;
SET LOCAL jev.result_cache_kb=4096;
CREATE TEMP TABLE switch_scan_expected AS
 SELECT id,l,r,ctid::text AS tid,tableoid::oid AS source_oid FROM ONLY public.switch_scan
 WHERE active AND l COLLATE "C" = r COLLATE "C";
CREATE FUNCTION pg_temp.switch_plan(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE p jsonb; BEGIN
 EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, COSTS OFF, TIMING OFF) '||statement INTO p;
 RETURN jsonb_path_query_first(p,'$.** ? (@."Custom Plan Provider" == "JEVSemanticScan")');
END $$;
-- All combinations of the five executor switches preserve complete row bags.
DO $$ DECLARE mask integer; p jsonb; BEGIN
 FOR mask IN 0..31 LOOP
  PERFORM set_config('jev.enable_batching',((mask&1)<>0)::text,true);
  PERFORM set_config('jev.enable_deduplication',((mask&2)<>0)::text,true);
  PERFORM set_config('jev.enable_result_cache',((mask&4)<>0)::text,true);
  PERFORM set_config('jev.enable_relational_prefilter',((mask&8)<>0)::text,true);
  PERFORM set_config('jev.reuse_kernel_plan',((mask&16)<>0)::text,true);
  ASSERT NOT EXISTS (
   (SELECT id,l,r,ctid::text,tableoid::oid FROM ONLY public.switch_scan WHERE active AND jev.semantic_match('exact',l,r)
    EXCEPT ALL TABLE switch_scan_expected)
   UNION ALL (TABLE switch_scan_expected EXCEPT ALL
    SELECT id,l,r,ctid::text,tableoid::oid FROM ONLY public.switch_scan WHERE active AND jev.semantic_match('exact',l,r))
  ), 'executor switch combination changed bag';
  p:=pg_temp.switch_plan($q$SELECT id FROM ONLY public.switch_scan WHERE active AND jev.semantic_match('exact',l,r)$q$);
  ASSERT p IS NOT NULL;
  ASSERT (p->>'Actual Rows')::integer=6;
  ASSERT (p->>'Candidate Rows')::integer=CASE WHEN (mask&8)<>0 THEN 8 ELSE 12 END;
  ASSERT (p->>'Batch Size')::integer=CASE WHEN (mask&1)<>0 THEN 4 ELSE 1 END;
  IF (mask&4)=0 THEN ASSERT (p->>'Cache Allocated Bytes')::integer=0; END IF;
  IF (mask&1)<>0 AND (mask&2)=0 AND (mask&4)=0 THEN
   ASSERT (p->>'Kernel Inputs')::integer=CASE WHEN (mask&8)<>0 THEN 7 ELSE 10 END;
  END IF;
 END LOOP;
END $$;
SET LOCAL jev.enable_batching=on;
SET LOCAL jev.enable_deduplication=on;
SET LOCAL jev.enable_result_cache=on;
SET LOCAL jev.enable_relational_prefilter=on;
SET LOCAL jev.reuse_kernel_plan=on;
-- Changes during an open cursor are rejected rather than mixing SQL/C settings.
DECLARE switch_cursor CURSOR FOR SELECT id FROM ONLY public.switch_scan WHERE active AND jev.semantic_match('exact',l,r);
FETCH 1 FROM switch_cursor;
SET LOCAL jev.enable_deduplication=off;
DO $$ DECLARE failed boolean:=false; BEGIN
 BEGIN EXECUTE 'FETCH 1 FROM switch_cursor'; EXCEPTION WHEN object_not_in_prerequisite_state THEN failed:=true; END;
 ASSERT failed, 'feature change during cursor was silently accepted';
END $$;
CLOSE switch_cursor;
ROLLBACK;

BEGIN ISOLATION LEVEL REPEATABLE READ;
CREATE TEMP TABLE switch_a(k integer);
CREATE TEMP TABLE switch_b(k integer,l text,r text);
INSERT INTO switch_a VALUES(1),(1),(NULL),(2);
INSERT INTO switch_b VALUES(1,'a','a'),(1,'a','a'),(NULL,'b','b'),(3,'c','c');
CREATE TEMP TABLE switch_baseline AS SELECT a.k,b.l,b.r FROM switch_a a JOIN switch_b b USING(k);
DO $$ DECLARE enabled boolean; rels regclass[]; counts bigint[]; differs boolean; BEGIN
 FOREACH enabled IN ARRAY ARRAY[true,false] LOOP
  PERFORM set_config('jev.enable_join_reduction',enabled::text,true);
  SELECT array_agg(reduced_relation ORDER BY node),array_agg(retained_rows ORDER BY node)
   INTO rels,counts FROM jev.reduce_join_tree(ARRAY['switch_a','switch_b']::regclass[],ARRAY[(1,ARRAY['k'],2,ARRAY['k'])::jev.join_edge]);
  ASSERT counts=CASE WHEN enabled THEN ARRAY[2,2]::bigint[] ELSE ARRAY[4,4]::bigint[] END;
  EXECUTE format('SELECT EXISTS ((SELECT a.k,b.l,b.r FROM %s a JOIN %s b USING(k) EXCEPT ALL TABLE switch_baseline) UNION ALL (TABLE switch_baseline EXCEPT ALL SELECT a.k,b.l,b.r FROM %s a JOIN %s b USING(k)))',rels[1],rels[2],rels[1],rels[2]) INTO differs;
  ASSERT NOT differs,'reduction switch changed final join bag';
 END LOOP;
 ASSERT (SELECT count(*)=4 FROM switch_a) AND (SELECT count(*)=4 FROM switch_b);
END $$;
ROLLBACK;
\echo 'optimization switch assertions passed'
