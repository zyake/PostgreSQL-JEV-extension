#!/usr/bin/env python3
"""Measure every combination of the seven JEV switches on one combined workflow.

An owned temporary database only; deterministic providers, no external inference.
Every warmup and measured trial verifies full bag equality outside its timer.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import random
import statistics
import time

from run import ROOT, Sandbox, command, digest, extension_sql_path, nodes
from switch_compare import FLAGS

EXPLAIN_FLAGS = {
    'enable_batching': 'Batching Enabled',
    'enable_deduplication': 'Input Deduplication',
    'enable_result_cache': 'Result Cache Enabled',
    'enable_relational_prefilter': 'Relational Prefilter',
    'reuse_kernel_plan': 'Reuse Kernel Plan',
    'enable_selective_fallback': 'Selective Fallback',
}


def settings(mask):
    return {flag: bool(mask & (1 << i)) for i, flag in enumerate(FLAGS)}


def configure(session, mask):
    session.query('; '.join(f"SET jev.{k}={'on' if v else 'off'}" for k, v in settings(mask).items()))


def setup(session, rows):
    session.query(f"""
SET jev.enable_custom_scan=on;
SET jev.force_custom_scan=on;
SET jev.auto_batch_size=off;
SET jev.batch_size=128;
SET jev.batch_memory_kb=65536;
SET jev.result_cache_kb=4096;
CREATE TABLE factorial_a(a_id text,join_key integer);
INSERT INTO factorial_a VALUES ('a1',1),('a1',1),(NULL,2),('a3',3),('an',NULL);
CREATE TABLE factorial_c(c_id text,join_key integer);
INSERT INTO factorial_c VALUES ('c1',1),('c2',2),('c2',2),('c4',4),('cn',NULL);
CREATE TABLE factorial_b AS
SELECT CASE WHEN k%17=0 THEN NULL ELSE (k%23)::text END AS b_id,
       CASE WHEN i%509=0 THEN NULL ELSE 1+((i-1)/64)%4 END AS join_key,
       k%4<2 AS active,
       CASE WHEN i%97=0 THEN NULL ELSE k::text||':'||repeat('input text ',12) END AS left_text,
       CASE WHEN k%3=0 THEN k::text||':'||repeat('input text ',12) ELSE 'other:'||k END AS right_text
FROM (SELECT i,((i-1)/4)%256 AS k FROM generate_series(1,{rows}) i) input
ORDER BY i;
ANALYZE factorial_a; ANALYZE factorial_b; ANALYZE factorial_c;
CREATE FUNCTION public.factorial_primary(text[],text[],jsonb,jsonb)
RETURNS jev.prediction[] LANGUAGE sql STABLE AS $$
SELECT array_agg(ROW(l COLLATE "C"=r COLLATE "C",
    CASE WHEN split_part(l,':',1)::integer%10=0 THEN 0.2 ELSE 0.99 END)::jev.prediction ORDER BY i)
FROM unnest($1,$2) WITH ORDINALITY AS inputs(l,r,i)
$$;
INSERT INTO jev.models(name,version,provider,score_kind) VALUES
 ('factorial-primary','1','public.factorial_primary(text[],text[],jsonb,jsonb)'::regprocedure,'decision_confidence');
INSERT INTO jev.predicates(name,version,model_name,fallback_model_name,min_confidence)
 VALUES ('factorial-cascade','1','factorial-primary','exact-v1',0.9);
CREATE TABLE factorial_reference AS
SELECT a.a_id,b.b_id,c.c_id,b.join_key,b.left_text,b.right_text
FROM factorial_a a JOIN factorial_b b USING(join_key) JOIN factorial_c c USING(join_key)
WHERE b.active AND b.left_text COLLATE "C"=b.right_text COLLATE "C";
CREATE FUNCTION pg_temp.factorial_trial() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE started timestamptz:=clock_timestamp(); after_reduce timestamptz;
        after_semantic timestamptz; finished timestamptz;
        rels regclass[]; kept bigint[]; original bigint[]; plan jsonb;
        actual_rows bigint; differs boolean;
