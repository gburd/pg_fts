/*-------------------------------------------------------------------------
 *
 * pg_fts_am.c
 *		The "bm25" index access method for pg_fts.
 *
 * A segmented inverted index over an ftsdoc column, answering the @@@ operator
 * (boolean / phrase / NEAR / prefix / fuzzy / regex) and the <=> ordering
 * operator (block-max WAND / MaxScore top-k), plus a fast fts_count() path.
 * It maintains the corpus statistics BM25 needs (document count N, sum of
 * document lengths, per-term document frequency) and scores index-only.
 *
 * On-disk layout (the Lucene/Tantivy-style segmented design):
 *
 *	 block 0            metapage: N, sum(doclen), a directory of segments, and
 *							the pending write buffer pointers
 *	 per segment        a term dictionary (+ sparse block index), FOR-packed
 *							128-doc posting blocks with per-block max-tf/min-|D|
 *							impacts, a trigram index, and a livedocs tombstone
 *							bitmap
 *	 pending pages      newly inserted docs stored verbatim, searched directly
 *							until folded into a new segment by a flush
 *
 * Inserts append to the pending buffer and are immediately visible; a flush
 * (fts_merge() or VACUUM cleanup) folds pending docs into a new segment, and a
 * size-tiered merge compacts segments (dropping tombstoned docs).  Deletes are
 * recorded as per-segment livedocs tombstones by ambulkdelete.  All page writes
 * go through GenericXLog, so the index is crash-safe and replicated without a
 * custom resource manager.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts_am.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "pg_fts.h"
#include "pg_fts_am.h"
#include "pg_fts_sm.h"			/* namespaced sparsemap (tombstones, trigrams) */
#include <math.h>
#include "access/genam.h"
#include "access/generic_xlog.h"
#include "access/parallel.h"
#include "access/reloptions.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/visibilitymap.h"
#include "catalog/index.h"
#include "catalog/pg_am.h"
#include "catalog/pg_type.h"
#include "commands/defrem.h"
#include "commands/vacuum.h"
#include "executor/tuptable.h"
#include "executor/executor.h"
#include "executor/instrument.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/pathnodes.h"
#include "nodes/tidbitmap.h"
#include "optimizer/cost.h"
#include "optimizer/optimizer.h"
#include "pgstat.h"
#include "storage/bufmgr.h"
#include "storage/buffile.h"
#include "catalog/storage.h"
#include "storage/condition_variable.h"
#include "storage/freespace.h"
#include "storage/indexfsm.h"
#include "storage/lmgr.h"
#include "storage/spin.h"
#include "tcop/tcopprot.h"
#include "utils/array.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/selfuncs.h"

/* palloc/repalloc that transparently use the Huge variants past MaxAllocSize.
 * Build-time posting arrays for a very high-df term (e.g. tokens present in
 * millions of JSON-log lines) can exceed 1 GB, especially when the final merge
 * concatenates a term's postings across several segments before dedup.
 *
 * Note: this only lifts the *byte-size* ceiling (>1 GB). The element
 * counts (nposts/npos, int) still cap at INT_MAX (~2.1 G postings/positions
 * per term); a single term that common would overflow the int counters (and
 * their doubling) first. Not hit even at 20M diverse docs; widen these counts
 * to int64 if a term ever approaches that df. */
#define FTS_ALLOC_MAYBE_HUGE(sz) \
	(((Size) (sz)) > MaxAllocSize \
	 ? MemoryContextAllocHuge(CurrentMemoryContext, (sz)) \
	 : palloc((sz)))
#define FTS_REALLOC_MAYBE_HUGE(p, sz) \
	(((Size) (sz)) > MaxAllocSize \
	 ? repalloc_huge((p), (sz)) \
	 : repalloc((p), (sz)))

PG_FUNCTION_INFO_V1(fts_handler);

/*
 * Reloptions for the bm25 index.  Only one knob: `positions` -- whether to
 * store per-token positions in the postings so phrase/NEAR is answered
 * directly from the index (no heap recheck).  Registered once from _PG_init.
 */
typedef struct BM25Options
{
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	bool		positions;		/* store token positions in postings (default off) */
} BM25Options;

static relopt_kind bm25_relopt_kind;

void		bm25_init_reloptions(void);
static bool bm25_index_wants_positions(Relation index);

void
bm25_init_reloptions(void)
{
	bm25_relopt_kind = add_reloption_kind();
	add_bool_reloption(bm25_relopt_kind, "positions",
					   "store token positions in postings for index-only phrase/NEAR",
					   false, AccessExclusiveLock);
}

/* ----- build: collect postings from the heap ----- */

typedef struct BuildTerm
{
	char	   *term;
	int			len;
	/* postings for this term */
	ItemPointerData *tids;
	uint32	   *tfs;
	uint32	   *doclens;
	/* token positions for this term, when the index carries positions.  Flat
	 * arena of all postings' positions; posting i owns positions[posoff[i] ..
	 * posoff[i]+tfs[i]).  Never reordered (postings are sorted by copying these
	 * offsets into the sort struct), so posoff stays valid across the sort. */
	uint32	   *positions;
	uint32	   *posoff;		/* per-posting start index into positions[] */
	uint32	   *poscnt;		/* per-posting stored position count (0 if dropped;
								 * may be < tf when a source block dropped positions) */
	int			npos;		/* total positions stored (== Sum poscnt) */
	int			maxpos;
	int			nposts;
	int			maxposts;
	uint32		max_tf;		/* max tf across postings; set by bm25_write_postings
								 * so bm25_write_dictionary reads it instead of
								 * rescanning tfs[] -- lets a streaming merge keep
								 * only term metadata (no tfs[] body) and still write
								 * a correct max_tf */
	int			next;			/* next BuildTerm sharing the same hash key, or -1 */
} BuildTerm;

typedef struct BM25BuildState
{
	MemoryContext ctx;
	BuildTerm  *terms;			/* sorted-on-flush; kept in a simple array */
	int			nterms;
	int			maxterms;
	bool		want_positions;	/* index built WITH (positions=on): carry token
								 * positions through build/merge into the postings */
	/* build-time term list: an unsorted array collected during the heap scan,
	 * sorted once before the dictionary is written */
	double		ndocs;
	double		sumdoclen;
	Size		flush_budget;	/* current in-memory budget before a segment is
								 * flushed; grows as this participant flushes more,
								 * so the flush count stays far under
								 * BM25_MAX_SEGMENTS (0 = use the default) */
	int			nflushes;		/* segments this participant has flushed so far */
} BM25BuildState;

static int
cmp_buildterm(const void *a, const void *b)
{
	const BuildTerm *ta = (const BuildTerm *) a;
	const BuildTerm *tb = (const BuildTerm *) b;
	int			min = Min(ta->len, tb->len);
	int			c = memcmp(ta->term, tb->term, min);

	if (c != 0)
		return c;
	return ta->len - tb->len;
}

/*
 * Find or create a BuildTerm for (term,len).  We use a dynahash keyed by a
 * fixed-size padded copy of the term to avoid an O(n^2) linear scan.  Terms
 * longer than the key buffer fall back to exact comparison via the stored
 * BuildTerm, which is correct though it may hash-collide slightly; term length
 * is bounded by MAXSTRLEN in practice.
 */
#include "utils/hsearch.h"

#define BM25_TERMKEYLEN 64

typedef struct TermKey
{
	char		key[BM25_TERMKEYLEN];
} TermKey;

typedef struct TermHashEntry
{
	TermKey		key;			/* must be first: dynahash key */
	int			termidx;		/* head of a chain of BuildTerms sharing this key */
} TermHashEntry;

static HTAB *build_ht;

/*
 * (Re)initialize the build hash table that maps a term key to its BuildTerm
 * index.  Created in bs->ctx so it is freed when that context is reset between
 * segment flushes during a large build.
 */
static void
bm25_build_ht_init(BM25BuildState *bs)
{
	HASHCTL		ctl;

	ctl.keysize = sizeof(TermKey);
	ctl.entrysize = sizeof(TermHashEntry);
	ctl.hcxt = bs->ctx;
	build_ht = hash_create("bm25 build terms", 1024, &ctl,
						   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
}

static void
make_termkey(TermKey *k, const char *term, int len)
{
	int			n = len;

	/* defensive: `len` ultimately derives from an on-disk/pending entries[].len
	 * (a uint32 read into an int).  A corrupt value could be negative or absurd;
	 * clamp to [0, BM25_TERMKEYLEN] so this fixed-size key copy can never turn
	 * into a wild memcpy (a _FORTIFY_SOURCE abort).  Callers validate the doc
	 * first (fts_doc_is_valid); this is the last line of defense. */
	if (n < 0)
		n = 0;
	memset(k, 0, sizeof(TermKey));
	memcpy(k->key, term, Min(n, BM25_TERMKEYLEN));
	/* fold length into the tail so different-length terms sharing a prefix do
	 * not collide on the key */
	if (n < BM25_TERMKEYLEN)
		k->key[n] = '\1';
}

static void
add_posting(BM25BuildState *bs, const char *term, int len,
			ItemPointer tid, uint32 tf, uint32 doclen,
			const uint32 *pos, int npos)
{
	TermKey		key;
	TermHashEntry *entry;
	bool		found;
	BuildTerm  *bt = NULL;
	int			idx;

	make_termkey(&key, term, len);
	entry = (TermHashEntry *) hash_search(build_ht, &key, HASH_ENTER, &found);

	/*
	 * On a hash hit, walk the chain of BuildTerms sharing this key and pick the
	 * truly-equal one.  The key is a padded/length-folded prefix, so two DISTINCT
	 * terms >= BM25_TERMKEYLEN bytes sharing that prefix can land on the same
	 * key; chaining keeps them as separate BuildTerms instead of clobbering the
	 * entry (which previously fragmented a term's postings across unreachable
	 * dictionary entries).
	 */
	if (found)
	{
		for (idx = entry->termidx; idx >= 0; idx = bs->terms[idx].next)
		{
			BuildTerm  *cand = &bs->terms[idx];

			if (cand->len == len && memcmp(cand->term, term, len) == 0)
			{
				bt = cand;
				break;
			}
		}
	}

	if (bt == NULL)
	{
		if (bs->nterms >= bs->maxterms)
		{
			bs->maxterms = bs->maxterms ? bs->maxterms * 2 : 1024;
			if (bs->terms == NULL)
				bs->terms = (BuildTerm *) FTS_ALLOC_MAYBE_HUGE(bs->maxterms * sizeof(BuildTerm));
			else
				bs->terms = (BuildTerm *) FTS_REALLOC_MAYBE_HUGE(bs->terms,
														   bs->maxterms * sizeof(BuildTerm));
		}
		bt = &bs->terms[bs->nterms];
		bt->term = (char *) palloc(len);
		memcpy(bt->term, term, len);
		bt->len = len;
		bt->maxposts = 4;
		bt->nposts = 0;
		bt->max_tf = 0;			/* filled by bm25_write_postings */
		bt->tids = (ItemPointerData *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(ItemPointerData));
		bt->tfs = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
		bt->doclens = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
		bt->positions = NULL;
		bt->posoff = NULL;
		bt->poscnt = NULL;
		bt->npos = 0;
		bt->maxpos = 0;
		if (bs->want_positions)
		{
			bt->posoff = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
			bt->poscnt = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
			bt->maxpos = 8;
			bt->positions = (uint32 *) palloc(bt->maxpos * sizeof(uint32));	/* alloc-ok: seed=8, grown huge-safe below; one term in a budget-bounded segment */
		}
		/* push onto the head of this key's chain (-1 = end of chain) */
		bt->next = found ? entry->termidx : -1;
		entry->termidx = bs->nterms;
		bs->nterms++;
	}

	if (bt->nposts >= bt->maxposts)
	{
		bt->maxposts *= 2;
		bt->tids = (ItemPointerData *) FTS_REALLOC_MAYBE_HUGE(bt->tids,
												bt->maxposts * sizeof(ItemPointerData));
		bt->tfs = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->tfs, bt->maxposts * sizeof(uint32));
		bt->doclens = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->doclens, bt->maxposts * sizeof(uint32));
		if (bt->posoff != NULL)
		{
			bt->posoff = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->posoff, bt->maxposts * sizeof(uint32));
			bt->poscnt = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->poscnt, bt->maxposts * sizeof(uint32));
		}
	}
	bt->tids[bt->nposts] = *tid;
	bt->tfs[bt->nposts] = tf;
	bt->doclens[bt->nposts] = doclen;
	/*
	 * Carry positions when the index wants them and the caller supplied a full
	 * set (npos == tf).  A per-(term,doc) position count is bounded by the
	 * analyzer's MAXENTRYPOS cap, so appending tf values here cannot blow up a
	 * single posting; the segment total is bounded by the build memory budget
	 * (checked between tuples in bm25_build_callback), which flushes before the
	 * arena grows unbounded -- so this never materializes the whole corpus'
	 * positions in one array.
	 */
	if (bs->want_positions && pos != NULL && npos == (int) tf && tf > 0)
	{
		if (bt->npos + (int) tf > bt->maxpos)
		{
			while (bt->npos + (int) tf > bt->maxpos)
				bt->maxpos *= 2;
			bt->positions = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->positions,
												bt->maxpos * sizeof(uint32));
		}
		bt->posoff[bt->nposts] = (uint32) bt->npos;
		bt->poscnt[bt->nposts] = tf;
		memcpy(bt->positions + bt->npos, pos, tf * sizeof(uint32));
		bt->npos += (int) tf;
	}
	else if (bt->posoff != NULL)
	{
		/* want positions but this posting has none (tf==0, or a source block
		 * dropped them on a prior write): record an empty run + zero count so
		 * posoff stays aligned with the posting index and the writer knows this
		 * posting stores no positions (it will drop the block's positions). */
		bt->posoff[bt->nposts] = (uint32) bt->npos;
		bt->poscnt[bt->nposts] = 0;
	}
	bt->nposts++;
}

/* forward decls: segment writers are defined later; the build flush uses them */
static void bm25_write_segment(Relation index, BM25BuildState *bs, BM25SegMeta *seg);
static void bm25_meta_add_segment(Relation index, const BM25SegMeta *seg);

/*
 * Memory budget for the in-memory build state before it is flushed to a
 * segment.  A very large CREATE INDEX would otherwise accumulate the whole
 * corpus's terms + postings in bs->ctx and exhaust memory; instead, once the
 * build context grows past this, we write the accumulated terms as a segment
 * and start fresh.  Derived from maintenance_work_mem (bounded so a small
 * setting still makes progress).  The later size-tiered merge compacts the
 * resulting segments.
 */
static Size
bm25_build_mem_budget(void)
{
	Size		budget = (Size) maintenance_work_mem * (Size) 1024;

	if (budget < (Size) 32 * 1024 * 1024)
		budget = (Size) 32 * 1024 * 1024;	/* floor: 32MB */
	return budget;
}

/*
 * Bound a build participant's flush-segment count without merging mid-build.
 *
 * Each participant (the serial builder, or the leader + each parallel worker)
 * flushes an in-memory segment every time its accumulator reaches the flush
 * budget, plus one residual at the end.  All participants append into the same
 * fixed BM25_MAX_SEGMENTS metapage directory, so a large build could otherwise
 * overflow it (bm25_meta_add_segment errors) even though the data is fine and
 * merges to a single segment at the end.  A parallel worker cannot merge
 * mid-build to reclaim slots -- it runs while IsInParallelMode() and the
 * metapage swap is single-writer only -- so instead each participant caps its
 * own flush count by DOUBLING its budget every BM25_BUILD_FLUSHES_PER_TIER
 * flushes, UP TO A CEILING of 2 * maintenance_work_mem.  The doubling keeps the
 * flush (segment) count low on a huge build; the ceiling keeps peak MEMORY
 * bounded -- memory is the hard limit (exhausting it degrades the host),
 * segment-count overflow is a clean error backstopped by BM25_MAX_SEGMENTS.
 * With the cap a participant of total in-memory volume V flushes about
 *   V / (2 * maintenance_work_mem) + O(BM25_BUILD_FLUSHES_PER_TIER) rampup
 * segments, which stays well under the cap for realistic corpora, while peak
 * memory is bounded to (max_parallel_maintenance_workers + 1) * 2 * mwm.  An
 * UNcapped budget (2GB->4->8->16->32GB ...) instead let a participant grow to
 * tens of GB before flushing, driving a real 1.8M-doc / 19GB build into swap
 * death several hours in.  This needs no up-front size estimate (the in-memory
 * arena / heap-bytes ratio varies with the data), touches only this
 * participant's own state (parallel-safe), and never falls below the operator's
 * maintenance_work_mem for the first tier.  BM25_MAX_SEGMENTS stays as the hard
 * backstop.
 */
#define BM25_BUILD_FLUSHES_PER_TIER 8


/*
 * Flush the current in-memory build state as one immutable segment and reset
 * the state (freeing bs->ctx) so the heap scan can continue within a bounded
 * memory footprint.  A document's terms are always fully accumulated before a
 * flush (we only flush between tuples), so no document is split across
 * segments and each segment's ndocs/sumdoclen are self-consistent.
 */
static void
bm25_build_flush_segment(Relation index, BM25BuildState *bs)
{
	BM25SegMeta seg;

	if (bs->nterms == 0)
		return;
	if (bs->nterms > 1)
		qsort(bs->terms, bs->nterms, sizeof(BuildTerm), cmp_buildterm);

	/*
	 * Serialize index-page writes across parallel-build participants.  During a
	 * parallel build several backends flush segments into the same index
	 * concurrently; pg_fts appends pages (bm25_new_buffer -> ReadBuffer(P_NEW)),
	 * and overlapping appenders race on relation extension ("unexpected data
	 * beyond EOF").  Holding the relation extension lock around the whole
	 * segment write makes each participant's page additions atomic w.r.t. the
	 * others.  The expensive part of the build -- heap scan + tsearch analysis
	 * -- runs fully parallel, and the segment write appends pages via
	 * bm25_new_buffer(), which now serializes only the P_NEW extension itself
	 * (per page) rather than the whole write -- so participants write
	 * concurrently.  In a serial build IsInParallelMode() is false and no
	 * extension lock is taken at all.
	 */
	bm25_write_segment(index, bs, &seg);
	bm25_meta_add_segment(index, &seg);

	/*
	 * Grow the flush budget geometrically so this participant's flush count
	 * stays far under BM25_MAX_SEGMENTS on a huge build, but CAP it at
	 * 2 * maintenance_work_mem so peak build memory stays bounded.  The cap is
	 * the hard limit: memory exhaustion crashes/degrades the host, whereas
	 * exceeding the segment count is a clean error (bm25_meta_add_segment) with
	 * the end-of-build merge collapsing to one segment.  Uncapped doubling
	 * (2GB -> 4 -> 8 -> 16 -> 32GB ...) let bs->ctx grow to tens of GB before a
	 * flush; with the leader + max_parallel_maintenance_workers each holding its
	 * own budget, peak memory is (workers+1) * budget, so an uncapped budget
	 * drove a real 1.8M-doc / 19GB build into swap death several hours in (once
	 * participants crossed into the 16GB+ tier).  At the 2*mwm cap a
	 * per-participant build of accumulated in-memory volume V flushes about
	 * V/(2*mwm) + a few rampup segments; for realistic corpora that stays well
	 * under BM25_MAX_SEGMENTS, and peak memory is bounded to
	 * (workers+1) * 2 * maintenance_work_mem.
	 *
	 * Note: peak build memory is (max_parallel_maintenance_workers + 1) times
	 * this budget -- size maintenance_work_mem with that multiplier in mind.
	 */
	if (bs->flush_budget == 0)
		bs->flush_budget = bm25_build_mem_budget();
	bs->nflushes++;
	if (bs->nflushes % BM25_BUILD_FLUSHES_PER_TIER == 0 &&
		bs->flush_budget < (Size) 2 * bm25_build_mem_budget())
		bs->flush_budget *= 2;

	/* reset: free everything in the build context and start a fresh segment */
	MemoryContextReset(bs->ctx);
	bs->terms = NULL;
	bs->nterms = 0;
	bs->maxterms = 0;
	bs->ndocs = 0;
	bs->sumdoclen = 0;
	bm25_build_ht_init(bs);
}

