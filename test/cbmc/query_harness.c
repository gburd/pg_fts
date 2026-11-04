/*-------------------------------------------------------------------------
 *
 * query_harness.c
 *		CBMC proofs that the query-shape shortcuts on the ranked and collect
 *		paths never drop a matching document.  Each shortcut decides from
 *		the query's RPN alone (plus which terms a segment holds) that some
 *		work cannot produce a match, and skips it; a wrong decision is a
 *		missing row, not a slow query.
 *
 *	The query is any well-formed RPN of up to QN items over AND / OR / NOT
 *	and up to QN term leaves (exactly the shapes ftsquery_recv accepts for a
 *	pure-boolean query: every operator has its operands, one root).  A
 *	document is any subset of the terms; a segment is any subset too.  The
 *	reference is bool_gate_admits, the RPN evaluation over term presence
 *	that every pure-boolean ranked path admits through (and that agrees
 *	with @@@ for these shapes).  The functions under proof are VERBATIM
 *	copies (check_verbatim.py), with palloc/pfree mapped to malloc/free.
 *
 *	PROPERTIES
 *	  Q1  query_and_operands: every reported operand is satisfied by every
 *	      matching document (it is a conjunct of the root), and pos[n] is
 *	      true only for a subtree without NOT.
 *	  Q2  bm25_required_term_absent (I19b, Codeberg #6): if it reports that
 *	      a segment lacks a required operand, no document whose terms all lie
 *	      in that segment matches.  (Plain terms only, as the shape test
 *	      requires; bm25_lookup_df is "is term t in the segment".)
 *	  Q3  bool_gate_may_admit (1.14.3): if it returns false for the set of
 *	      terms that have a cursor, no document over those terms matches.
 *	  Q4  bool_gate_driver (I19a): every matching document holds at least
 *	      one of the driver's terms, so enumerating the driver's postings
 *	      enumerates every match.
 *	  Q5  eval_not_parity: odd[i] is the parity of NOT operators on the
 *	      path from the root to item i (checked against a recursive
 *	      reference).
 *
 *	TEETH: -DTEETH_ABSENT_NOT lets bm25_required_term_absent test an
 *	operand containing NOT (the too-permissive shape from the I19b review):
 *	Q2 must fail.  -DTEETH_MAYADMIT drops the odd-NOT clearing in
 *	bool_gate_may_admit: Q3 must fail.  -DTEETH_DRIVER lets the driver
 *	choose an operand with a NOT: Q4 must fail.
 *
 * IDENTIFICATION
 *	  test/cbmc/query_harness.c
 *
 *-------------------------------------------------------------------------
 */
#include "cbmc_pg.h"

#ifndef QN
#define QN 7					/* RPN items: up to 4 leaves and 3 operators */
#endif

#define palloc(n) cbmc_palloc(n)
#define palloc0(n) memset(cbmc_palloc(n), 0, (n))
#define pfree(p) free(p)

/* pg_fts.h */
typedef enum FtsQueryItemType
{
	FTS_QI_VAL = 1,
	FTS_QI_OPR
} FtsQueryItemType;
typedef enum FtsQueryOp
{
	FTS_OP_NOT = 1,
	FTS_OP_AND,
	FTS_OP_OR,
	FTS_OP_PHRASE,
	FTS_OP_WITHIN,
	FTS_OP_EXACT
} FtsQueryOp;
typedef struct FtsQueryItem
{
	uint8		type;
	uint8		op;
	uint16		flags;
	uint32		distance;
	uint32		termoff;
	uint32		termlen;
} FtsQueryItem;
#define FTS_QF_PREFIX	0x0001
#define FTS_QF_FUZZY	0x0002
#define FTS_QF_REGEX	0x0004
#define FTS_QF_WEIGHTED	0x0008
typedef struct FtsQueryData
{
	int32		vl_len_;
	uint16		version;
	uint16		flags;
	uint32		nitems;
	FtsQueryItem items[QN];
} FtsQueryData;
typedef FtsQueryData *FtsQuery;
#define FTS_QUERY_ITEMTEXT(q, it) ((const char *) &(it)->termoff)	/* unused text */

