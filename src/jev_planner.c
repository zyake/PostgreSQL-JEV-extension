/*
 * jev_planner.c
 *
 * Narrow planner integration and bounded semantic filter batching.  Complex
 * predicates retain scalar ExecScan evaluation.  The heap AM supplies ordinary
 * MVCC-visible tuples; copied tuples preserve occurrences and system columns.
 *
 * Supported API: PostgreSQL 17.  Custom-scan interfaces are major-version APIs.
 */
#include "postgres.h"

#include <math.h>

#include "access/tableam.h"
#include "access/htup_details.h"
#include "catalog/dependency.h"
#include "catalog/namespace.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_class.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type_d.h"
#include "catalog/pg_type.h"
#include "common/hashfn.h"
#include "commands/extension.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/extensible.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/cost.h"
#include "optimizer/pathnode.h"
#include "optimizer/optimizer.h"
#include "optimizer/paths.h"
#include "optimizer/plancat.h"
#include "optimizer/restrictinfo.h"
#include "utils/builtins.h"
#include "utils/array.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/syscache.h"
#include "utils/typcache.h"
#include "portability/instr_time.h"

PG_MODULE_MAGIC;

PGDLLEXPORT void _PG_init(void);
PGDLLEXPORT void _PG_fini(void);

static bool jev_enable_custom_scan = false;
static bool jev_force_custom_scan = false;
static bool jev_auto_batch_size = false;
static bool jev_enable_batching = true;
static bool jev_enable_deduplication = true;
static bool jev_enable_result_cache = true;
static bool jev_enable_relational_prefilter = true;
static bool jev_reuse_kernel_plan = true;
static bool jev_enable_join_reduction = true;
static bool jev_enable_selective_fallback = true;
static int jev_batch_size = 128;
static int jev_batch_memory_kb = 1024;
static int jev_result_cache_kb = 4096;
static double jev_batch_call_cost = 100.0;
static double jev_batch_input_cost = 10.0;
static set_rel_pathlist_hook_type previous_set_rel_pathlist_hook = NULL;

/* Serializable plan-time estimates: never retain planner-owned pointers. */
enum JevPlanInfo
{
	JEV_BATCHED,
	JEV_EST_CANDIDATES,
	JEV_EST_SELECTIVITY,
	JEV_EST_BATCH_ROWS,
	JEV_EST_CALLS,
	JEV_EST_ROW_BYTES,
	JEV_EST_WORK_COST,
	JEV_SCALAR_COST,
	JEV_PLAN_BATCH_SIZE,
	JEV_PLAN_MEMORY_KB,
	JEV_PLAN_CALL_COST,
	JEV_PLAN_INPUT_COST,
	JEV_PLAN_FORCED,
	JEV_PLAN_AUTO_BATCH,
	JEV_PLAN_BATCH_LIMIT
};

typedef struct JevPairKey
{
	text *left;
	text *right;
} JevPairKey;

typedef struct JevBatchPair
{
	JevPairKey key;
	int miss_index;
	bool cached;
	bool decision;
} JevBatchPair;

/* Keys and bucket links live inside one explicitly bounded byte arena. */
typedef struct JevResultEntry
{
	struct JevResultEntry *next;
	uint32 hash;
	uint32 left_size;
	uint32 right_size;
	bool decision;
	char data[FLEXIBLE_ARRAY_MEMBER];
} JevResultEntry;

typedef struct JevScanState
{
	CustomScanState css;
	bool batched;
	bool exhausted;
	bool enable_batching;
	bool enable_deduplication;
	bool enable_result_cache;
	bool enable_relational_prefilter;
	bool reuse_kernel_plan;
	bool enable_selective_fallback;
	Oid execution_user;
	int batch_size;
	Size memory_target;
	MemoryContext batch_context;
	TupleTableSlot *input_slot;
	ExprState *relational_qual;
	ExprState *left_expr;
	ExprState *right_expr;
	Datum predicate_name;
	Oid candidate_type;
	TupleDesc candidate_desc;
	HeapTuple *tuples;
	Datum *candidates;
	bool *matches;
	int *result_map;
	JevPairKey *miss_keys;
	bool *miss_matches;
	int miss_count;
	int count;
	int position;
	Size cache_budget;
	Size cache_used;
	char *cache_arena;
	JevResultEntry **cache_buckets;
	uint32 cache_bucket_count;
	uint64 cache_entries;
	uint64 cache_hits;
	uint64 cache_admission_skips;
	SPIPlanPtr kernel_plan;
	MemoryContextCallback plan_cleanup;
	uint64 rows_read;
	uint64 candidate_rows;
	uint64 unique_inputs;
	uint64 reused_inputs;
	uint64 provider_calls;
	uint64 batches;
	uint64 peak_rows;
	uint64 peak_bytes;
	uint64 evaluated_match_rows;
	double kernel_ms;
} JevScanState;

static void jev_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel,
								Index rti, RangeTblEntry *rte);
static Plan *jev_plan_custom_path(PlannerInfo *root, RelOptInfo *rel,
								 CustomPath *best_path, List *tlist,
								 List *clauses, List *custom_plans);
static Node *jev_create_scan_state(CustomScan *scan);
static void jev_begin_scan(CustomScanState *node, EState *estate, int eflags);
static TupleTableSlot *jev_exec_scan(CustomScanState *node);
static void jev_end_scan(CustomScanState *node);
static void jev_rescan(CustomScanState *node);
static void jev_explain_scan(CustomScanState *node, List *ancestors,
							 ExplainState *es);
static void jev_free_kernel_plan(void *argument);

static bool
jev_check_cost(double *newval, void **extra, GucSource source)
{
	if (!isfinite(*newval))
	{
		GUC_check_errdetail("JEV cost estimates must be finite.");
		return false;
	}
	return true;
}

static const CustomPathMethods jev_path_methods = {
	.CustomName = "JEVSemanticScan",
	.PlanCustomPath = jev_plan_custom_path
};

static const CustomScanMethods jev_scan_methods = {
	.CustomName = "JEVSemanticScan",
	.CreateCustomScanState = jev_create_scan_state
};

static const CustomExecMethods jev_exec_methods = {
	.CustomName = "JEVSemanticScan",
	.BeginCustomScan = jev_begin_scan,
	.ExecCustomScan = jev_exec_scan,
	.EndCustomScan = jev_end_scan,
	.ReScanCustomScan = jev_rescan,
	.ExplainCustomScan = jev_explain_scan
};

