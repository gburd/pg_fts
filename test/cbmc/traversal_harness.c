/*-------------------------------------------------------------------------
 *
 * traversal_harness.c
 *		CBMC proof that the two docid-order ranked traversals,
 *		fts_search_bmw (block-max WAND) and fts_search_maxscore, return
 *		EXACTLY the top-k a brute-force ranking returns -- same documents,
 *		same scores, same order -- for every small posting configuration.
 *
 *	Both functions are VERBATIM copies (generated from the source and
 *	re-checked by check_verbatim.py), down to the heap admission and tie
 *	rules.  What is modelled is the cursor layer underneath them:
 *	wand_prime / wand_next / wand_seek / wand_skip_block walk an in-memory
 *	posting list cut into blocks of BLK postings, exactly as the real
 *	cursor does over pages (a block is loaded whole; seek moves forward to
 *	the first posting >= target, never backwards; a skip loads the next
 *	block).  The on-page decode under the real cursor is ondisk_harness's
 *	subject.
 *
 *	Scores are INTEGERS here: the copy is compiled with `double` meaning
 *	`int` (see below).  That proves the ALGORITHM -- pivot selection, the
 *	block-skip arithmetic, the essential/non-essential split, the heap and
 *	its tie order -- exact given sound bounds.  That the shipped IEEE bounds
 *	are sound is bound_harness's subject; integer scores make ties common,
 *	which is exactly where the tie rules are stressed.
 *
 *	INPUTS (bound): NT terms (2 for BMW, 4 for MaxScore: the dispatcher
 *	sends >= 4 terms to MaxScore), documents 1..ND, each term in any subset
 *	of them with a contribution 1..CMAX per posting; blocks of BLK postings;
 *	every block bound any value >= its postings' contributions and every
 *	term bound any value >= its block bounds (so ANY sound bound, not only
 *	the tight one); k fixed per run (-DK=1, 2).
 *
 *	PROPERTY: result count == min(k, #matching docs), and result[i] equals
 *	the reference's i-th (score descending, then docid ascending: the order
 *	cmp_scored_desc sorts by and WAND's strict "beats the threshold" admits
 *	by), for every i.
 *
 *	TEETH: -DTEETH_PIVOT_CLAMP re-adds the "always make progress" clamp
 *	(skipto <= pivot => pivot + 1) whose removal fixed the 1.3.0..1.15.1
 *	wrong top-k (ROADMAP I26, test bmw_block_end); -DTEETH_SUFFIX uses the
 *	1.10.0 suffix sum in MaxScore's essential split (the "film | music |
 *	album | band" wrong top-k, test ranked_exact).  Each must fail.
 *
 * IDENTIFICATION
 *	  test/cbmc/traversal_harness.c
 *
 *-------------------------------------------------------------------------
 */
#include "cbmc_pg.h"

#ifndef NT
#define NT 2
#endif
#ifndef ND
#define ND 5
#endif
#ifndef BLK
#define BLK 2
#endif
#ifndef CMAX
#define CMAX 3
#endif
#define BM25_BLOCK_SIZE BLK

/* integer scores: see the header comment (int, not long: half the SAT bits) */
#define double int

#define palloc(n) cbmc_palloc(n)
#define palloc0(n) memset(cbmc_palloc(n), 0, (n))
#define pfree(p) free(p)
#define CHECK_FOR_INTERRUPTS() ((void) 0)
#define pg_noinline

/* heap TIDs: a docid stands for its TID (bm25_docid_to_tid is monotone, so
 * ItemPointerCompare orders TIDs as docids) */
typedef struct ItemPointerData
{
	uint64		d;
} ItemPointerData;
typedef ItemPointerData *ItemPointer;
static inline int
ItemPointerCompare(ItemPointer a, ItemPointer b)
{
	return a->d < b->d ? -1 : a->d > b->d ? 1 : 0;
}
static inline void
bm25_docid_to_tid(uint64 docid, ItemPointer tid)
{
	tid->d = docid;
}

typedef struct ScoredTid
{
	ItemPointerData tid;
	double		score;
} ScoredTid;

/* the cursor: the fields the traversals read, over a model posting list */
typedef struct WandCursor
{
	/* model posting list for this term */
	int			np;				/* postings */
	uint64		pdoc[ND];		/* ascending docids */
	int			pcontrib[ND];	/* contribution of each posting */
	int			pblkbound[ND];	/* bound of the block holding posting i */
	int			blkstart;		/* index of the current block's first posting */
	/* the fields the traversal reads (pg_fts_am_scan.c WandCursor) */
	uint64		docids[BM25_BLOCK_SIZE];
	int			blkcount;
	int			cur;
	uint64		docid;
	int			max_contrib;
	int			termidx;
	uint32		segidx;
	uint32		df;
	unsigned char *blkbuf;
	unsigned char *posbuf;
	int		   *posoff;
	int			doclenc;
} WandCursor;

typedef struct DocidFilter DocidFilter;
typedef struct BoolGate BoolGate;
static inline bool
docid_admitted(const DocidFilter *f, uint64 docid)
{
	(void) f;
	(void) docid;
	return true;
}
static inline bool
bmw_gate_admits(BoolGate *g, WandCursor *cursors, int nterms, uint64 pivot_docid)
{
	(void) g;
	(void) cursors;
	(void) nterms;
	(void) pivot_docid;
	return true;
}
static inline void
bm25_doclen_cursor_free(int *c)
{
	(void) c;
}

/* load the block starting at posting index s (or exhaust) */
static void
model_load(WandCursor *c, int s)
{
	int			i;

	c->blkstart = s;
	c->cur = 0;
	if (s >= c->np)
	{
		c->blkcount = 0;
		c->docid = UINT64_MAX;
		return;
	}
	c->blkcount = (c->np - s < BLK) ? c->np - s : BLK;
	for (i = 0; i < c->blkcount; i++)
		c->docids[i] = c->pdoc[s + i];
	c->docid = c->docids[0];
}

static void
wand_prime(WandCursor *c)
{
	model_load(c, 0);
}