/* the cursor and gate fields the functions read */
typedef struct WandCursor
{
	int			termidx;
	uint32		df;
} WandCursor;
typedef struct PhraseGate PhraseGate;
typedef struct BoolGate
{
	FtsQuery	q;
	bool	   *present;
	bool	   *stack;
	int			nterms;
	PhraseGate *phrase;
} BoolGate;

/* segment model for bm25_lookup_df: VAL ordinal -> in this segment? */
typedef struct BM25SegMeta
{
	bool		has[QN];
} BM25SegMeta;
typedef void *Relation;
static FtsQuery cur_q;			/* the query bm25_lookup_df resolves leaves in */

static uint32
bm25_lookup_df(Relation index, const BM25SegMeta *seg, const char *term, int termlen)
{
	/* `term` points into cur_q->items[m]: recover m, then the VAL ordinal */
	const FtsQueryItem *it = (const FtsQueryItem *) (term - offsetof(FtsQueryItem, termoff));
	int			m = (int) (it - cur_q->items);
	int			vi = 0,
				j;

	(void) index;
	(void) termlen;
	for (j = 0; j < m; j++)
		if (cur_q->items[j].type == FTS_QI_VAL)
			vi++;
	return seg->has[vi] ? 1 : 0;
}

/* VERBATIM pg_fts_am_scan.c eval_not_parity */
static bool *
eval_not_parity(FtsQuery q)
{
	bool	   *odd = palloc(q->nitems * sizeof(bool));
	bool	   *work = palloc(q->nitems * sizeof(bool));
	int			depth = 0;
	uint32		i;

	work[depth++] = false;
	for (i = q->nitems; i-- > 0;)
	{
		FtsQueryItem *it = &q->items[i];
		bool		p = (depth > 0) ? work[--depth] : false;

		odd[i] = p;
		if (it->type == FTS_QI_VAL)
			continue;
		if (it->op == FTS_OP_NOT)
			work[depth++] = !p;
		else if (depth + 2 <= (int) q->nitems)
		{
			work[depth++] = p;
			work[depth++] = p;
		}
	}
	pfree(work);
	return odd;
}
/* END VERBATIM */

/* VERBATIM pg_fts_am_scan.c query_and_operands */
static int
query_and_operands(FtsQuery q, int *ops, int *start, bool *pos)
{
	int		   *stk = (int *) palloc(Max(q->nitems, 1) * sizeof(int));	/* alloc-ok: query items */
	int		   *lchild = (int *) palloc(Max(q->nitems, 1) * sizeof(int));	/* alloc-ok: query items */
	int			sp = 0,
				nops = 0;
	uint32		i;

	for (i = 0; i < q->nitems; i++)
	{
		FtsQueryItem *it = &q->items[i];

		lchild[i] = -1;
		if (it->type == FTS_QI_VAL)
		{
			start[i] = (int) i;
			pos[i] = true;
		}
		else if (it->op == FTS_OP_NOT)
		{
			int			c = stk[--sp];

			start[i] = start[c];
			pos[i] = false;
		}
		else
		{
			int			b = stk[--sp];
			int			a = stk[--sp];

			start[i] = start[a];
			pos[i] = pos[a] && pos[b];
			lchild[i] = a;
		}
		stk[sp++] = (int) i;
	}
	if (sp == 1 && q->items[stk[0]].type != FTS_QI_VAL && q->items[stk[0]].op == FTS_OP_AND)
	{
		int			wl[64];		/* AND nodes to expand */
		int			nwl = 0;

		wl[nwl++] = stk[0];
		while (nwl > 0)
		{
			int			n = wl[--nwl];
			int			kids[2];
			int			j;

			kids[0] = lchild[n];
			kids[1] = n - 1;	/* the right subtree ends just before its operator */
			for (j = 0; j < 2; j++)
			{
				int			c = kids[j];

				/* past 64 nested ANDs an AND is itself reported as an operand:
				 * coarser, never wrong (every match still satisfies it) */
				if (q->items[c].type != FTS_QI_VAL && q->items[c].op == FTS_OP_AND &&
					nwl < (int) lengthof(wl))
					wl[nwl++] = c;
				else
					ops[nops++] = c;
			}
		}
	}
	pfree(stk);
	pfree(lchild);
	return nops;
}
/* END VERBATIM */