/* per-heap-tuple callback */
static void
bm25_build_callback(Relation index, ItemPointer tid, Datum *values,
					bool *isnull, bool tupleIsAlive, void *state)
{
	BM25BuildState *bs = (BM25BuildState *) state;
	FtsDoc		doc;
	FtsTermEntry *entries;
	uint32		i;
	MemoryContext old;

	if (isnull[0])
		return;

	/*
	 * Bound build memory: if the accumulated segment has grown past the budget,
	 * flush it as a segment and continue with a fresh build state.  Checked
	 * between tuples so a document's terms are never split across segments.
	 *
	 * Recurse into child contexts (the `true`): the term dynahash (build_ht) is
	 * created with hcxt = bs->ctx, so dynahash puts its bucket directory and all
	 * TermHashEntry entries in a CHILD context of bs->ctx.  Counting only bs->ctx
	 * itself (the old `false`) missed the hash-table memory entirely, so on a
	 * huge-vocabulary corpus (e.g. long email/body text: quoted chains, patches,
	 * code -> millions of distinct terms) the flush undercounted the real working
	 * set and fired far too late, letting the build's memory grow for hours
	 * instead of settling at ~maintenance_work_mem.  bs->ctx and its children are
	 * exactly what MemoryContextReset frees at flush, so `true` counts precisely
	 * the reclaimable footprint the budget is meant to bound.
	 */
	if (bs->nterms > 0 &&
		MemoryContextMemAllocated(bs->ctx, true) >=
		(bs->flush_budget ? bs->flush_budget : bm25_build_mem_budget()))
		bm25_build_flush_segment(index, bs);

	old = MemoryContextSwitchTo(bs->ctx);

	doc = (FtsDoc) PG_DETOAST_DATUM(values[0]);
	entries = FTS_DOC_ENTRIES(doc);

	for (i = 0; i < doc->nterms; i++)
	{
		const uint32 *pos = NULL;
		int			npos = 0;

		if (bs->want_positions && FTS_DOC_HAS_POS(doc))
		{
			pos = FTS_DOC_TERMPOS(doc, &entries[i]);
			npos = (int) entries[i].tf;
		}
		add_posting(bs, FTS_DOC_TERMTEXT(doc, &entries[i]), entries[i].len,
					tid, entries[i].tf, doc->doclen, pos, npos);
	}

	bs->ndocs += 1.0;
	bs->sumdoclen += doc->doclen;

	MemoryContextSwitchTo(old);
}

/* ----- posting compression (delta + varint) ----- */

/*
 * Pack/unpack a heap TID into a monotonic 48-bit docid so that ascending TIDs
 * yield ascending docids and small gaps.  MaxHeapTuplesPerPage bounds the
 * offset, so block*factor+offset is monotonic in (block, offset).
 */
#define BM25_OFFSET_FACTOR ((uint64) MaxHeapTuplesPerPage)

static inline uint64
bm25_tid_to_docid(ItemPointer tid)
{
	return (uint64) ItemPointerGetBlockNumber(tid) * BM25_OFFSET_FACTOR +
		(uint64) ItemPointerGetOffsetNumber(tid);
}

static inline void
bm25_docid_to_tid(uint64 docid, ItemPointer tid)
{
	BlockNumber blk = (BlockNumber) (docid / BM25_OFFSET_FACTOR);
	OffsetNumber off = (OffsetNumber) (docid % BM25_OFFSET_FACTOR);

	ItemPointerSet(tid, blk, off);
}

/*
 * FOR (frame-of-reference) bit-packing of a block's three columns.  The codec
 * (bm25_bitwidth / bm25_for_pack / bm25_for_unpack / bm25_for_bytelen /
 * bm25_for_get) lives in pg_fts_for.h as pure standalone C so the standalone
 * property tests (test/hegel/) share this exact copy -- single source of truth.
 */
#include "pg_fts_for.h"

/*
 * Decode exactly one term's postings from the shared posting chain: start at
 * (firstblk, firstoff) and decode consecutive blocks -- following nextblk
 * across pages -- until `df` postings have been read.  A term's blocks are
 * written contiguously, so its run is delimited purely by df.  Returns the
 * count (== df on a consistent index); *out (and *blockmax if non-NULL) are
 * palloc'd.  `off` on pages after the first is the contents start.
 *
 * When want_positions is true and a block carries a positions column
 * (posbytelen>0), each posting's `pos` is set to point into a single palloc'd
 * positions arena (*posarena, returned so the caller can free it); the pointer
 * is valid until that arena is freed.  When want_positions is false the
 * positions column is SKIPPED with a pointer add (posbytelen) and never
 * decoded -- so plain BM25/AND/count queries pay ~zero for positions existing,
 * mirroring the tf/doclen bytelen-skip.
 */
