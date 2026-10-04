#!/usr/bin/env python3
"""Paired optimization ablations in an owned database; deterministic providers only."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics

from run import ROOT, Sandbox, command, digest, extension_sql_path, nodes, populate, query_for

FLAGS = ['enable_batching', 'enable_deduplication', 'enable_result_cache',
         'enable_relational_prefilter', 'reuse_kernel_plan', 'enable_join_reduction',
         'enable_selective_fallback']
SCAN_CASES = [
    ('batching', 'enable_batching', 1, False, 1),
    ('deduplication', 'enable_deduplication', 8, False, 1),
    ('result_cache', 'enable_result_cache', 8, True, 1),
    ('relational_prefilter', 'enable_relational_prefilter', 1, False, 10),
    ('kernel_plan_reuse', 'reuse_kernel_plan', 1, False, 1),
]


def configure(session, flag, enabled):
    settings = {f: 'on' for f in FLAGS}
    # Isolate every ablation from cross-buffer cache reuse except its own case.
    settings['enable_result_cache'] = 'off'
    settings[flag] = 'on' if enabled else 'off'
    session.query('SET jev.enable_custom_scan=on; SET jev.force_custom_scan=on; '
                  'SET jev.auto_batch_size=off; SET jev.batch_size=128; '
                  'SET jev.batch_memory_kb=65536; SET jev.result_cache_kb=4096; ' +
                  '; '.join(f'SET jev.{k}={v}' for k, v in settings.items()))


def summarize(name, flag, records, validation, method, workload):
    modes = []
    for enabled in [False, True]:
        rows = [r for r in records if r['enabled'] == enabled]
        times = [r['execution_ms'] for r in rows]
        modes.append(dict(enabled=enabled, median_ms=statistics.median(times),
                          min_ms=min(times), max_ms=max(times), samples_ms=times,
                          work=rows[0]['work']))
        assert all(r['work'] == rows[0]['work'] for r in rows), name
    return dict(case=name, switch='jev.'+flag, methodology=method, workload=workload,
                validation=validation, results=modes,
                off_over_on=modes[0]['median_ms']/modes[1]['median_ms'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rows', type=int, default=8192)
    p.add_argument('--repeats', type=int, default=7)
    p.add_argument('--pg-config', default='pg_config')
    args = p.parse_args()
    if args.rows < 128 or args.repeats < 1:
        p.error('rows must be at least 128; repeats positive')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    libname = 'jev.dylib' if platform.system() == 'Darwin' else 'jev.so'
    lib = Path(command([args.pg_config, '--pkglibdir']))/libname
    sql = extension_sql_path()
    installed_sql = Path(command([args.pg_config, '--sharedir']))/'extension'/Path(sql).name
    assert digest(lib) == digest(ROOT/libname) and digest(installed_sql) == digest(ROOT/sql), 'install current build'
    paths = ['src/jev_planner.c',sql,'bench/run.py','bench/switch_compare.py']
    meta = dict(started_utc=datetime.now(timezone.utc).isoformat(),
                postgres=command([args.pg_config,'--version']),platform=platform.platform(),
                rows=args.rows,repeats=args.repeats,seed=20261005,
                providers='deterministic equality; fallback primary has synthetic confidence, no network/model',
                methodology='One switch changed at a time; warm full-result validation; randomized ON/OFF order each round. Scan/cascade EXPLAIN Execution Time; reduction server clock includes copies, passes, inference and final join, excludes transaction cleanup. Fixture creation excluded.',
                source_sha256={f:digest(ROOT/f) for f in paths},library_sha256=digest(lib))
    (out/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
    box = Sandbox(args,out)
    success = False
    summaries = []
    rng = random.Random(meta['seed'])
    try:
        s = box.start()
        with (out/'raw.jsonl').open('w') as raw:
            for name, flag, repeats, interleaved, select in SCAN_CASES:
                data = populate(s,dict(suite='kernel',duplicates=repeats,interleaved=interleaved,select_every=select),args.rows)
                expected = sorted(s.query(query_for('kernel','native',validation=True)).splitlines())
                validation = dict(rows=len(expected),sha256=hashlib.sha256(json.dumps(expected).encode()).hexdigest(),bags_equal=True)
                records=[]
                for enabled in [False, True]:
                    configure(s,flag,enabled)
                    assert sorted(s.query(query_for('kernel','batch_128',validation=True)).splitlines()) == expected, (name,enabled)
                for rep in range(args.repeats):
                    order=[False,True];rng.shuffle(order)
                    for enabled in order:
                        configure(s,flag,enabled)
                        plan=json.loads(s.query('EXPLAIN (ANALYZE,FORMAT JSON,TIMING OFF,BUFFERS ON) '+query_for('kernel','batch_128')))[0]
                        scan=next(n for n in nodes(plan) if n.get('Custom Plan Provider')=='JEVSemanticScan')
                        assert plan['Plan']['Actual Rows']==len(expected)
                        work={k:scan[k] for k in ['Candidate Rows','Kernel Inputs','Kernel Calls','Cache Hits','Batch Size']}
                        r=dict(case=name,enabled=enabled,repeat=rep+1,execution_ms=plan['Execution Time'],work=work,plan=plan)
                        records.append(r);raw.write(json.dumps(r)+'\n');raw.flush()
                summaries.append(summarize(name,flag,records,validation,'EXPLAIN Execution Time',data))
                print(name, summaries[-1]['off_over_on'],flush=True)

            # Synthetic confidence is used only to exercise the routing mechanism.
            s.query(f"""