#ifndef TEETH_ABSENT_NOT
/* VERBATIM pg_fts_am_scan.c bm25_required_term_absent */
static bool
bm25_required_term_absent(Relation index, const BM25SegMeta *seg, FtsQuery q)
{
	int		   *ops,
			   *start;
	bool	   *pos;
	int			nops,
				j;
	bool		absent = false;

	if (q->nitems < 3)
		return false;
	ops = (int *) palloc(q->nitems * sizeof(int));	/* alloc-ok: query items */
	start = (int *) palloc(q->nitems * sizeof(int));	/* alloc-ok: query items */
	pos = (bool *) palloc(q->nitems * sizeof(bool));	/* alloc-ok: query items */
	nops = query_and_operands(q, ops, start, pos);
	for (j = 0; j < nops && !absent; j++)
	{
		int			n = ops[j],
					m;

		/* shape first (no I/O): plain terms joined by OR only */
		absent = true;
		for (m = start[n]; m <= n && absent; m++)
		{
			FtsQueryItem *it = &q->items[m];

			if (it->type == FTS_QI_VAL
				? (it->flags & (FTS_QF_PREFIX | FTS_QF_FUZZY | FTS_QF_REGEX | FTS_QF_WEIGHTED)) != 0
				: it->op != FTS_OP_OR)
				absent = false;
		}
		for (m = start[n]; m <= n && absent; m++)
		{
			FtsQueryItem *it = &q->items[m];

			if (it->type == FTS_QI_VAL &&
				bm25_lookup_df(index, seg, FTS_QUERY_ITEMTEXT(q, it), it->termlen) != 0)
				absent = false;
		}
	}
	pfree(ops);
	pfree(start);
	pfree(pos);
	return absent;
}
/* END VERBATIM */
#else
/* mutant: the shape test also lets NOT through (the I19b review's case) */
static bool
bm25_required_term_absent(Relation index, const BM25SegMeta *seg, FtsQuery q)
{
	int		   *ops = (int *) palloc(q->nitems * sizeof(int));
	int		   *start = (int *) palloc(q->nitems * sizeof(int));
	bool	   *pos = (bool *) palloc(q->nitems * sizeof(bool));
	int			nops,
				j;
	bool		absent = false;

	if (q->nitems < 3)
		return false;
	nops = query_and_operands(q, ops, start, pos);
	for (j = 0; j < nops && !absent; j++)
	{
		int			n = ops[j],
					m;

		absent = true;
		for (m = start[n]; m <= n && absent; m++)
		{
			FtsQueryItem *it = &q->items[m];

			if (it->type != FTS_QI_VAL && it->op != FTS_OP_OR && it->op != FTS_OP_NOT)
				absent = false;
		}
		for (m = start[n]; m <= n && absent; m++)
		{
			FtsQueryItem *it = &q->items[m];

			if (it->type == FTS_QI_VAL &&
				bm25_lookup_df(index, seg, FTS_QUERY_ITEMTEXT(q, it), it->termlen) != 0)
				absent = false;
		}
	}
	return absent;
}
#endif

/* VERBATIM pg_fts_am_scan.c bool_gate_admits */
static inline bool
bool_gate_admits(const BoolGate *g)
{
	FtsQuery	q;
	bool	   *st;
	int			top = 0;
	int			vi = 0;
	uint32		i;

	if (g == NULL || g->q == NULL)
		return true;
	q = g->q;
	st = g->stack;
	for (i = 0; i < q->nitems; i++)
	{
		FtsQueryItem *it = &q->items[i];

		if (it->type == FTS_QI_VAL)
			st[top++] = g->present[vi++];
		else if (it->op == FTS_OP_NOT)
			st[top - 1] = !st[top - 1];
		else if (it->op == FTS_OP_AND)
		{
			st[top - 2] = st[top - 2] && st[top - 1];
			top--;
		}
		else					/* FTS_OP_OR */
		{
			st[top - 2] = st[top - 2] || st[top - 1];
			top--;
		}
	}
	return top == 1 ? st[0] : false;
}
/* END VERBATIM */