static void
wand_next(WandCursor *c)
{
	c->cur++;
	if (c->cur < c->blkcount)
		c->docid = c->docids[c->cur];
	else
		model_load(c, c->blkstart + c->blkcount);
}

/* first posting >= target, forward only, whole blocks skipped as needed */
static void
wand_seek_model(WandCursor *c, uint64 target)
{
	if (c->docid == UINT64_MAX || c->docid >= target)
		return;
	for (;;)
	{
		while (c->cur < c->blkcount && c->docids[c->cur] < target)
			c->cur++;
		if (c->cur < c->blkcount)
		{
			c->docid = c->docids[c->cur];
			return;
		}
		model_load(c, c->blkstart + c->blkcount);
		if (c->docid == UINT64_MAX)
			return;
	}
}

static void
wand_seek(WandCursor *c, uint64 target)
{
	wand_seek_model(c, target);
}

static void
wand_skip_block(WandCursor *c)
{
	model_load(c, c->blkstart + c->blkcount);
}

static inline int
wand_contrib_cur(WandCursor *c)
{
	return c->pcontrib[c->blkstart + c->cur];
}

static inline int
wand_block_max_contrib(WandCursor *c)
{
	return c->pblkbound[c->blkstart + c->cur];
}

/* qsort over ScoredTid with cmp_scored_desc (insertion sort: tiny inputs) */
static int cmp_scored_desc(const void *a, const void *b);
static void
model_qsort(void *base, size_t n, size_t sz, int (*cmp) (const void *, const void *))
{
	ScoredTid  *h = (ScoredTid *) base;
	size_t		i,
				j;

	(void) sz;
	for (i = 1; i < n; i++)
		for (j = i; j > 0 && cmp(&h[j - 1], &h[j]) > 0; j--)
		{
			ScoredTid	t = h[j];

			h[j] = h[j - 1];
			h[j - 1] = t;
		}
}
#define qsort(b, n, s, c) model_qsort((b), (n), (s), (c))

/* VERBATIM pg_fts_am_scan.c wand_cursor_before */
static inline bool
wand_cursor_before(const WandCursor *a, const WandCursor *b)
{
	if (a->docid != b->docid)
		return a->docid < b->docid;
	if (a->termidx != b->termidx)
		return a->termidx < b->termidx;
	return a->segidx < b->segidx;
}
/* END VERBATIM */

/* VERBATIM pg_fts_am_scan.c scored_worse */
static inline bool
scored_worse(const ScoredTid *a, const ScoredTid *b)
{
	if (a->score != b->score)
		return a->score < b->score;
	return ItemPointerCompare((ItemPointer) &a->tid, (ItemPointer) &b->tid) > 0;
}
/* END VERBATIM */

/* VERBATIM pg_fts_am_scan.c cmp_scored_desc */
static int
cmp_scored_desc(const void *a, const void *b)
{
	double		sa = ((const ScoredTid *) a)->score;
	double		sb = ((const ScoredTid *) b)->score;

	if (sa < sb)
		return 1;
	if (sa > sb)
		return -1;
	/*
	 * Ties: ascending TID.  WAND admits a doc only when it STRICTLY beats the
	 * threshold and walks docids ascending, so among equal scores the lowest
	 * docids are the ones kept.  Ordering ties the same way makes a top-k batch a
	 * prefix of every larger batch, which the ordering scan's grow-and-resume
	 * (ordpos = prev) relies on; an unstable tie order could repeat or skip a
	 * row across a recompute.  More recomputes happen since 1.9.0's LIMIT hint.
	 */
	return ItemPointerCompare((ItemPointer) &((const ScoredTid *) a)->tid,
							  (ItemPointer) &((const ScoredTid *) b)->tid);
}
/* END VERBATIM */

/* VERBATIM pg_fts_am_scan.c sum_term_order */
static inline double
sum_term_order(double *acc, int nq)
{
	double		s = 0.0;
	int			t;

	for (t = 0; t < nq; t++)
		if (acc[t] != 0.0)
		{
			s += acc[t];
			acc[t] = 0.0;
		}
	return s;
}
/* END VERBATIM */

/* VERBATIM pg_fts_am_scan.c cursors_nq */
static int
cursors_nq(const WandCursor *cursors, int nterms)
{
	int			nq = 0,
				i;

	for (i = 0; i < nterms; i++)
		nq = Max(nq, cursors[i].termidx + 1);
	return nq;
}
/* END VERBATIM */