static int
bm25_decode_term(Relation index, BlockNumber firstblk, uint32 firstoff,
				 uint32 df, BM25Posting **out, uint32 **blockmax,
				 bool want_positions, uint32 **posarena)
{
	BM25Posting *posts;
	uint32	   *bmax = NULL;
	uint32	   *parena = NULL;
	int		   *pos_start = NULL;	/* per-posting arena offset (fixed to ptr below) */
	int			parena_n = 0;
	int			parena_cap = 0;
	int			n = 0;
	BlockNumber blk = firstblk;
	uint32		off = firstoff;

	posts = (BM25Posting *) ((Size) df * sizeof(BM25Posting) > MaxAllocSize
							 ? MemoryContextAllocHuge(CurrentMemoryContext,
													 Max(df, 1u) * sizeof(BM25Posting))
							 : palloc(Max(df, 1u) * sizeof(BM25Posting)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */
	if (blockmax)
		bmax = (uint32 *) ((Size) df * sizeof(uint32) > MaxAllocSize
						   ? MemoryContextAllocHuge(CurrentMemoryContext, Max(df, 1u) * sizeof(uint32))
						   : palloc(Max(df, 1u) * sizeof(uint32)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */
	if (want_positions)
		pos_start = (int *) ((Size) df * sizeof(int) > MaxAllocSize
							 ? MemoryContextAllocHuge(CurrentMemoryContext, Max(df, 1u) * sizeof(int))
							 : palloc(Max(df, 1u) * sizeof(int)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */

	while (blk != InvalidBlockNumber && n < (int) df)
	{
		Buffer		buf = ReadBuffer(index, blk);
		Page		page;
		char	   *p,
				   *pend;
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		pend = (char *) page + ((PageHeader) page)->pd_lower;
		next = BM25PageGetOpaque(page)->nextblk;
		p = (char *) page + off;
		while (p + sizeof(BM25BlockHdr) <= pend && n < (int) df)
		{
			BM25BlockHdr *bh = (BM25BlockHdr *) p;
			const unsigned char *stream = (const unsigned char *) (bh + 1);
			uint64		docid = ((uint64) bh->first_docid_hi << 32) | bh->first_docid_lo;
			uint64		gaps[BM25_BLOCK_SIZE];
			uint64		tfs[BM25_BLOCK_SIZE];
			uint64		dls[BM25_BLOCK_SIZE];
			int			cnt = (int) bh->count;
			int			pos = 0;
			int			i;

			if (cnt == 0)
				break;

			/*
			 * Never trust the on-disk block header's own count/lengths: a torn
			 * page, a stale-format image, or any producing bug could give a
			 * count > BM25_BLOCK_SIZE (which would overflow the fixed gaps/tfs/
			 * dls stack arrays via bm25_for_unpack) or a bytelen/posbytelen that
			 * runs the FOR columns past the page (an out-of-bounds read).  Clamp
			 * the count (as the WAND block loader already does) and stop
			 * decoding this term at the first block whose declared payload does
			 * not fit within the page -- returning the postings decoded so far
			 * rather than reading off the end.  A corrupt block is thus a
			 * bounded, non-crashing miss; REINDEX rebuilds it from the heap.
			 *
			 * bh->count is uint32: test the unsigned value (a >2^31 count would
			 * cast to a negative int and slip past a `cnt > BM25_BLOCK_SIZE`
			 * check).  Anything not in [1, BM25_BLOCK_SIZE] is a corrupt block.
			 */
			if (bh->count == 0 || bh->count > (uint32) BM25_BLOCK_SIZE)
				cnt = BM25_BLOCK_SIZE;
			if (stream + (Size) bh->bytelen + (Size) bh->posbytelen > (const unsigned char *) pend)
			{
				ereport(WARNING,
						(errcode(ERRCODE_DATA_CORRUPTED),
						 errmsg("pg_fts: truncated posting block in index \"%s\"; stopping term decode",
								RelationGetRelationName(index)),
						 errhint("REINDEX the index to rebuild it from the heap.")));
				UnlockReleaseBuffer(buf);
				goto done;
			}

			/*
			 * The three FOR columns must fit within the block's own declared
			 * bytelen (which the guard above proved fits within the page).
			 * bm25_for_unpack consumes a byte count driven by the on-disk width
			 * byte; a corrupt width could otherwise read past the page even with
			 * a small bytelen.  Sum the three columns' declared consumption and
			 * reject the block if it overruns bytelen, before decoding any of it.
			 */
			{
				int			gl = bm25_for_bytelen(stream, cnt);
				int			tl = (gl <= (int) bh->bytelen)
					? bm25_for_bytelen(stream + gl, cnt) : 0;
				int			dl = (gl + tl <= (int) bh->bytelen)
					? bm25_for_bytelen(stream + gl + tl, cnt) : 0;

				if ((Size) gl + tl + dl > (Size) bh->bytelen)
				{
					ereport(WARNING,
							(errcode(ERRCODE_DATA_CORRUPTED),
							 errmsg("pg_fts: corrupt posting block (columns overrun bytelen) in index \"%s\"; stopping term decode",
									RelationGetRelationName(index)),
							 errhint("REINDEX the index to rebuild it from the heap.")));
					UnlockReleaseBuffer(buf);
					goto done;
				}
			}
			pos += bm25_for_unpack(stream + pos, cnt, gaps);
			pos += bm25_for_unpack(stream + pos, cnt, tfs);
			pos += bm25_for_unpack(stream + pos, cnt, dls);

			if (want_positions && bh->posbytelen > 0)
			{
				/* the positions column packs Sum(tf) delta values over the whole
				 * block; decode them once, then un-delta per posting below.  n0
				 * is the first posting index of this block. */
				const unsigned char *pstream = stream + bh->bytelen;
				uint64		deltas[BM25_BLOCK_SIZE * 4];
				uint64	   *dbuf = deltas;
				int			sumtf = 0;
				int			n0 = n;
				int			j;

				for (i = 0; i < cnt; i++)
					sumtf += (int) tfs[i];

				/*
				 * Sanity-bound sumtf against the declared positions bytes before
				 * trusting it: the positions column is one FOR block of sumtf
				 * values at width pstream[0], occupying exactly
				 *   width==0 ? 1 : 1 + ceil(sumtf*width/8)   bytes.
				 * A corrupt/inflated tfs[] (each value in range, but summing huge)
				 * can push sumtf far above what posbytelen actually encodes;
				 * without this check bm25_for_unpack would read past the block and
				 * we would size a bogus multi-GB arena.  The existing bh->count /
				 * FOR-column guards do not catch an inflated tfs[].  Compute the
				 * exact required length in 64-bit Size arithmetic (NOT via
				 * bm25_for_bytelen, whose int n*width would itself overflow on a
				 * corrupt sumtf); comparing the exact length avoids false positives
				 * on a legitimate width-0 (all-zero-delta) block with large sumtf.
				 * pstream[0] is in-bounds: the guard above proved
				 * stream+bytelen+posbytelen <= pend and posbytelen>0 here.
				 */
				{
					unsigned int pw = pstream[0];	/* FOR width byte */
					Size		need;

					if (sumtf < 0)
						need = MaxAllocSize + 1;	/* overflow -> force reject */
					else
						need = (pw == 0) ? 1
							: (Size) 1 + (((Size) sumtf * pw + 7) / 8);

					if (need > (Size) bh->posbytelen)
					{
						ereport(WARNING,
								(errcode(ERRCODE_DATA_CORRUPTED),
								 errmsg("pg_fts: corrupt posting block (positions count exceeds declared bytes) in index \"%s\"; stopping term decode",
										RelationGetRelationName(index)),
								 errhint("REINDEX the index to rebuild it from the heap.")));
						UnlockReleaseBuffer(buf);
						goto done;
					}
				}

				/*
				 * A legitimately huge sumtf (a term repeated very many times in
				 * one document) needs a huge-safe alloc: a plain palloc throws
				 * "invalid memory alloc request size" once sumtf*8 crosses
				 * MaxAllocSize, aborting any decode caller (scan/merge/bulkdelete/
				 * CIC validation).  Mirrors the write-side guard in
				 * bm25_write_postings.
				 */
				if (sumtf > (int) (sizeof(deltas) / sizeof(deltas[0])))
					dbuf = (uint64 *) FTS_ALLOC_MAYBE_HUGE((Size) sumtf * sizeof(uint64));
				(void) bm25_for_unpack(pstream, sumtf, dbuf);

				/* grow the arena to hold this block's positions.  parena_cap*4 is
				 * likewise huge-safe (accumulated across the term's blocks). */
				if (parena_n + sumtf > parena_cap)
				{
					parena_cap = Max(parena_cap * 2, parena_n + sumtf);
					parena = parena == NULL
						? (uint32 *) FTS_ALLOC_MAYBE_HUGE((Size) parena_cap * sizeof(uint32))
						: (uint32 *) FTS_REALLOC_MAYBE_HUGE(parena, (Size) parena_cap * sizeof(uint32));
				}

				/* un-delta each posting's run (delta reset at posting boundaries) */
				j = 0;
				for (i = 0; i < cnt; i++)
				{
					int			tf = (int) tfs[i];
					uint32		run = 0;
					int			t;

					if (n0 + i < (int) df)
						pos_start[n0 + i] = parena_n;
					for (t = 0; t < tf; t++)
					{
						run += (uint32) dbuf[j++];
						parena[parena_n++] = run;
					}
				}
				if (dbuf != deltas)
					pfree(dbuf);
			}
			else if (want_positions)
			{
				/* positions absent for this block (posbytelen==0: a page-overflow
				 * block dropped them).  Mark each posting -1 so the pointer
				 * conversion yields NULL -- NOT a valid arena offset, which would
				 * alias another block's positions and misread adjacency. */
				for (i = 0; i < cnt && n + i < (int) df; i++)
					pos_start[n + i] = -1;
			}

			for (i = 0; i < cnt && n < (int) df; i++)
			{
				docid += gaps[i];
				bm25_docid_to_tid(docid, &posts[n].tid);
				posts[n].tf = (uint32) tfs[i];
				posts[n].doclen = (uint32) dls[i];
				posts[n].pos = NULL;
				if (bmax)
					bmax[n] = bh->max_tf;
				n++;
			}
			/* skip past the three columns AND the positions column (posbytelen)
			 * -- a non-positions reader never touches the blob, only adds it */
			p = (char *) (bh + 1) + bh->bytelen + bh->posbytelen;
			p = (char *) MAXALIGN(p);
		}
		UnlockReleaseBuffer(buf);
		blk = next;
		off = MAXALIGN(SizeOfPageHeaderData);	/* later pages: contents start */
	}
done:
	/* convert per-posting arena offsets to stable pointers now the arena is final */
	if (want_positions)
	{
		int			k;

		for (k = 0; k < n; k++)
			posts[k].pos = (parena != NULL && posts[k].tf > 0 && pos_start[k] >= 0)
				? parena + pos_start[k] : NULL;
		if (pos_start)
			pfree(pos_start);
	}
	*out = posts;
	if (blockmax)
		*blockmax = bmax;
	if (posarena)
		*posarena = parena;
	else if (parena)
		pfree(parena);
	return n;
}

/* ----- writing the index pages ----- */

/*
 * Low-page-biased allocation context.  Normally bm25_new_buffer() hands out
 * whatever free page the FSM offers (unordered), then extends.  During a
 * space-reclaiming compaction we instead want to pack live pages toward the
 * FRONT of the file so the dead tail can be truncated.  bm25_alloc_begin()
 * gathers all currently-free blocks, sorts them ascending, and
 * bm25_new_buffer() hands them out low-first; when the low-free list is
 * exhausted it falls back to the ordinary FSM/extend path.  The context is a
 * single backend-scoped hint (compaction is single-writer), reset by
 * bm25_alloc_end().
 */
static BlockNumber *bm25_lowfree = NULL;
static int	bm25_lowfree_n = 0;
static int	bm25_lowfree_i = 0;

/*
 * Extend-only allocation mode.  When set, bm25_new_buffer() skips ALL free-page
 * reuse (the low-free list AND the FSM) and only extends the relation, so a
 * rewrite writes its whole output to fresh high blocks.  Used by the vacuum
 * compactor's "vacate" phase to push a live segment above the free region,
 * turning the freed old pages into one contiguous low-free run big enough for
 * the following "pack" phase to relocate the segment to the front and truncate.
 */
static bool bm25_alloc_extend_only = false;

static int
cmp_blocknumber(const void *a, const void *b)
{
	BlockNumber x = *(const BlockNumber *) a;
	BlockNumber y = *(const BlockNumber *) b;

	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

/*
 * Gather all free blocks (via a linear FSM probe) into an ascending array so
 * subsequent bm25_new_buffer() calls reuse the lowest blocks first.  Single
 * writer only.  Cheap relative to the segment rewrite it precedes.
 */
static void
bm25_alloc_begin(Relation index)
{
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	BlockNumber blk;

	bm25_lowfree_i = 0;
	bm25_lowfree_n = 0;
	bm25_lowfree = NULL;
	if (nblocks <= 1)
		return;
	bm25_lowfree = (BlockNumber *) palloc(sizeof(BlockNumber) * nblocks);
	for (blk = 1; blk < nblocks; blk++)	/* block 0 = metapage, never free */
		if (GetRecordedFreeSpace(index, blk) >= BLCKSZ / 2)
			bm25_lowfree[bm25_lowfree_n++] = blk;
	if (bm25_lowfree_n > 1)
		qsort(bm25_lowfree, bm25_lowfree_n, sizeof(BlockNumber), cmp_blocknumber);
}

static void
bm25_alloc_end(void)
{
	if (bm25_lowfree)
		pfree(bm25_lowfree);
	bm25_lowfree = NULL;
	bm25_lowfree_n = 0;
	bm25_lowfree_i = 0;
}

static Buffer
bm25_new_buffer(Relation index)
{
	Buffer		buffer;

	/*
	 * Low-bias reuse: during a compaction, prefer the lowest free block so
	 * live pages pack at the front of the file.
	 */
	while (!bm25_alloc_extend_only && bm25_lowfree && bm25_lowfree_i < bm25_lowfree_n)
	{
		BlockNumber blk = bm25_lowfree[bm25_lowfree_i++];

		buffer = ReadBuffer(index, blk);
		if (ConditionalLockBuffer(buffer))
		{
			RecordUsedIndexPage(index, blk);
			return buffer;
		}
		ReleaseBuffer(buffer);
	}

	/* Try to reuse a page freed by a previous merge before extending. */
	while (!bm25_alloc_extend_only)
	{
		BlockNumber blk = GetFreeIndexPage(index);

		if (blk == InvalidBlockNumber)
			break;				/* no free page; extend below */
		buffer = ReadBuffer(index, blk);
		if (ConditionalLockBuffer(buffer))
			return buffer;		/* got it */
		/* someone else is using it; try the next free page */
		ReleaseBuffer(buffer);
	}

	/*
	 * Extend the relation.  Concurrent appenders (parallel build/merge
	 * participants) would otherwise race on P_NEW and trip "unexpected data
	 * beyond EOF", so the extension itself is serialized with the relation
	 * extension lock -- but ONLY around the single P_NEW call, not around the
	 * whole segment write.  Holding it for the entire (multi-GB) write would
	 * serialize the participants' writes and defeat the parallel merge; a
	 * per-page extension lock lets them write concurrently.
	 */
	if (IsInParallelMode())
		LockRelationForExtension(index, ExclusiveLock);
	buffer = ReadBuffer(index, P_NEW);
	LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);
	if (IsInParallelMode())
		UnlockRelationForExtension(index, ExclusiveLock);
	return buffer;
}

static void
bm25_init_page(Page page, uint16 flags)
{
	BM25PageOpaque opaque;

	PageInit(page, BLCKSZ, sizeof(BM25PageOpaqueData));
	opaque = BM25PageGetOpaque(page);
	opaque->flags = flags;
	opaque->nextblk = InvalidBlockNumber;
	/* start item area at the (MAXALIGN'd) contents offset used by readers */
	((PageHeader) page)->pd_lower = (char *) PageGetContents(page) - (char *) page;
}

static void
bm25_init_metapage(Relation index)
{
	Buffer		buffer;
	GenericXLogState *state;
	Page		page;
	BM25MetaPageData *meta;

	buffer = bm25_new_buffer(index);
	Assert(BufferGetBlockNumber(buffer) == BM25_METAPAGE_BLKNO);

	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buffer, GENERIC_XLOG_FULL_IMAGE);
	bm25_init_page(page, BM25_META);
	meta = BM25PageGetMeta(page);
	MemSet(meta, 0, sizeof(BM25MetaPageData));
	meta->magic = BM25_MAGIC;
	meta->version = BM25_VERSION;
	meta->ndocs = 0;
	meta->sumdoclen = 0;
	meta->nsegments = 0;
	meta->pendinghead = InvalidBlockNumber;
	meta->pendingtail = InvalidBlockNumber;
	meta->npending = 0;
	((PageHeader) page)->pd_lower =
		((char *) meta + sizeof(BM25MetaPageData)) - (char *) page;
	GenericXLogFinish(state);
	UnlockReleaseBuffer(buffer);
}

/*
 * Validate a metapage's magic and format version before trusting its contents.
 * Guards against a pg_fts shared library reading an index written by an
 * incompatible on-disk format (e.g. a .so upgraded/downgraded out of step with
 * the physical index) — the classic ".so vs catalog/on-disk skew".  Callers
 * pass the metapage of an index being opened for scan/insert/maintenance; a
 * mismatch raises a clear, actionable error rather than silently misreading
 * bytes.
 */
static void
bm25_check_meta(Page page, Relation index)
{
	BM25MetaPageData *meta = BM25PageGetMeta(page);

	if (meta->magic != BM25_MAGIC)
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("index \"%s\" is not a valid pg_fts index",
						RelationGetRelationName(index)),
				 errdetail("Metapage magic 0x%08X does not match the expected 0x%08X.",
						   meta->magic, BM25_MAGIC)));

	if (meta->version != BM25_VERSION)
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("index \"%s\" has pg_fts on-disk format version %u, but this build expects version %u",
						RelationGetRelationName(index),
						meta->version, BM25_VERSION),
				 errhint("REINDEX the index to rebuild it in the current format.")));
}

/*
 * Write all postings for one term into the segment's shared posting-page chain
 * via a BM25PostWriter, returning the term's first block + byte offset.
 * Postings are docid-sorted and packed into 128-doc FOR blocks (BM25BlockHdr +
 * three frame-of-reference bit-packed columns: docid-gaps, tfs, doclens), which
 * compresses the common case of many clustered docids into a few bits each.
 */
typedef struct BM25PostingSort
{
	uint64		docid;
	uint32		tf;
	uint32		doclen;
	uint32		posoff;			/* start index into bt->positions (valid iff bt->positions) */
	uint32		poscnt;			/* stored position count (<= tf; 0 if dropped) */
	ItemPointerData tid;
}			BM25PostingSort;

static int
cmp_posting_docid(const void *a, const void *b)
{
	uint64		da = ((const BM25PostingSort *) a)->docid;
	uint64		db = ((const BM25PostingSort *) b)->docid;

	if (da < db)
		return -1;
	if (da > db)
		return 1;
	return 0;
}

/*
 * Shared posting-page writer.  All terms in a segment append their blocks into
 * ONE chain of posting pages, so a rare term (a handful of postings) costs a
 * few dozen bytes instead of a whole 8 KB page -- critical for a Zipfian
 * vocabulary where most terms are tiny.  Each term records its start (block +
 * byte offset); the reader decodes blocks from there, counting postings until
 * it has read the term's df, following nextblk across page boundaries.
 */
typedef struct BM25PostWriter
{
	Relation	index;
	Buffer		buffer;
	GenericXLogState *state;
	Page		page;
} BM25PostWriter;

static void
pw_begin(BM25PostWriter *pw, Relation index)
{
	pw->index = index;
	pw->buffer = InvalidBuffer;
	pw->state = NULL;
	pw->page = NULL;
}

static void
pw_finish(BM25PostWriter *pw)
{
	if (pw->buffer != InvalidBuffer)
	{
		GenericXLogFinish(pw->state);
		UnlockReleaseBuffer(pw->buffer);
		pw->buffer = InvalidBuffer;
	}
}

/*
 * Append one term's postings to the shared writer.  Returns the block and byte
 * offset where the term's first block begins (for its dictionary entry).
 */
static void
bm25_write_postings(BM25PostWriter *pw, BuildTerm *bt,
					BlockNumber *firstblk, uint32 *firstoff)
{
	Relation	index = pw->index;
	BM25PostingSort *sorted;
	int			i;
	bool		start_recorded = false;
	uint32		term_max_tf = 0;

	*firstblk = InvalidBlockNumber;
	*firstoff = 0;

	sorted = (BM25PostingSort *) ((Size) bt->nposts * sizeof(BM25PostingSort) > MaxAllocSize
								  ? MemoryContextAllocHuge(CurrentMemoryContext,
													  Max(bt->nposts, 1) * sizeof(BM25PostingSort))
								  : palloc(Max(bt->nposts, 1) * sizeof(BM25PostingSort)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */
	for (i = 0; i < bt->nposts; i++)
	{
		sorted[i].docid = bm25_tid_to_docid(&bt->tids[i]);
		sorted[i].tf = bt->tfs[i];
		sorted[i].doclen = bt->doclens[i];
		sorted[i].posoff = bt->positions ? bt->posoff[i] : 0;
		sorted[i].poscnt = bt->positions ? bt->poscnt[i] : 0;
		sorted[i].tid = bt->tids[i];
	}
	if (bt->nposts > 1)
		qsort(sorted, bt->nposts, sizeof(BM25PostingSort), cmp_posting_docid);

	i = 0;
	while (i < bt->nposts)
	{
		uint64		gaps[BM25_BLOCK_SIZE];
		uint64		tfs[BM25_BLOCK_SIZE];
		uint64		dls[BM25_BLOCK_SIZE];
		unsigned char scratch[3 * (1 + (BM25_BLOCK_SIZE * 64 + 7) / 8)];
		int			sclen = 0;
		uint32		blk_max_tf = 0;
		uint32		blk_min_dl = UINT32_MAX;
		uint64		blk_first_docid = sorted[i].docid;
		uint64		prev_docid = sorted[i].docid;
		int			bcount = 0;
		int			blk_first = i;
		int			poslen = 0;
		uint64	   *posdeltas = NULL;
		unsigned char *posbuf = NULL;
		char	   *pageend;
		Size		need;
		Size		usable;
		char	   *dst;
		BM25BlockHdr *bh;

		/* gather up to BM25_BLOCK_SIZE postings into columns (SoA) */
		while (i < bt->nposts && bcount < BM25_BLOCK_SIZE)
		{
			gaps[bcount] = sorted[i].docid - prev_docid;	/* first gap is 0 */
			tfs[bcount] = sorted[i].tf;
			dls[bcount] = sorted[i].doclen;
			if (sorted[i].tf > blk_max_tf)
				blk_max_tf = sorted[i].tf;
			if (sorted[i].tf > term_max_tf)
				term_max_tf = sorted[i].tf;
			if (sorted[i].doclen < blk_min_dl)
				blk_min_dl = sorted[i].doclen;
			prev_docid = sorted[i].docid;
			bcount++;
			i++;
		}

		sclen += bm25_for_pack(gaps, bcount, scratch + sclen);
		sclen += bm25_for_pack(tfs, bcount, scratch + sclen);
		sclen += bm25_for_pack(dls, bcount, scratch + sclen);

		/*
		 * Build the positions blob for this block (WITH positions=on).  It packs
		 * Sum(tf) delta values -- each posting's positions delta-coded from 0 and
		 * reset at the posting boundary.  Sum(tf) per block is unbounded in
		 * principle (P1's build-alloc trap), so size the scratch from the ACTUAL
		 * Sum(tf) with a huge-safe alloc, never a fixed stack array.  If the
		 * resulting block would not fit even an empty page, write the block WITH
		 * NO positions (posbytelen=0) -- decode then yields NULL positions for
		 * these postings and phrase eval correctly falls back to recheck for
		 * those docids (bounded, and only for pathological Sum(tf)).
		 */
		usable = BLCKSZ - MAXALIGN(SizeOfPageHeaderData) - MAXALIGN(sizeof(BM25PageOpaqueData));
		if (bt->positions)
		{
			int64		sumtf = 0;
			int			k;
			int			j = 0;
			bool		all_pos = true;

			/* only build the positions blob if EVERY posting in this block has a
			 * complete position set (poscnt == tf).  A posting whose positions
			 * were dropped on a prior write (poscnt < tf) cannot contribute tf
			 * deltas, so drop the whole block's positions (posbytelen=0) and let
			 * phrase fall back to recheck for these docids. */
			for (k = 0; k < bcount; k++)
			{
				sumtf += (int64) tfs[k];
				if (sorted[blk_first + k].poscnt != (uint32) tfs[k])
					all_pos = false;
			}
			if (sumtf > 0 && all_pos)
			{
				Size		dlbytes = (Size) sumtf * sizeof(uint64);
				Size		pbbytes = 1 + ((Size) sumtf * 32 + 7) / 8;	/* FOR worst case */

				posdeltas = (uint64 *) (dlbytes > MaxAllocSize
										? MemoryContextAllocHuge(CurrentMemoryContext, dlbytes)
										: palloc(dlbytes));
				posbuf = (unsigned char *) (pbbytes > MaxAllocSize
											? MemoryContextAllocHuge(CurrentMemoryContext, pbbytes)
											: palloc(pbbytes));
				for (k = 0; k < bcount; k++)
				{
					const uint32 *pp = bt->positions + sorted[blk_first + k].posoff;
					uint32		tf = (uint32) tfs[k];
					uint32		prev = 0;
					uint32		t;

					for (t = 0; t < tf; t++)
					{
						/* positions are ascending within a posting; delta-code,
						 * reset prev to 0 at each posting boundary */
						posdeltas[j++] = (uint64) (pp[t] - prev);
						prev = pp[t];
					}
				}
				poslen = bm25_for_pack(posdeltas, (int) sumtf, posbuf);
			}
		}

		need = MAXALIGN(sizeof(BM25BlockHdr) + sclen + poslen);
		if (poslen > 0 && need > usable)
		{
			/* positions push the block past a whole page: drop them for this
			 * block (recheck fallback keeps phrase correct for these docids) */
			poslen = 0;
			need = MAXALIGN(sizeof(BM25BlockHdr) + sclen);
		}

		/* need a page with room for this block? */
		if (pw->buffer != InvalidBuffer)
		{
			pageend = (char *) pw->page + BLCKSZ - MAXALIGN(sizeof(BM25PageOpaqueData));
			if ((char *) pw->page + ((PageHeader) pw->page)->pd_lower + need > pageend)
			{
				Buffer		next = bm25_new_buffer(index);
				BlockNumber nextblk = BufferGetBlockNumber(next);

				BM25PageGetOpaque(pw->page)->nextblk = nextblk;
				GenericXLogFinish(pw->state);
				UnlockReleaseBuffer(pw->buffer);
				pw->buffer = next;
				pw->state = GenericXLogStart(index);
				pw->page = GenericXLogRegisterBuffer(pw->state, pw->buffer, GENERIC_XLOG_FULL_IMAGE);
				bm25_init_page(pw->page, BM25_POSTING);
			}
		}
		if (pw->buffer == InvalidBuffer)
		{
			pw->buffer = bm25_new_buffer(index);
			pw->state = GenericXLogStart(index);
			pw->page = GenericXLogRegisterBuffer(pw->state, pw->buffer, GENERIC_XLOG_FULL_IMAGE);
			bm25_init_page(pw->page, BM25_POSTING);
		}

		/* record the term's start at its first block */
		if (!start_recorded)
		{
			*firstblk = BufferGetBlockNumber(pw->buffer);
			*firstoff = (uint32) ((PageHeader) pw->page)->pd_lower;
			start_recorded = true;
		}

		dst = (char *) pw->page + ((PageHeader) pw->page)->pd_lower;
		bh = (BM25BlockHdr *) dst;
		bh->count = (uint32) bcount;
		bh->max_tf = blk_max_tf;
		bh->min_doclen = (blk_min_dl == UINT32_MAX ? 0 : blk_min_dl);
		bh->first_docid_hi = (uint32) (blk_first_docid >> 32);
		bh->first_docid_lo = (uint32) (blk_first_docid & 0xFFFFFFFF);
		bh->bytelen = (uint32) sclen;
		bh->posbytelen = (uint32) poslen;
		memcpy((char *) (bh + 1), scratch, sclen);
		if (poslen > 0)
			memcpy((char *) (bh + 1) + sclen, posbuf, poslen);
		((PageHeader) pw->page)->pd_lower += need;
		if (posdeltas)
			pfree(posdeltas);
		if (posbuf)
			pfree(posbuf);
	}

	pfree(sorted);
	bt->max_tf = term_max_tf;	/* dictionary reads this; no tfs[] rescan */
}

/*
 * Write the dictionary: sorted (term, df, firstposting) entries packed into a
 * chain of dictionary pages.  Returns the first dictionary block, and via
 * *indexstart the first page of the sparse block index (Invalid if empty).
 */
/*
 * One dictionary record streamed into bm25_write_dictionary_iter: the term
 * bytes plus the metadata a BM25DictEntry needs.  `term` need only stay valid
 * until the iterator's next() call.
 */
typedef struct DictRec
{
	const char *term;
	int			len;
	uint32		df;
	uint32		max_tf;
	BlockNumber firstposting;
	uint32		firstoffset;
} DictRec;

/* Iterator: fill *r with the next term in sorted order, return false at end. */
typedef bool (*DictNextFn) (void *state, DictRec *r);

/*
 * Write a segment's on-disk dictionary (dict pages + sparse block index) by
 * pulling terms from an iterator in sorted order.  O(1) caller memory: the only
 * state retained across the stream is the per-DICT-PAGE block-index metadata
 * (one entry per ~8KB page, i.e. index_size/BLCKSZ entries -- tiny), including a
 * copy of each page's first term's bytes so the block-index pass needs no
 * random access back into the (possibly spilled) term stream.
 */
static BlockNumber
bm25_write_dictionary_iter(Relation index, DictNextFn next, void *nstate,
						   BlockNumber *indexstart)
{
	BlockNumber first = InvalidBlockNumber;
	Buffer		buffer = InvalidBuffer;
	GenericXLogState *state = NULL;
	Page		page = NULL;
	DictRec		r;

	/* block index: (blk, first-term bytes) per dict page -- bounded by #pages */
	BlockNumber *pgblk = NULL;
	char	  **pgfirst = NULL;	/* first term bytes of each page (palloc'd) */
	int		   *pgfirstlen = NULL;
	int			npages = 0;
	int			pgcap = 0;
	int			j;

	*indexstart = InvalidBlockNumber;

	while (next(nstate, &r))
	{
		Size		need = MAXALIGN(sizeof(BM25DictEntry) + r.len);
		char	   *dst;
		bool		newpage = false;

		CHECK_FOR_INTERRUPTS();		/* per-term; page-copy semantics keep it safe */

		if (buffer == InvalidBuffer ||
			((PageHeader) page)->pd_lower + need >
			BLCKSZ - sizeof(BM25PageOpaqueData))
		{
			Buffer		nextbuf = bm25_new_buffer(index);
			BlockNumber nextblk = BufferGetBlockNumber(nextbuf);

			if (buffer != InvalidBuffer)
			{
				BM25PageGetOpaque(page)->nextblk = nextblk;
				GenericXLogFinish(state);
				UnlockReleaseBuffer(buffer);
			}
			else
				first = nextblk;

			buffer = nextbuf;
			state = GenericXLogStart(index);
			page = GenericXLogRegisterBuffer(state, buffer, GENERIC_XLOG_FULL_IMAGE);
			bm25_init_page(page, BM25_DICT);
			newpage = true;
		}

		if (newpage)
		{
			if (npages >= pgcap)
			{
				pgcap = Max(pgcap * 2, 64);
				pgblk = pgblk ? repalloc(pgblk, pgcap * sizeof(BlockNumber))
					: palloc(pgcap * sizeof(BlockNumber));
				pgfirst = pgfirst ? repalloc(pgfirst, pgcap * sizeof(char *))
					: palloc(pgcap * sizeof(char *));
				pgfirstlen = pgfirstlen ? repalloc(pgfirstlen, pgcap * sizeof(int))
					: palloc(pgcap * sizeof(int));
			}
			pgblk[npages] = BufferGetBlockNumber(buffer);
			pgfirstlen[npages] = r.len;
			pgfirst[npages] = (char *) palloc(Max(r.len, 1));
			memcpy(pgfirst[npages], r.term, r.len);
			npages++;
		}

		dst = (char *) page + ((PageHeader) page)->pd_lower;
		{
			BM25DictEntry *de = (BM25DictEntry *) dst;

			de->termlen = r.len;
			de->df = r.df;
			de->max_tf = r.max_tf;
			de->firstposting = r.firstposting;
			de->firstoffset = r.firstoffset;
			memcpy(de->term, r.term, r.len);
		}
		((PageHeader) page)->pd_lower += need;
	}

	if (buffer != InvalidBuffer)
	{
		GenericXLogFinish(state);
		UnlockReleaseBuffer(buffer);
	}

	/* write the sparse block index: one entry per dict page, in term order */
	if (npages > 0)
	{
		BlockNumber ifirst = InvalidBlockNumber;
		Buffer		ib = InvalidBuffer;
		Page		ip = NULL;
		GenericXLogState *istate = NULL;

		for (j = 0; j < npages; j++)
		{
			int			flen = pgfirstlen[j];
			Size		need = MAXALIGN(offsetof(BM25DictIndexEntry, term) + flen);
			char	   *dst;
			BM25DictIndexEntry *ie;

			if (ib == InvalidBuffer ||
				((PageHeader) ip)->pd_lower + need >
				BLCKSZ - sizeof(BM25PageOpaqueData))
			{
				Buffer		nextbuf = bm25_new_buffer(index);
				BlockNumber nextblk = BufferGetBlockNumber(nextbuf);

				if (ib != InvalidBuffer)
				{
					BM25PageGetOpaque(ip)->nextblk = nextblk;
					GenericXLogFinish(istate);
					UnlockReleaseBuffer(ib);
				}
				else
					ifirst = nextblk;
				ib = nextbuf;
				istate = GenericXLogStart(index);
				ip = GenericXLogRegisterBuffer(istate, ib, GENERIC_XLOG_FULL_IMAGE);
				bm25_init_page(ip, BM25_DICTINDEX);
			}
			dst = (char *) ip + ((PageHeader) ip)->pd_lower;
			ie = (BM25DictIndexEntry *) dst;
			ie->blk = pgblk[j];
			ie->termlen = flen;
			memcpy(ie->term, pgfirst[j], flen);
			((PageHeader) ip)->pd_lower += need;
		}
		if (ib != InvalidBuffer)
		{
			GenericXLogFinish(istate);
			UnlockReleaseBuffer(ib);
		}
		*indexstart = ifirst;
	}
	for (j = 0; j < npages; j++)
		pfree(pgfirst[j]);
	if (pgblk)
		pfree(pgblk);
	if (pgfirst)
		pfree(pgfirst);
	if (pgfirstlen)
		pfree(pgfirstlen);

	return first;
}

/*
 * Iterator over an in-memory bs->terms[] (the segment-flush path): postings[]/
 * offsets[] carry the firstposting/firstoffset for each term.
 */
typedef struct DictArrayIter
{
	BM25BuildState *bs;
	BlockNumber *postings;
	uint32	   *offsets;
	int			i;
} DictArrayIter;

static bool
dict_array_next(void *st, DictRec *r)
{
	DictArrayIter *it = (DictArrayIter *) st;
	BuildTerm  *bt;

	if (it->i >= it->bs->nterms)
		return false;
	bt = &it->bs->terms[it->i];
	r->term = bt->term;
	r->len = bt->len;
	r->df = bt->nposts;
	r->max_tf = bt->max_tf;
	r->firstposting = it->postings[it->i];
	r->firstoffset = it->offsets[it->i];
	it->i++;
	return true;
}

/* Thin wrapper: write a dictionary from an in-memory bs->terms[] array. */
static BlockNumber
bm25_write_dictionary(Relation index, BM25BuildState *bs,
					  BlockNumber *postings, uint32 *offsets,
					  BlockNumber *indexstart)
{
	DictArrayIter it;

	it.bs = bs;
	it.postings = postings;
	it.offsets = offsets;
	it.i = 0;
	return bm25_write_dictionary_iter(index, dict_array_next, &it, indexstart);
}

/*
 * Iterator over an in-memory bs->terms[] yielding only term bytes (the trigram
 * writer needs term/len + the running ordinal; not postings/offsets).
 */
typedef struct DictTermArrayIter
{
	BM25BuildState *bs;
	int			i;
} DictTermArrayIter;

static bool
dict_term_array_next(void *st, DictRec *r)
{
	DictTermArrayIter *it = (DictTermArrayIter *) st;
	BuildTerm  *bt;

	if (it->i >= it->bs->nterms)
		return false;
	bt = &it->bs->terms[it->i];
	r->term = bt->term;
	r->len = bt->len;
	r->df = bt->nposts;
	r->max_tf = bt->max_tf;
	r->firstposting = InvalidBlockNumber;
	r->firstoffset = 0;
	it->i++;
	return true;
}

/* forward decl: trigram index writer (pg_fts_trgm_index.c, included below) */
static BlockNumber bm25_write_trigrams(Relation index, BM25BuildState *bs);
static BlockNumber bm25_write_trigrams_iter(Relation index, DictNextFn next,
											void *nstate);
/* forward decls: blob read/write live in pg_fts_trgm_index.c (included below) */
static BlockNumber bm25_write_blob(Relation index, const uint8 *data, Size len);
static uint8 *bm25_read_blob(Relation index, BlockNumber blk, Size len);

/*
 * Write one immutable segment (dictionary + postings + trigram index) from a
 * populated build state, filling *seg.  The build state's terms must already
 * be sorted.  livedocs starts empty (no tombstones); segments share the global
 * docid space via heap TIDs.
 */
static void
bm25_write_segment(Relation index, BM25BuildState *bs, BM25SegMeta *seg)
{
	BlockNumber *postings;
	uint32	   *offsets;
	BM25PostWriter pw;
	int			i;

	postings = (BlockNumber *) palloc(Max(bs->nterms, 1) * sizeof(BlockNumber));	/* alloc-ok: bs->nterms is a single build/pending segment, bounded by maintenance_work_mem (the merge path spills to disk instead) */
	offsets = (uint32 *) palloc(Max(bs->nterms, 1) * sizeof(uint32));	/* alloc-ok: see postings[] above */
	pw_begin(&pw, index);
	for (i = 0; i < bs->nterms; i++)
	{
		/* per-term: safe to cancel here (GenericXLog works on a page copy, so a
		 * throw mid-write leaves on-disk pages untouched; unwind releases the
		 * buffer lock and leaks at most the new segment's pages) */
		CHECK_FOR_INTERRUPTS();
		bm25_write_postings(&pw, &bs->terms[i], &postings[i], &offsets[i]);
	}
	pw_finish(&pw);

	MemSet(seg, 0, sizeof(BM25SegMeta));
	seg->dictstart = bm25_write_dictionary(index, bs, postings, offsets, &seg->dictindexstart);
	seg->trgmstart = bm25_write_trigrams(index, bs);
	seg->livedocs = InvalidBlockNumber;
	seg->ndocs = bs->ndocs;
	seg->sumdoclen = bs->sumdoclen;
	seg->nterms = bs->nterms;
	seg->ndeleted = 0;
	seg->livedocslen = 0;
	pfree(postings);
	pfree(offsets);
}

/*
 * Append a segment descriptor to the metapage directory and fold its doc stats
 * into the corpus totals.  The directory is a fixed array in the metapage; the
 * size-tiered merge keeps the live segment count far below BM25_MAX_SEGMENTS,
 * so hitting the cap means merging is not keeping up -- we raise a clear error
 * (data is intact) rather than chain overflow directory pages, which would add
 * complexity to every reader for a case the merge policy makes unreachable.
 */
static void
bm25_meta_add_segment(Relation index, const BM25SegMeta *seg)
{
	Buffer		buf = ReadBuffer(index, BM25_METAPAGE_BLKNO);
	GenericXLogState *state;
	Page		page;
	BM25MetaPageData *m;

	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	m = BM25PageGetMeta(page);
	if (m->nsegments >= BM25_MAX_SEGMENTS)
	{
		GenericXLogAbort(state);
		UnlockReleaseBuffer(buf);
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("bm25 index \"%s\" reached the maximum of %d segments",
						RelationGetRelationName(index), BM25_MAX_SEGMENTS),
				 errhint("Run VACUUM to merge segments, or REINDEX to rebuild.")));
	}
	m->segs[m->nsegments] = *seg;
	m->nsegments++;
	m->generation++;			/* directory changed: invalidate concurrent scan snapshots */
	m->ndocs += seg->ndocs;
	m->sumdoclen += seg->sumdoclen;
	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}


/* ---- bounded, streaming k-way segment merge --------------------------------
 *
 * bm25_read_segment_into (above) decodes an ENTIRE segment's postings into the
 * build state; merging K segments that way buffers all their live postings at
 * once, so the final full compaction of a large index holds the whole index in
 * RAM and can OOM the server.  The streaming merge below bounds peak memory to
 * ONE term's merged postings at a time (plus the per-segment dictionary
 * metadata, which is small relative to the postings).
 *
 * Every segment's dictionary is written term-sorted (bm25_write_dictionary
 * emits bs->terms in cmp_buildterm order), so a merge is a k-way merge of
 * sorted streams: read each source's dictionary METADATA (term/df/firstposting/
 * firstoffset, no posting bodies), then sweep the distinct terms in sorted
 * order; for each term decode ONLY that term's postings from the segments that
 * carry it, tombstone-filter + merge into one single-term build state, write
 * that term's postings immediately, record its dict metadata, and free the
 * term's postings before advancing.  The rare huge stopword is covered by the
 * FTS_ALLOC_MAYBE_HUGE path in add_posting/bm25_write_postings.
 */
typedef struct MergeDictTerm
{
	char	   *term;			/* term bytes (points INTO the pinned dict page) */
	uint32		termlen;
	uint32		df;
	BlockNumber firstposting;
	uint32		firstoffset;
} MergeDictTerm;

/*
 * A merge source is a forward cursor over one segment's term-sorted dictionary.
 * It keeps only the CURRENT dict page pinned (~8KB) and exposes the current
 * term; the k-way merge peeks the current term of each source and advances the
 * ones carrying the smallest.  This keeps the merge's per-source footprint O(1)
 * (one page) instead of loading the segment's entire vocabulary into memory --
 * critical for a large, high-vocabulary corpus where the sum of all input
 * dictionaries would otherwise be many GB, unbounded by maintenance_work_mem.
 *
 * `cur` is valid (points into `curbuf`'s page) iff `valid`; the term bytes it
 * references stay live until the next merge_source_advance() on this source, so
 * the merge must consume/copy them (add_posting does) before advancing.
 */
typedef struct MergeSource
{
	Relation	index;
	BlockNumber nextblk;			/* next dict page to read, or Invalid */
	MergeDictTerm *page;			/* decoded entries of the current page (copied) */
	char	   *pagebytes;			/* backing store for this page's term bytes */
	int			npage;				/* entries in page[] */
	int			pcur;				/* index of current entry within page[] */
	int			pagecap;			/* capacity of page[]/pagebytes reuse */
	Size		bytescap;
	MergeDictTerm cur;				/* current term (points into pagebytes) */
	bool		valid;				/* cur holds a term (source not exhausted) */
	MemoryContext ctx;
	uint8	   *tombbuf;			/* tombstone bitmap blob, or NULL */
	sm_t		tomb;
	bool		hastomb;
	sm_cursor_cached_t tombcache;
} MergeSource;

/*
 * Load the next dict page (src->nextblk) into src->page[] / src->pagebytes,
 * copying each entry's metadata and term bytes so the page buffer can be
 * released immediately (no page pin held across posting reads).  Skips empty
 * pages.  Sets src->npage = 0 and returns when the dictionary is exhausted.
 * page[]/pagebytes are sized by ONE page's contents (bounded by BLCKSZ), reused
 * across pages -- so a source's footprint stays O(one page), not O(vocabulary).
 */
static void
merge_source_load_page(MergeSource *src)
{
	MemoryContext old = MemoryContextSwitchTo(src->ctx);

	src->npage = 0;
	src->pcur = 0;

	while (src->npage == 0 && src->nextblk != InvalidBlockNumber)
	{
		Buffer		buffer;
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;
		int			n;
		Size		used;

		CHECK_FOR_INTERRUPTS();		/* between pages, no lock held across yields */
		buffer = ReadBuffer(src->index, src->nextblk);
		LockBuffer(buffer, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buffer);
		ptr = (char *) PageGetContents(page);
		end = (char *) page + ((PageHeader) page)->pd_lower;
		next = BM25PageGetOpaque(page)->nextblk;

		/* count entries + term bytes on this page (bounded by BLCKSZ) */
		n = 0;
		used = 0;
		while (ptr < end)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;

			n++;
			used += de->termlen;
			ptr += MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);
		}

		if (n > src->pagecap)
		{
			src->pagecap = Max(n, src->pagecap ? src->pagecap * 2 : 256);
			src->page = src->page
				? repalloc(src->page, src->pagecap * sizeof(MergeDictTerm))
				: palloc(src->pagecap * sizeof(MergeDictTerm));
		}
		if (used > src->bytescap || (n > 0 && src->pagebytes == NULL))
		{
			/* floor at BLCKSZ so pagebytes is non-NULL for any n>0 page, even the
			 * degenerate all-zero-length-term case (avoids memcpy(NULL,...,0)) */
			src->bytescap = Max(Max(used, (Size) 1), src->bytescap ? src->bytescap * 2 : (Size) BLCKSZ);
			src->pagebytes = src->pagebytes
				? repalloc(src->pagebytes, src->bytescap)
				: palloc(src->bytescap);
		}

		ptr = (char *) PageGetContents(page);
		used = 0;
		n = 0;
		while (ptr < end)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;
			MergeDictTerm *mt = &src->page[n++];

			mt->termlen = de->termlen;
			mt->df = de->df;
			mt->firstposting = de->firstposting;
			mt->firstoffset = de->firstoffset;
			mt->term = src->pagebytes + used;
			memcpy(mt->term, de->term, de->termlen);
			used += de->termlen;
			ptr += MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);
		}
		src->npage = n;
		src->nextblk = next;
		UnlockReleaseBuffer(buffer);
	}

	if (src->npage > 0)
	{
		src->cur = src->page[0];
		src->valid = true;
	}
	else
		src->valid = false;

	MemoryContextSwitchTo(old);
}