#ifndef TEETH_MAYADMIT
/* VERBATIM pg_fts_am_scan.c bool_gate_may_admit */
static bool
bool_gate_may_admit(BoolGate *g, const WandCursor *cursors, int ncur)
{
	bool	   *odd = eval_not_parity(g->q);
	int			vi = 0;
	uint32		i;

	memset(g->present, 0, (Size) g->nterms * sizeof(bool));
	for (i = 0; i < (uint32) ncur; i++)
		g->present[cursors[i].termidx] = true;
	for (i = 0; i < g->q->nitems; i++)
	{
		if (g->q->items[i].type != FTS_QI_VAL)
			continue;
		if (odd[i])
			g->present[vi] = false;
		vi++;
	}
	pfree(odd);
	return bool_gate_admits(g);
}
/* END VERBATIM */
#else
/* mutant: a leaf under an odd number of NOTs is not cleared */
static bool
bool_gate_may_admit(BoolGate *g, const WandCursor *cursors, int ncur)
{
	uint32		i;

	memset(g->present, 0, (Size) g->nterms * sizeof(bool));
	for (i = 0; i < (uint32) ncur; i++)
		g->present[cursors[i].termidx] = true;
	return bool_gate_admits(g);
}
#endif

#ifndef TEETH_DRIVER
/* VERBATIM pg_fts_am_scan.c bool_gate_driver */
static double
bool_gate_driver(const BoolGate *g, const WandCursor *cursors, int ncur, bool *drv)
{
	FtsQuery	q = g->q;
	int		   *ops = (int *) palloc(Max(q->nitems, 1) * sizeof(int));	/* alloc-ok: query items */
	int		   *start = (int *) palloc(Max(q->nitems, 1) * sizeof(int));	/* alloc-ok: query items */
	bool	   *pos = (bool *) palloc(Max(q->nitems, 1) * sizeof(bool));	/* alloc-ok: query items */
	int		   *vord = (int *) palloc(Max(q->nitems, 1) * sizeof(int));	/* alloc-ok: query items */
	double	   *tdf = (double *) palloc0(Max(g->nterms, 1) * sizeof(double));	/* alloc-ok: query term count */
	int			nops = query_and_operands(q, ops, start, pos);
	int			best = -1,
				vi = 0,
				j;
	double		bestcost = -1;
	uint32		i;

	for (i = 0; i < q->nitems; i++)
		vord[i] = (q->items[i].type == FTS_QI_VAL) ? vi++ : -1;
	for (j = 0; j < ncur; j++)	/* a term's df over all its segment cursors, once */
		if (cursors[j].termidx >= 0 && cursors[j].termidx < g->nterms)
			tdf[cursors[j].termidx] += cursors[j].df;
	for (j = 0; j < nops; j++)
	{
		int			n = ops[j];
		double		cost = 0;
		int			m;

		if (!pos[n])
			continue;
		for (m = start[n]; m <= n; m++)
			if (vord[m] >= 0 && vord[m] < g->nterms)
				cost += tdf[vord[m]];
		if (best < 0 || cost < bestcost)
		{
			best = n;
			bestcost = cost;
		}
	}
	if (best >= 0)
	{
		memset(drv, 0, (Size) g->nterms * sizeof(bool));
		for (j = start[best]; j <= best; j++)
			if (vord[j] >= 0)
				drv[vord[j]] = true;
	}
	pfree(ops);
	pfree(start);
	pfree(pos);
	pfree(vord);
	pfree(tdf);
	return best >= 0 ? bestcost : -1;
}
/* END VERBATIM */
#else
/* mutant: any operand may drive, including one with a NOT */
static double
bool_gate_driver(const BoolGate *g, const WandCursor *cursors, int ncur, bool *drv)
{
	FtsQuery	q = g->q;
	int		   *ops = (int *) palloc(Max(q->nitems, 1) * sizeof(int));
	int		   *start = (int *) palloc(Max(q->nitems, 1) * sizeof(int));
	bool	   *pos = (bool *) palloc(Max(q->nitems, 1) * sizeof(bool));
	int			nops = query_and_operands(q, ops, start, pos);
	int			vi = 0,
				j,
				pick = nondet_int();
	uint32		i;
	int			vord[QN];

	(void) cursors;
	(void) ncur;
	if (nops == 0)
		return -1;
	__CPROVER_assume(pick >= 0 && pick < nops);
	for (i = 0; i < q->nitems; i++)
		vord[i] = (q->items[i].type == FTS_QI_VAL) ? vi++ : -1;
	memset(drv, 0, (Size) g->nterms * sizeof(bool));
	for (j = start[ops[pick]]; j <= ops[pick]; j++)
		if (vord[j] >= 0)
			drv[vord[j]] = true;
	return 0;
}
#endif