#ifndef TEETH_PIVOT_CLAMP
/* VERBATIM pg_fts_am_scan.c fts_search_bmw */
static int
fts_search_bmw(WandCursor *cursors, int nterms, int k, const DocidFilter *filter,
			   BoolGate *gate, ScoredTid **out)
{
	ScoredTid  *heap;			/* min-heap of current top-k by score */
	int			nheap = 0;
	double		threshold = 0.0;
	int			t;
	int			nq = cursors_nq(cursors, nterms);
	double	   *acc = (double *) palloc0(Max(nq, 1) * sizeof(double));	/* alloc-ok: nq = query term count */

	heap = (ScoredTid *) palloc(Max(k, 1) * sizeof(ScoredTid));

	/* prime each cursor with its first page */
	for (t = 0; t < nterms; t++)
		wand_prime(&cursors[t]);

	for (;;)
	{
		int			i,
					j;
		uint64		pivot_docid;
		double		maxsum;
		double		score;

		CHECK_FOR_INTERRUPTS();	/* per document-at-a-time step; cursor blocks are palloc'd copies, no lock held */

		/* selection-sort by docid and fixed term identity (nterms is small) */
		for (i = 0; i < nterms; i++)
			for (j = i + 1; j < nterms; j++)
				if (wand_cursor_before(&cursors[j], &cursors[i]))
				{
					WandCursor	tmp = cursors[i];

					cursors[i] = cursors[j];
					cursors[j] = tmp;
				}

		if (cursors[0].docid == UINT64_MAX)
			break;				/* all exhausted */

		/*
		 * WAND pivot: accumulate max_contrib in docid order until the running
		 * sum could exceed the threshold; that cursor's docid is the pivot.
		 */
		maxsum = 0.0;
		pivot_docid = UINT64_MAX;
		for (i = 0; i < nterms; i++)
		{
			if (cursors[i].docid == UINT64_MAX)
				break;
			maxsum += cursors[i].max_contrib;
			if (maxsum > threshold || nheap < k)
			{
				pivot_docid = cursors[i].docid;
				break;
			}
		}
		if (pivot_docid == UINT64_MAX)
			break;				/* no document can beat the threshold */

		/*
		 * Block-max WAND (BMW) refinement: the pivot passed the term-wide
		 * bound, but the *current blocks* may bound tighter.  Sum the per-block
		 * max contribution of every cursor whose docid <= pivot; if even that
		 * cannot beat the threshold, no document up to the pivot can enter the
		 * top-k, so skip the earliest cursor past its current 128-block instead
		 * of scoring.  Sound because block max_tf >= every tf in the block.
		 */
		if (nheap >= k)
		{
			double		blocksum = 0.0;
			int			nle = 0;		/* cursors with docid <= pivot */
			int			lei = -1;		/* index of the (single) such cursor */

			for (i = 0; i < nterms; i++)
			{
				if (cursors[i].docid == UINT64_MAX)
					break;
				if (cursors[i].docid <= pivot_docid)
				{
					blocksum += wand_block_max_contrib(&cursors[i]);
					nle++;
					lei = i;
				}
			}
			if (blocksum <= threshold)
			{
				/*
				 * FAST PATH -- exactly one cursor is at/before the pivot AND
				 * no other term's cursor falls within that cursor's current
				 * block's docid range.  Then blocksum bounded the WHOLE block,
				 * every docid in it contains ONLY this term (all other cursors
				 * sit strictly past the block's last docid), so no document in
				 * the block -- even under a conjunctive/AND score -- can beat the
				 * threshold.  Skipping the entire block is exact and O(1).
				 *
				 * The block-range guard is essential for correctness with
				 * multi-term AND: "other cursors are past the PIVOT" does NOT
				 * imply "past the block"; a cursor at docid in (pivot, blocklast]
				 * means a document in the skipped range could contain BOTH terms
				 * and score sum-of-both -- which blocksum (one term) never
				 * bounded.  Skipping it then drops true top-k AND docs (the
				 * pre-existing multi-term AND recall gap).
				 *
				 * SAFE PATH -- two or more cursors sit at/before the pivot, OR a
				 * cursor overlaps the block's docid range: advance every cursor
				 * at-or-before the pivot to the earliest current block end + 1 (or
				 * the first later cursor), below.  The current-block bounds only
				 * cover postings through the earliest current block end; a later
				 * block before the pivot may have a higher contribution.
				 */
				bool		block_isolated = false;

				if (nle == 1 && cursors[lei].blkcount > 0)
				{
					uint64		blocklast = cursors[lei].docids[cursors[lei].blkcount - 1];

					block_isolated = true;
					for (i = 0; i < nterms; i++)
						if (i != lei && cursors[i].docid != UINT64_MAX &&
							cursors[i].docid <= blocklast)
						{
							block_isolated = false;
							break;
						}
				}
				if (block_isolated)
					wand_skip_block(&cursors[lei]);
				else
				{
					/*
					 * Block-max WAND skip (1.11.0).  blocksum bounds every
					 * document in [pivot, d) where d is the smallest of
					 *   - one past the last docid of any at-or-before cursor's
					 *     current block (beyond it that cursor's bound changes),
					 *   - the docid of the first cursor AFTER the pivot (from
					 *     there that term can add its contribution).
					 * No document below d can beat the threshold, so every
					 * at-or-before cursor may jump to d.  The 1.10.0 code
					 * advanced only to pivot+1, which on a two-common-term OR
					 * was ~240k seeks to score ~94k postings.  With the
					 * effective-length block bounds this branch is the common
					 * one, so the jump is what makes them pay off.
					 */
					uint64		skipto = UINT64_MAX;

					for (i = 0; i < nterms; i++)
					{
						if (cursors[i].docid == UINT64_MAX)
							continue;
						if (cursors[i].docid <= pivot_docid)
						{
							if (cursors[i].blkcount > 0)
							{
								uint64		last = cursors[i].docids[cursors[i].blkcount - 1];

								if (last + 1 < skipto)
									skipto = last + 1;
							}
							else if (pivot_docid + 1 < skipto)
								skipto = pivot_docid + 1;
						}
						else if (cursors[i].docid < skipto)
							skipto = cursors[i].docid;
					}
					/*
					 * No "always make progress" clamp to pivot + 1 (1.15.2,
					 * from jimdawdy-hub/pg_fts e4bba08): when an at-or-before
					 * cursor's current block ends before the pivot, skipto is
					 * at or below it, and a later block of that term may score
					 * the pivot higher than blocksum did -- jumping past the
					 * pivot dropped it unscored (a wrong top-k, test
					 * bmw_block_end).  Progress holds without it: that cursor
					 * sits at or below its block end, so it moves to skipto.
					 */
					for (i = 0; i < nterms; i++)
						if (cursors[i].docid != UINT64_MAX &&
							cursors[i].docid <= pivot_docid)
							wand_seek(&cursors[i], skipto);
				}
				continue;
			}
		}

		/* if the smallest docid equals the pivot, score it fully */
		if (cursors[0].docid == pivot_docid)
		{
			ItemPointerData tid;

			bm25_docid_to_tid(pivot_docid, &tid);

			for (i = 0; i < nterms; i++)
				if (cursors[i].docid == pivot_docid)
					acc[cursors[i].termidx] += wand_contrib_cur(&cursors[i]);
			score = sum_term_order(acc, nq);

			/* push into the top-k min-heap -- but only if the docid is admitted
			 * by the boolean match-set gate.  Two equivalent gates:
			 *  - DocidFilter (filter): binary-search a pre-collected @@@ set
			 *    (used for non-pure-boolean: phrase/near/prefix/fuzzy/regex).
			 *  - BoolGate (gate): evaluate the query's RPN LAZILY over which
			 *    terms have a cursor at the pivot (pure-boolean AND/NOT); no
			 *    collect pass.  For pure-OR both are NULL (admit all).
			 * A rejected doc does NOT count toward k and does NOT raise the
			 * threshold; the traversal and its block-skip math are unchanged
			 * (the threshold may just stay lower longer, costing pruning only,
			 * never correctness). */
			/* a doc that cannot enter a full heap (score <= threshold: the
			 * replace branch below needs score > threshold) never needs the
			 * gate -- for the lazy phrase gate that skips a positions decode */
			if ((nheap < k || score > threshold) &&
				docid_admitted(filter, pivot_docid) &&
				bmw_gate_admits(gate, cursors, nterms, pivot_docid))
			{
			if (nheap < k)
			{
				heap[nheap].tid = tid;
				heap[nheap].score = score;
				nheap++;
				if (nheap == k)
				{
					threshold = heap[0].score;
					for (i = 1; i < nheap; i++)
						if (heap[i].score < threshold)
							threshold = heap[i].score;
				}
			}
			else if (score > threshold)
			{
				int			minpos = 0;

				for (i = 1; i < nheap; i++)
					if (scored_worse(&heap[i], &heap[minpos]))
						minpos = i;
				heap[minpos].tid = tid;
				heap[minpos].score = score;
				threshold = heap[0].score;
				for (i = 1; i < nheap; i++)
					if (heap[i].score < threshold)
						threshold = heap[i].score;
			}
			}					/* end docid_admitted gate */

			/* advance every cursor positioned at the pivot */
			for (i = 0; i < nterms; i++)
				if (cursors[i].docid == pivot_docid)
					wand_next(&cursors[i]);
		}
		else
		{
			/*
			 * Advance every cursor before the pivot up to pivot_docid.  Use a
			 * seek (block-skipping) rather than stepping one posting at a time:
			 * for a high-df term this skips entire 128-blocks whose docids are
			 * all below the pivot, instead of decoding hundreds of thousands of
			 * postings individually (the Q5/Q7 cost).
			 */
			for (i = 0; i < nterms; i++)
				if (cursors[i].docid < pivot_docid)
					wand_seek(&cursors[i], pivot_docid);
		}
	}

	/* release any still-loaded block buffers + doclen page directories */
	for (t = 0; t < nterms; t++)
	{
		if (cursors[t].blkbuf)
			pfree(cursors[t].blkbuf);
		if (cursors[t].posbuf)
			pfree(cursors[t].posbuf);
		if (cursors[t].posoff)
			pfree(cursors[t].posoff);
		cursors[t].blkbuf = NULL;
		cursors[t].posbuf = NULL;
		cursors[t].posoff = NULL;
		bm25_doclen_cursor_free(&cursors[t].doclenc);
	}

	pfree(acc);
	qsort(heap, nheap, sizeof(ScoredTid), cmp_scored_desc);
	*out = heap;
	return nheap;
}
/* END VERBATIM */
#else
static int
fts_search_bmw(WandCursor *cursors, int nterms, int k, const DocidFilter *filter,
			   BoolGate *gate, ScoredTid **out)
{
	ScoredTid  *heap;			/* min-heap of current top-k by score */
	int			nheap = 0;
	double		threshold = 0.0;
	int			t;
	int			nq = cursors_nq(cursors, nterms);
	double	   *acc = (double *) palloc0(Max(nq, 1) * sizeof(double));	/* alloc-ok: nq = query term count */

	heap = (ScoredTid *) palloc(Max(k, 1) * sizeof(ScoredTid));

	/* prime each cursor with its first page */
	for (t = 0; t < nterms; t++)
		wand_prime(&cursors[t]);

	for (;;)
	{
		int			i,
					j;
		uint64		pivot_docid;
		double		maxsum;
		double		score;

		CHECK_FOR_INTERRUPTS();	/* per document-at-a-time step; cursor blocks are palloc'd copies, no lock held */

		/* selection-sort by docid and fixed term identity (nterms is small) */
		for (i = 0; i < nterms; i++)
			for (j = i + 1; j < nterms; j++)
				if (wand_cursor_before(&cursors[j], &cursors[i]))
				{
					WandCursor	tmp = cursors[i];

					cursors[i] = cursors[j];
					cursors[j] = tmp;
				}

		if (cursors[0].docid == UINT64_MAX)
			break;				/* all exhausted */

		/*
		 * WAND pivot: accumulate max_contrib in docid order until the running
		 * sum could exceed the threshold; that cursor's docid is the pivot.
		 */
		maxsum = 0.0;
		pivot_docid = UINT64_MAX;
		for (i = 0; i < nterms; i++)
		{
			if (cursors[i].docid == UINT64_MAX)
				break;
			maxsum += cursors[i].max_contrib;
			if (maxsum > threshold || nheap < k)
			{
				pivot_docid = cursors[i].docid;
				break;
			}
		}
		if (pivot_docid == UINT64_MAX)
			break;				/* no document can beat the threshold */

		/*
		 * Block-max WAND (BMW) refinement: the pivot passed the term-wide
		 * bound, but the *current blocks* may bound tighter.  Sum the per-block
		 * max contribution of every cursor whose docid <= pivot; if even that
		 * cannot beat the threshold, no document up to the pivot can enter the
		 * top-k, so skip the earliest cursor past its current 128-block instead
		 * of scoring.  Sound because block max_tf >= every tf in the block.
		 */
		if (nheap >= k)
		{
			double		blocksum = 0.0;
			int			nle = 0;		/* cursors with docid <= pivot */
			int			lei = -1;		/* index of the (single) such cursor */

			for (i = 0; i < nterms; i++)
			{
				if (cursors[i].docid == UINT64_MAX)
					break;
				if (cursors[i].docid <= pivot_docid)
				{
					blocksum += wand_block_max_contrib(&cursors[i]);
					nle++;
					lei = i;
				}
			}
			if (blocksum <= threshold)
			{
				/*
				 * FAST PATH -- exactly one cursor is at/before the pivot AND
				 * no other term's cursor falls within that cursor's current
				 * block's docid range.  Then blocksum bounded the WHOLE block,
				 * every docid in it contains ONLY this term (all other cursors
				 * sit strictly past the block's last docid), so no document in
				 * the block -- even under a conjunctive/AND score -- can beat the
				 * threshold.  Skipping the entire block is exact and O(1).
				 *
				 * The block-range guard is essential for correctness with
				 * multi-term AND: "other cursors are past the PIVOT" does NOT
				 * imply "past the block"; a cursor at docid in (pivot, blocklast]
				 * means a document in the skipped range could contain BOTH terms
				 * and score sum-of-both -- which blocksum (one term) never
				 * bounded.  Skipping it then drops true top-k AND docs (the
				 * pre-existing multi-term AND recall gap).
				 *
				 * SAFE PATH -- two or more cursors sit at/before the pivot, OR a
				 * cursor overlaps the block's docid range: advance every cursor
				 * at-or-before the pivot to the earliest current block end + 1 (or
				 * the first later cursor), below.  The current-block bounds only
				 * cover postings through the earliest current block end; a later
				 * block before the pivot may have a higher contribution.
				 */
				bool		block_isolated = false;

				if (nle == 1 && cursors[lei].blkcount > 0)
				{
					uint64		blocklast = cursors[lei].docids[cursors[lei].blkcount - 1];

					block_isolated = true;
					for (i = 0; i < nterms; i++)
						if (i != lei && cursors[i].docid != UINT64_MAX &&
							cursors[i].docid <= blocklast)
						{
							block_isolated = false;
							break;
						}
				}
				if (block_isolated)
					wand_skip_block(&cursors[lei]);
				else
				{
					/*
					 * Block-max WAND skip (1.11.0).  blocksum bounds every
					 * document in [pivot, d) where d is the smallest of
					 *   - one past the last docid of any at-or-before cursor's
					 *     current block (beyond it that cursor's bound changes),
					 *   - the docid of the first cursor AFTER the pivot (from
					 *     there that term can add its contribution).
					 * No document below d can beat the threshold, so every
					 * at-or-before cursor may jump to d.  The 1.10.0 code
					 * advanced only to pivot+1, which on a two-common-term OR
					 * was ~240k seeks to score ~94k postings.  With the
					 * effective-length block bounds this branch is the common
					 * one, so the jump is what makes them pay off.
					 */
					uint64		skipto = UINT64_MAX;

					for (i = 0; i < nterms; i++)
					{
						if (cursors[i].docid == UINT64_MAX)
							continue;
						if (cursors[i].docid <= pivot_docid)
						{
							if (cursors[i].blkcount > 0)
							{
								uint64		last = cursors[i].docids[cursors[i].blkcount - 1];

								if (last + 1 < skipto)
									skipto = last + 1;
							}
							else if (pivot_docid + 1 < skipto)
								skipto = pivot_docid + 1;
						}
						else if (cursors[i].docid < skipto)
							skipto = cursors[i].docid;
					}
					/*
					 * No "always make progress" clamp to pivot + 1 (1.15.2,
					 * from jimdawdy-hub/pg_fts e4bba08): when an at-or-before
					 * cursor's current block ends before the pivot, skipto is
					 * at or below it, and a later block of that term may score
					 * the pivot higher than blocksum did -- jumping past the
					 * pivot dropped it unscored (a wrong top-k, test
					 * bmw_block_end).  Progress holds without it: that cursor
					 * sits at or below its block end, so it moves to skipto.
					 */
					if (skipto <= pivot_docid)
						skipto = pivot_docid + 1;	/* 1.3.0..1.15.1 */
					for (i = 0; i < nterms; i++)
						if (cursors[i].docid != UINT64_MAX &&
							cursors[i].docid <= pivot_docid)
							wand_seek(&cursors[i], skipto);
				}
				continue;
			}
		}

		/* if the smallest docid equals the pivot, score it fully */
		if (cursors[0].docid == pivot_docid)
		{
			ItemPointerData tid;

			bm25_docid_to_tid(pivot_docid, &tid);

			for (i = 0; i < nterms; i++)
				if (cursors[i].docid == pivot_docid)
					acc[cursors[i].termidx] += wand_contrib_cur(&cursors[i]);
			score = sum_term_order(acc, nq);

			/* push into the top-k min-heap -- but only if the docid is admitted
			 * by the boolean match-set gate.  Two equivalent gates:
			 *  - DocidFilter (filter): binary-search a pre-collected @@@ set
			 *    (used for non-pure-boolean: phrase/near/prefix/fuzzy/regex).
			 *  - BoolGate (gate): evaluate the query's RPN LAZILY over which
			 *    terms have a cursor at the pivot (pure-boolean AND/NOT); no
			 *    collect pass.  For pure-OR both are NULL (admit all).
			 * A rejected doc does NOT count toward k and does NOT raise the
			 * threshold; the traversal and its block-skip math are unchanged
			 * (the threshold may just stay lower longer, costing pruning only,
			 * never correctness). */
			/* a doc that cannot enter a full heap (score <= threshold: the
			 * replace branch below needs score > threshold) never needs the
			 * gate -- for the lazy phrase gate that skips a positions decode */
			if ((nheap < k || score > threshold) &&
				docid_admitted(filter, pivot_docid) &&
				bmw_gate_admits(gate, cursors, nterms, pivot_docid))
			{
			if (nheap < k)
			{
				heap[nheap].tid = tid;
				heap[nheap].score = score;
				nheap++;
				if (nheap == k)
				{
					threshold = heap[0].score;
					for (i = 1; i < nheap; i++)
						if (heap[i].score < threshold)
							threshold = heap[i].score;
				}
			}
			else if (score > threshold)
			{
				int			minpos = 0;

				for (i = 1; i < nheap; i++)
					if (scored_worse(&heap[i], &heap[minpos]))
						minpos = i;
				heap[minpos].tid = tid;
				heap[minpos].score = score;
				threshold = heap[0].score;
				for (i = 1; i < nheap; i++)
					if (heap[i].score < threshold)
						threshold = heap[i].score;
			}
			}					/* end docid_admitted gate */

			/* advance every cursor positioned at the pivot */
			for (i = 0; i < nterms; i++)
				if (cursors[i].docid == pivot_docid)
					wand_next(&cursors[i]);
		}
		else
		{
			/*
			 * Advance every cursor before the pivot up to pivot_docid.  Use a
			 * seek (block-skipping) rather than stepping one posting at a time:
			 * for a high-df term this skips entire 128-blocks whose docids are
			 * all below the pivot, instead of decoding hundreds of thousands of
			 * postings individually (the Q5/Q7 cost).
			 */
			for (i = 0; i < nterms; i++)
				if (cursors[i].docid < pivot_docid)
					wand_seek(&cursors[i], pivot_docid);
		}
	}

	/* release any still-loaded block buffers + doclen page directories */
	for (t = 0; t < nterms; t++)
	{
		if (cursors[t].blkbuf)
			pfree(cursors[t].blkbuf);
		if (cursors[t].posbuf)
			pfree(cursors[t].posbuf);
		if (cursors[t].posoff)
			pfree(cursors[t].posoff);
		cursors[t].blkbuf = NULL;
		cursors[t].posbuf = NULL;
		cursors[t].posoff = NULL;
		bm25_doclen_cursor_free(&cursors[t].doclenc);
	}

	pfree(acc);
	qsort(heap, nheap, sizeof(ScoredTid), cmp_scored_desc);
	*out = heap;
	return nheap;
}
#endif

