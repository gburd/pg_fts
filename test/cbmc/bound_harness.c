/*-------------------------------------------------------------------------
 *
 * bound_harness.c
 *		CBMC proof that the per-block BM25 upper bounds the ranked paths
 *		prune with are >= the score of every posting they cover, in the
 *		IEEE double arithmetic the code actually runs.
 *
 *	A block-max traversal skips a block when its bound cannot beat the
 *	current top-k threshold.  If the bound is below a posting's real score --
 *	even by one ulp -- that posting can be skipped while it belongs in the
 *	top-k: a wrong answer, not a slow one.  Two bound expressions are in use:
 *
 *	  BMW   wand_block_max_contrib (pg_fts_am_scan.c, VERBATIM)
 *	          idf * mtf * (k1 + 1.0) / (mtf + k1_1mb + k1b_inv_avgdl * mindl)
 *	  BF    the best-first block bound (bestfirst_collect, pg_fts_am_scan.c)
 *	          idf_k1p1 * mtf / (mtf + k1_1mb + k1b_inv_avgdl * mindl)
 *
 *	and one score expression, wand_contrib_cur (VERBATIM):
 *	          idf_k1p1 * tf / (tf + k1_1mb + k1b_inv_avgdl * dl)
 *
 *	where mtf is the block's max tf and mindl is the reader's quantised copy
 *	of the header's min_doclen, which the writer (bm25_write_postings,
 *	1.11.0) sets to floor(max_tf * min over postings of dl/tf), the
 *	"effective minimum length", with dl quantised for v4 segments.
 *
 *	PROPERTIES (bound: one posting (tf, dl) of a block whose max tf is mtf
 *	and which contains the posting, so tf <= mtf and dl/tf >= the block's
 *	min ratio; tf, mtf <= TF_MAX, dl <= DL_MAX; k1 = 1.2, b = 0.75 as
 *	shipped; avgdl and idf are any positive doubles in the ranges below):
 *
 *	  B1  score(tf, dl) <= BF bound           (best-first paths)
 *	  B2  score(tf, dl) <= BMW bound          (fts_search_bmw)
 *	  B3  the writer's floor and the reader's quantisation only LOWER
 *	      mindl (so they can only RAISE the bound): mindl <= mtf * dl / tf.
 *	  B4  (harness_bound_self) for the posting at the bound's own (max tf,
 *	      min length), bound >= score for every idf, avgdl, tf and length.
 *
 *	B1 and B2 are stated about real doubles, not reals: CBMC bit-blasts the
 *	IEEE operations, so a 1-ulp rounding difference between the bound and
 *	the score is found if it exists in the bound.
 *
 *	A fully symbolic avgdl and idf make the SAT problem two nondet IEEE
 *	divisions deep and do not finish in 30 minutes; run.sh fixes them per
 *	run (-DAVGDL, -DIDF) at corpus shapes that include the ones where the
 *	1.15.2 expression is one ulp low, and leaves tf, |D|, the block's max
 *	tf and its min dl/tf ratio, and the segment format symbolic.
 *
 *	TEETH: -DTEETH_EXACT_MINDL bounds with the EXACT min length instead of
 *	the quantised one on a v4 segment (the 1.9.x WAND unsoundness that missed
 *	true top-k on multi-term AND): B1 must fail.  -DTEETH_BMW_ORDER restores
 *	the 0.1.0..1.15.2 BMW expression, idf * mtf * (k1 + 1): B2 must fail --
 *	this harness found that one ulp (CHANGELOG 1.16.0).
 *
 * IDENTIFICATION
 *	  test/cbmc/bound_harness.c
 *
 *-------------------------------------------------------------------------
 */
#include "cbmc_pg.h"
#include "../../pg_fts_for.h"

/*
 * floor() for the writer's x = floor(max_tf * min_ratio): x is non-negative
 * and far below 2^32 here, where C's conversion to an unsigned integer
 * truncates toward zero, i.e. IS floor.  (CBMC 6.6's floor() model aborts with
 * "l2_rename_rvalues case floatbv_typecast not handled".)
 */
static inline double
floor_nonneg(double v)
{
	return (double) (uint64) v;
}