/* Advance the cursor to the next term, loading the next page as needed. */
static void
merge_source_advance(MergeSource *src)
{
	src->pcur++;
	if (src->pcur < src->npage)
		src->cur = src->page[src->pcur];
	else
		merge_source_load_page(src);	/* refills page[], sets cur/valid */
}

/*
 * Open a merge source as a forward, page-at-a-time cursor over one segment's
 * term-sorted dictionary metadata (no posting bodies).  Positions it on the
 * first term.  Only one dict page's worth of metadata is resident at a time.
 */
static void
merge_source_open(Relation index, const BM25SegMeta *seg, MergeSource *src,
				  MemoryContext ctx)
{
	MemoryContext old = MemoryContextSwitchTo(ctx);

	src->index = index;
	src->ctx = ctx;
	src->nextblk = seg->dictstart;
	src->page = NULL;
	src->pagebytes = NULL;
	src->npage = 0;
	src->pcur = 0;
	src->pagecap = 0;
	src->bytescap = 0;
	src->valid = false;
	src->tombbuf = NULL;
	src->hastomb = false;
	memset(&src->tombcache, 0, sizeof(src->tombcache));

	if (seg->livedocs != InvalidBlockNumber && seg->livedocslen > 0)
	{
		src->tombbuf = bm25_read_blob(index, seg->livedocs, seg->livedocslen);
		sm_open(&src->tomb, (uint8_t *) src->tombbuf, seg->livedocslen);
		src->hastomb = true;
	}

	merge_source_load_page(src);	/* position on the first term */
	MemoryContextSwitchTo(old);

}

/* Order two term keys the same way cmp_buildterm orders BuildTerms. */
static int
merge_cmp_term(const char *a, uint32 alen, const char *b, uint32 blen)
{
	uint32		min = Min(alen, blen);
	int			c = memcmp(a, b, min);

	if (c != 0)
		return c;
	return (int) alen - (int) blen;
}

/*
 * Dictionary-metadata spill for the streaming merge.  As the k-way merge
 * produces each output term (in sorted order) we append its dict record --
 * term bytes + df/max_tf/firstposting/firstoffset -- to a temp BufFile instead
 * of an in-memory array.  The whole merged VOCABULARY is thus never resident;
 * only one record at a time is, both when writing the spill and when streaming
 * it back into bm25_write_dictionary_iter and the trigram writer.  This is what
 * bounds the merge's memory on a huge, high-vocabulary corpus.
 *
 * Record layout: [int termlen][uint32 df][uint32 max_tf][BlockNumber fp]
 *                [uint32 fo][termlen term bytes].
 */
typedef struct DictSpill
{
	BufFile    *bf;
	char	   *tbuf;			/* reusable read buffer for term bytes */
	int			tcap;
	DictRec		cur;			/* last record read back (term points into tbuf) */
	int			ordinal;		/* ordinal of cur among all spilled records */
} DictSpill;

static void
dict_spill_begin(DictSpill *sp)
{
	sp->bf = BufFileCreateTemp(false);
	sp->tbuf = NULL;
	sp->tcap = 0;
	sp->ordinal = -1;
}

static void
dict_spill_write(DictSpill *sp, const DictRec *r)
{
	BufFileWrite(sp->bf, (void *) &r->len, sizeof(int));
	BufFileWrite(sp->bf, (void *) &r->df, sizeof(uint32));
	BufFileWrite(sp->bf, (void *) &r->max_tf, sizeof(uint32));
	BufFileWrite(sp->bf, (void *) &r->firstposting, sizeof(BlockNumber));
	BufFileWrite(sp->bf, (void *) &r->firstoffset, sizeof(uint32));
	if (r->len > 0)
		BufFileWrite(sp->bf, (void *) r->term, r->len);
}

/* Rewind to the start for a (re)read pass. */
static void
dict_spill_rewind(DictSpill *sp)
{
	if (BufFileSeek(sp->bf, 0, 0, SEEK_SET) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("could not rewind pg_fts merge dictionary spill file")));
	sp->ordinal = -1;
}

/* DictNextFn over the spill: reads the next record into sp->cur. */
static bool
dict_spill_next(void *st, DictRec *out)
{
	DictSpill  *sp = (DictSpill *) st;
	size_t		n;

	n = BufFileReadMaybeEOF(sp->bf, &sp->cur.len, sizeof(int), true);
	if (n == 0)
		return false;			/* clean EOF */
	BufFileReadExact(sp->bf, &sp->cur.df, sizeof(uint32));
	BufFileReadExact(sp->bf, &sp->cur.max_tf, sizeof(uint32));
	BufFileReadExact(sp->bf, &sp->cur.firstposting, sizeof(BlockNumber));
	BufFileReadExact(sp->bf, &sp->cur.firstoffset, sizeof(uint32));
	if (sp->cur.len > sp->tcap)
	{
		sp->tcap = Max(sp->cur.len, sp->tcap ? sp->tcap * 2 : 256);
		sp->tbuf = sp->tbuf ? repalloc(sp->tbuf, sp->tcap) : palloc(sp->tcap);
	}
	if (sp->cur.len > 0)
		BufFileReadExact(sp->bf, sp->tbuf, sp->cur.len);
	sp->cur.term = sp->tbuf;
	sp->ordinal++;
	if (out != &sp->cur)
		*out = sp->cur;
	return true;
}

static void
dict_spill_end(DictSpill *sp)
{
	BufFileClose(sp->bf);
	if (sp->tbuf)
		pfree(sp->tbuf);
}


/*
 * Streaming k-way merge of the `chosen` segments into ONE new segment, bounded
 * to one term's postings at a time.  Writes the new segment's pages and fills
 * *seg (dictstart/dictindexstart) plus the corpus totals in bs (ndocs,
 * sumdoclen).  All allocations live in bs->ctx, which the caller owns.
 */