#ifndef TEETH_SUFFIX
/* VERBATIM pg_fts_am_scan.c fts_search_maxscore */
static int
fts_search_maxscore(WandCursor *cursors, int nterms, int k,
					const DocidFilter *filter, BoolGate *gate, ScoredTid **out)
{
	ScoredTid  *heap;
	int			nheap = 0;
	double		threshold = 0.0;
	double	   *suffix;			/* suffix[i] = sum of max_contrib over [0, i) (a
								 * prefix sum; name kept for the diff) */
	int			t,
				i,
				j;
	int			first_essential;	/* cursors[first_essential..) are essential */
	int			nq = cursors_nq(cursors, nterms);
	double	   *acc = (double *) palloc0(Max(nq, 1) * sizeof(double));	/* alloc-ok: nq = query term count */

	heap = (ScoredTid *) palloc(Max(k, 1) * sizeof(ScoredTid));
	suffix = (double *) palloc((nterms + 1) * sizeof(double));	/* alloc-ok: nterms = query term count */

	for (t = 0; t < nterms; t++)
		wand_prime(&cursors[t]);

	/* order cursors by ascending term-wide max_contrib (once; it is static) */
	for (i = 0; i < nterms; i++)
		for (j = i + 1; j < nterms; j++)
			if (cursors[j].max_contrib < cursors[i].max_contrib)
			{
				WandCursor	tmp = cursors[i];

				cursors[i] = cursors[j];
				cursors[j] = tmp;
			}
	/*
	 * prefix[i] = sum of max_contrib over cursors [0, i): the most the first i
	 * (lowest-impact) terms can add to any document.  1.10.0 used a SUFFIX sum
	 * here and declared term i non-essential when the terms AFTER it could not
	 * reach the threshold -- the wrong side: it then iterated candidates only
	 * from the high-impact terms and missed documents whose score came mostly
	 * from the "non-essential" ones.  Found by an exhaustive-reference check
	 * (bench/data_A_2026-10-07): a 4-term OR returned none of the true top-10.
	 */
	suffix[0] = 0.0;
	for (i = 0; i < nterms; i++)
		suffix[i + 1] = suffix[i] + cursors[i].max_contrib;

	first_essential = 0;

	for (;;)
	{
		uint64		cand = UINT64_MAX;
		double		score;

		CHECK_FOR_INTERRUPTS();	/* per document-at-a-time step; cursor blocks are palloc'd copies, no lock held */

		/* recompute the essential boundary from the current threshold: the
		 * longest low-impact prefix whose max_contrib sum <= threshold is
		 * non-essential */
		if (nheap >= k)
		{
			/* terms [0, first_essential] together cannot beat the threshold:
			 * a document containing only those terms cannot enter the top-k */
			while (first_essential < nterms &&
				   suffix[first_essential + 1] <= threshold)
				first_essential++;
		}

		/* smallest docid among essential cursors drives the iteration */
		for (i = first_essential; i < nterms; i++)
			if (cursors[i].docid < cand)
				cand = cursors[i].docid;
		if (cand == UINT64_MAX)
			break;				/* essential cursors exhausted */

		/* score cand: essential contributions + upper bound of non-essentials;
		 * the exact score is summed in query-term order (sum_term_order) */
		score = 0.0;
		for (i = first_essential; i < nterms; i++)
			if (cursors[i].docid == cand)
			{
				double		c = wand_contrib_cur(&cursors[i]);

				score += c;
				acc[cursors[i].termidx] += c;
			}

		/* early-exit check: essential score + every non-essential term's max
		 * (prefix sum over [0, first_essential)) <= threshold => cand cannot
		 * make the top-k, skip the non-essential lookups */
		if (nheap >= k && score + suffix[first_essential] <= threshold)
			(void) sum_term_order(acc, nq);	/* clears acc */
		else
		{
			/* add exact non-essential contributions by seeking to cand */
			for (i = 0; i < first_essential; i++)
			{
				wand_seek(&cursors[i], cand);
				if (cursors[i].docid == cand)
					acc[cursors[i].termidx] += wand_contrib_cur(&cursors[i]);
			}
			score = sum_term_order(acc, nq);

			/* gate heap admission by the boolean match-set (DocidFilter for
			 * non-pure-boolean, or the lazy BoolGate over term-presence at cand
			 * for pure-boolean AND/NOT).  A rejected doc never enters the heap
			 * and never raises the threshold.  The essential/non-essential
			 * traversal (incl. the non-essential seeks above) is unchanged --
			 * only heap insertion is gated. */
			if ((nheap < k || score > threshold) &&
				docid_admitted(filter, cand) &&
				bmw_gate_admits(gate, cursors, nterms, cand))
			{
			if (nheap < k)
			{
				ItemPointerData tid;

				bm25_docid_to_tid(cand, &tid);
				heap[nheap].tid = tid;
				heap[nheap].score = score;
				nheap++;
				if (nheap == k)
				{
					threshold = heap[0].score;
					for (i = 1; i < nheap; i++)
						if (heap[i].score < threshold)
							threshold = heap[i].score;
				}
			}
			else if (score > threshold)
			{
				ItemPointerData tid;
				int			minpos = 0;

				bm25_docid_to_tid(cand, &tid);
				for (i = 1; i < nheap; i++)
					if (scored_worse(&heap[i], &heap[minpos]))
						minpos = i;
				heap[minpos].tid = tid;
				heap[minpos].score = score;
				threshold = heap[0].score;
				for (i = 1; i < nheap; i++)
					if (heap[i].score < threshold)
						threshold = heap[i].score;
			}
			}					/* end docid_admitted gate */
		}

		/* advance every essential cursor sitting at cand */
		for (i = first_essential; i < nterms; i++)
			if (cursors[i].docid == cand)
				wand_next(&cursors[i]);
	}

	for (t = 0; t < nterms; t++)
	{
		if (cursors[t].blkbuf)
			pfree(cursors[t].blkbuf);
		if (cursors[t].posbuf)
			pfree(cursors[t].posbuf);
		if (cursors[t].posoff)
			pfree(cursors[t].posoff);
		cursors[t].blkbuf = NULL;
		cursors[t].posbuf = NULL;
		cursors[t].posoff = NULL;
		bm25_doclen_cursor_free(&cursors[t].doclenc);
	}

	pfree(acc);
	qsort(heap, nheap, sizeof(ScoredTid), cmp_scored_desc);
	*out = heap;
	return nheap;
}
/* END VERBATIM */
#else
static int
fts_search_maxscore(WandCursor *cursors, int nterms, int k,
					const DocidFilter *filter, BoolGate *gate, ScoredTid **out)
{
	ScoredTid  *heap;
	int			nheap = 0;
	double		threshold = 0.0;
	double	   *suffix;			/* suffix[i] = sum of max_contrib over [0, i) (a
								 * prefix sum; name kept for the diff) */
	int			t,
				i,
				j;
	int			first_essential;	/* cursors[first_essential..) are essential */
	int			nq = cursors_nq(cursors, nterms);
	double	   *acc = (double *) palloc0(Max(nq, 1) * sizeof(double));	/* alloc-ok: nq = query term count */

	heap = (ScoredTid *) palloc(Max(k, 1) * sizeof(ScoredTid));
	suffix = (double *) palloc((nterms + 1) * sizeof(double));	/* alloc-ok: nterms = query term count */

	for (t = 0; t < nterms; t++)
		wand_prime(&cursors[t]);

	/* order cursors by ascending term-wide max_contrib (once; it is static) */
	for (i = 0; i < nterms; i++)
		for (j = i + 1; j < nterms; j++)
			if (cursors[j].max_contrib < cursors[i].max_contrib)
			{
				WandCursor	tmp = cursors[i];

				cursors[i] = cursors[j];
				cursors[j] = tmp;
			}
	/*
	 * prefix[i] = sum of max_contrib over cursors [0, i): the most the first i
	 * (lowest-impact) terms can add to any document.  1.10.0 used a SUFFIX sum
	 * here and declared term i non-essential when the terms AFTER it could not
	 * reach the threshold -- the wrong side: it then iterated candidates only
	 * from the high-impact terms and missed documents whose score came mostly
	 * from the "non-essential" ones.  Found by an exhaustive-reference check
	 * (bench/data_A_2026-10-07): a 4-term OR returned none of the true top-10.
	 */
	suffix[nterms] = 0.0;	/* 1.10.0 */
	for (i = nterms - 1; i >= 0; i--)
		suffix[i] = suffix[i + 1] + cursors[i].max_contrib;

	first_essential = 0;

	for (;;)
	{
		uint64		cand = UINT64_MAX;
		double		score;

		CHECK_FOR_INTERRUPTS();	/* per document-at-a-time step; cursor blocks are palloc'd copies, no lock held */

		/* recompute the essential boundary from the current threshold: the
		 * longest low-impact prefix whose max_contrib sum <= threshold is
		 * non-essential */
		if (nheap >= k)
		{
			/* terms [0, first_essential] together cannot beat the threshold:
			 * a document containing only those terms cannot enter the top-k */
			while (first_essential < nterms &&
				   suffix[first_essential + 1] <= threshold)
				first_essential++;
		}

		/* smallest docid among essential cursors drives the iteration */
		for (i = first_essential; i < nterms; i++)
			if (cursors[i].docid < cand)
				cand = cursors[i].docid;
		if (cand == UINT64_MAX)
			break;				/* essential cursors exhausted */

		/* score cand: essential contributions + upper bound of non-essentials;
		 * the exact score is summed in query-term order (sum_term_order) */
		score = 0.0;
		for (i = first_essential; i < nterms; i++)
			if (cursors[i].docid == cand)
			{
				double		c = wand_contrib_cur(&cursors[i]);

				score += c;
				acc[cursors[i].termidx] += c;
			}

		/* early-exit check: essential score + every non-essential term's max
		 * (prefix sum over [0, first_essential)) <= threshold => cand cannot
		 * make the top-k, skip the non-essential lookups */
		if (nheap >= k && score + suffix[first_essential] <= threshold)
			(void) sum_term_order(acc, nq);	/* clears acc */
		else
		{
			/* add exact non-essential contributions by seeking to cand */
			for (i = 0; i < first_essential; i++)
			{
				wand_seek(&cursors[i], cand);
				if (cursors[i].docid == cand)
					acc[cursors[i].termidx] += wand_contrib_cur(&cursors[i]);
			}
			score = sum_term_order(acc, nq);

			/* gate heap admission by the boolean match-set (DocidFilter for
			 * non-pure-boolean, or the lazy BoolGate over term-presence at cand
			 * for pure-boolean AND/NOT).  A rejected doc never enters the heap
			 * and never raises the threshold.  The essential/non-essential
			 * traversal (incl. the non-essential seeks above) is unchanged --
			 * only heap insertion is gated. */
			if ((nheap < k || score > threshold) &&
				docid_admitted(filter, cand) &&
				bmw_gate_admits(gate, cursors, nterms, cand))
			{
			if (nheap < k)
			{
				ItemPointerData tid;

				bm25_docid_to_tid(cand, &tid);
				heap[nheap].tid = tid;
				heap[nheap].score = score;
				nheap++;
				if (nheap == k)
				{
					threshold = heap[0].score;
					for (i = 1; i < nheap; i++)
						if (heap[i].score < threshold)
							threshold = heap[i].score;
				}
			}
			else if (score > threshold)
			{
				ItemPointerData tid;
				int			minpos = 0;

				bm25_docid_to_tid(cand, &tid);
				for (i = 1; i < nheap; i++)
					if (scored_worse(&heap[i], &heap[minpos]))
						minpos = i;
				heap[minpos].tid = tid;
				heap[minpos].score = score;
				threshold = heap[0].score;
				for (i = 1; i < nheap; i++)
					if (heap[i].score < threshold)
						threshold = heap[i].score;
			}
			}					/* end docid_admitted gate */
		}

		/* advance every essential cursor sitting at cand */
		for (i = first_essential; i < nterms; i++)
			if (cursors[i].docid == cand)
				wand_next(&cursors[i]);
	}

	for (t = 0; t < nterms; t++)
	{
		if (cursors[t].blkbuf)
			pfree(cursors[t].blkbuf);
		if (cursors[t].posbuf)
			pfree(cursors[t].posbuf);
		if (cursors[t].posoff)
			pfree(cursors[t].posoff);
		cursors[t].blkbuf = NULL;
		cursors[t].posbuf = NULL;
		cursors[t].posoff = NULL;
		bm25_doclen_cursor_free(&cursors[t].doclenc);
	}

	pfree(acc);
	qsort(heap, nheap, sizeof(ScoredTid), cmp_scored_desc);
	*out = heap;
	return nheap;
}
#endif