BEGIN
 SELECT array_agg(reduced_relation ORDER BY node),array_agg(retained_rows ORDER BY node),
        array_agg(input_rows ORDER BY node)
 INTO rels,kept,original
 FROM jev.reduce_join_tree(ARRAY['factorial_a','factorial_b','factorial_c']::regclass[],
 ARRAY[(1,ARRAY['join_key'],2,ARRAY['join_key'])::jev.join_edge,
       (2,ARRAY['join_key'],3,ARRAY['join_key'])::jev.join_edge],2);
 after_reduce:=clock_timestamp();
 EXECUTE format('EXPLAIN (ANALYZE,FORMAT JSON,TIMING OFF,BUFFERS ON) CREATE TEMP TABLE factorial_matches ON COMMIT DROP AS SELECT * FROM ONLY %s WHERE active AND jev.semantic_match(''factorial-cascade'',left_text,right_text)',rels[2]) INTO plan;
 after_semantic:=clock_timestamp();
 EXECUTE format('CREATE TEMP TABLE factorial_result ON COMMIT DROP AS SELECT a.a_id,b.b_id,c.c_id,b.join_key,b.left_text,b.right_text FROM factorial_matches b JOIN %s a USING(join_key) JOIN %s c USING(join_key)',rels[1],rels[3]);
 finished:=clock_timestamp();
 -- Complete duplicate-preserving verification is outside the timed region.
 SELECT EXISTS ((TABLE factorial_result EXCEPT ALL TABLE factorial_reference)
      UNION ALL (TABLE factorial_reference EXCEPT ALL TABLE factorial_result)) INTO differs;
 IF differs THEN RAISE EXCEPTION 'optimization combination changed the result bag'; END IF;
 SELECT count(*) INTO actual_rows FROM factorial_result;
 RETURN jsonb_build_object('execution_ms',extract(epoch FROM finished-started)*1000,
    'stage_ms',jsonb_build_object('reduction',extract(epoch FROM after_reduce-started)*1000,
       'semantic',extract(epoch FROM after_semantic-after_reduce)*1000,
       'join',extract(epoch FROM finished-after_semantic)*1000),
    'retained_rows',kept,'input_rows',original,'result_rows',actual_rows,
    'full_bag_equal',NOT differs,'semantic_plan',plan);
END $$;
""")
    return json.loads(session.query("""
SELECT jsonb_build_object('source_rows',(SELECT count(*) FROM factorial_b),
 'active_rows',(SELECT count(*) FROM factorial_b WHERE active),
 'nonnull_rows',(SELECT count(*) FROM factorial_b WHERE left_text IS NOT NULL AND right_text IS NOT NULL),
 'distinct_pairs',(SELECT count(DISTINCT (left_text COLLATE "C",right_text COLLATE "C")) FROM factorial_b WHERE left_text IS NOT NULL AND right_text IS NOT NULL),
 'relationally_supported_b_rows',(SELECT count(*) FROM factorial_b b WHERE EXISTS(SELECT FROM factorial_a a WHERE a.join_key=b.join_key) AND EXISTS(SELECT FROM factorial_c c WHERE c.join_key=b.join_key)),
 'result_rows',(SELECT count(*) FROM factorial_reference))