static void
bm25_merge_segments_streaming(Relation index, const BM25SegMeta *chosen,
							  uint32 nsel, BM25BuildState *bs, BM25SegMeta *seg)
{
	MergeSource *srcv;
	BM25PostWriter pw;
	DictSpill	spill;			/* per-output-term dict metadata, spilled to disk */
	uint32		nout = 0;
	uint32		i;
	MemoryContext old = MemoryContextSwitchTo(bs->ctx);

	srcv = (MergeSource *) palloc0(nsel * sizeof(MergeSource));
	for (i = 0; i < nsel; i++)
	{
		bs->sumdoclen += chosen[i].sumdoclen;
		bs->ndocs += chosen[i].ndocs - chosen[i].ndeleted;
		merge_source_open(index, &chosen[i], &srcv[i], bs->ctx);
	}

	dict_spill_begin(&spill);

	pw_begin(&pw, index);

	for (;;)
	{
		const char *smterm = NULL;
		uint32		smlen = 0;
		MemoryContext termctx;
		MemoryContext told;
		BM25BuildState tbs;
		BuildTerm  *bt;
		BlockNumber fb;
		uint32		fo;

		CHECK_FOR_INTERRUPTS();		/* per output term; no lock/window held */

		/* smallest current term across all live cursors */
		for (i = 0; i < nsel; i++)
		{
			MergeSource *s = &srcv[i];

			if (!s->valid)
				continue;
			if (smterm == NULL ||
				merge_cmp_term(s->cur.term, s->cur.termlen,
							   smterm, smlen) < 0)
			{
				smterm = s->cur.term;
				smlen = s->cur.termlen;
			}
		}
		if (smterm == NULL)
			break;				/* all cursors exhausted */

		/* gather this term's postings from every segment that carries it into a
		 * fresh single-term build state in its own child context */
		termctx = AllocSetContextCreate(bs->ctx, "bm25 merge term",
										ALLOCSET_DEFAULT_SIZES);
		told = MemoryContextSwitchTo(termctx);

		/*
		 * Copy the smallest term into termctx-owned memory: smterm points into
		 * one source's page, which merge_source_advance() below overwrites as
		 * cursors advance, so we must not alias it during the gather loop.  Sized
		 * to the real term length (no fixed cap), freed with termctx each pass.
		 */
		{
			char	   *smcopy = (char *) palloc(Max(smlen, 1u));

			memcpy(smcopy, smterm, smlen);
			smterm = smcopy;
		}

		tbs.ctx = termctx;
		tbs.want_positions = bs->want_positions;
		tbs.terms = NULL;
		tbs.nterms = 0;
		tbs.maxterms = 0;
		tbs.ndocs = 0;
		tbs.sumdoclen = 0;
		bm25_build_ht_init(&tbs);

		for (i = 0; i < nsel; i++)
		{
			MergeSource *s = &srcv[i];
			MergeDictTerm *mt;
			BM25Posting *post;
			uint32	   *posarena = NULL;
			int			np,
						k;

			if (!s->valid)
				continue;
			mt = &s->cur;
			if (merge_cmp_term(mt->term, mt->termlen, smterm, smlen) != 0)
				continue;		/* this segment lacks the smallest term */

			np = bm25_decode_term(index, mt->firstposting, mt->firstoffset,
								  mt->df, &post, NULL, bs->want_positions,
								  &posarena);
			for (k = 0; k < np; k++)
			{
				if (s->hastomb &&
					sm_contains_cached(&s->tomb,
									   bm25_tid_to_docid(&post[k].tid),
									   &s->tombcache))
					continue;	/* tombstoned: physically drop */
				add_posting(&tbs, mt->term, mt->termlen,
							&post[k].tid, post[k].tf, post[k].doclen,
							post[k].pos, post[k].pos ? (int) post[k].tf : 0);
			}
			pfree(post);
			if (posarena)
				pfree(posarena);
			merge_source_advance(s);	/* advance the cursors that matched this term */
		}
		MemoryContextSwitchTo(told);

		/* the term may have been entirely tombstoned away */
		if (tbs.nterms == 0)
		{
			MemoryContextDelete(termctx);
			continue;
		}
		Assert(tbs.nterms == 1);
		bt = &tbs.terms[0];

		/* write this term's postings now (sets bt->max_tf), then spill only its
		 * small dictionary metadata to disk and free the postings arena */
		bm25_write_postings(&pw, bt, &fb, &fo);

		{
			DictRec		rec;

			rec.term = bt->term;
			rec.len = bt->len;
			rec.df = bt->nposts;
			rec.max_tf = bt->max_tf;
			rec.firstposting = fb;
			rec.firstoffset = fo;
			dict_spill_write(&spill, &rec);
		}
		nout++;

		MemoryContextDelete(termctx);	/* frees this term's postings */
	}

	pw_finish(&pw);

	/*
	 * Emit the dictionary and trigram index by streaming the spilled per-term
	 * metadata back from disk -- one record resident at a time, so neither the
	 * merged vocabulary's dict metadata nor the term bytes are ever fully in
	 * memory.  bm25_write_trigrams_iter still accumulates its trigram->ordinal
	 * map (bounded by the vocabulary's trigram content, huge-safe), but no
	 * longer needs a resident bs->terms[] array.
	 */
	bs->nterms = (int) nout;

	MemSet(seg, 0, sizeof(BM25SegMeta));
	dict_spill_rewind(&spill);
	seg->dictstart = bm25_write_dictionary_iter(index, dict_spill_next, &spill,
												&seg->dictindexstart);
	dict_spill_rewind(&spill);
	seg->trgmstart = bm25_write_trigrams_iter(index, dict_spill_next, &spill);
	/* both passes must consume exactly the nout spilled records; a mismatch would
	 * mean the trigram->term-ordinal mapping diverged from the dict write order */
	Assert(spill.ordinal + 1 == (int) nout);
	seg->livedocs = InvalidBlockNumber;
	seg->ndocs = bs->ndocs;
	seg->sumdoclen = bs->sumdoclen;
	seg->nterms = bs->nterms;
	seg->ndeleted = 0;
	seg->livedocslen = 0;

	dict_spill_end(&spill);
	MemoryContextSwitchTo(old);
}

/* Recycle a chained page list (dict/trigram/posting/data) to the FSM. */
static void
bm25_free_chain(Relation index, BlockNumber blk)
{
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		next = BM25PageGetOpaque(BufferGetPage(buf))->nextblk;
		UnlockReleaseBuffer(buf);
		RecordFreeIndexPage(index, blk);
		blk = next;
	}
}

/* Free all pages of a segment (dict + each term's postings + trigram dir+data). */
static void
bm25_free_segment(Relation index, const BM25SegMeta *seg)
{
	BlockNumber blk = seg->dictstart;
	BlockNumber postchain = InvalidBlockNumber;

	/* dictionary pages; capture the shared posting chain's first block */
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		ptr = (char *) PageGetContents(page);
		end = (char *) page + ((PageHeader) page)->pd_lower;
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;
			Size		esize = MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);

			/* all terms share ONE posting chain; the first term names its head */
			if (postchain == InvalidBlockNumber)
				postchain = de->firstposting;
			ptr += esize;
		}
		UnlockReleaseBuffer(buf);
		RecordFreeIndexPage(index, blk);
		blk = next;
	}
	if (postchain != InvalidBlockNumber)
		bm25_free_chain(index, postchain);	/* free the shared posting chain once */

	/* trigram directory pages (+ their data blobs) */
	blk = seg->trgmstart;
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		ptr = (char *) PageGetContents(page);
		end = (char *) page + ((PageHeader) page)->pd_lower;
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25TrgmEntry *te = (BM25TrgmEntry *) ptr;

			bm25_free_chain(index, te->firstdata);
			ptr += MAXALIGN(sizeof(BM25TrgmEntry));
		}
		UnlockReleaseBuffer(buf);
		RecordFreeIndexPage(index, blk);
		blk = next;
	}

	if (seg->livedocs != InvalidBlockNumber)
		bm25_free_chain(index, seg->livedocs);
	if (seg->dictindexstart != InvalidBlockNumber)
		bm25_free_chain(index, seg->dictindexstart);
}

/*
 * Size-tiered segment merge (a Lucene TieredMergePolicy in miniature).
 *
 * Rather than merging the whole directory into one segment on every trigger
 * (O(index) write amplification under steady inserts), we merge only a RUN of
 * similarly-sized segments at a time: sort the live segments by size (live doc
 * count) and, if the smallest ones fall within a size factor of each other,
 * merge just those into one new segment.  Small flushes coalesce cheaply while
 * large segments are rarely rewritten.  We loop until no tier qualifies and the
 * count is within budget, so query cost stays O(nsegments) small.  Tombstoned
 * docs are dropped as segments are read.  Called after a flush, from build, and
 * from VACUUM.
 */
#define BM25_MERGE_THRESHOLD 8		/* keep the live segment count at or below this */
#define BM25_MERGE_TIER_MIN 4		/* merge when >= this many same-tier segments */
#define BM25_MERGE_SIZE_FACTOR 3.0	/* "same tier" = within this size ratio */

/* segment (index,size) pair for sorting merge candidates by size */
typedef struct MergeCand
{
	uint32		idx;
	double		size;
}			MergeCand;

static int
cmp_mergecand(const void *a, const void *b)
{
	double		sa = ((const MergeCand *) a)->size;
	double		sb = ((const MergeCand *) b)->size;

	return (sa < sb) ? -1 : (sa > sb) ? 1 : 0;
}

/*
 * Merge one selected set of segments (by directory index) into a single new
 * segment, rewrite the metapage directory to drop the merged ones (preserving
 * the order of the rest) and append the new segment, then recycle the merged
 * segments' pages.  Returns true on success, false if the directory changed
 * underneath (caller stops).
 */
/*
 * Merge a specific set of segment descriptors (by CONTENT, not directory index)
 * into one new segment, writing its pages but NOT touching the metapage
 * directory.  Returns the new descriptor in *out.  Safe to run concurrently
 * with other callers merging DISJOINT descriptor sets: page appends are
 * serialized by the relation extension lock (in bm25_build_flush_segment's
 * peer path we lock explicitly; here bm25_write_segment appends under the same
 * discipline when IsInParallelMode()).  The caller (leader) removes the
 * consumed descriptors and installs *out in a single metapage update.
 */
static void
bm25_merge_group_to_seg(Relation index, const BM25SegMeta *group, uint32 ngroup,
						BM25SegMeta *out)
{
	BM25BuildState bs;

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 merge group",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;

	/* Streaming k-way merge (bounded memory); page appends are serialized
	 * per-page inside bm25_new_buffer under the extension lock. */
	bm25_merge_segments_streaming(index, group, ngroup, &bs, out);
	out->ndocs = bs.ndocs;
	out->sumdoclen = bs.sumdoclen;

	MemoryContextDelete(bs.ctx);
}

static bool
bm25_merge_selected(Relation index, const uint32 *sel, uint32 nsel)
{
	BM25MetaPageData meta;
	BM25BuildState bs;
	BM25SegMeta newseg;
	BM25SegMeta chosen[BM25_MAX_SEGMENTS];
	uint32		i;

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
		UnlockReleaseBuffer(mb);
	}
	for (i = 0; i < nsel; i++)
	{
		if (sel[i] >= meta.nsegments)
			return false;		/* directory changed under us */
		chosen[i] = meta.segs[sel[i]];
	}

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 merge segs",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;

	/* Streaming k-way merge: bounded to one term's postings at a time, so a
	 * full compaction of a large index does not buffer the whole index in RAM
	 * (see bm25_merge_segments_streaming). */
	bm25_merge_segments_streaming(index, chosen, nsel, &bs, &newseg);
	newseg.ndocs = bs.ndocs;
	newseg.sumdoclen = bs.sumdoclen;

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *state;
		Page		mp;
		BM25MetaPageData *m;
		bool		same = true;

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		state = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(state, mb, 0);
		m = BM25PageGetMeta(mp);

		/* single-writer (VACUUM/flush/build) context, but re-check the chosen
		 * descriptors still match before committing the rewrite */
		if (m->nsegments != meta.nsegments)
			same = false;
		for (i = 0; same && i < nsel; i++)
			if (memcmp(&m->segs[sel[i]], &chosen[i], sizeof(BM25SegMeta)) != 0)
				same = false;

		if (same)
		{
			BM25SegMeta kept[BM25_MAX_SEGMENTS];
			uint32		nkept = 0;
			uint32		j;
			bool		issel;

			/* keep every segment not in sel[], preserving order */
			for (i = 0; i < m->nsegments; i++)
			{
				issel = false;
				for (j = 0; j < nsel; j++)
					if (sel[j] == i)
					{
						issel = true;
						break;
					}
				if (!issel)
					kept[nkept++] = m->segs[i];
			}
			kept[nkept++] = newseg;	/* append the merged segment */
			memcpy(m->segs, kept, nkept * sizeof(BM25SegMeta));
			m->nsegments = nkept;
			m->generation++;	/* directory changed: invalidate concurrent scan snapshots */
			/* corpus totals unchanged (same docs, tombstones already excluded) */
			GenericXLogFinish(state);
			UnlockReleaseBuffer(mb);
			for (i = 0; i < nsel; i++)
				bm25_free_segment(index, &chosen[i]);
			IndexFreeSpaceMapVacuum(index);
			MemoryContextDelete(bs.ctx);
			return true;
		}
		else
		{
			/* directory changed; abandon (new segment leaks until next merge/
			 * REINDEX -- rare, single-writer path) */
			GenericXLogAbort(state);
			UnlockReleaseBuffer(mb);
			MemoryContextDelete(bs.ctx);
			return false;
		}
	}
}

/*
 * Merge ALL live segments into a single segment (explicit full compaction).
 * Used by fts_merge() so an on-demand call actually produces an optimal,
 * single-segment index (the tiered bm25_merge_segments only coalesces
 * same-size tiers and may deliberately leave several segments).  Merges in
 * bounded batches (BM25_MAX_SEGMENTS worth of selection at a time is fine since
 * a build/merge never exceeds the cap) and loops until one segment remains.
 * Returns true if it changed anything.
 */
/* ---- parallel merge (compact many segments into few, in parallel) ----
 *
 * The leader partitions the live segments into W disjoint groups; each worker
 * merges ONE group into one new segment (bm25_merge_group_to_seg -- writes
 * pages only, no directory touch) and reports the new descriptor via DSM.  The
 * leader then performs a SINGLE metapage update: drop all the consumed source
 * descriptors and install the W new ones.  This confines the expensive
 * decode/re-encode to parallel workers and keeps the directory swap serial and
 * atomic (no concurrent-swap race).  Result: W segments; caller may run a
 * final (cheap, W-way) pass if it wants exactly one.
 *
 * Future work: Level-2 could recurse the parallel merge (W -> W/2 -> ... -> 1) so
 * even the final combine parallelizes; deferred -- one parallel pass already
 * removes the dominant per-segment decode cost from the serial path.
 */
#define PARALLEL_KEY_BM25_MERGE		UINT64CONST(0xB250000000000010)

typedef struct BM25MergeShared
{
	Oid			heaprelid;
	Oid			indexrelid;
	int			ngroups;		/* number of worker groups */
	int			nsrc;			/* total source segments */
	slock_t		mutex;
	/* filled by workers: the merged-segment descriptor per group */
	BM25SegMeta outseg[BM25_MAX_SEGMENTS];
	bool		outvalid[BM25_MAX_SEGMENTS];
	/* group layout: src[groupoff[g] .. groupoff[g+1]) are group g's sources */
	int			groupoff[BM25_MAX_SEGMENTS + 1];
	BM25SegMeta src[BM25_MAX_SEGMENTS];
}			BM25MergeShared;

static void bm25_merge_one_group(Relation index, BM25MergeShared *ms, int g);

PGDLLEXPORT void bm25_parallel_merge_main(dsm_segment *seg, shm_toc *toc);

void
bm25_parallel_merge_main(dsm_segment *seg, shm_toc *toc)
{
	BM25MergeShared *ms;
	Relation	heap;
	Relation	index;

	ms = (BM25MergeShared *) shm_toc_lookup(toc, PARALLEL_KEY_BM25_MERGE, false);
	heap = table_open(ms->heaprelid, AccessShareLock);
	index = index_open(ms->indexrelid, RowExclusiveLock);

	/* worker N handles group (N+1); group 0 is the leader's */
	if (ParallelWorkerNumber + 1 < ms->ngroups)
		bm25_merge_one_group(index, ms, ParallelWorkerNumber + 1);

	index_close(index, RowExclusiveLock);
	table_close(heap, AccessShareLock);
}

/* merge group g's sources into one segment, store descriptor in shared state */
static void
bm25_merge_one_group(Relation index, BM25MergeShared *ms, int g)
{
	int			lo = ms->groupoff[g];
	int			hi = ms->groupoff[g + 1];
	BM25SegMeta out;

	if (hi - lo <= 0)
		return;
	if (hi - lo == 1)
	{
		/* singleton group: nothing to merge, keep the source as-is */
		ms->outseg[g] = ms->src[lo];
		ms->outvalid[g] = false;	/* signals "source kept, no new seg" */
		return;
	}
	bm25_merge_group_to_seg(index, &ms->src[lo], (uint32) (hi - lo), &out);
	SpinLockAcquire(&ms->mutex);
	ms->outseg[g] = out;
	ms->outvalid[g] = true;
	SpinLockRelease(&ms->mutex);
}

/*
 * Parallel merge-all: partition live segments into (workers+1) groups, each
 * participant merges its group into a new segment, then the leader installs the
 * results with a single metapage update.  Returns true if it ran (and did the
 * directory swap), false to signal the caller to fall back to serial.
 */
static bool
bm25_merge_all_parallel(Relation index, int request)
{
	ParallelContext *pcxt;
	BM25MergeShared *ms;
	BM25MetaPageData meta;
	Size		estms;
	int			ngroups;
	int			nsrc;
	int			g,
				i;
	Relation	heap;
	Oid			heaprelid;

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
		UnlockReleaseBuffer(mb);
	}
	if (meta.nsegments <= 2)
		return false;			/* not worth parallelizing; serial handles it */

	heaprelid = index->rd_index->indrelid;

	EnterParallelMode();
	pcxt = CreateParallelContext("pg_fts", "bm25_parallel_merge_main", request);
	estms = BUFFERALIGN(sizeof(BM25MergeShared));
	shm_toc_estimate_chunk(&pcxt->estimator, estms);
	shm_toc_estimate_keys(&pcxt->estimator, 1);
	InitializeParallelDSM(pcxt);

	if (pcxt->seg == NULL)
	{
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return false;
	}

	ms = (BM25MergeShared *) shm_toc_allocate(pcxt->toc, estms);
	ms->heaprelid = heaprelid;
	ms->indexrelid = RelationGetRelid(index);
	SpinLockInit(&ms->mutex);

	/* collect the live source segments */
	nsrc = 0;
	for (i = 0; i < (int) meta.nsegments; i++)
		if (meta.segs[i].dictstart != InvalidBlockNumber)
			ms->src[nsrc++] = meta.segs[i];
	ms->nsrc = nsrc;

	/* groups = min(participants, nsrc); participant 0 = leader */
	ngroups = request + 1;
	if (ngroups > nsrc)
		ngroups = nsrc;
	ms->ngroups = ngroups;

	/* even contiguous partition of the nsrc sources into ngroups */
	for (g = 0; g <= ngroups; g++)
		ms->groupoff[g] = (int) ((int64) g * nsrc / ngroups);
	for (g = 0; g < ngroups; g++)
		ms->outvalid[g] = false;

	shm_toc_insert(pcxt->toc, PARALLEL_KEY_BM25_MERGE, ms);
	LaunchParallelWorkers(pcxt);

	if (pcxt->nworkers_launched == 0)
	{
		WaitForParallelWorkersToFinish(pcxt);
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return false;			/* no workers; serial fallback */
	}

	/* leader merges group 0 itself while workers handle groups 1..n */
	heap = table_open(heaprelid, AccessShareLock);
	bm25_merge_one_group(index, ms, 0);
	table_close(heap, AccessShareLock);

	WaitForParallelWorkersToFinish(pcxt);

	/*
	 * Single atomic directory update: drop every consumed source descriptor
	 * (content-match) and install each group's merged descriptor.  Groups that
	 * did not actually merge (singleton) keep their one source, so we simply
	 * don't drop it.
	 */
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *state;
		Page		mp;
		BM25MetaPageData *m;
		BM25SegMeta kept[BM25_MAX_SEGMENTS];
		uint32		nkept = 0;
		uint32		j;
		int			k;

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		state = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(state, mb, 0);
		m = BM25PageGetMeta(mp);

		/* keep any segment that is NOT a consumed source of a merged group */
		for (j = 0; j < m->nsegments; j++)
		{
			bool		consumed = false;

			for (g = 0; g < ngroups && !consumed; g++)
			{
				if (!ms->outvalid[g])
					continue;	/* singleton group merged nothing */
				for (k = ms->groupoff[g]; k < ms->groupoff[g + 1]; k++)
					if (memcmp(&m->segs[j], &ms->src[k], sizeof(BM25SegMeta)) == 0)
					{
						consumed = true;
						break;
					}
			}
			if (!consumed)
				kept[nkept++] = m->segs[j];
		}
		/* append each merged group's new segment */
		for (g = 0; g < ngroups; g++)
			if (ms->outvalid[g])
				kept[nkept++] = ms->outseg[g];

		memcpy(m->segs, kept, nkept * sizeof(BM25SegMeta));
		m->nsegments = nkept;
		m->generation++;		/* directory changed: invalidate concurrent scan snapshots */
		GenericXLogFinish(state);
		UnlockReleaseBuffer(mb);

		/* recycle the consumed source segments' pages */
		for (g = 0; g < ngroups; g++)
			if (ms->outvalid[g])
				for (k = ms->groupoff[g]; k < ms->groupoff[g + 1]; k++)
					bm25_free_segment(index, &ms->src[k]);
	}

	DestroyParallelContext(pcxt);
	ExitParallelMode();
	IndexFreeSpaceMapVacuum(index);
	return true;
}