/* ---- the query generator ------------------------------------------------- */

static FtsQueryData qd;
static int	nleaves;

/*
 * A nondeterministic well-formed pure-boolean RPN: n items, each a leaf or
 * AND / OR / NOT, accepted exactly when ftsquery_recv would accept it
 * (operators have their operands, one root).  Leaves are plain terms
 * (flags 0), as the pure-boolean paths require.
 */
static FtsQuery
nondet_query(void)
{
	int			n = nondet_int();
	int			depth = 0,
				i;

	__CPROVER_assume(n >= 1 && n <= QN);
	qd.nitems = (uint32) n;
	nleaves = 0;
	for (i = 0; i < n; i++)
	{
		FtsQueryItem *it = &qd.items[i];
		uint8		kind = nondet_u8();

		memset(it, 0, sizeof(*it));
		__CPROVER_assume(kind <= 3);
		if (kind == 0)
		{
			it->type = FTS_QI_VAL;
			nleaves++;
			depth++;
		}
		else
		{
			it->type = FTS_QI_OPR;
			it->op = kind == 1 ? FTS_OP_NOT : kind == 2 ? FTS_OP_AND : FTS_OP_OR;
			__CPROVER_assume(depth >= (it->op == FTS_OP_NOT ? 1 : 2));
			if (it->op != FTS_OP_NOT)
				depth--;
		}
	}
	__CPROVER_assume(depth == 1);
	cur_q = &qd;
	return &qd;
}

static bool doc[QN];			/* doc[v]: term with VAL ordinal v present */
static bool stackbuf[QN];

static bool
matches(FtsQuery q, const bool *present)
{
	BoolGate	g;

	g.q = q;
	g.present = (bool *) present;
	g.stack = stackbuf;
	g.nterms = nleaves;
	g.phrase = NULL;
	return bool_gate_admits(&g);
}

/* evaluate the subtree [start, end] of q over present (reference for Q1) */
static bool
eval_sub(FtsQuery q, int s, int e, const bool *present)
{
	bool		st[QN];
	int			top = 0,
				vi = 0,
				i;

	for (i = 0; i < s; i++)
		if (q->items[i].type == FTS_QI_VAL)
			vi++;
	for (i = s; i <= e; i++)
	{
		FtsQueryItem *it = &q->items[i];

		if (it->type == FTS_QI_VAL)
			st[top++] = present[vi++];
		else if (it->op == FTS_OP_NOT)
			st[top - 1] = !st[top - 1];
		else if (it->op == FTS_OP_AND)
		{
			st[top - 2] = st[top - 2] && st[top - 1];
			top--;
		}
		else
		{
			st[top - 2] = st[top - 2] || st[top - 1];
			top--;
		}
	}
	return st[0];
}

void
harness_operands(void)			/* Q1 */
{
	FtsQuery	q = nondet_query();
	int			ops[QN],
				start[QN];
	bool		pos[QN];
	int			nops = query_and_operands(q, ops, start, pos);
	int			j,
				v;

	for (v = 0; v < nleaves; v++)
		doc[v] = nondet_bool();
	for (j = 0; j < nops; j++)
	{
		int			n = ops[j],
					m;

		__CPROVER_assert(n >= 0 && n < (int) q->nitems && start[n] <= n, "operand in range");
		if (matches(q, doc))
			__CPROVER_assert(eval_sub(q, start[n], n, doc), "Q1: every match satisfies every operand");
		if (pos[n])
			for (m = start[n]; m <= n; m++)
				__CPROVER_assert(q->items[m].type == FTS_QI_VAL || q->items[m].op != FTS_OP_NOT,
								 "Q1: pos[n] => no NOT in the subtree");
	}
}