/* ---- inputs and the brute-force reference -------------------------------- */

static WandCursor cs[NT];
static int	contrib[NT][ND + 1];	/* contrib[t][d] > 0 iff term t is in doc d */

/* any posting configuration, any sound block and term bounds */
static void
nondet_postings(void)
{
	int			t,
				d;

	for (t = 0; t < NT; t++)
	{
		WandCursor *c = &cs[t];
		int			i,
					b;
		int			tmax = 0;

		memset(c, 0, sizeof(*c));
		c->termidx = t;
		c->np = 0;
		for (d = 1; d <= ND; d++)
		{
			contrib[t][d] = 0;
			if (nondet_bool())
			{
				int			v = nondet_u8();

				__CPROVER_assume(v >= 1 && v <= CMAX);
				contrib[t][d] = v;
				c->pdoc[c->np] = (uint64) d;
				c->pcontrib[c->np] = v;
				c->np++;
			}
		}
		c->df = (uint32) c->np;
		/* block bounds: any value >= every contribution in the block */
		for (b = 0; b < c->np; b += BLK)
		{
			int			bmax = 0,
						bound = nondet_u8();

			for (i = b; i < c->np && i < b + BLK; i++)
				if (c->pcontrib[i] > bmax)
					bmax = c->pcontrib[i];
			__CPROVER_assume(bound >= bmax && bound <= CMAX + 1);
			for (i = b; i < c->np && i < b + BLK; i++)
				c->pblkbound[i] = bound;
			if (bound > tmax)
				tmax = bound;
		}
		/* term bound: any value >= every block bound */
		c->max_contrib = nondet_u8();
		__CPROVER_assume(c->max_contrib >= tmax && c->max_contrib <= CMAX + 2);
	}
}