static bool
bm25_merge_all(Relation index)
{
	bool		didwork = false;
	int			guard;

	/*
	 * Try a parallel merge first (unless already inside a parallel operation,
	 * e.g. the parallel build leader -- no nested parallelism).  It compacts
	 * the sources into (workers+1) groups in one parallel pass; the serial
	 * loop below then finishes to a single segment.
	 *
	 * NB: iterating the parallel pass to one segment was measured WORSE at 2M
	 * (each pass rewrites data -> write amplification) and did not cut the
	 * tail: the final reduction is the write of ONE multi-GB output segment by
	 * a single backend, which no group-partition scheme parallelizes.  The
	 * merge tail is a single-output-write cost, not a parallelism-partition
	 * one -- see ROADMAP.md (codec / streamed-write direction).
	 */
	if (!IsInParallelMode() && max_parallel_maintenance_workers > 0)
	{
		int			request = Min(max_parallel_maintenance_workers,
								 max_parallel_workers);

		if (request > 0 && bm25_merge_all_parallel(index, request))
			didwork = true;
	}

	for (guard = 0; guard < BM25_MAX_SEGMENTS; guard++)
	{
		BM25MetaPageData meta;
		uint32		sel[BM25_MAX_SEGMENTS];
		uint32		nsel = 0;
		uint32		i;

		{
			Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

			LockBuffer(mb, BUFFER_LOCK_SHARE);
			memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
			UnlockReleaseBuffer(mb);
		}
		if (meta.nsegments <= 1)
			break;				/* already optimal */

		/* select every populated segment */
		for (i = 0; i < meta.nsegments; i++)
			if (meta.segs[i].dictstart != InvalidBlockNumber)
				sel[nsel++] = i;
		if (nsel <= 1)
			break;

		if (!bm25_merge_selected(index, sel, nsel))
			break;				/* directory changed underneath; stop */
		didwork = true;
	}
	return didwork;
}

/*
 * Full-compaction with tail truncation, for VACUUM FULL / an explicit
 * fts_vacuum().  Merge every live segment into one, biasing allocation toward
 * the lowest free blocks so live pages pack at the front; then truncate the
 * contiguous run of free blocks at the end of the file back to the OS.  This
 * is what reclaims the physical bloat left by ordinary merges (which recycle
 * freed pages to the FSM for later reuse but never shrink the relation).
 *
 * Single-writer only (holds a lock that excludes concurrent writers, e.g.
 * VACUUM's ShareUpdateExclusiveLock or CIC's AccessExclusiveLock).
 */

/*
 * Coalesce every live segment into a single segment, allocating either
 * low-first (extend_only=false: pack toward the front) or extend-only
 * (extend_only=true: write the whole output to fresh high blocks, vacating the
 * free region below).  Returns true if anything was written.  Not parallel:
 * the allocator hints are backend-scoped and compaction wants a deterministic
 * layout.
 */
static bool
bm25_compact_to_one(Relation index, bool extend_only)
{
	bool		didwork = false;
	int			guard;

	if (extend_only)
		bm25_alloc_extend_only = true;
	else
		bm25_alloc_begin(index);	/* gather + hand out lowest free first */

	PG_TRY();
	{
		/* rewrite all live segments once (relocates their pages) ... */
		{
			BM25MetaPageData meta;
			uint32		sel[BM25_MAX_SEGMENTS];
			uint32		nsel = 0;
			uint32		i;
			Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

			LockBuffer(mb, BUFFER_LOCK_SHARE);
			memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
			UnlockReleaseBuffer(mb);
			for (i = 0; i < meta.nsegments; i++)
				if (meta.segs[i].dictstart != InvalidBlockNumber)
					sel[nsel++] = i;
			if (nsel >= 1 && bm25_merge_selected(index, sel, nsel))
				didwork = true;
		}

		/* ... then coalesce any remaining segments down to one */
		for (guard = 0; guard < BM25_MAX_SEGMENTS; guard++)
		{
			BM25MetaPageData meta;
			uint32		sel[BM25_MAX_SEGMENTS];
			uint32		nsel = 0;
			uint32		i;
			Buffer		mb;

			CHECK_FOR_INTERRUPTS();	/* between merges (no lock/window held) */
			mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
			LockBuffer(mb, BUFFER_LOCK_SHARE);
			memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
			UnlockReleaseBuffer(mb);
			if (meta.nsegments <= 1)
				break;
			for (i = 0; i < meta.nsegments; i++)
				if (meta.segs[i].dictstart != InvalidBlockNumber)
					sel[nsel++] = i;
			if (nsel <= 1)
				break;
			if (!bm25_merge_selected(index, sel, nsel))
				break;
			didwork = true;
		}
	}
	PG_FINALLY();
	{
		if (extend_only)
			bm25_alloc_extend_only = false;
		else
			bm25_alloc_end();
	}
	PG_END_TRY();

	return didwork;
}

/* Truncate the contiguous run of free blocks at the end of the file back to
 * the OS.  Returns the new block count.  Scan is cancel-safe (no lock held). */
static BlockNumber
bm25_truncate_free_tail(Relation index)
{
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	BlockNumber truncpoint = nblocks;
	BlockNumber blk;

	for (blk = nblocks; blk > 1; blk--)
	{
		CHECK_FOR_INTERRUPTS();		/* scan-only, no lock held */
		if (GetRecordedFreeSpace(index, blk - 1) >= BLCKSZ / 2)
			truncpoint = blk - 1;	/* free -> part of the truncatable tail */
		else
			break;				/* first live block from the end; stop */
	}
	if (truncpoint < nblocks)
	{
		FreeSpaceMapVacuumRange(index, truncpoint, nblocks);
		RelationTruncate(index, truncpoint);
		nblocks = truncpoint;
	}
	return nblocks;
}

/*
 * Is the index already at its compaction floor -- i.e. would a vacate+pack
 * rewrite be pure waste?  True only when BOTH:
 *   (1) the live data is already front-packed (negligible free space below the
 *       highest live block), so a rewrite would only re-grow then re-truncate
 *       to the same size, and
 *   (2) there is at most ONE live segment, so there is nothing to coalesce
 *       (fts_vacuum's other job is to merge segments to one for scan speed).
 * If either fails, the vacate+pack pass still has work to do.  Scan-only for
 * the FSM part; a brief shared lock on the metapage for the segment count.
 */
static bool
bm25_index_is_compacted(Relation index)
{
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	BlockNumber lastlive = 0;
	BlockNumber freebelow = 0;
	BlockNumber threshold;
	BlockNumber blk;
	uint32		nlive = 0;

	/* (2) segment count: only a single live segment counts as coalesced */
	{
		BM25MetaPageData meta;
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		uint32		i;

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
		UnlockReleaseBuffer(mb);
		for (i = 0; i < meta.nsegments; i++)
			if (meta.segs[i].dictstart != InvalidBlockNumber)
				nlive++;
	}
	if (nlive > 1)
		return false;				/* multiple segments: pack must coalesce */

	/* (1) front-packed: highest live block, then free-below count */
	for (blk = nblocks; blk > 1; blk--)
	{
		CHECK_FOR_INTERRUPTS();		/* scan-only, no lock held */
		if (GetRecordedFreeSpace(index, blk - 1) < BLCKSZ / 2)
		{
			lastlive = blk - 1;
			break;
		}
	}
	if (lastlive <= 1)
		return true;				/* empty / only the metapage: nothing to pack */

	/* count mostly-free blocks strictly below the last live block */
	for (blk = 1; blk < lastlive; blk++)
	{
		CHECK_FOR_INTERRUPTS();
		if (GetRecordedFreeSpace(index, blk) >= BLCKSZ / 2)
			freebelow++;
	}
	threshold = Max(nblocks / 50, 8);
	return freebelow <= threshold;
}

static bool
bm25_vacuum_compact(Relation index)
{
	BlockNumber startblocks;
	BlockNumber nblocks;
	BlockNumber prevblocks;
	bool		didwork = false;
	int			pass;

	/*
	 * Converge a bloated index to its size floor in ONE call, stably (repeated
	 * calls do not oscillate) and NEVER returning larger than we started.
	 *
	 * The hard case (verified): after ordinary merges the single live segment
	 * sits at the HIGH end of the file with the freed dead pages as a LOW free
	 * region, and that free region is SMALLER than the live segment (the file is
	 * >50% live).  A plain low-bias rewrite then fills the low free and EXTENDS
	 * the rest, so the new segment straddles the file and its tail is live --
	 * nothing is truncatable.  Iterating that rewrite just oscillates between two
	 * layouts and never reaches the floor.  (This is the "stable but never
	 * shrinks" defect; the earlier code instead oscillated and could end larger.)
	 *
	 * The fix is a two-phase relocation per pass, because a merge writes the new
	 * segment BEFORE freeing the old one (write-before-free, required for crash
	 * safety -- the old on-disk pages must stay valid until the metapage swap
	 * commits):
	 *
	 *   Phase 1 (VACATE): rewrite the segment EXTEND-ONLY, so the new copy lands
	 *     on fresh high blocks and the old pages -- wherever they were -- are all
	 *     freed.  The free region below the new (high) copy is now contiguous and
	 *     at least as large as the live segment.  The file grows transiently.
	 *
	 *   Phase 2 (PACK): rewrite the segment LOW-BIAS.  Its free list now includes
	 *     that whole low region (>= live size), so the copy fits entirely at the
	 *     front; the phase-1 high copy is freed and becomes a contiguous free
	 *     TAIL, which we truncate.  Result: front-packed at the floor.
	 *
	 * One vacate+pass reaches the floor in the common single-segment case; the
	 * loop re-checks and stops as soon as a pass stops shrinking, bounded by
	 * BM25_VACUUM_MAX_PASSES.  A final backstop guarantees we never return above
	 * the pre-call size even if the cap is hit mid-vacate.
	 *
	 * Single-writer only (holds a lock that excludes concurrent writers, e.g.
	 * VACUUM's ShareUpdateExclusiveLock or CIC's AccessExclusiveLock).
	 */
	startblocks = RelationGetNumberOfBlocks(index);
	prevblocks = startblocks;

	for (pass = 0; pass < BM25_VACUUM_MAX_PASSES; pass++)
	{
		CHECK_FOR_INTERRUPTS();		/* between passes: no lock/window held */

		/*
		 * Pre-pass convergence guard.  If the live data is already at the front
		 * of the file, a vacate+pack rewrite would only re-grow it and truncate
		 * back to the same floor -- pure waste, and the dominant cost on a large
		 * index (each rewrite streams the whole multi-GB segment through the
		 * buffer pool twice).  Just truncate any free tail and stop.  This makes
		 * a bloated index converge in ONE vacate+pack+truncate pass and an
		 * already-compact index a near-no-op (no rewrite at all).
		 */
		if (bm25_index_is_compacted(index))
		{
			nblocks = bm25_truncate_free_tail(index);
			if (nblocks < prevblocks)
				didwork = true;
			prevblocks = nblocks;
			break;
		}

		/* Phase 1: vacate -- push the live segment onto fresh high blocks so the
		 * freed old pages form one contiguous low free region >= live size. */
		if (bm25_compact_to_one(index, true))
			didwork = true;
		IndexFreeSpaceMapVacuum(index);

		/* Phase 2: pack -- relocate the segment to the front (its free list now
		 * spans that whole low region), freeing the phase-1 high copy. */
		if (bm25_compact_to_one(index, false))
			didwork = true;
		IndexFreeSpaceMapVacuum(index);

		/* Truncate the free tail the pack phase left above the front-packed data. */
		nblocks = bm25_truncate_free_tail(index);
		if (nblocks < prevblocks)
			didwork = true;

		/* Converged: a full vacate+pack+truncate pass made no further progress. */
		if (nblocks >= prevblocks)
		{
			prevblocks = nblocks;
			break;
		}
		prevblocks = nblocks;
	}

	/*
	 * Backstop: never return larger than we started.  Phase 1 grows the file
	 * transiently; if the pass cap were somehow hit right after a vacate, the
	 * pack phase would still have run, but guard anyway by truncating any free
	 * tail down to at most the pre-call size.
	 */
	nblocks = RelationGetNumberOfBlocks(index);
	if (nblocks > startblocks)
	{
		BlockNumber truncpoint = nblocks;
		BlockNumber blk;

		for (blk = nblocks; blk > startblocks; blk--)
		{
			CHECK_FOR_INTERRUPTS();		/* scan-only, no lock held */
			if (GetRecordedFreeSpace(index, blk - 1) >= BLCKSZ / 2)
				truncpoint = blk - 1;
			else
				break;
		}
		if (truncpoint < nblocks)
		{
			FreeSpaceMapVacuumRange(index, truncpoint, nblocks);
			RelationTruncate(index, truncpoint);
			didwork = true;
		}
	}

	return didwork;
}

static void
bm25_merge_segments(Relation index)
{
	int			guard;

	/*
	 * Repeatedly merge one qualifying size-tier until no tier has enough
	 * segments and the total count is within budget.  The guard bounds the loop
	 * (each successful merge reduces nsegments).
	 */
	for (guard = 0; guard < BM25_MAX_SEGMENTS; guard++)
	{
		BM25MetaPageData meta;
		MergeCand	cand[BM25_MAX_SEGMENTS];
		uint32		sel[BM25_MAX_SEGMENTS];
		uint32		nsel = 0;
		uint32		i;

		{
			Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

			LockBuffer(mb, BUFFER_LOCK_SHARE);
			memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
			UnlockReleaseBuffer(mb);
		}
		if (meta.nsegments <= 1)
			return;

		/* candidates sorted by live size (ndocs - ndeleted) */
		for (i = 0; i < meta.nsegments; i++)
		{
			cand[i].idx = i;
			cand[i].size = meta.segs[i].ndocs - meta.segs[i].ndeleted;
			if (cand[i].size < 1)
				cand[i].size = 1;
		}
		qsort(cand, meta.nsegments, sizeof(MergeCand), cmp_mergecand);

		/* longest run of same-tier segments from the smallest: each within
		 * BM25_MERGE_SIZE_FACTOR of the run's smallest member */
		{
			double		base = cand[0].size;
			uint32		run = 0;

			for (i = 0; i < meta.nsegments; i++)
			{
				if (cand[i].size <= base * BM25_MERGE_SIZE_FACTOR)
					run++;
				else
					break;
			}
			/* merge this tier if large enough, or if we simply have too many
			 * segments overall (force progress toward the budget) */
			if (run >= BM25_MERGE_TIER_MIN ||
				(meta.nsegments > BM25_MERGE_THRESHOLD && run >= 2))
			{
				for (i = 0; i < run; i++)
					sel[nsel++] = cand[i].idx;
			}
		}

		if (nsel < 2)
			return;				/* no tier worth merging */
		if (!bm25_merge_selected(index, sel, nsel))
			return;				/* directory changed underneath */
	}
}

/* ---- parallel index build (level 1: parallel heap scan + per-worker segment
 * flush; the leader merges the workers' segments at the end) ---- */

#define PARALLEL_KEY_BM25_SHARED		UINT64CONST(0xB250000000000001)
#define PARALLEL_KEY_QUERY_TEXT			UINT64CONST(0xB250000000000002)
#define PARALLEL_KEY_WAL_USAGE			UINT64CONST(0xB250000000000003)
#define PARALLEL_KEY_BUFFER_USAGE		UINT64CONST(0xB250000000000004)

/*
 * Shared state for a parallel bm25 build, in the DSM segment.  Workers write
 * their own segments straight into the index (segments are self-contained and
 * appended to the metapage under its exclusive lock), so unlike a btree build
 * there is no central sort or result hand-off -- the only shared state is the
 * parallel table scan and a done-counter.
 */
typedef struct BM25Shared
{
	Oid			heaprelid;
	Oid			indexrelid;
	bool		isconcurrent;
	ConditionVariable workersdonecv;
	slock_t		mutex;
	int			nparticipantsdone;
	double		reltuples;
	/* ParallelTableScanDescData follows (alignment: allocated separately) */
}			BM25Shared;

#define ParallelTableScanFromBM25Shared(shared) \
	(ParallelTableScanDesc) ((char *) (shared) + BUFFERALIGN(sizeof(BM25Shared)))

typedef struct BM25Leader
{
	ParallelContext *pcxt;
	int			nparticipanttuplesorts;
	BM25Shared *bm25shared;
	Snapshot	snapshot;
	BufferUsage *bufferusage;
	WalUsage   *walusage;
}			BM25Leader;

/*
 * Run the heap scan (serial or, if pscan != NULL, a parallel slice) building
 * segments into `index`.  Returns the number of heap tuples this participant
 * saw.  Flushing the residual terms is left to the caller so the leader can
 * account the total before the final merge.
 */
static double
bm25_scan_and_build(Relation heap, Relation index, IndexInfo *indexInfo,
					BM25BuildState *bs, ParallelTableScanDesc pscan)
{
	TableScanDesc scan = NULL;

	if (pscan != NULL)
#if PG_VERSION_NUM >= 190000
		scan = table_beginscan_parallel(heap, pscan, SO_NONE);
#else
		scan = table_beginscan_parallel(heap, pscan);
#endif
	return table_index_build_scan(heap, index, indexInfo, true, true,
								  bm25_build_callback, (void *) bs, scan);
}

/*
 * Worker entry point (registered as "pg_fts"/"bm25_parallel_build_main").
 */
PGDLLEXPORT void bm25_parallel_build_main(dsm_segment *seg, shm_toc *toc);