#ifndef TF_MAX
#define TF_MAX 8
#endif
#ifndef DL_MAX
#define DL_MAX 4096
#endif

/* the cursor fields the two functions read */
typedef struct WandCursor
{
	double		idf;
	double		k1b_inv_avgdl;
	double		k1_1mb;
	double		idf_k1p1;
	uint32		blk_max_tf;
	uint32		blk_min_dl;
	bool		has_doclen_col;
	/* wand_contrib_cur reads tf and dl through the block columns; the
	 * harness supplies them directly */
	uint32		cur_tf;
	uint32		cur_dl;
} WandCursor;

#ifndef TEETH_BMW_ORDER
/* VERBATIM pg_fts_am_scan.c wand_block_max_contrib */
static inline double
wand_block_max_contrib(WandCursor *c)
{
	double		mtf = (double) c->blk_max_tf;
	uint32		mindl_raw = c->blk_min_dl;
	double		mindl = (double) (c->has_doclen_col
									 ? mindl_raw			/* v3: exact inline doclen */
									 : fts_byte_to_doclen(fts_doclen_to_byte(mindl_raw)));

	return c->idf_k1p1 * mtf / (mtf + c->k1_1mb + c->k1b_inv_avgdl * mindl);
}
/* END VERBATIM */
#else
/* mutant: 0.1.0..1.15.2, multiplied in a different order than the score */
static inline double
wand_block_max_contrib(WandCursor *c)
{
	double		k1 = 1.2;
	double		mtf = (double) c->blk_max_tf;
	uint32		mindl_raw = c->blk_min_dl;
	double		mindl = (double) (c->has_doclen_col
									 ? mindl_raw
									 : fts_byte_to_doclen(fts_doclen_to_byte(mindl_raw)));

	return c->idf * mtf * (k1 + 1.0) / (mtf + c->k1_1mb + c->k1b_inv_avgdl * mindl);
}
#endif

/* wand_contrib_cur (pg_fts_am_scan.c) with the column reads replaced by the
 * posting's tf and dl -- the arithmetic is the shipped expression */
static inline double
contrib(const WandCursor *c, double tf, double dl)
{
	double		norm = tf + c->k1_1mb + c->k1b_inv_avgdl * dl;

	return c->idf_k1p1 * tf / norm;
}

/* bestfirst_collect's bound (pg_fts_am_scan.c), same operands */
static inline double
bf_bound(const WandCursor *c)
{
	double		mtf = (double) c->blk_max_tf;
	double		mindl = (double) (c->has_doclen_col
								  ? c->blk_min_dl
								  : fts_byte_to_doclen(fts_doclen_to_byte(c->blk_min_dl)));

	return c->idf_k1p1 * mtf /
		(mtf + c->k1_1mb + c->k1b_inv_avgdl * mindl);
}