/* brute force: every document, score = sum in term order, sorted by
 * cmp_scored_desc; the first min(k, n) */
static int
reference_topk(int k, ScoredTid *ref)
{
	ScoredTid	all[ND];
	int			n = 0,
				d,
				t;

	for (d = 1; d <= ND; d++)
	{
		int			s = 0;
		bool		any = false;

		for (t = 0; t < NT; t++)
			if (contrib[t][d] > 0)
			{
				s += contrib[t][d];
				any = true;
			}
		if (any)
		{
			all[n].tid.d = (uint64) d;
			all[n].score = s;
			n++;
		}
	}
	model_qsort(all, n, sizeof(ScoredTid), cmp_scored_desc);
	if (n > k)
		n = k;
	for (d = 0; d < n; d++)
		ref[d] = all[d];
	return n;
}

/* k is fixed per run (-DK): a symbolic k makes the heap a symbolic-size
 * allocation, which multiplies the SAT problem */
#ifndef K
#define K 1
#endif

static void
check(int (*search) (WandCursor *, int, int, const DocidFilter *, BoolGate *, ScoredTid **))
{
	ScoredTid	ref[K];
	ScoredTid  *got;
	const int	k = K;
	int			nref,
				ngot,
				i;

	nondet_postings();
	nref = reference_topk(k, ref);
	ngot = search(cs, NT, k, NULL, NULL, &got);
	__CPROVER_assert(ngot == nref, "top-k count == reference");
	for (i = 0; i < nref && i < ngot; i++)
	{
		__CPROVER_assert(got[i].tid.d == ref[i].tid.d, "top-k document == reference");
		__CPROVER_assert(got[i].score == ref[i].score, "top-k score == reference");
	}
}

void
harness_bmw(void)
{
	check(fts_search_bmw);
}

void
harness_maxscore(void)
{
	check(fts_search_maxscore);
}