void
bm25_parallel_build_main(dsm_segment *seg, shm_toc *toc)
{
	BM25Shared *bm25shared;
	Relation	heap;
	Relation	index;
	IndexInfo  *indexInfo;
	ParallelTableScanDesc pscan;
	BM25BuildState bs;
	LOCKMODE	heapLockmode;
	LOCKMODE	indexLockmode;
	double		reltuples;
	char	   *sharedquery;
	BufferUsage *bufferusage;
	WalUsage   *walusage;

	bm25shared = (BM25Shared *) shm_toc_lookup(toc, PARALLEL_KEY_BM25_SHARED, false);

	sharedquery = shm_toc_lookup(toc, PARALLEL_KEY_QUERY_TEXT, true);
	debug_query_string = sharedquery;

	if (!bm25shared->isconcurrent)
	{
		heapLockmode = ShareLock;
		indexLockmode = AccessExclusiveLock;
	}
	else
	{
		heapLockmode = ShareUpdateExclusiveLock;
		indexLockmode = RowExclusiveLock;
	}

	heap = table_open(bm25shared->heaprelid, heapLockmode);
	index = index_open(bm25shared->indexrelid, indexLockmode);
	indexInfo = BuildIndexInfo(index);
	indexInfo->ii_Concurrent = bm25shared->isconcurrent;

	/* report buffer/WAL usage so EXPLAIN ANALYZE etc. account worker I/O */
	bufferusage = shm_toc_lookup(toc, PARALLEL_KEY_BUFFER_USAGE, false);
	walusage = shm_toc_lookup(toc, PARALLEL_KEY_WAL_USAGE, false);
	InstrStartParallelQuery();

	pscan = ParallelTableScanFromBM25Shared(bm25shared);

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 parallel worker",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	bs.flush_budget = 0;
	bs.nflushes = 0;
	bm25_build_ht_init(&bs);
	reltuples = bm25_scan_and_build(heap, index, indexInfo, &bs, pscan);
	bm25_build_flush_segment(index, &bs);	/* worker's residual -> a segment */
	MemoryContextDelete(bs.ctx);

	InstrEndParallelQuery(&bufferusage[ParallelWorkerNumber],
						  &walusage[ParallelWorkerNumber]);

	/* report done + this worker's tuple count */
	SpinLockAcquire(&bm25shared->mutex);
	bm25shared->nparticipantsdone++;
	bm25shared->reltuples += reltuples;
	SpinLockRelease(&bm25shared->mutex);
	ConditionVariableSignal(&bm25shared->workersdonecv);

	index_close(index, indexLockmode);
	table_close(heap, heapLockmode);
}

/*
 * Set up the parallel context, DSM shared state, and launch workers.  Returns
 * the leader struct, or NULL if no workers could be launched (fall back to a
 * serial build).
 */
static BM25Leader *
bm25_begin_parallel(Relation heap, Relation index, bool isconcurrent,
					int request)
{
	ParallelContext *pcxt;
	Snapshot	snapshot;
	Size		estbm25shared;
	Size		estscan;
	BM25Shared *bm25shared;
	ParallelTableScanDesc pscan;
	BM25Leader *bm25leader;
	BufferUsage *bufferusage;
	WalUsage   *walusage;
	char	   *sharedquery;
	int			querylen;
	bool		leaderparticipates = true;

	EnterParallelMode();
	Assert(request > 0);
	pcxt = CreateParallelContext("pg_fts", "bm25_parallel_build_main", request);

	if (!isconcurrent)
		snapshot = SnapshotAny;
	else
		snapshot = RegisterSnapshot(GetTransactionSnapshot());

	estbm25shared = BUFFERALIGN(sizeof(BM25Shared));
	estscan = table_parallelscan_estimate(heap, snapshot);
	shm_toc_estimate_chunk(&pcxt->estimator, estbm25shared + estscan);
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	/* query text for worker debug/reporting */
	if (debug_query_string)
	{
		querylen = strlen(debug_query_string);
		shm_toc_estimate_chunk(&pcxt->estimator, querylen + 1);
		shm_toc_estimate_keys(&pcxt->estimator, 1);
	}
	else
		querylen = 0;

	shm_toc_estimate_chunk(&pcxt->estimator,
						   mul_size(sizeof(BufferUsage), pcxt->nworkers));
	shm_toc_estimate_keys(&pcxt->estimator, 1);
	shm_toc_estimate_chunk(&pcxt->estimator,
						   mul_size(sizeof(WalUsage), pcxt->nworkers));
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	InitializeParallelDSM(pcxt);

	if (pcxt->seg == NULL)
	{
		if (IsMVCCSnapshot(snapshot))
			UnregisterSnapshot(snapshot);
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return NULL;
	}

	bm25shared = (BM25Shared *) shm_toc_allocate(pcxt->toc,
												 estbm25shared + estscan);
	bm25shared->heaprelid = RelationGetRelid(heap);
	bm25shared->indexrelid = RelationGetRelid(index);
	bm25shared->isconcurrent = isconcurrent;
	bm25shared->nparticipantsdone = 0;
	bm25shared->reltuples = 0.0;
	ConditionVariableInit(&bm25shared->workersdonecv);
	SpinLockInit(&bm25shared->mutex);

	pscan = ParallelTableScanFromBM25Shared(bm25shared);
	table_parallelscan_initialize(heap, pscan, snapshot);
	shm_toc_insert(pcxt->toc, PARALLEL_KEY_BM25_SHARED, bm25shared);

	if (debug_query_string)
	{
		sharedquery = (char *) shm_toc_allocate(pcxt->toc, querylen + 1);
		memcpy(sharedquery, debug_query_string, querylen + 1);
		shm_toc_insert(pcxt->toc, PARALLEL_KEY_QUERY_TEXT, sharedquery);
	}

	bufferusage = shm_toc_allocate(pcxt->toc,
								   mul_size(sizeof(BufferUsage), pcxt->nworkers));
	shm_toc_insert(pcxt->toc, PARALLEL_KEY_BUFFER_USAGE, bufferusage);
	walusage = shm_toc_allocate(pcxt->toc,
								mul_size(sizeof(WalUsage), pcxt->nworkers));
	shm_toc_insert(pcxt->toc, PARALLEL_KEY_WAL_USAGE, walusage);

	LaunchParallelWorkers(pcxt);

	if (pcxt->nworkers_launched == 0)
	{
		/* no workers actually started; caller will do a serial build */
		WaitForParallelWorkersToFinish(pcxt);
		if (IsMVCCSnapshot(snapshot))
			UnregisterSnapshot(snapshot);
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return NULL;
	}

	bm25leader = (BM25Leader *) palloc0(sizeof(BM25Leader));
	bm25leader->pcxt = pcxt;
	bm25leader->nparticipanttuplesorts = pcxt->nworkers_launched;
	if (leaderparticipates)
		bm25leader->nparticipanttuplesorts++;
	bm25leader->bm25shared = bm25shared;
	bm25leader->snapshot = snapshot;
	bm25leader->bufferusage = bufferusage;
	bm25leader->walusage = walusage;
	return bm25leader;
}

/*
 * Wait for all workers to finish, accumulate their I/O stats + tuple count,
 * and tear down.  Returns the total heap tuples the workers scanned (read from
 * the DSM before it is unmapped).
 */
static double
bm25_end_parallel(BM25Leader *bm25leader)
{
	int			i;
	double		worker_tuples;

	WaitForParallelWorkersToFinish(bm25leader->pcxt);

	for (i = 0; i < bm25leader->pcxt->nworkers_launched; i++)
		InstrAccumParallelQuery(&bm25leader->bufferusage[i], &bm25leader->walusage[i]);

	/* read the workers' accumulated tuple count while the DSM is still mapped */
	worker_tuples = bm25leader->bm25shared->reltuples;

	if (IsMVCCSnapshot(bm25leader->snapshot))
		UnregisterSnapshot(bm25leader->snapshot);
	DestroyParallelContext(bm25leader->pcxt);
	ExitParallelMode();
	return worker_tuples;
}

static IndexBuildResult *
bm25_build(Relation heap, Relation index, IndexInfo *indexInfo)
{
	IndexBuildResult *result;
	BM25BuildState bs;
	double		reltuples;
	BM25Leader *bm25leader = NULL;

	if (RelationGetNumberOfBlocks(index) != 0)
		elog(ERROR, "index \"%s\" already contains data",
			 RelationGetRelationName(index));

	/* metapage must be block 0 -- write it before workers or the scan touch it */
	bm25_init_metapage(index);

	/* Try a parallel build if the planner requested workers. */
	if (indexInfo->ii_ParallelWorkers > 0)
		bm25leader = bm25_begin_parallel(heap, index, indexInfo->ii_Concurrent,
										 indexInfo->ii_ParallelWorkers);

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 build",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	bs.flush_budget = 0;
	bs.nflushes = 0;
	bm25_build_ht_init(&bs);

	if (bm25leader != NULL)
	{
		/*
		 * Parallel build: the leader also scans a slice (leaderparticipates),
		 * using the same shared parallel scan the workers use, and flushes its
		 * residual as a segment.  Workers write their own segments directly.
		 */
		ParallelTableScanDesc pscan =
			ParallelTableScanFromBM25Shared(bm25leader->bm25shared);

		reltuples = bm25_scan_and_build(heap, index, indexInfo, &bs, pscan);
		bm25_build_flush_segment(index, &bs);

		/* add the workers' tuple counts BEFORE tearing down the DSM */
		reltuples += bm25_end_parallel(bm25leader);

		/*
		 * Compact the participants' segments into an optimal single segment.
		 * bm25_end_parallel() has exited parallel mode, so bm25_merge_all() can
		 * itself run the PARALLEL merge (workers merge disjoint segment groups),
		 * making the compaction fast rather than the single-threaded O(index)
		 * tail that a naive build-time merge would be.  This keeps a freshly
		 * built (or REINDEXed) index optimal at first query -- a multi-segment
		 * index makes ranked scans traverse every segment's postings, which
		 * regresses common-term ranked latency.
		 */
		bm25_merge_all(index);
	}
	else
	{
		/* Serial build. */
		reltuples = bm25_scan_and_build(heap, index, indexInfo, &bs, NULL);
		bm25_build_flush_segment(index, &bs);

		/*
		 * Compact to a single optimal segment.  A serial build makes few
		 * segments (budget-triggered flushes + the residual), and the tiered
		 * bm25_merge_segments deliberately leaves same-size tiers -- which would
		 * leave a multi-segment index and regress ranked scans.  bm25_merge_all
		 * finishes to one segment (and uses the parallel merge if workers are
		 * available, since we are not in parallel mode here).
		 */
		bm25_merge_all(index);
	}

	/*
	 * Reclaim the free tail the end-of-build merge left on disk.  The merge
	 * writes the merged output before freeing the input segments (write-before-
	 * free, for crash safety), so freed input pages accumulate but the file is
	 * never shrunk during a build (only fts_vacuum truncates).  Truncating the
	 * contiguous free tail reclaims what the final merge leaves above the
	 * front-packed data -- substantial on a parallel build (freed tail present),
	 * a no-op when the free space is interior (a serial single-segment layout);
	 * fully compacting a freshly built index still needs fts_vacuum.  We hold the
	 * index AccessExclusiveLock and any parallel workers are already torn down
	 * (bm25_end_parallel), and during ambuild the index is not yet visible to
	 * other backends (indisready=false, even under CONCURRENTLY), so this backend
	 * is the sole writer -- truncating the free tail is safe.
	 */
	bm25_truncate_free_tail(index);

	MemoryContextDelete(bs.ctx);

	result = (IndexBuildResult *) palloc0(sizeof(IndexBuildResult));
	result->heap_tuples = reltuples;
	result->index_tuples = reltuples;
	return result;
}

static void
bm25_buildempty(Relation index)
{
	bm25_init_metapage(index);
}

/*
 * Index one oversized document (its analyzed ftsdoc does not fit on a single
 * pending page) directly as its own one-document segment, bypassing the
 * verbatim pending buffer.  Segment posting storage is a chain of FOR-packed
 * pages with no per-document size limit, so arbitrarily large documents (e.g.
 * long Wikipedia articles) can be indexed.  Rare, so building a whole segment
 * per such document is acceptable.
 */
static void
bm25_insert_oversized_as_segment(Relation index, FtsDoc doc, ItemPointer tid)
{
	BM25BuildState bs;
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	uint32		j;

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 oversized",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	bm25_build_ht_init(&bs);

	{
		MemoryContext old = MemoryContextSwitchTo(bs.ctx);

		for (j = 0; j < doc->nterms; j++)
		{
			const uint32 *pos = (bs.want_positions && FTS_DOC_HAS_POS(doc))
				? FTS_DOC_TERMPOS(doc, &entries[j]) : NULL;

			add_posting(&bs, FTS_DOC_TERMTEXT(doc, &entries[j]), entries[j].len,
						tid, entries[j].tf, doc->doclen,
						pos, pos ? (int) entries[j].tf : 0);
		}
		bs.ndocs = 1.0;
		bs.sumdoclen = doc->doclen;
		MemoryContextSwitchTo(old);
	}

	/* write the one-doc segment (updates corpus N/sumdoclen via add_segment) */
	bm25_build_flush_segment(index, &bs);
	MemoryContextDelete(bs.ctx);

	/*
	 * A bulk INSERT/UPDATE of many oversized documents would create one
	 * segment each and could approach BM25_MAX_SEGMENTS before the next VACUUM
	 * gets a chance to merge.  Coalesce eagerly once the count climbs, so the
	 * segment directory never overflows on a write-heavy oversized workload.
	 */
	{
		BM25MetaPageData meta;
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
		UnlockReleaseBuffer(mb);
		if (meta.nsegments >= BM25_MAX_SEGMENTS - 16)
			bm25_merge_segments(index);
	}
}

/*
 * aminsert: append the new document to the pending list.
 *
 * The document is stored verbatim (its ftsdoc bytes) on a chain of pending
 * pages and is searched directly at scan time, so newly inserted rows are
 * immediately visible to @@@ without a REINDEX.  The metapage N and sum(doclen)
 * are updated so BM25 length-normalization stays correct; per-term df in the
 * dictionary is not updated until a merge (REINDEX), matching GIN fastupdate's
 * documented staleness.
 */
static bool
bm25_insert(Relation index, Datum *values, bool *isnull,
			ItemPointer ht_ctid, Relation heapRel,
			IndexUniqueCheck checkUnique, bool indexUnchanged,
			IndexInfo *indexInfo)
{
	FtsDoc		doc;
	Size		doclen;
	Size		need;
	Buffer		metabuf;
	GenericXLogState *state;
	Page		metapage;
	BM25MetaPageData *meta;
	BlockNumber tailblk;
	Buffer		tailbuf;
	Page		tailpage;
	bool		appended = false;

	if (isnull[0])
		return false;

	doc = (FtsDoc) PG_DETOAST_DATUM(values[0]);
	doclen = VARSIZE(doc);
	need = MAXALIGN(sizeof(BM25PendingItem) + doclen);

	if (need > BLCKSZ - MAXALIGN(SizeOfPageHeaderData) - MAXALIGN(sizeof(BM25PageOpaqueData)))
	{
		/* Too large for the verbatim pending buffer: index it directly as its
		 * own one-document segment (no per-doc size limit there). */
		bm25_insert_oversized_as_segment(index, doc, ht_ctid);
		return true;
	}

	/* Lock the metapage for the whole append (serializes inserters; a
	 * per-inserter fast path is a later optimization). */
	metabuf = ReadBuffer(index, BM25_METAPAGE_BLKNO);
	LockBuffer(metabuf, BUFFER_LOCK_EXCLUSIVE);
	metapage = BufferGetPage(metabuf);
	bm25_check_meta(metapage, index);
	meta = BM25PageGetMeta(metapage);
	tailblk = meta->pendingtail;

	/* Try to append to the current tail page. */
	if (tailblk != InvalidBlockNumber)
	{
		tailbuf = ReadBuffer(index, tailblk);
		LockBuffer(tailbuf, BUFFER_LOCK_EXCLUSIVE);
		tailpage = BufferGetPage(tailbuf);
		if (((PageHeader) tailpage)->pd_lower + need <=
			BLCKSZ - MAXALIGN(sizeof(BM25PageOpaqueData)))
		{
			BM25PendingItem *pi;

			state = GenericXLogStart(index);
			tailpage = GenericXLogRegisterBuffer(state, tailbuf, 0);
			pi = (BM25PendingItem *) ((char *) tailpage +
									 ((PageHeader) tailpage)->pd_lower);
			pi->tid = *ht_ctid;
			pi->doclen = doclen;
			memcpy((char *) pi + sizeof(BM25PendingItem), doc, doclen);
			((PageHeader) tailpage)->pd_lower += need;
			metapage = GenericXLogRegisterBuffer(state, metabuf, 0);
			meta = BM25PageGetMeta(metapage);
			meta->ndocs += 1.0;
			meta->sumdoclen += doc->doclen;
			meta->npending += 1;
			GenericXLogFinish(state);
			appended = true;
		}
		if (!appended)
			UnlockReleaseBuffer(tailbuf);	/* re-read below as oldtail */
	}

	/* Need a fresh pending page (either none yet, or the tail is full). */
	if (!appended)
	{
		Buffer		newbuf = bm25_new_buffer(index);
		BlockNumber newblk = BufferGetBlockNumber(newbuf);
		BM25PendingItem *pi;

		state = GenericXLogStart(index);
		{
			Page		np = GenericXLogRegisterBuffer(state, newbuf,
													   GENERIC_XLOG_FULL_IMAGE);

			bm25_init_page(np, BM25_PENDING);
			pi = (BM25PendingItem *) ((char *) np +
									 ((PageHeader) np)->pd_lower);
			pi->tid = *ht_ctid;
			pi->doclen = doclen;
			memcpy((char *) pi + sizeof(BM25PendingItem), doc, doclen);
			((PageHeader) np)->pd_lower += need;
		}

		/* link previous tail (if any) to the new page */
		if (tailblk != InvalidBlockNumber)
		{
			Buffer		oldtail = ReadBuffer(index, tailblk);
			Page		op;

			LockBuffer(oldtail, BUFFER_LOCK_EXCLUSIVE);
			op = GenericXLogRegisterBuffer(state, oldtail, 0);
			BM25PageGetOpaque(op)->nextblk = newblk;
			metapage = GenericXLogRegisterBuffer(state, metabuf, 0);
			meta = BM25PageGetMeta(metapage);
			meta->pendingtail = newblk;
			meta->ndocs += 1.0;
			meta->sumdoclen += doc->doclen;
			meta->npending += 1;
			GenericXLogFinish(state);
			UnlockReleaseBuffer(oldtail);
		}
		else
		{
			metapage = GenericXLogRegisterBuffer(state, metabuf, 0);
			meta = BM25PageGetMeta(metapage);
			meta->pendinghead = newblk;
			meta->pendingtail = newblk;
			meta->ndocs += 1.0;
			meta->sumdoclen += doc->doclen;
			meta->npending += 1;
			GenericXLogFinish(state);
		}
		UnlockReleaseBuffer(newbuf);
	}
	else
		UnlockReleaseBuffer(tailbuf);

	UnlockReleaseBuffer(metabuf);
	return true;
}

/* ----- scan ----- */

#include "pg_fts_lev.c"
#include "pg_fts_am_scan.c"
#include "pg_fts_trgm_index.c"

/* ----- vacuum / flush / merge / cost / options ----- */