CREATE FUNCTION public.ablation_primary(text[],text[],jsonb,jsonb) RETURNS jev.prediction[]
LANGUAGE sql STABLE AS $$ SELECT array_agg(ROW(l=r,CASE WHEN l::int%10=0 THEN 0.2 ELSE 0.99 END)::jev.prediction ORDER BY i)
 FROM unnest($1,$2) WITH ORDINALITY AS x(l,r,i) $$;
INSERT INTO jev.models(name,version,provider,score_kind) VALUES
 ('ablation-primary','1','public.ablation_primary(text[],text[],jsonb,jsonb)'::regprocedure,'decision_confidence');
INSERT INTO jev.predicates(name,version,model_name,fallback_model_name,min_confidence)
 VALUES ('ablation-cascade','1','ablation-primary','exact-v1',0.9);
CREATE TABLE ablation_inputs AS SELECT array_agg(ROW(i::text,i::text,i::text)::jev.candidate ORDER BY i) AS inputs FROM generate_series(1,{args.rows}) i;
""")
            cascade_query=f"SELECT e.* FROM ablation_inputs CROSS JOIN LATERAL jev.evaluate_batch('ablation-cascade',inputs,128) e"
            name='selective_fallback';flag='enable_selective_fallback';records=[];reference=None
            for enabled in [False,True]:
                configure(s,flag,enabled)
                result=s.query(f'SELECT row_to_json(e) FROM ({cascade_query}) e ORDER BY ordinal')
                if reference is None: reference=result
                assert result==reference, 'fallback output policy changed'
            for rep in range(args.repeats):
                order=[False,True];rng.shuffle(order)
                for enabled in order:
                    configure(s,flag,enabled)
                    plan=json.loads(s.query('EXPLAIN (ANALYZE,FORMAT JSON,TIMING OFF) '+cascade_query))[0]
                    assert plan['Plan']['Actual Rows']==args.rows
                    work=dict(primary_inputs=args.rows,expected_fallback_inputs=args.rows//10 if enabled else args.rows)
                    r=dict(case=name,enabled=enabled,repeat=rep+1,execution_ms=plan['Execution Time'],work=work,plan=plan)
                    records.append(r);raw.write(json.dumps(r)+'\n');raw.flush()
            summaries.append(summarize(name,flag,records,dict(rows=args.rows,sha256=hashlib.sha256(reference.encode()).hexdigest(),bags_equal=True),'EXPLAIN Execution Time',dict(rows=args.rows,synthetic_confidence=True)))

            s.query(f"""