"""))


def vacuum_catalogs(session):
    # The trial rolls back private tables; reclaim catalog churn between rounds.
    # These are only the disposable cluster's catalogs, never a user's database.
    for name in ['pg_class', 'pg_attribute', 'pg_type', 'pg_depend', 'pg_statistic']:
        session.query(f'VACUUM (ANALYZE) pg_catalog.{name}')


def trial(session, mask, data):
    configure(session, mask)
    session.query('BEGIN ISOLATION LEVEL REPEATABLE READ')
    try:
        result = json.loads(session.query('SELECT pg_temp.factorial_trial()'))
    finally:
        session.query('ROLLBACK')
    assert result['full_bag_equal'] and result['result_rows'] == data['result_rows']
    scans = [n for n in nodes(result['semantic_plan']) if n.get('Custom Plan Provider') == 'JEVSemanticScan']
    assert len(scans) == 1 and scans[0]['Semantic Evaluation'] == 'batched', 'custom scan missing'
    scan = scans[0]
    mode = settings(mask)
    for flag, field in EXPLAIN_FLAGS.items():
        assert scan[field] == mode[flag], (mask, field, scan[field])
    assert scan['Batch Size'] == (128 if mode['enable_batching'] else 1)
    assert result['retained_rows'][1] == (data['relationally_supported_b_rows'] if mode['enable_join_reduction'] else data['source_rows'])
    if not mode['enable_result_cache']:
        assert scan['Cache Hits'] == scan['Cache Allocated Bytes'] == 0
    result['work'] = {k:scan[k] for k in ['Candidate Rows','Kernel Inputs','Kernel Calls','Cache Hits','Batch Size']}
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rows', type=int, default=8192)
    p.add_argument('--repeats', type=int, default=7)
    p.add_argument('--pg-config', default='pg_config')
    args = p.parse_args()
    if args.rows < 256 or args.repeats < 1:
        p.error('rows must be at least 256, repeats positive')
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    libname='jev.dylib' if platform.system()=='Darwin' else 'jev.so'
    library=Path(command([args.pg_config,'--pkglibdir']))/libname
    sql=extension_sql_path()
    installed_sql=Path(command([args.pg_config,'--sharedir']))/'extension'/Path(sql).name
    assert digest(library)==digest(ROOT/libname) and digest(installed_sql)==digest(ROOT/sql), 'install current build'
    source_paths=['src/jev_planner.c',sql,'bench/run.py','bench/switch_compare.py','bench/factorial_compare.py']
    metadata=dict(started_utc=datetime.now(timezone.utc).isoformat(),
        postgres=command([args.pg_config,'--version']),platform=platform.platform(),
        flags=FLAGS,mask_convention='bit i is flags[i]; printed bits are low bit first',
        rows=args.rows,repeats=args.repeats,combinations=128,seed=20261004,
        provider='Deterministic equality, synthetic confidence (0.2 for pair key divisible by 10, otherwise 0.99); exact fallback. No network or real model.',
        fixed_settings=dict(force_custom_scan=True,auto_batch_size=False,batch_size=128,batch_memory_kb=65536,result_cache_kb=4096),
        methodology='One common three-table workflow for all128 masks. One warmup per mask, seven/default shuffled complete rounds. Server clock includes copies/ANALYZE/reduction, semantic EXPLAIN ANALYZE CTAS (TIMING OFF), and final join CTAS; excludes settings, transaction begin/rollback, fixture creation and full EXCEPT ALL verification. All-off still uses custom executor/private copies. Catalog vacuum between rounds outside timing.',
        source_sha256={f:digest(ROOT/f) for f in source_paths},library_sha256=digest(library))
    (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    box=Sandbox(args,out);success=False;rng=random.Random(metadata['seed']);records=[]
    started=time.monotonic()
    try:
        s=box.start()
        data=setup(s,args.rows);metadata['workload']=data
        print('Workload: '+json.dumps(data),flush=True)
        warm=list(range(128));rng.shuffle(warm)
        with (out/'warmup.jsonl').open('w') as log:
            for position,mask in enumerate(warm):
                r=trial(s,mask,data);log.write(json.dumps(dict(mask=mask,position=position,**r))+'\n');log.flush()
                if (position+1)%32==0: print(f'Warmup {position+1}/128; {time.monotonic()-started:.1f}s elapsed',flush=True)
        with (out/'raw.jsonl').open('w') as log:
            for repeat in range(args.repeats):
                vacuum_catalogs(s)
                order=list(range(128));rng.shuffle(order)
                for position,mask in enumerate(order):
                    r=trial(s,mask,data)
                    record=dict(mask=mask,repeat=repeat+1,position=position,**r)
                    records.append(record);log.write(json.dumps(record)+'\n');log.flush()
                    if (position+1)%32==0: print(f'Round {repeat+1}/{args.repeats}: {position+1}/128; {time.monotonic()-started:.1f}s elapsed',flush=True)
        summary=[]
        for mask in range(128):
            rows=[r for r in records if r['mask']==mask]
            assert len(rows)==args.repeats
            times=[float(r['execution_ms']) for r in rows]
            assert all(r['work']==rows[0]['work'] for r in rows), ('work counters varied',mask)
            summary.append(dict(mask=mask,bits=''.join('1' if settings(mask)[f] else '0' for f in FLAGS),settings=settings(mask),
                median_ms=statistics.median(times),min_ms=min(times),max_ms=max(times),samples_ms=times,
                median_stage_ms={k:statistics.median(float(r['stage_ms'][k]) for r in rows) for k in ['reduction','semantic','join']},
                work=rows[0]['work'],retained_rows=rows[0]['retained_rows'],result_rows=data['result_rows']))
        assert all(digest(ROOT/f)==h for f,h in metadata['source_sha256'].items()), 'source changed'
        assert digest(library)==digest(ROOT/libname)==metadata['library_sha256'] and digest(installed_sql)==metadata['source_sha256'][sql], 'build changed'
        metadata.update(completed_utc=datetime.now(timezone.utc).isoformat(),source_and_build_unchanged=True,
                        measured_trials=len(records),warmup_trials=128,full_bag_validations=len(records)+128)
        (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
        print('Complete: '+json.dumps(dict(measured=len(records),all_off_ms=summary[0]['median_ms'],all_on_ms=summary[127]['median_ms'],fastest=min(summary,key=lambda r:r['median_ms']))),flush=True)
        success=True
    finally:box.close(success)


if __name__=='__main__':main()