void
harness_required_absent(void)	/* Q2 */
{
	FtsQuery	q = nondet_query();
	BM25SegMeta seg;
	int			v;

	for (v = 0; v < QN; v++)
		seg.has[v] = nondet_bool();
	/* a document of this segment holds only terms the segment has */
	for (v = 0; v < nleaves; v++)
	{
		doc[v] = nondet_bool();
		if (!seg.has[v])
			doc[v] = false;
	}
	if (bm25_required_term_absent(NULL, &seg, q))
		__CPROVER_assert(!matches(q, doc), "Q2: skipped segment has no match");
}

void
harness_may_admit(void)			/* Q3 */
{
	FtsQuery	q = nondet_query();
	WandCursor	cur[QN];
	bool		present[QN];
	bool		hascur[QN];
	BoolGate	g;
	int			ncur = 0,
				v;

	for (v = 0; v < nleaves; v++)
	{
		hascur[v] = nondet_bool();
		if (hascur[v])
		{
			cur[ncur].termidx = v;
			cur[ncur].df = 1;
			ncur++;
		}
		/* a document of the walk holds only terms that have a cursor */
		doc[v] = hascur[v] && nondet_bool();
	}
	g.q = q;
	g.present = present;
	g.stack = stackbuf;
	g.nterms = nleaves;
	g.phrase = NULL;
	if (!bool_gate_may_admit(&g, cur, ncur))
		__CPROVER_assert(!matches(q, doc), "Q3: may_admit false => no match");
}

void
harness_driver(void)			/* Q4 */
{
	FtsQuery	q = nondet_query();
	WandCursor	cur[QN];
	bool		present[QN];
	bool		drv[QN];
	BoolGate	g;
	int			v;
	bool		hit = false;

	for (v = 0; v < nleaves; v++)
	{
		cur[v].termidx = v;
		cur[v].df = nondet_u8();
		doc[v] = nondet_bool();
	}
	g.q = q;
	g.present = present;
	g.stack = stackbuf;
	g.nterms = nleaves;
	g.phrase = NULL;
	if (bool_gate_driver(&g, cur, nleaves, drv) < 0)
		return;
	for (v = 0; v < nleaves; v++)
		if (drv[v] && doc[v])
			hit = true;
	if (matches(q, doc))
		__CPROVER_assert(hit, "Q4: every match holds a driver term");
}

/* reference NOT parity: walk from item i to the root */
static bool
ref_parity(FtsQuery q, int target)
{
	int			parent[QN],
				stk[QN],
				sp = 0,
				i;
	bool		odd = false;

	for (i = 0; i < (int) q->nitems; i++)
	{
		parent[i] = -1;
		if (q->items[i].type == FTS_QI_VAL)
			stk[sp++] = i;
		else if (q->items[i].op == FTS_OP_NOT)
		{
			parent[stk[sp - 1]] = i;
			stk[sp - 1] = i;
		}
		else
		{
			parent[stk[sp - 1]] = i;
			parent[stk[sp - 2]] = i;
			sp--;
			stk[sp - 1] = i;
		}
	}
	for (i = parent[target]; i >= 0; i = parent[i])
		if (q->items[i].type != FTS_QI_VAL && q->items[i].op == FTS_OP_NOT)
			odd = !odd;
	return odd;
}

void
harness_parity(void)			/* Q5 */
{
	FtsQuery	q = nondet_query();
	bool	   *odd = eval_not_parity(q);
	int			i = nondet_int();

	__CPROVER_assume(i >= 0 && i < (int) q->nitems);
	__CPROVER_assert(odd[i] == ref_parity(q, i), "Q5: odd[i] == NOT parity of item i");
	free(odd);
}