CREATE TABLE ablation_a AS SELECT k FROM generate_series(1,{args.rows//10}) k CROSS JOIN generate_series(1,2) occurrence;
CREATE TABLE ablation_c AS SELECT k FROM generate_series(1,{args.rows//5}) k;
CREATE TABLE ablation_b AS SELECT k, CASE WHEN k%97=0 THEN NULL ELSE k::text END AS left_text,
 CASE WHEN k%4=0 THEN k::text ELSE 'other' END AS right_text FROM generate_series(1,{args.rows}) k;
CREATE FUNCTION pg_temp.join_trial() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE t timestamptz:=clock_timestamp(); rels regclass[]; kept bigint[]; n bigint; h text; inputs bigint;
BEGIN
 SELECT array_agg(reduced_relation ORDER BY node),array_agg(retained_rows ORDER BY node) INTO rels,kept
 FROM jev.reduce_join_tree(ARRAY['ablation_a','ablation_b','ablation_c']::regclass[],
 ARRAY[(1,ARRAY['k'],2,ARRAY['k'])::jev.join_edge,(2,ARRAY['k'],3,ARRAY['k'])::jev.join_edge],2);
 EXECUTE format('CREATE TEMP TABLE trial_inputs ON COMMIT DROP AS SELECT row_number() OVER ()::text AS row_id,b.* FROM %s b',rels[2]);
 CREATE TEMP TABLE trial_decisions ON COMMIT DROP AS SELECT * FROM jev.evaluate_relation('exact','trial_inputs',128);
 SELECT count(*) INTO inputs FROM trial_inputs WHERE left_text IS NOT NULL AND right_text IS NOT NULL;
 EXECUTE format('SELECT count(*),md5(string_agg(jsonb_build_array(a.k,b.k,c.k,b.left_text,b.right_text)::text,''|'' ORDER BY a.k,b.k,c.k,b.left_text,b.right_text)) FROM trial_inputs b JOIN trial_decisions d USING(row_id) JOIN %s a ON a.k=b.k JOIN %s c ON c.k=b.k WHERE d.decision',rels[1],rels[3]) INTO n,h;
 RETURN jsonb_build_object('execution_ms',extract(epoch FROM clock_timestamp()-t)*1000,'rows',n,'bag_md5',h,'retained_rows',kept,'provider_inputs',inputs);
END $$;
""")
            reference=json.loads(s.query("SELECT jsonb_build_object('rows',count(*),'bag_md5',md5(string_agg(jsonb_build_array(a.k,b.k,c.k,b.left_text,b.right_text)::text,'|' ORDER BY a.k,b.k,c.k,b.left_text,b.right_text))) FROM ablation_a a JOIN ablation_b b USING(k) JOIN ablation_c c USING(k) WHERE b.left_text COLLATE \"C\" = b.right_text COLLATE \"C\""))
            name='join_reduction';flag='enable_join_reduction';records=[]
            def join_trial(enabled):
                configure(s,flag,enabled)
                s.query('BEGIN ISOLATION LEVEL REPEATABLE READ')
                try: result=json.loads(s.query('SELECT pg_temp.join_trial()'))
                finally: s.query('ROLLBACK')
                assert all(result[k]==v for k,v in reference.items()), (name,enabled,result,reference)
                return result
            for enabled in [False,True]: join_trial(enabled)
            for rep in range(args.repeats):
                order=[False,True];rng.shuffle(order)
                for enabled in order:
                    result=join_trial(enabled)
                    r=dict(case=name,enabled=enabled,repeat=rep+1,execution_ms=float(result['execution_ms']),work={k:result[k] for k in ['retained_rows','provider_inputs']})
                    records.append(r);raw.write(json.dumps(r)+'\n');raw.flush()
            summaries.append(summarize(name,flag,records,dict(**reference,bags_equal=True),'Server elapsed time for copying/reduction/inference/final join',dict(semantic_source_rows=args.rows)))
        assert all(digest(ROOT/f)==v for f,v in meta['source_sha256'].items()), 'source changed'
        assert digest(lib)==digest(ROOT/libname)==meta['library_sha256'] and digest(installed_sql)==meta['source_sha256'][sql], 'build changed'
        meta.update(completed_utc=datetime.now(timezone.utc).isoformat(),source_and_build_unchanged=True)
        (out/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
        (out/'summary.json').write_text(json.dumps(summaries,indent=2)+'\n')
        print(json.dumps([{k:v for k,v in r.items() if k in ['case','off_over_on','results']} for r in summaries]),flush=True)
        success=True
    finally: box.close(success)


if __name__=='__main__': main()