void
_PG_init(void)
{
	DefineCustomBoolVariable("jev.enable_custom_scan",
							 "Offer the experimental JEV semantic scan path.",
							 "Only simple single-table SELECT queries are eligible.",
							 &jev_enable_custom_scan, false,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.force_custom_scan",
							 "Route eligible queries through JEV for tests and demos.",
							 "Requires jev.enable_custom_scan; replaces eligible "
							 "access paths without claiming a cost improvement.",
							 &jev_force_custom_scan, false,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.enable_batching",
							 "Evaluate multiple inputs in one kernel/provider call.",
							 "When disabled, semantic scans and explicit APIs use batches of one.",
							 &jev_enable_batching, true,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.enable_deduplication",
							 "Deduplicate identical input pairs within each batch.",
							 "Result caching is controlled independently.",
							 &jev_enable_deduplication, true,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.enable_result_cache",
							 "Reuse decisions across buffers in one semantic scan.",
							 "When disabled, no result-cache arena is allocated.",
							 &jev_enable_result_cache, true,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.enable_relational_prefilter",
							 "Apply ordinary immutable scan filters before semantic inference.",
							 "When disabled, those filters run after semantic decisions.",
							 &jev_enable_relational_prefilter, true,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.reuse_kernel_plan",
							 "Retain one SPI kernel plan for each semantic scan.",
							 "When disabled, each kernel dispatch is parsed and planned again.",
							 &jev_reuse_kernel_plan, true,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.enable_join_reduction",
							 "Apply exact semijoin reduction in reduce_join_tree.",
							 "When disabled, the explicit API copies the source relations without reduction.",
							 &jev_enable_join_reduction, true,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.enable_selective_fallback",
							 "Send only uncertain primary decisions to a configured fallback.",
							 "When disabled, evaluate fallback for all inputs while retaining the decision policy.",
							 &jev_enable_selective_fallback, true,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomIntVariable("jev.batch_size",
							"Maximum candidate occurrences in one semantic scan batch.",
							NULL, &jev_batch_size, 128, 1, 65536,
							PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("jev.auto_batch_size",
							 "Offer alternative batch sizes to the PostgreSQL planner.",
							 "Requires jev.enable_custom_scan; jev.batch_size remains "
							 "the maximum. Forced custom scans retain the fixed size.",
							 &jev_auto_batch_size, false,
							 PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomIntVariable("jev.batch_memory_kb",
							"Soft byte target for buffered tuples and semantic inputs.",
							"A batch stops after crossing this target; a single wide "
							"row may exceed it. Provider and SQL workspace are additional.",
							&jev_batch_memory_kb, 1024, 1, 1048576,
							PGC_USERSET, GUC_UNIT_KB, NULL, NULL, NULL);
	DefineCustomIntVariable("jev.result_cache_kb",
							"Maximum retained result-cache arena per semantic scan.",
							"Zero disables reuse across buffers. Oversized entries and "
							"entries that do not fit are evaluated without admission.",
							&jev_result_cache_kb, 4096, 0, 1048575,
							PGC_USERSET, GUC_UNIT_KB, NULL, NULL, NULL);
	DefineCustomRealVariable("jev.batch_call_cost",
							 "Estimated fixed cost of one batch kernel call.",
							 "In cpu_operator_cost units, like SQL function COST; "
							 "a heuristic, not milliseconds or measured model latency.",
							 &jev_batch_call_cost, 100.0, 0.0, 1e10,
							 PGC_USERSET, 0, jev_check_cost, NULL, NULL);
	DefineCustomRealVariable("jev.batch_input_cost",
							 "Estimated kernel/provider work per input pair in a batch.",
							 "In cpu_operator_cost units; includes expected fallback "
							 "work, excludes buffering and assumes no result reuse.",
							 &jev_batch_input_cost, 10.0, 0.0, 1e10,
							 PGC_USERSET, 0, jev_check_cost, NULL, NULL);

	RegisterCustomScanMethods(&jev_scan_methods);
	previous_set_rel_pathlist_hook = set_rel_pathlist_hook;
	set_rel_pathlist_hook = jev_set_rel_pathlist;
}

void
_PG_fini(void)
{
	/* Do not overwrite a hook installed after ours. */
	if (set_rel_pathlist_hook == jev_set_rel_pathlist)
		set_rel_pathlist_hook = previous_set_rel_pathlist_hook;
}

/*
 * Resolve on each planning invocation: never retain an OID across DROP/CREATE.
 * Both the qualified signature and extension membership must agree.  A
 * same-named user function, or a function attached to another schema, is not
 * a semantic marker recognized by this extension.
 */
static Oid
jev_semantic_match_oid(void)
{
	Oid			argument_types[3] = {TEXTOID, TEXTOID, TEXTOID};
	Oid			extension_oid = get_extension_oid("jev", true);
	Oid			namespace_oid;
	Oid			function_oid;
	oidvector  *signature;

	if (!OidIsValid(extension_oid))
		return InvalidOid;

	/*
	 * Catalog identity lookup must not require schema USAGE: this hook also
	 * runs for queries which never call JEV.  The parser/executor check access
	 * to an actual semantic_match call in the ordinary PostgreSQL manner.
	 */
	namespace_oid = get_namespace_oid("jev", true);
	if (!OidIsValid(namespace_oid))
		return InvalidOid;
	signature = buildoidvector(argument_types, lengthof(argument_types));
	function_oid = GetSysCacheOid3(PROCNAMEARGSNSP, Anum_pg_proc_oid,
									CStringGetDatum("semantic_match"),
									PointerGetDatum(signature),
									ObjectIdGetDatum(namespace_oid));
	pfree(signature);
	if (!OidIsValid(function_oid) ||
		getExtensionOfObject(ProcedureRelationId, function_oid) != extension_oid ||
		get_func_rettype(function_oid) != BOOLOID)
		return InvalidOid;

	return function_oid;
}

static bool
jev_contains_semantic_match(Node *node, void *context)
{
	Oid			function_oid = *((Oid *) context);

	if (node == NULL)
		return false;
	if (IsA(node, FuncExpr) &&
		((FuncExpr *) node)->funcid == function_oid)
		return true;

	return expression_tree_walker(node, jev_contains_semantic_match, context);
}

/* Only a positive conjunct with inert operands can move into the batcher. */
static FuncExpr *
jev_batch_marker(List *quals, Node *target, Oid function_oid, Index scanrelid)
{
	FuncExpr *marker = NULL;
	ListCell *cell;

	if (contain_volatile_functions(target) ||
		jev_contains_semantic_match(target, &function_oid) ||
		func_volatile(function_oid) != PROVOLATILE_STABLE ||
		!func_strict(function_oid))
		return NULL;

	foreach(cell, quals)
	{
		Node *qual = lfirst(cell);

		if (IsA(qual, FuncExpr) &&
			((FuncExpr *) qual)->funcid == function_oid)
		{
			FuncExpr *candidate = (FuncExpr *) qual;
			ListCell *argcell;
			Const *predicate;

			if (marker != NULL || list_length(candidate->args) != 3)
				return NULL;
			if (!IsA(linitial(candidate->args), Const))
				return NULL;
			predicate = linitial_node(Const, candidate->args);
			if (predicate->consttype != TEXTOID || predicate->constisnull)
				return NULL;
			foreach(argcell, candidate->args)
			{
				Node *arg = lfirst(argcell);

				if (exprType(arg) != TEXTOID ||
					(!IsA(arg, Var) && !IsA(arg, Const)))
					return NULL;
				if (IsA(arg, Var) &&
					(((Var *) arg)->varno != scanrelid ||
					 ((Var *) arg)->varlevelsup != 0 ||
					 ((Var *) arg)->varattno <= 0))
					return NULL;
			}
			marker = candidate;
		}
		else if (contain_mutable_functions(qual) ||
				 jev_contains_semantic_match(qual, &function_oid))
			return NULL;
	}
	return marker;
}

static double
jev_operand_width(Node *operand, Oid relation_oid)
{
	if (IsA(operand, Const))
	{
		Const *value = (Const *) operand;

		return value->constisnull ? 0 :
			(double) VARSIZE_ANY(DatumGetPointer(value->constvalue));
	}
	else
	{
		Var *var = (Var *) operand;
		int32 width = get_attavgwidth(relation_oid, var->varattno);

		return width > 0 ? width : get_typavgwidth(TEXTOID, var->vartypmod);
	}
}

static List *
jev_append_estimate(List *values, double value)
{
	return lappend(values, makeFloat(psprintf("%.17g", value)));
}

/*
 * Cost only the execution strategy we actually implement: a serial heap scan,
 * ordinary immutable quals before or after bounded semantic batches.
 * PostgreSQL still estimates output cardinality for every competing path. No provider or JEV
 * metadata is consulted, and no speculative NULL/dedup/cache saving is priced.
 */
static void
jev_cost_batch_path(CustomPath *custom, PlannerInfo *root, RelOptInfo *rel,
					RangeTblEntry *rte, FuncExpr *marker, Path *scalar_path,
					int path_batch_size, bool automatic)
{
	RelOptInfo heap_rel = *rel;
	Path heap_path = {0};
	List *ordinary = NIL;
	List *info = list_make1(makeInteger(true));
	ListCell *cell;
	double candidates;
	double selectivity;
	double pair_bytes;
	double row_bytes;
	double batch_rows;
	double calls;
	double first_rows;
	double first_fraction;
	Cost per_row;
	Cost per_call = jev_batch_call_cost * cpu_operator_cost;
	Cost batch_work;
	Cost heap_run;

	foreach(cell, rel->baserestrictinfo)
	{
		RestrictInfo *restriction = lfirst_node(RestrictInfo, cell);

		if (!equal(restriction->clause, marker))
			ordinary = lappend(ordinary, restriction);
	}
	candidates = rel->tuples;
	if (jev_enable_relational_prefilter)
		candidates *= clauselist_selectivity(root, ordinary,
											 rel->relid, JOIN_INNER, NULL);
	selectivity = clause_selectivity(root, (Node *) marker,
									rel->relid, JOIN_INNER, NULL);

	/* Re-cost a local copy, keeping native paths and relation estimates intact.
	 * This also preserves tablespace page costs and enable_seqscan's penalty.
	 */
	heap_rel.baserestrictinfo = ordinary;
	cost_qual_eval(&heap_rel.baserestrictcost, ordinary, root);
	heap_path.pathtarget = rel->reltarget;
	cost_seqscan(&heap_path, root, &heap_rel, NULL);

	/* Full source tuple, copied operands, candidate tuple.  Width statistics
	 * are approximate (especially for TOAST); 128 covers tuple/header padding.
	 * Arrays, hash tables and provider workspace are outside the soft target.
	 */
	pair_bytes = jev_operand_width(lsecond(marker->args), rte->relid) +
		jev_operand_width(lthird(marker->args), rte->relid);
	row_bytes = get_relation_data_width(rte->relid, NULL) + 2.0 * pair_bytes + 128.0;
	batch_rows = Min((double) path_batch_size,
					 Max(1.0, floor((double) jev_batch_memory_kb * 1024.0 / row_bytes)));
	calls = ceil(candidates / batch_rows);
	/* Include buffering and a conservative allowance for pair hashing, even
	 * when inference is cheap. This remains an uncalibrated cost model.
	 */
	per_row = jev_batch_input_cost * cpu_operator_cost +
		cpu_tuple_cost + 2.0 * cpu_operator_cost;
	batch_work = calls * per_call + candidates * per_row;

	/* Charge work needed before the first buffer can return any row.  Move,
	 * rather than duplicate, this cost from run to startup for LIMIT costing.
	 * Projection happens only when returning rows, not while filling a batch.
	 */
	heap_run = Max(0.0, heap_path.total_cost - heap_path.startup_cost -
				   rel->reltarget->cost.per_tuple * heap_path.rows);
	first_rows = Min(candidates, batch_rows);
	first_fraction = candidates > 0 ? first_rows / candidates : 1.0;
	custom->path.total_cost = heap_path.total_cost + batch_work;
	custom->path.startup_cost = Min(custom->path.total_cost,
		heap_path.startup_cost + heap_run * first_fraction +
		(calls > 0 ? per_call : 0) + first_rows * per_row);

	/* The list order is shared with enum JevPlanInfo and EXPLAIN below. */
	info = jev_append_estimate(info, candidates);
	info = jev_append_estimate(info, selectivity);
	info = jev_append_estimate(info, batch_rows);
	info = jev_append_estimate(info, calls);
	info = jev_append_estimate(info, row_bytes);
	info = jev_append_estimate(info, batch_work);
	info = jev_append_estimate(info, scalar_path->total_cost);
	info = lappend(info, makeInteger(path_batch_size));
	info = lappend(info, makeInteger(jev_batch_memory_kb));
	info = jev_append_estimate(info, jev_batch_call_cost);
	info = jev_append_estimate(info, jev_batch_input_cost);
	info = lappend(info, makeInteger(jev_force_custom_scan));
	info = lappend(info, makeInteger(automatic));
	info = lappend(info, makeInteger(jev_enable_batching ? jev_batch_size : 1));
	custom->custom_private = info;
}

static void
jev_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel,
					Index rti, RangeTblEntry *rte)
{
	CustomPath *custom_path;
	Path	   *seq_path = NULL;
	Path		scalar_baseline = {0};
	ListCell   *cell;
	Oid			function_oid;
	bool		found_semantic_match = false;
	bool		batched;
	bool		automatic;
	int			path_batch_size;
	int			batch_limit = jev_enable_batching ? jev_batch_size : 1;
	FuncExpr   *marker;

	if (previous_set_rel_pathlist_hook)
		previous_set_rel_pathlist_hook(root, rel, rti, rte);

	/*
	 * Keep the initial contract small.  In particular, do not introduce a
	 * different join strategy, evaluate security quals in a new context, or
	 * participate in EvalPlanQual for row locking and data modification.
	 */
	if (!jev_enable_custom_scan ||
		root->parent_root != NULL ||
		root->parse->commandType != CMD_SELECT ||
		root->parse->hasModifyingCTE ||
		root->parse->hasSubLinks ||
		root->parse->hasRowSecurity ||
		root->parse->rowMarks != NIL ||
		root->parse->cteList != NIL ||
		root->parse->setOperations != NULL ||
		list_length(root->parse->rtable) != 1 ||
		bms_num_members(root->all_baserels) != 1 ||
		root->append_rel_list != NIL ||
		rel->reloptkind != RELOPT_BASEREL ||
		rel->lateral_relids != NULL ||
		rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION ||
		rte->inh || rte->tablesample != NULL ||
		rte->securityQuals != NIL ||
		get_rel_relispartition(rte->relid) ||
		get_rel_relam(rte->relid) != HEAP_TABLE_AM_OID)
		return;

	function_oid = jev_semantic_match_oid();
	if (!OidIsValid(function_oid))
		return;

	foreach(cell, rel->baserestrictinfo)
	{
		RestrictInfo *restriction = lfirst_node(RestrictInfo, cell);

		if (restriction->security_level != 0)
			return;
		if (jev_contains_semantic_match((Node *) restriction->clause,
									   &function_oid))
			found_semantic_match = true;
	}
	if (!found_semantic_match)
		return;
	marker = jev_batch_marker(extract_actual_clauses(rel->baserestrictinfo, false),
							   (Node *) root->parse->targetList,
							   function_oid, rti);
	batched = marker != NULL;

	/* Obtain the native serial heap baseline without changing native paths. */
	foreach(cell, rel->pathlist)
	{
		Path	   *candidate = lfirst(cell);

		if (candidate->pathtype == T_SeqScan &&
			candidate->param_info == NULL && !candidate->parallel_aware)
		{
			seq_path = candidate;
			break;
		}
	}
	if (seq_path == NULL)
	{
		/* add_path may already have pruned the SeqScan in favor of an index.
		 * Our heap strategy still needs its own comparison and force routing.
		 */
		scalar_baseline.pathtarget = rel->reltarget;
		cost_seqscan(&scalar_baseline, root, rel, NULL);
		seq_path = &scalar_baseline;
	}

	/* add_path can free a dominated native SeqScan. Copy the scalar baseline
	 * before adding any alternative; subsequent alternatives must not use it.
	 */
	scalar_baseline = *seq_path;
	automatic = batched && jev_enable_batching && jev_auto_batch_size &&
		!jev_force_custom_scan;
	if (jev_force_custom_scan)
	{
		/* Explicit test routing, not a learned or fabricated cost estimate. */
		rel->pathlist = NIL;
		rel->partial_pathlist = NIL;
	}
	/* Geometric alternatives plus the exact user cap: at most 17 paths. Let
	 * PostgreSQL handle LIMIT/OFFSET, sorts and aggregates through its normal
	 * path comparisons; do not infer a row demand from the syntax of LIMIT.
	 */
	path_batch_size = automatic ? 1 : batch_limit;
	for (;;)
	{
		custom_path = makeNode(CustomPath);
		custom_path->path.pathtype = T_CustomScan;
		custom_path->path.parent = rel;
		custom_path->path.pathtarget = rel->reltarget;
		custom_path->path.param_info = NULL;
		custom_path->path.parallel_aware = false;
		custom_path->path.parallel_safe = false;
		custom_path->path.parallel_workers = 0;
		custom_path->path.rows = scalar_baseline.rows;
		custom_path->path.startup_cost = scalar_baseline.startup_cost;
		custom_path->path.total_cost = scalar_baseline.total_cost;
		custom_path->path.pathkeys = NIL;
		custom_path->flags = CUSTOMPATH_SUPPORT_PROJECTION;
		if (!batched)
			custom_path->flags |= CUSTOMPATH_SUPPORT_BACKWARD_SCAN;
		custom_path->custom_private = list_make1(makeInteger(batched));
		custom_path->methods = &jev_path_methods;
		if (batched)
			jev_cost_batch_path(custom_path, root, rel, rte, marker,
								&scalar_baseline, path_batch_size, automatic);
		add_path(rel, &custom_path->path);
		if (path_batch_size == batch_limit)
			break;
		path_batch_size = Min(path_batch_size * 2, batch_limit);
	}
}

static Plan *
jev_plan_custom_path(PlannerInfo *root, RelOptInfo *rel,
					 CustomPath *best_path, List *tlist,
					 List *clauses, List *custom_plans)
{
	CustomScan *scan = makeNode(CustomScan);
	FuncExpr *marker = NULL;

	/* Core has already ordered these quals and will apply setrefs normally. */
	scan->scan.plan.targetlist = tlist;
	scan->scan.plan.qual = extract_actual_clauses(clauses, false);
	scan->scan.scanrelid = rel->relid;
	scan->flags = best_path->flags;
	scan->methods = &jev_scan_methods;
	if (intVal(linitial(best_path->custom_private)))
		marker = jev_batch_marker(scan->scan.plan.qual, (Node *) tlist,
								  jev_semantic_match_oid(), rel->relid);
	scan->custom_private = marker != NULL ? copyObject(best_path->custom_private) :
		list_make1(makeInteger(false));
	if (marker != NULL)
		scan->custom_exprs = list_make1(copyObject(marker));
	/* NIL custom_scan_tlist means the original base relation's row type. */
	return &scan->scan.plan;
}

static Node *
jev_create_scan_state(CustomScan *scan)
{
	JevScanState *state = palloc0(sizeof(JevScanState));

	NodeSetTag(&state->css, T_CustomScanState);
	state->css.methods = &jev_exec_methods;
	state->batched = intVal(linitial(scan->custom_private));
	/* A batch owns copied heap tuples, not pins in the AM's current buffer. */
	state->css.slotOps = state->batched ? &TTSOpsHeapTuple : &TTSOpsBufferHeapTuple;
	return (Node *) state;
}

static void
jev_begin_scan(CustomScanState *node, EState *estate, int eflags)
{
	JevScanState *state = (JevScanState *) node;
	CustomScan *plan = (CustomScan *) node->ss.ps.plan;
	FuncExpr *marker;
	List *relational_quals = NIL;
	ListCell *cell;
	Oid namespace_oid;

	/* ExecInitCustomScan owns relation/slot/qual/projection initialization.
	 * Open the table scan lazily so EXPLAIN without ANALYZE never reads rows.
	 */
	Assert(node->ss.ss_currentRelation != NULL);
	Assert(node->ss.ss_currentScanDesc == NULL);
	if (!state->batched)
		return;
	state->execution_user = GetUserId();
	state->enable_batching = jev_enable_batching;
	state->enable_deduplication = jev_enable_deduplication;
	state->enable_result_cache = jev_enable_result_cache;
	state->enable_relational_prefilter = jev_enable_relational_prefilter;
	state->reuse_kernel_plan = jev_reuse_kernel_plan;
	state->enable_selective_fallback = jev_enable_selective_fallback;
	if (eflags & EXEC_FLAG_BACKWARD)
		elog(ERROR, "batched JEV scan requires a forward-only child scan");

	marker = linitial_node(FuncExpr, plan->custom_exprs);
	/*
	 * Keep the complete original qual in the plan: core has compiled it,
	 * including semantic_match's native EXECUTE check, even under LIMIT 0.
	 * The batch access method applies the quals; ExecScan only projects.
	 */
	foreach(cell, plan->scan.plan.qual)
		if (!equal(lfirst(cell), marker))
			relational_quals = lappend(relational_quals, lfirst(cell));
	state->relational_qual = ExecInitQual(relational_quals, &node->ss.ps);
	node->ss.ps.qual = NULL;
	state->left_expr = ExecInitExpr(lsecond(marker->args), &node->ss.ps);
	state->right_expr = ExecInitExpr(lthird(marker->args), &node->ss.ps);
	state->predicate_name = linitial_node(Const, marker->args)->constvalue;
	state->batch_size = state->enable_batching ? jev_batch_size : 1;
	/* Retained plans keep their selected strategy, while a lower current cap
	 * still limits memory/provider work. Fixed mode keeps its original runtime
	 * GUC behavior. Changing the auto switch alone does not replan a statement.
	 */
	if (intVal(list_nth(plan->custom_private, JEV_PLAN_AUTO_BATCH)))
		state->batch_size = Min(state->batch_size,
							   intVal(list_nth(plan->custom_private, JEV_PLAN_BATCH_SIZE)));
	state->memory_target = (Size) jev_batch_memory_kb * 1024;
	state->cache_budget = state->enable_result_cache ?
		(Size) jev_result_cache_kb * 1024 : 0;
	state->plan_cleanup.func = jev_free_kernel_plan;
	state->plan_cleanup.arg = state;
	MemoryContextRegisterResetCallback(estate->es_query_cxt, &state->plan_cleanup);
	state->batch_context = AllocSetContextCreate(estate->es_query_cxt,
											   "JEV semantic batch",
											   ALLOCSET_DEFAULT_SIZES);
	state->input_slot = MakeSingleTupleTableSlot(
		RelationGetDescr(node->ss.ss_currentRelation), &TTSOpsBufferHeapTuple);
	namespace_oid = get_namespace_oid("jev", false);
	state->candidate_type = GetSysCacheOid2(TYPENAMENSP, Anum_pg_type_oid,
										  CStringGetDatum("candidate"),
										  ObjectIdGetDatum(namespace_oid));
	state->candidate_desc = lookup_rowtype_tupdesc(state->candidate_type, -1);
}

/* Hash and equality have the same byte-exact boundary as evaluate_batch. */
static uint32
jev_pair_hash(const void *key, Size keysize)
{
	const JevPairKey *pair = key;
	uint32 left = hash_bytes((const unsigned char *) VARDATA_ANY(pair->left),
							VARSIZE_ANY_EXHDR(pair->left));
	uint32 right = hash_bytes((const unsigned char *) VARDATA_ANY(pair->right),
							 VARSIZE_ANY_EXHDR(pair->right));

	return hash_combine(left, right);
}

static int
jev_pair_compare(const void *key1, const void *key2, Size keysize)
{
	const JevPairKey *first = key1;
	const JevPairKey *second = key2;
	Size left_size = VARSIZE_ANY_EXHDR(first->left);
	Size right_size = VARSIZE_ANY_EXHDR(first->right);

	return left_size != VARSIZE_ANY_EXHDR(second->left) ||
		right_size != VARSIZE_ANY_EXHDR(second->right) ||
		memcmp(VARDATA_ANY(first->left), VARDATA_ANY(second->left), left_size) ||
		memcmp(VARDATA_ANY(first->right), VARDATA_ANY(second->right), right_size);
}

static void
jev_free_kernel_plan(void *argument)
{
	JevScanState *state = argument;

	/* Also runs on errors, when EndCustomScan need not be called. */
	if (state->kernel_plan != NULL)
	{
		SPI_freeplan(state->kernel_plan);
		state->kernel_plan = NULL;
	}
}

static JevResultEntry *
jev_cache_lookup(JevScanState *state, const JevPairKey *pair)
{
	JevResultEntry *entry;
	uint32 hash;
	Size left_size = VARSIZE_ANY_EXHDR(pair->left);
	Size right_size = VARSIZE_ANY_EXHDR(pair->right);

	if (state->cache_arena == NULL)
		return NULL;
	hash = jev_pair_hash(pair, sizeof(JevPairKey));
	entry = state->cache_buckets[hash & (state->cache_bucket_count - 1)];
	for (; entry != NULL; entry = entry->next)
	{
		if (entry->hash == hash && entry->left_size == left_size &&
			entry->right_size == right_size &&
			memcmp(entry->data, VARDATA_ANY(pair->left), left_size) == 0 &&
			memcmp(entry->data + left_size, VARDATA_ANY(pair->right), right_size) == 0)
			return entry;
	}
	return NULL;
}

static void
jev_cache_admit(JevScanState *state, const JevPairKey *pair, bool decision)
{
	Size left_size = VARSIZE_ANY_EXHDR(pair->left);
	Size right_size = VARSIZE_ANY_EXHDR(pair->right);
	Size entry_size = MAXALIGN(offsetof(JevResultEntry, data) + left_size + right_size);
	Size bucket_bytes;
	uint32 bucket_count;
	uint32 bucket;
	JevResultEntry *entry;

	if (state->cache_budget == 0)
		return;
	/* Without within-buffer deduplication, repeated misses are dispatched
	 * independently. Retain one cache entry, not one copy per occurrence.
	 */
	if (!state->enable_deduplication && jev_cache_lookup(state, pair) != NULL)
		return;
	/* A power-of-two directory consumes a bounded part of the same arena. */
	bucket_count = 8;
	while (bucket_count < 65536 &&
		   (Size) bucket_count * 2 <= state->cache_budget / 128)
		bucket_count *= 2;
	bucket_bytes = MAXALIGN(bucket_count * sizeof(JevResultEntry *));
	if (entry_size > state->cache_budget - bucket_bytes ||
		(state->cache_arena != NULL && entry_size > state->cache_budget - state->cache_used))
	{
		state->cache_admission_skips++;
		return;
	}
	if (state->cache_arena == NULL)
	{
		/* Only the allocator's constant chunk header is outside this budget. */
		state->cache_arena = MemoryContextAlloc(state->css.ss.ps.state->es_query_cxt,
												state->cache_budget);
		state->cache_buckets = (JevResultEntry **) state->cache_arena;
		memset(state->cache_buckets, 0, bucket_bytes);
		state->cache_bucket_count = bucket_count;
		state->cache_used = bucket_bytes;
	}
	entry = (JevResultEntry *) (state->cache_arena + state->cache_used);
	entry->hash = jev_pair_hash(pair, sizeof(JevPairKey));
	entry->left_size = left_size;
	entry->right_size = right_size;
	entry->decision = decision;
	memcpy(entry->data, VARDATA_ANY(pair->left), left_size);
	memcpy(entry->data + left_size, VARDATA_ANY(pair->right), right_size);
	bucket = entry->hash & (state->cache_bucket_count - 1);
	entry->next = state->cache_buckets[bucket];
	state->cache_buckets[bucket] = entry;
	state->cache_used += entry_size;
	state->cache_entries++;
}

static void
jev_clear_result_cache(JevScanState *state)
{
	if (state->cache_arena != NULL)
		pfree(state->cache_arena);
	state->cache_arena = NULL;
	state->cache_buckets = NULL;
	state->cache_bucket_count = 0;
	state->cache_used = 0;
	state->cache_entries = 0;
}

static void
jev_clear_batch(JevScanState *state)
{
	/* Slots can still borrow the most recently returned batch's storage. */
	ExecClearTuple(state->css.ss.ss_ScanTupleSlot);
	ExecClearTuple(state->css.ss.ps.ps_ResultTupleSlot);
	MemoryContextReset(state->batch_context);
	state->tuples = NULL;
	state->candidates = NULL;
	state->matches = NULL;
	state->result_map = NULL;
	state->miss_keys = NULL;
	state->miss_matches = NULL;
	state->miss_count = 0;
	state->count = state->position = 0;
}

static void
jev_evaluate_chunk(JevScanState *state)
{
	Oid argument_types[3] = {TEXTOID, InvalidOid, INT4OID};
	Datum arguments[3];
	ArrayType *candidates;
	int status;
	uint64 i;
	instr_time started;
	instr_time ended;

	argument_types[1] = get_array_type(state->candidate_type);
	candidates = construct_array(state->candidates, state->miss_count,
								 state->candidate_type, -1, false, TYPALIGN_DOUBLE);
	arguments[0] = state->predicate_name;
	arguments[1] = PointerGetDatum(candidates);
	arguments[2] = Int32GetDatum(state->miss_count);
	INSTR_TIME_SET_CURRENT(started);
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "could not connect JEV batch executor to SPI");
	if (state->reuse_kernel_plan)
	{
		if (state->kernel_plan == NULL)
		{
			SPIPlanPtr plan = SPI_prepare(
				"SELECT ordinal, decision FROM jev.evaluate_batch($1, $2, $3)",
				3, argument_types);

			if (plan == NULL || SPI_keepplan(plan) != 0)
				elog(ERROR, "could not prepare JEV batch evaluator");
			state->kernel_plan = plan;
		}
		/* Saved plans retain ordinary invalidation, ACL and snapshot handling. */
		status = SPI_execute_plan(state->kernel_plan, arguments, NULL, true, 0);
	}
	else
		/* The unsaved one-shot plan is released by SPI_finish, including its
		 * normal error cleanup. Bound arguments preserve the same privileges.
		 */
		status = SPI_execute_with_args(
			"SELECT ordinal, decision FROM jev.evaluate_batch($1, $2, $3)",
			3, argument_types, arguments, NULL, true, 0);
	if (status != SPI_OK_SELECT || SPI_processed != (uint64) state->miss_count)
		elog(ERROR, "JEV batch evaluator returned an unexpected row count");
	for (i = 0; i < SPI_processed; i++)
	{
		bool isnull;
		Datum ordinal = SPI_getbinval(SPI_tuptable->vals[i],
									 SPI_tuptable->tupdesc, 1, &isnull);
		Datum decision;

		if (isnull || DatumGetInt64(ordinal) != (int64) i + 1)
			elog(ERROR, "JEV batch evaluator returned an unexpected ordinal");
		decision = SPI_getbinval(SPI_tuptable->vals[i],
								SPI_tuptable->tupdesc, 2, &isnull);
		if (isnull)
			elog(ERROR, "JEV batch evaluator returned a NULL decision for non-NULL input");
		state->miss_matches[i] = DatumGetBool(decision);
	}
	SPI_finish();
	INSTR_TIME_SET_CURRENT(ended);
	INSTR_TIME_SUBTRACT(ended, started);
	state->kernel_ms += INSTR_TIME_GET_MILLISEC(ended);
	/* A kernel dispatch may invoke several providers, e.g. a cascade. */
	state->provider_calls++;
	for (i = 0; i < (uint64) state->miss_count; i++)
		jev_cache_admit(state, &state->miss_keys[i], state->miss_matches[i]);
}

static void
jev_fill_batch(JevScanState *state)
{
	ScanState *scan = &state->css.ss;
	ExprContext *econtext = scan->ps.ps_ExprContext;
	MemoryContext old_context;
	HASHCTL control = {0};
	HTAB *pairs = NULL;
	Size buffered_bytes = 0;
	int capacity = Min(state->batch_size, 128);
	int i;

	jev_clear_batch(state);
	old_context = MemoryContextSwitchTo(state->batch_context);
	state->tuples = palloc(capacity * sizeof(HeapTuple));
	state->candidates = palloc(capacity * sizeof(Datum));
	state->matches = palloc0(capacity * sizeof(bool));
	state->result_map = palloc(capacity * sizeof(int));
	state->miss_keys = palloc(capacity * sizeof(JevPairKey));
	state->miss_matches = palloc(capacity * sizeof(bool));
	if (state->enable_deduplication)
	{
		control.keysize = sizeof(JevPairKey);
		control.entrysize = sizeof(JevBatchPair);
		control.hash = jev_pair_hash;
		control.match = jev_pair_compare;
		control.hcxt = state->batch_context;
		pairs = hash_create("JEV input pairs", capacity, &control,
							HASH_ELEM | HASH_FUNCTION | HASH_COMPARE | HASH_CONTEXT);
	}
	MemoryContextSwitchTo(old_context);

	if (scan->ss_currentScanDesc == NULL)
		scan->ss_currentScanDesc = table_beginscan(scan->ss_currentRelation,
												scan->ps.state->es_snapshot, 0, NULL);
	while (state->count < state->batch_size)
	{
		HeapTuple source;
		Datum values[3] = {0, 0, 0};
		bool nulls[3] = {true, false, false};
		JevPairKey pair = {NULL, NULL};
		int index = state->count;

		CHECK_FOR_INTERRUPTS();
		ResetExprContext(econtext);
		ExecClearTuple(scan->ss_ScanTupleSlot);
		if (!table_scan_getnextslot(scan->ss_currentScanDesc,
								   ForwardScanDirection, state->input_slot))
		{
			state->exhausted = true;
			break;
		}
		state->rows_read++;
		source = ExecFetchSlotHeapTuple(state->input_slot, false, NULL);
		/* Expressions were compiled for a HeapTuple scan slot. */
		ExecStoreHeapTuple(source, scan->ss_ScanTupleSlot, false);
		scan->ss_ScanTupleSlot->tts_tableOid = RelationGetRelid(scan->ss_currentRelation);
		econtext->ecxt_scantuple = scan->ss_ScanTupleSlot;
		if (state->enable_relational_prefilter &&
			!ExecQual(state->relational_qual, econtext))
		{
			InstrCountFiltered1(scan, 1);
			continue;
		}
		values[1] = ExecEvalExprSwitchContext(state->left_expr, econtext, &nulls[1]);
		values[2] = ExecEvalExprSwitchContext(state->right_expr, econtext, &nulls[2]);
		/* No operand payload is needed for a STRICT NULL result. */
		if (nulls[1] || nulls[2])
			nulls[1] = nulls[2] = true;
		MemoryContextSwitchTo(state->batch_context);
		if (index == capacity)
		{
			capacity = Min(capacity * 2, state->batch_size);
			state->tuples = repalloc(state->tuples, capacity * sizeof(HeapTuple));
			state->candidates = repalloc(state->candidates, capacity * sizeof(Datum));
			state->matches = repalloc(state->matches, capacity * sizeof(bool));
			state->result_map = repalloc(state->result_map, capacity * sizeof(int));
			state->miss_keys = repalloc(state->miss_keys, capacity * sizeof(JevPairKey));
			state->miss_matches = repalloc(state->miss_matches, capacity * sizeof(bool));
		}
		state->matches[index] = false;
		state->result_map[index] = -1;
		state->tuples[index] = heap_copytuple(source);
		buffered_bytes += HEAPTUPLESIZE + source->t_len;
		if (!nulls[1])
		{
			pair.left = DatumGetTextPCopy(values[1]);
			values[1] = PointerGetDatum(pair.left);
			buffered_bytes += VARSIZE_ANY(pair.left);
		}
		if (!nulls[2])
		{
			pair.right = DatumGetTextPCopy(values[2]);
			values[2] = PointerGetDatum(pair.right);
			buffered_bytes += VARSIZE_ANY(pair.right);
		}
		if (!nulls[1] && !nulls[2])
		{
			bool found = false;
			JevBatchPair occurrence_pair;
			JevBatchPair *batch_pair;

			/* A stack entry tracks each occurrence independently when reuse
			 * within this buffer is disabled. Cache lookup remains independent.
			 */
			batch_pair = state->enable_deduplication ?
				hash_search(pairs, &pair, HASH_ENTER, &found) : &occurrence_pair;
			if (!found)
			{
				JevResultEntry *cached = jev_cache_lookup(state, &pair);

				batch_pair->cached = cached != NULL;
				batch_pair->miss_index = -1;
				batch_pair->decision = cached != NULL && cached->decision;
				if (cached == NULL)
				{
					HeapTuple candidate = heap_form_tuple(state->candidate_desc, values, nulls);
					int miss_index = state->miss_count++;

					batch_pair->miss_index = miss_index;
					state->candidates[miss_index] = HeapTupleGetDatum(candidate);
					state->miss_keys[miss_index] = pair;
					buffered_bytes += HEAPTUPLESIZE + candidate->t_len;
				}
			}
			if (batch_pair->cached)
			{
				state->matches[index] = batch_pair->decision;
				state->cache_hits++;
				state->reused_inputs++;
			}
			else
			{
				state->result_map[index] = batch_pair->miss_index;
				if (found)
					state->reused_inputs++;
			}
		}
		state->count++;
		state->candidate_rows++;
		MemoryContextSwitchTo(old_context);
		if (buffered_bytes >= state->memory_target)
			break;
	}
	ExecClearTuple(scan->ss_ScanTupleSlot);
	ExecClearTuple(state->input_slot);
	ResetExprContext(econtext);
	if (state->count == 0)
		return;
	state->batches++;
	state->unique_inputs += state->miss_count;
	state->peak_rows = Max(state->peak_rows, (uint64) state->count);
	state->peak_bytes = Max(state->peak_bytes, (uint64) buffered_bytes);
	/* STRICT scalar evaluation never resolves metadata for NULL-only input. */
	if (state->miss_count > 0)
	{
		MemoryContextSwitchTo(state->batch_context);
		jev_evaluate_chunk(state);
		MemoryContextSwitchTo(old_context);
	}
	for (i = 0; i < state->count; i++)
	{
		if (state->result_map[i] >= 0)
			state->matches[i] = state->miss_matches[state->result_map[i]];
		if (state->matches[i])
			state->evaluated_match_rows++;
	}
}

static TupleTableSlot *
jev_next_batch_tuple(ScanState *scan)
{
	JevScanState *state = (JevScanState *) scan;
	ExprContext *econtext = scan->ps.ps_ExprContext;

	Assert(ScanDirectionIsForward(scan->ps.state->es_direction));
	for (;;)
	{
		while (state->position < state->count)
		{
			int index = state->position++;

			if (state->matches[index])
			{
				ExecStoreHeapTuple(state->tuples[index], scan->ss_ScanTupleSlot, false);
				scan->ss_ScanTupleSlot->tts_tableOid = RelationGetRelid(scan->ss_currentRelation);
				if (!state->enable_relational_prefilter)
				{
					ResetExprContext(econtext);
					econtext->ecxt_scantuple = scan->ss_ScanTupleSlot;
					if (!ExecQual(state->relational_qual, econtext))
					{
						InstrCountFiltered1(scan, 1);
						continue;
					}
				}
				return scan->ss_ScanTupleSlot;
			}
			InstrCountFiltered1(scan, 1);
		}
		if (state->exhausted)
			return ExecClearTuple(scan->ss_ScanTupleSlot);
		jev_fill_batch(state);
	}
}

static TupleTableSlot *
jev_next_tuple(ScanState *state)
{
	EState	   *estate = state->ps.state;

	if (state->ss_currentScanDesc == NULL)
		state->ss_currentScanDesc =
			table_beginscan(state->ss_currentRelation, estate->es_snapshot,
						   0, NULL);

	if (table_scan_getnextslot(state->ss_currentScanDesc, estate->es_direction,
							  state->ss_ScanTupleSlot))
		return state->ss_ScanTupleSlot;
	return NULL;
}

static bool
jev_recheck_tuple(ScanState *state, TupleTableSlot *slot)
{
	/* No AM scan keys; ExecScan applies the full original qualification. */
	return true;
}

static TupleTableSlot *
jev_exec_scan(CustomScanState *node)
{
	JevScanState *state = (JevScanState *) node;

	/* A cursor pins its snapshot, but can be fetched after SET ROLE. Never
	 * serve a cached or buffered decision under another execution identity.
	 */
	if (state->batched && GetUserId() != state->execution_user)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("cannot change role during a batched JEV scan"),
				 errhint("Close and reopen the cursor under the intended role.")));
	/* Explicit SQL APIs read these switches at call entry. Do not mix their
	 * new settings with buffered decisions or a scan cache from an old mode.
	 * Numeric buffer/cache budgets retain the existing captured-scan behavior.
	 */
	if (state->batched &&
		(state->enable_batching != jev_enable_batching ||
		 state->enable_deduplication != jev_enable_deduplication ||
		 state->enable_result_cache != jev_enable_result_cache ||
		 state->enable_relational_prefilter != jev_enable_relational_prefilter ||
		 state->reuse_kernel_plan != jev_reuse_kernel_plan ||
		 state->enable_selective_fallback != jev_enable_selective_fallback))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("cannot change optimization switches during a batched JEV scan"),
				 errhint("Close and reopen the cursor with the intended optimization settings.")));

	return ExecScan(&node->ss,
					state->batched ? jev_next_batch_tuple : jev_next_tuple,
					jev_recheck_tuple);
}