/*
 * Flush the pending write buffer into a NEW immutable segment.
 *
 * O(pending), not O(index): only the pending documents are folded into a fresh
 * segment appended to the directory.  (The old monolithic design re-read and
 * rewrote the entire index on every merge -- O(index) and quadratic under
 * steady inserts.)  Pending pages are then recycled to the FSM.  Tiered
 * compaction of many small segments is a separate operation.  Returns true if
 * a flush happened.
 */
static bool
bm25_flush_pending(Relation index)
{
	BM25MetaPageData meta;
	BM25BuildState bs;
	BM25SegMeta seg;
	BlockNumber blk;

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
		UnlockReleaseBuffer(mb);
	}
	if (meta.npending == 0)
		return false;

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 flush",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	{
		HASHCTL		ctl;

		ctl.keysize = sizeof(TermKey);
		ctl.entrysize = sizeof(TermHashEntry);
		ctl.hcxt = bs.ctx;
		build_ht = hash_create("bm25 flush terms", 1024, &ctl,
							   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	/* fold only the pending documents into the build state */
	blk = meta.pendinghead;
	while (blk != InvalidBlockNumber)
	{
		Buffer		buffer = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;
		MemoryContext old = MemoryContextSwitchTo(bs.ctx);

		LockBuffer(buffer, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buffer);
		ptr = (char *) PageGetContents(page);
		end = (char *) page + ((PageHeader) page)->pd_lower;
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25PendingItem *pi = (BM25PendingItem *) ptr;
			FtsDoc		pdoc = (FtsDoc) ((char *) pi + sizeof(BM25PendingItem));
			FtsTermEntry *entries;
			uint32		j;

			/* Never trust raw pending-page bytes: a torn page or any producing
			 * bug could give a bad nterms/len/posoff that turns into a wild
			 * write in add_posting.  Validate against the item's own doclen and
			 * skip (not crash) a corrupt doc so autovacuum can make progress. */
			if (!fts_doc_is_valid(pdoc, pi->doclen))
			{
				ereport(WARNING,
						(errcode(ERRCODE_DATA_CORRUPTED),
						 errmsg("pg_fts: skipping malformed pending document in index \"%s\" during flush",
								RelationGetRelationName(index)),
						 errhint("REINDEX the index to rebuild it from the heap.")));
				ptr += MAXALIGN(sizeof(BM25PendingItem) + pi->doclen);
				continue;
			}
			entries = FTS_DOC_ENTRIES(pdoc);

			for (j = 0; j < pdoc->nterms; j++)
			{
				const uint32 *pos = (bs.want_positions && FTS_DOC_HAS_POS(pdoc))
					? FTS_DOC_TERMPOS(pdoc, &entries[j]) : NULL;

				add_posting(&bs, FTS_DOC_TERMTEXT(pdoc, &entries[j]),
							entries[j].len, &pi->tid, entries[j].tf,
							pdoc->doclen, pos, pos ? (int) entries[j].tf : 0);
			}
			bs.ndocs += 1.0;
			bs.sumdoclen += pdoc->doclen;
			ptr += MAXALIGN(sizeof(BM25PendingItem) + pi->doclen);
		}
		UnlockReleaseBuffer(buffer);
		MemoryContextSwitchTo(old);
		blk = next;
	}

	if (bs.nterms > 1)
		qsort(bs.terms, bs.nterms, sizeof(BuildTerm), cmp_buildterm);

	bm25_write_segment(index, &bs, &seg);
	bm25_meta_add_segment(index, &seg);

	/*
	 * Clear the pending list.  Pending docs were already counted into the
	 * corpus totals at insert time; add_segment counted them again, so subtract
	 * the segment's contribution to avoid a double count.
	 */
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *state;
		Page		mp;
		BM25MetaPageData *m;

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		state = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(state, mb, 0);
		m = BM25PageGetMeta(mp);
		m->ndocs -= seg.ndocs;
		m->sumdoclen -= seg.sumdoclen;
		m->pendinghead = InvalidBlockNumber;
		m->pendingtail = InvalidBlockNumber;
		m->npending = 0;
		GenericXLogFinish(state);
		UnlockReleaseBuffer(mb);
	}

	/* recycle the old pending pages */
	blk = meta.pendinghead;
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		next = BM25PageGetOpaque(BufferGetPage(buf))->nextblk;
		UnlockReleaseBuffer(buf);
		RecordFreeIndexPage(index, blk);
		blk = next;
	}
	IndexFreeSpaceMapVacuum(index);

	MemoryContextDelete(bs.ctx);

	/* keep the segment count bounded (query cost is O(nsegments) per term) */
	bm25_merge_segments(index);
	return true;
}

/*
 * Collect the distinct docids present in a segment into a sparsemap (the
 * segment's docid "universe").  Used by bulkdelete to enumerate the TIDs the
 * vacuum callback must be asked about.
 */
static sm_t *
bm25_segment_docids(Relation index, const BM25SegMeta *seg)
{
	sm_t	   *seen = sm_create(256);
	BlockNumber blk = seg->dictstart;

	if (seen == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("out of memory building bm25 tombstone map")));

	while (blk != InvalidBlockNumber)
	{
		Buffer		buffer = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		LockBuffer(buffer, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buffer);
		ptr = (char *) PageGetContents(page);
		end = (char *) page + ((PageHeader) page)->pd_lower;
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;
			Size		esize = MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);
			BM25Posting *post;
			int			np,
						k;

			np = bm25_decode_term(index, de->firstposting, de->firstoffset,
								  de->df, &post, NULL, false, NULL);
			for (k = 0; k < np; k++)
				sm_add_grow(&seen, bm25_tid_to_docid(&post[k].tid));
			pfree(post);
			ptr += esize;
		}
		UnlockReleaseBuffer(buffer);
		blk = next;
	}
	return seen;
}

/*
 * bm25_bulkdelete: VACUUM asks us, via `callback`, which of the TIDs in the
 * index refer to now-dead heap tuples.  Because postings live in immutable
 * segments, we cannot cheaply remove individual entries; instead we maintain a
 * per-segment livedocs TOMBSTONE bitmap (a docid sparsemap of deleted docs).
 * Scans and counts subtract tombstoned docids, and the tiered merge physically
 * drops them.  This is essential for correctness: the index-only
 * scan and fts_count paths trust the visibility map, so a vacuumed+reused heap
 * slot MUST NOT still be reported as a match -- the tombstone prevents that.
 */
static IndexBulkDeleteResult *
bm25_bulkdelete(IndexVacuumInfo *info, IndexBulkDeleteResult *stats,
				IndexBulkDeleteCallback callback, void *callback_state)
{
	Relation	index = info->index;
	BM25MetaPageData meta;
	uint32		s;
	int64		num_index_tuples = 0;
	int64		tuples_removed = 0;

	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_check_meta(BufferGetPage(mb), index);
		memcpy(&meta, BM25PageGetMeta(BufferGetPage(mb)), sizeof(meta));
		UnlockReleaseBuffer(mb);
	}

	for (s = 0; s < meta.nsegments; s++)
	{
		BM25SegMeta *sg = &meta.segs[s];
		sm_t	   *seen;
		sm_t	   *dead;
		sm_cursor_t cur = SM_CURSOR_INIT;
		uint64		v;
		uint32		ndead = 0;
		BlockNumber oldlivedocs;
		uint32		oldlen;

		if (sg->dictstart == InvalidBlockNumber)
			continue;

		seen = bm25_segment_docids(index, sg);
		dead = sm_create(256);
		if (dead == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("out of memory building bm25 tombstone map")));

		/* carry forward any docids already tombstoned in this segment */
		if (sg->livedocs != InvalidBlockNumber && sg->livedocslen > 0)
		{
			uint8	   *buf = bm25_read_blob(index, sg->livedocs, sg->livedocslen);
			sm_t		old;
			sm_cursor_t oc = SM_CURSOR_INIT;
			uint64		dv;

			sm_open(&old, (uint8_t *) buf, sg->livedocslen);
			for (dv = sm_next_member(&old, (uint64_t) -1, &oc);
				 dv != SM_IDX_MAX;
				 dv = sm_next_member(&old, dv, &oc))
			{
				sm_add_grow(&dead, dv);
				ndead++;
			}
			pfree(buf);
		}

		/* ask the callback about each live (not-yet-tombstoned) docid */
		for (v = sm_next_member(seen, (uint64_t) -1, &cur);
			 v != SM_IDX_MAX;
			 v = sm_next_member(seen, v, &cur))
		{
			ItemPointerData tid;
			sm_cursor_t ccur = SM_CURSOR_INIT;

			num_index_tuples++;
			if (sm_contains(dead, v, &ccur))
				continue;		/* already tombstoned */
			bm25_docid_to_tid(v, &tid);
			if (callback(&tid, callback_state))
			{
				sm_add_grow(&dead, v);
				ndead++;
				tuples_removed++;
			}
		}
		sm_free(seen);

		oldlivedocs = sg->livedocs;
		oldlen = sg->livedocslen;

		/* write the updated tombstone bitmap (if any) and patch the metapage */
		{
			BlockNumber newblk = InvalidBlockNumber;
			uint32		newlen = 0;

			if (ndead > 0)
			{
				newlen = (uint32) sm_get_size(dead);
				newblk = bm25_write_blob(index, (const uint8 *) sm_get_data(dead),
										 newlen);
			}
			sm_free(dead);


			{
				Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
				GenericXLogState *st;
				Page		mp;
				BM25MetaPageData *m;

				LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
				st = GenericXLogStart(index);
				mp = GenericXLogRegisterBuffer(st, mb, 0);
				m = BM25PageGetMeta(mp);
				if (s < m->nsegments)
				{
					m->segs[s].livedocs = newblk;
					m->segs[s].livedocslen = newlen;
					m->segs[s].ndeleted = ndead;
					m->generation++;	/* livedocs blob pages freed: invalidate scan snapshots */
				}
				GenericXLogFinish(st);
				UnlockReleaseBuffer(mb);
			}
		}

		/* recycle the previous tombstone blob pages */
		if (oldlivedocs != InvalidBlockNumber && oldlen > 0)
			bm25_free_chain(index, oldlivedocs);
	}

	/* refresh corpus N so IDF/avgdl reflect the deletions */
	if (tuples_removed > 0)
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *st;
		Page		mp;
		BM25MetaPageData *m;
		uint32		i;
		double		nd = 0;

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		st = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(st, mb, 0);
		m = BM25PageGetMeta(mp);
		for (i = 0; i < m->nsegments; i++)
			nd += m->segs[i].ndocs - m->segs[i].ndeleted;
		m->ndocs = nd + m->npending;
		GenericXLogFinish(st);
		UnlockReleaseBuffer(mb);
	}

	stats->num_index_tuples = (double) (num_index_tuples - tuples_removed);
	stats->tuples_removed += (double) tuples_removed;
	stats->num_pages = RelationGetNumberOfBlocks(index);
	return stats;
}

static IndexBulkDeleteResult *
bm25_vacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	/* Fold any pending documents into a new segment, then compact segments. */
	if (!info->analyze_only)
	{
		(void) bm25_flush_pending(info->index);
		bm25_merge_segments(info->index);

		/*
		 * If the relation carries substantial dead space (physical size well
		 * above the live pages), reclaim it: compact to one segment reusing
		 * low blocks, then truncate the free tail.  Gated so routine
		 * autovacuum does not pay a full rewrite every pass -- only when the
		 * free tail is a meaningful fraction of the file.
		 */
		{
			BlockNumber nblocks = RelationGetNumberOfBlocks(info->index);
			BlockNumber freeblks = 0;
			BlockNumber b;

			for (b = 1; b < nblocks; b++)
				if (GetRecordedFreeSpace(info->index, b) >= BLCKSZ / 2)
					freeblks++;
			/* reclaim when >= 25% of the file is free (bloated after merges) */
			if (nblocks > 16 && freeblks > nblocks / 4)
				(void) bm25_vacuum_compact(info->index);
		}
	}

	return stats;
}

PG_FUNCTION_INFO_V1(fts_merge);

/* fts_merge(regclass) -> bool : merge the pending list on demand */
Datum
fts_merge(PG_FUNCTION_ARGS)
{
	Oid			indexoid = PG_GETARG_OID(0);
	Relation	index;
	bool		done;

	index = index_open(indexoid, ShareUpdateExclusiveLock);
	if (index->rd_rel->relam != get_index_am_oid("fts", true))
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" is not an fts index",
						RelationGetRelationName(index))));
	done = bm25_flush_pending(index);
	/*
	 * Also compact the segment directory to a single optimal segment.  This is
	 * what makes fts_merge() an explicit "optimize now": after a parallel build
	 * (which leaves the workers' segments unmerged for speed) or churn, one call
	 * yields a one-segment index.  The tiered auto-merge deliberately leaves
	 * several same-size segments, so it is not enough on its own here.
	 */
	if (bm25_merge_all(index))
		done = true;
	index_close(index, ShareUpdateExclusiveLock);

	PG_RETURN_BOOL(done);
}

PG_FUNCTION_INFO_V1(fts_vacuum);

/*
 * fts_vacuum(regclass) -> bool : on-demand full compaction with truncation.
 * Like fts_merge(), but after compacting to one segment it reclaims the dead
 * pages left by prior merges -- packing live pages at the front of the file
 * and truncating the free tail back to the OS.  Use this to shrink an index
 * that has grown physically larger than its live contents.
 */
Datum
fts_vacuum(PG_FUNCTION_ARGS)
{
	Oid			indexoid = PG_GETARG_OID(0);
	Relation	index;
	bool		done;

	index = index_open(indexoid, ShareUpdateExclusiveLock);
	if (index->rd_rel->relam != get_index_am_oid("fts", true))
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" is not an fts index",
						RelationGetRelationName(index))));
	done = bm25_flush_pending(index);
	if (bm25_vacuum_compact(index))
		done = true;
	index_close(index, ShareUpdateExclusiveLock);

	PG_RETURN_BOOL(done);
}

static void
bm25_costestimate(PlannerInfo *root, IndexPath *path, double loop_count,
				  Cost *indexStartupCost, Cost *indexTotalCost,
				  Selectivity *indexSelectivity, double *indexCorrelation,
				  double *indexPages)
{
	GenericCosts costs = {0};

	/* baseline: generic estimate gives selectivity, pages, and row counts */
	genericcostestimate(root, path, loop_count, &costs);

	*indexSelectivity = costs.indexSelectivity;
	*indexCorrelation = costs.indexCorrelation;
	*indexPages = costs.numIndexPages;

	if (path->indexorderbys != NIL)
	{
		/*
		 * Ordering scan (ORDER BY ftsdoc <=> ftsquery): the AM runs block-max
		 * WAND / MaxScore and, with a LIMIT pushed down, the executor pulls only
		 * about k best results -- work is sublinear in the match set, unlike a
		 * generic full index scan.  Price it as mostly a modest startup plus a
		 * small per-tuple cost, so the planner prefers the index (which honours
		 * the ORDER BY) over a seqscan + sort.  We deliberately keep this low
		 * but nonzero; the LIMIT is applied by the caller (limit_tuples), so a
		 * cheap-per-tuple total lets a small LIMIT win and a large one still
		 * scale.
		 */
		double		ntuples = costs.numIndexTuples;

		*indexStartupCost = costs.indexStartupCost + 2.0 * cpu_operator_cost;
		/* WAND touches ~log(N)*k blocks, not all matches: charge a fraction of
		 * a page fetch per matching tuple plus the per-tuple CPU */
		*indexTotalCost = *indexStartupCost +
			ntuples * (cpu_index_tuple_cost + cpu_operator_cost) +
			0.25 * costs.numIndexPages * costs.spc_random_page_cost;
	}
	else
	{
		/*
		 * Plain @@@ scan: the generic estimate (selectivity from clause
		 * selectivity, pages from the posting lists) is a reasonable model of
		 * decoding the matching TID sets, so use it as-is.
		 */
		*indexStartupCost = costs.indexStartupCost;
		*indexTotalCost = costs.indexTotalCost;
	}
}

static bytea *
bm25_options(Datum reloptions, bool validate)
{
	static const relopt_parse_elt tab[] = {
		{"positions", RELOPT_TYPE_BOOL, offsetof(BM25Options, positions)},
	};

	return (bytea *) build_reloptions(reloptions, validate,
									  bm25_relopt_kind,
									  sizeof(BM25Options),
									  tab, lengthof(tab));
}

/*
 * Does this index carry token positions in its postings?  Reads the
 * `positions` reloption (default OFF -- positions ~double the posting bytes,
 * so the size-sensitive majority who never phrase-search pay nothing; phrase
 * users opt in with WITH (positions=on)).  Phrase/NEAR is CORRECT either way:
 * positions=on evaluates it from the postings with no recheck; positions=off
 * falls back to the (correct, slower) heap recheck.
 */
static bool
bm25_index_wants_positions(Relation index)
{
	BM25Options *opts = (BM25Options *) index->rd_options;

	return opts ? opts->positions : false;
}

static bool
bm25_validate(Oid opclassoid)
{
	return true;
}

Datum
fts_handler(PG_FUNCTION_ARGS)
{
	IndexAmRoutine *amroutine = makeNode(IndexAmRoutine);

	amroutine->amstrategies = 2;
	amroutine->amsupport = 0;
	amroutine->amoptsprocnum = 0;
	amroutine->amcanorder = false;
	amroutine->amcanorderbyop = true;
#if PG_VERSION_NUM >= 180000
	amroutine->amcanhash = false;
	amroutine->amconsistentequality = false;
	amroutine->amconsistentordering = false;
#endif
	amroutine->amcanbackward = false;
	amroutine->amcanunique = false;
	amroutine->amcanmulticol = false;
	amroutine->amoptionalkey = false;
	amroutine->amsearcharray = false;
	amroutine->amsearchnulls = false;
	amroutine->amstorage = false;
	amroutine->amclusterable = false;
	amroutine->ampredlocks = false;
	amroutine->amcanparallel = false;
#if PG_VERSION_NUM >= 170000
	amroutine->amcanbuildparallel = true;
#endif
	amroutine->amcaninclude = false;
	amroutine->amusemaintenanceworkmem = false;
	amroutine->amparallelvacuumoptions = VACUUM_OPTION_NO_PARALLEL;
	amroutine->amkeytype = InvalidOid;

	amroutine->ambuild = bm25_build;
	amroutine->ambuildempty = bm25_buildempty;
	amroutine->aminsert = bm25_insert;
#if PG_VERSION_NUM >= 170000
	amroutine->aminsertcleanup = NULL;
#endif
	amroutine->ambulkdelete = bm25_bulkdelete;
	amroutine->amvacuumcleanup = bm25_vacuumcleanup;
	amroutine->amcanreturn = bm25_canreturn;
	amroutine->amcostestimate = bm25_costestimate;
#if PG_VERSION_NUM >= 180000
	amroutine->amgettreeheight = NULL;
#endif
	amroutine->amoptions = bm25_options;
	amroutine->amproperty = NULL;
	amroutine->ambuildphasename = NULL;
	amroutine->amvalidate = bm25_validate;
	amroutine->amadjustmembers = NULL;
	amroutine->ambeginscan = bm25_beginscan;
	amroutine->amrescan = bm25_rescan;
	amroutine->amgettuple = bm25_gettuple;
	amroutine->amgetbitmap = bm25_getbitmap;
	amroutine->amendscan = bm25_endscan;
	amroutine->ammarkpos = NULL;
	amroutine->amrestrpos = NULL;
	amroutine->amestimateparallelscan = NULL;
	amroutine->aminitparallelscan = NULL;
	amroutine->amparallelrescan = NULL;

	PG_RETURN_POINTER(amroutine);
}