void
harness_bound(void)
{
	WandCursor	c;
	double		k1 = 1.2,
				b = 0.75;
#if defined(AVGDL) && defined(IDF)
	double		avgdl = AVGDL;
	double		idf = IDF;
#else
	double		avgdl = nondet_double();
	double		idf = nondet_double();
#endif
	uint32		tf = nondet_u32(),
				mtf = nondet_u32(),
				dl = nondet_u32(),
				sdl;
	uint32		rtf = nondet_u32(),	/* the posting that sets the min ratio */
				rdl = nondet_u32(),
				rsdl;
	double		ratio,
				x,
				score;

	/* corpus statistics: avgdl >= 1 (a doc has a token), idf from
	 * bm25_index_idf is in (0, log(1 + 2N)) -- any positive finite value */
	__CPROVER_assume(avgdl >= 1.0 && avgdl <= 1e6);
	__CPROVER_assume(idf > 0.0 && idf <= 40.0);

	c.has_doclen_col = nondet_bool();
	c.idf = idf;
	c.k1b_inv_avgdl = k1 * b / avgdl;
	c.k1_1mb = k1 * (1.0 - b);
	c.idf_k1p1 = idf * (k1 + 1.0);

	/* the posting being scored, and the block's max tf */
	__CPROVER_assume(tf >= 1 && tf <= mtf && mtf <= TF_MAX);
	__CPROVER_assume(dl >= tf && dl <= DL_MAX);	/* a doc has >= tf tokens */
	/* the posting that sets the block's min dl/tf ratio */
	__CPROVER_assume(rtf >= 1 && rtf <= mtf && rdl >= rtf && rdl <= DL_MAX);

	/* the length the SCORER uses (bm25_write_postings: sdl) */
	sdl = c.has_doclen_col ? dl : fts_byte_to_doclen(fts_doclen_to_byte(dl));
	rsdl = c.has_doclen_col ? rdl : fts_byte_to_doclen(fts_doclen_to_byte(rdl));
	ratio = (double) rsdl / (double) rtf;
	/* the scored posting is in the block: its ratio is >= the minimum */
	__CPROVER_assume((double) sdl / (double) tf >= ratio);

	/* writer: bh->min_doclen = floor(max_tf * min_ratio), clamped */
	x = floor_nonneg((double) mtf * ratio);
	c.blk_max_tf = mtf;
	c.blk_min_dl = x >= 4294967295.0 ? 4294967295u : (uint32) x;
#ifdef TEETH_EXACT_MINDL
	/* 1.9.x: the bound used the exact minimum length of a v4 block */
	c.has_doclen_col = true;
	c.blk_min_dl = rdl;
	__CPROVER_assume(rsdl != rdl);	/* a length the quantiser lowers */
	__CPROVER_assume(tf == mtf && dl == rdl && tf == rtf);
#endif

	score = contrib(&c, (double) tf, (double) sdl);
	__CPROVER_assert(score <= bf_bound(&c), "B1: score <= best-first block bound");
	__CPROVER_assert(score <= wand_block_max_contrib(&c), "B2: score <= BMW block bound");
}

/* B3 in exact integer terms: floor and quantisation only lower mindl */
void
harness_mindl(void)
{
	uint32		mtf = nondet_u32(),
				rtf = nondet_u32(),
				rdl = nondet_u32();
	uint32		x,
				q;

	__CPROVER_assume(mtf >= 1 && mtf <= TF_MAX && rtf >= 1 && rtf <= mtf);
	__CPROVER_assume(rdl >= rtf && rdl <= DL_MAX);
	x = (uint32) floor_nonneg((double) mtf * ((double) rdl / (double) rtf));
	q = fts_byte_to_doclen(fts_doclen_to_byte(x));
	/* x <= mtf * rdl / rtf, i.e. x * rtf <= mtf * rdl */
	__CPROVER_assert((uint64) x * rtf <= (uint64) mtf * rdl, "B3: floor never raises mindl");
	__CPROVER_assert(q <= x, "B3: reader re-quantisation never raises mindl");
}

/*
 * B4, the case the 1.15.2 BMW expression got wrong, in isolation: for the
 * block's own (max tf, min length) posting -- the one the bound is computed
 * at -- the bound must be >= its score for EVERY idf, avgdl, tf and length
 * (all symbolic, not fixed shapes).  With the score's operation order the
 * two are the same double, which is what makes this tractable where
 * harness_bound with a symbolic corpus is not.
 */
void
harness_bound_self(void)
{
	WandCursor	c;
	double		k1 = 1.2,
				b = 0.75;
	double		avgdl = nondet_double();
	double		idf = nondet_double();
	uint32		mtf = nondet_u32(),
				mindl = nondet_u32();
	double		score;

	__CPROVER_assume(avgdl >= 1.0 && avgdl <= 1e6);
	__CPROVER_assume(idf > 0.0 && idf <= 40.0);
	__CPROVER_assume(mtf >= 1 && mtf <= 1000000 && mindl <= 100000000);
	c.has_doclen_col = true;	/* the length is used as stored */
	c.idf = idf;
	c.k1b_inv_avgdl = k1 * b / avgdl;
	c.k1_1mb = k1 * (1.0 - b);
	c.idf_k1p1 = idf * (k1 + 1.0);
	c.blk_max_tf = mtf;
	c.blk_min_dl = mindl;
	score = contrib(&c, (double) mtf, (double) mindl);
	__CPROVER_assert(score <= wand_block_max_contrib(&c), "B4: BMW bound >= its own posting's score");
	__CPROVER_assert(score <= bf_bound(&c), "B4: best-first bound >= its own posting's score");
}