static void
jev_end_scan(CustomScanState *node)
{
	JevScanState *state = (JevScanState *) node;

	if (state->batched)
	{
		jev_clear_batch(state);
		jev_clear_result_cache(state);
		jev_free_kernel_plan(state);
		ExecDropSingleTupleTableSlot(state->input_slot);
		ReleaseTupleDesc(state->candidate_desc);
		MemoryContextDelete(state->batch_context);
	}
	if (node->ss.ss_currentScanDesc != NULL)
	{
		table_endscan(node->ss.ss_currentScanDesc);
		node->ss.ss_currentScanDesc = NULL;
	}
}

static void
jev_rescan(CustomScanState *node)
{
	JevScanState *state = (JevScanState *) node;

	if (state->batched)
	{
		jev_clear_batch(state);
		/* Never reuse decisions across a rescan, even with the same operands. */
		jev_clear_result_cache(state);
		ExecClearTuple(state->input_slot);
		state->exhausted = false;
	}
	if (node->ss.ss_currentScanDesc != NULL)
		table_rescan(node->ss.ss_currentScanDesc, NULL);
	ExecScanReScan(&node->ss);
}

static void
jev_explain_scan(CustomScanState *node, List *ancestors, ExplainState *es)
{
	JevScanState *state = (JevScanState *) node;
	CustomScan *plan = (CustomScan *) node->ss.ps.plan;
	List *info = plan->custom_private;

	if (!state->batched)
	{
		ExplainPropertyText("Semantic Evaluation", "scalar (planner scaffold)", es);
		ExplainPropertyText("Batch Evaluation", "predicate shape is not batch eligible", es);
		return;
	}
	ExplainPropertyText("Semantic Evaluation", "batched", es);
	ExplainPropertyBool("Batching Enabled", state->enable_batching, es);
	ExplainPropertyBool("Input Deduplication", state->enable_deduplication, es);
	ExplainPropertyBool("Result Cache Enabled", state->enable_result_cache, es);
	ExplainPropertyBool("Relational Prefilter", state->enable_relational_prefilter, es);
	ExplainPropertyBool("Reuse Kernel Plan", state->reuse_kernel_plan, es);
	ExplainPropertyBool("Selective Fallback", state->enable_selective_fallback, es);
	ExplainPropertyText("Batch Size Selection",
		intVal(list_nth(info, JEV_PLAN_AUTO_BATCH)) ? "cost based" : "fixed", es);
	ExplainPropertyInteger("Batch Size", NULL, state->batch_size, es);
	ExplainPropertyInteger("Batch Memory Target", "kB", state->memory_target / 1024, es);
	ExplainPropertyInteger("Result Cache Limit", "kB", state->cache_budget / 1024, es);
	if (es->costs)
	{
		ExplainPropertyText("Cost Model", "batch-v1", es);
		ExplainPropertyText("Estimate Assumptions",
			"PostgreSQL estimates (including default semantic selectivity); configured costs; no NULL or reuse discount", es);
		ExplainPropertyFloat("Estimated Candidate Rows", NULL,
							 floatVal(list_nth(info, JEV_EST_CANDIDATES)), 2, es);
		ExplainPropertyFloat("Estimated Semantic Selectivity", NULL,
							 floatVal(list_nth(info, JEV_EST_SELECTIVITY)), 6, es);
		ExplainPropertyFloat("Estimated Batch Rows", NULL,
							 floatVal(list_nth(info, JEV_EST_BATCH_ROWS)), 0, es);
		ExplainPropertyFloat("Estimated Kernel Calls", NULL,
							 floatVal(list_nth(info, JEV_EST_CALLS)), 0, es);
		ExplainPropertyFloat("Estimated Buffered Row Bytes", NULL,
							 floatVal(list_nth(info, JEV_EST_ROW_BYTES)), 0, es);
		ExplainPropertyFloat("Estimated Batch Work Cost", NULL,
							 floatVal(list_nth(info, JEV_EST_WORK_COST)), 2, es);
		ExplainPropertyFloat("Scalar Seq Scan Total Cost", NULL,
							 floatVal(list_nth(info, JEV_SCALAR_COST)), 2, es);
		ExplainPropertyInteger("Planned Batch Size", NULL,
							   intVal(list_nth(info, JEV_PLAN_BATCH_SIZE)), es);
		ExplainPropertyInteger("Planned Batch Size Limit", NULL,
							   intVal(list_nth(info, JEV_PLAN_BATCH_LIMIT)), es);
		ExplainPropertyInteger("Planned Batch Memory", "kB",
							   intVal(list_nth(info, JEV_PLAN_MEMORY_KB)), es);
		ExplainPropertyFloat("Batch Call Cost", NULL,
							 floatVal(list_nth(info, JEV_PLAN_CALL_COST)), 3, es);
		ExplainPropertyFloat("Batch Input Cost", NULL,
							 floatVal(list_nth(info, JEV_PLAN_INPUT_COST)), 3, es);
		ExplainPropertyBool("Forced Custom Path", intVal(list_nth(info, JEV_PLAN_FORCED)), es);
	}
	if (es->analyze)
	{
		ExplainPropertyInteger("Rows Read", NULL, state->rows_read, es);
		ExplainPropertyInteger("Candidate Rows", NULL, state->candidate_rows, es);
		ExplainPropertyInteger("Evaluated Match Rows", NULL, state->evaluated_match_rows, es);
		/* No fraction is defined if LIMIT 0 or a relational filter saw no input. */
		if (state->candidate_rows > 0)
			ExplainPropertyFloat("Observed Match Fraction", NULL,
				(double) state->evaluated_match_rows / state->candidate_rows, 6, es);
		ExplainPropertyInteger("Unique Inputs", NULL, state->unique_inputs, es);
		ExplainPropertyText("Unique Inputs Meaning", "legacy alias for Kernel Inputs", es);
		ExplainPropertyInteger("Kernel Inputs", NULL, state->unique_inputs, es);
		ExplainPropertyInteger("Reused Inputs", NULL, state->reused_inputs, es);
		ExplainPropertyInteger("Provider Calls", NULL, state->provider_calls, es);
		ExplainPropertyText("Provider Calls Meaning", "legacy alias for Kernel Calls", es);
		ExplainPropertyInteger("Kernel Calls", NULL, state->provider_calls, es);
		ExplainPropertyInteger("Cache Hits", NULL, state->cache_hits, es);
		ExplainPropertyInteger("Cache Entries", NULL, state->cache_entries, es);
		ExplainPropertyInteger("Cache Used Bytes", NULL, state->cache_used, es);
		ExplainPropertyInteger("Cache Allocated Bytes", NULL,
							   state->cache_arena != NULL ? state->cache_budget : 0, es);
		ExplainPropertyInteger("Cache Admission Skips", NULL, state->cache_admission_skips, es);
		ExplainPropertyInteger("Batches", NULL, state->batches, es);
		ExplainPropertyInteger("Peak Buffered Rows", NULL, state->peak_rows, es);
		ExplainPropertyInteger("Peak Buffered Bytes", NULL, state->peak_bytes, es);
		ExplainPropertyFloat("Kernel Time", "ms", state->kernel_ms, 3, es);
	}
}
