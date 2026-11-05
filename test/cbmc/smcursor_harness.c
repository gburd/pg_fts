/*-------------------------------------------------------------------------
 *
 * smcursor_harness.c
 *		CBMC proof that a sparsemap read cursor never changes an answer:
 *		sm_contains(map, idx, &cursor) == sm_contains(map, idx, NULL) for
 *		any map, any index and ANY prior cursor state the scan can leave --
 *		including the gap-lookup resume the tombstone test on every ranked
 *		path depends on (pg_fts ROADMAP I25; sparsemap 5.8.4, redesigned in
 *		5.8.5 after ROADMAP I29).
 *
 *	The code under proof is vendor/sm.c itself, #included unprefixed as
 *	test/fuzz/fuzz_smblob.c does.  Maps are concrete layouts built by the
 *	library (see layout_map); the lookups and the cursor state are
 *	symbolic.
 *
 *	PROPERTIES (bound: four layouts; three ascending lookups then one
 *	arbitrary lookup, every index from one chunk before the map to past its
 *	end):
 *	  C1  ascending lookups with one cursor agree with cursor-free lookups
 *	      (the scan pattern: wand_cur_own_tombstoned);
 *	  C2  after them, a lookup at ANY index -- below the cached chunk, in the
 *	      gap before it, inside it, past the end -- agrees too (the cursor
 *	      self-validates; a stale or behind cursor must fall back, not lie);
 *	  C3  any cursor state the API can leave on the same unmodified map (a
 *	      lookup's cursor with its left-neighbour hint set to any chunk of
 *	      the map, or none) agrees on every index.
 *	  C3x any prev_offset value, chunk start or not, agrees (failed on
 *	      5.8.4: ROADMAP I29; fixed in sparsemap 5.8.5).
 *	  C4  a stale cursor -- a real chunk's start_idx at any 8-byte offset --
 *	      agrees (the start-word check; harness_stale_offset).
 *
 *	TEETH: mutate_sm.py writes a copy of vendor/sm.c without the cursor's
 *	start-word check (resume at cur->offset whatever is stored there): C4
 *	must fail.  The vendored file is never modified.
 *
 * IDENTIFICATION
 *	  test/cbmc/smcursor_harness.c
 *
 *-------------------------------------------------------------------------
 */
#define SPARSEMAP_PREFIX
#ifndef SM_SOURCE
#define SM_SOURCE "../../vendor/sm.c"
#endif
#include SM_SOURCE

#include <stdbool.h>
#include <stdint.h>
/*
 * The map.  Building it with sm_add from symbolic members makes the SAT
 * problem the whole insert path (it did not finish in 90 minutes on 256 GB),
 * and the insert path is not what is under proof.  Instead each run builds
 * one CONCRETE layout with the library (sm_add, so the bytes are exactly what
 * the library writes) and the LOOKUPS are symbolic: every index, every
 * lookup order, every cursor state.  run.sh runs the layouts that exercise
 * the cursor's cases: one member per chunk with gaps between (the pg_fts
 * tombstone shape, I25), adjacent chunks with no gap, a run-length chunk
 * followed by a sparse one, a single chunk.
 */
#ifndef LAYOUT
#define LAYOUT 0
#endif
#define CHUNK 2048u				/* SM_CHUNK_MAX_CAPACITY */
#define BASE  (16u * CHUNK)		/* above SM_SMALL_MAX_BITS: chunk mode */
#define SPAN  (6u * CHUNK)		/* lookups range over [BASE - CHUNK, BASE + SPAN) */

#ifndef GEN_LAYOUT
uint64_t	nondet_u64(void);

static uint64_t
nondet_index(void)
{
	uint64_t	v = nondet_u64();

	__CPROVER_assume(v >= BASE - CHUNK && v < BASE + SPAN);
	return v;
}
#endif

/*
 * The layout is built by the library on concrete inputs, and the result is
 * what the lookups run against.  CBMC still symbolically executes the build
 * (the insert path is ~2,000 lines), so the harness builds it NATIVELY once
 * (gen_layouts: compile this file with -DGEN_LAYOUT, run it) and embeds the
 * serialized bytes; the proof then sm_open()s them, exactly as pg_fts opens a
 * stored tombstone blob (bm25_sm_open_checked), and checks sm_validate first.
 */
#ifndef GEN_LAYOUT
#include "smcursor_layouts.h"	/* layout_bytes[LAYOUT], layout_len[LAYOUT] */

static sm_t smap;

static sm_t *
layout_map(void)
{
	static uint8_t buf[256];
	size_t		n = layout_len[LAYOUT];
	size_t		i;

	for (i = 0; i < n; i++)
		buf[i] = layout_bytes[LAYOUT][i];
	sm_open(&smap, buf, n);
	__CPROVER_assert(sm_validate(&smap) && sm_get_size(&smap) == n,
					 "the embedded layout reopens and validates");
	return &smap;
}
#endif

static sm_t *
layout_build(int layout)
{
	sm_t	   *m = sm_create(4096);
	uint64_t	i;

	(void) layout;
	if (layout == 0)
	{
		/* scattered: one member in each of chunks 0, 2 and 4 (gaps between) */
		sm_add(m, BASE + 17);
		sm_add(m, BASE + 2 * CHUNK + 1000);
		sm_add(m, BASE + 4 * CHUNK + 2047);
	}
	else if (layout == 1)
	{
		/* adjacent: members in chunks 0, 1 and 2 */
		sm_add(m, BASE + 5);
		sm_add(m, BASE + CHUNK + 5);
		sm_add(m, BASE + 2 * CHUNK + 5);
	}
	else if (layout == 2)
	{
		/* a two-chunk run, then a gap, then a sparse chunk */
		for (i = 0; i < 2 * CHUNK; i += 64)
			sm_add_range(m, BASE + i, BASE + i + 64);
		sm_add(m, BASE + 4 * CHUNK + 3);
	}
	else
	{
		/* one sparse chunk */
		sm_add(m, BASE + 100);
		sm_add(m, BASE + 101);
	}
	return m;
}

#ifndef GEN_LAYOUT
void
harness_ascending(void)			/* C1, C2 */
{
	sm_t	   *m = layout_map();
	sm_cursor_t cur = SM_CURSOR_INIT;
	uint64_t	a = nondet_index(),
				b = nondet_index(),
				c = nondet_index(),
				x = nondet_index();

	__CPROVER_assume(a <= b && b <= c);
	__CPROVER_assert(sm_contains(m, a, &cur) == sm_contains(m, a, NULL), "C1: first lookup");
	__CPROVER_assert(sm_contains(m, b, &cur) == sm_contains(m, b, NULL), "C1: ascending lookup");
	__CPROVER_assert(sm_contains(m, c, &cur) == sm_contains(m, c, NULL), "C1: ascending lookup");
	__CPROVER_assert(sm_contains(m, x, &cur) == sm_contains(m, x, NULL), "C2: any later lookup");
}

/* byte offset of a nondeterministic chunk of m, or SIZE_MAX */
static size_t
nondet_chunk_offset(sm_t *m)
{
	size_t		count = __sm_get_chunk_count(m),
				off = 0,
				c,
				pick = (size_t) nondet_u64();
	uint8_t    *base = __sm_get_chunk_data(m, 0);

	__CPROVER_assume(pick <= count);
	if (pick == count)
		return SIZE_MAX;
	for (c = 0; c < pick; c++)
	{
		__sm_chunk_t ch;

		__sm_chunk_init(&ch, base + off + SM_SIZEOF_OVERHEAD);
		off += SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&ch);
	}
	return off;
}

void
harness_any_cursor(void)		/* C3 */
{
	sm_t	   *m = layout_map();
	sm_cursor_t cur = SM_CURSOR_INIT;
	uint64_t	at = nondet_index(),
				x = nondet_index();

	/*
	 * Any cursor state the API can leave on this unmodified map: positioned by
	 * a lookup, with its left-neighbour hint any chunk of the map (or none) --
	 * a hint left by an earlier lookup, or copied from another cursor of the
	 * same map (pg_fts's checkpoints and memo do that).
	 */
	(void) sm_contains(m, at, &cur);
	cur.prev_offset = nondet_chunk_offset(m);
	__CPROVER_assert(sm_contains(m, x, &cur) == sm_contains(m, x, NULL), "C3: any cursor state of this map");
}

/*
 * C3x: ANY prev_offset value, chunk start or not.  5.8.4's gap resume trusted
 * a hint that only "ended exactly where the cached chunk begins", and with a
 * hint that was not a chunk start it walked from mid-chunk and answered
 * wrong (layout 1: hint 16, lookup 32773 -> false, truly true; ROADMAP I29).
 * sparsemap 5.8.5 never starts a walk at the hint, so this now verifies; it
 * was a finding (expected to FAIL) until then.
 */
void
harness_stale_hint(void)
{
	sm_t	   *m = layout_map();
	sm_cursor_t cur = SM_CURSOR_INIT;
	uint64_t	at = nondet_index(),
				x = nondet_index();

	(void) sm_contains(m, at, &cur);
	cur.prev_offset = (size_t) nondet_u64();
	__CPROVER_assert(sm_contains(m, x, &cur) == sm_contains(m, x, NULL), "C3x: any prev_offset value");
}
/*
 * C4, the teeth for 5.8.5's design (from the sparsemap maintainers): a stale
 * cursor whose start_idx is the real start of some chunk of the map but
 * whose offset is any 8-byte position (the layout moved under it).  The
 * start-word check in __sm_get_chunk_offset (the word at offset must be
 * start_idx) is what keeps such a cursor from walking mid-chunk, so this
 * verifies on vendor/sm.c and must FAIL on mutate_sm.py's copy, which drops
 * that check.  (A payload word that EQUALS the recorded start can still fool
 * a stale cursor -- sm.h documents that; the layouts here have no such word.)
 */
void
harness_stale_offset(void)
{
	sm_t	   *m = layout_map();
	sm_cursor_t cur = SM_CURSOR_INIT;
	uint64_t	x = nondet_index();
	size_t		off = (size_t) nondet_u64(),
				real = nondet_chunk_offset(m);

	__CPROVER_assume(real != SIZE_MAX);
	__CPROVER_assume(off % 8 == 0 && off + 8 <= sm_get_size(m) - SM_SIZEOF_OVERHEAD);
	cur.offset = off;
	cur.start_idx = __sm_load_idx(__sm_get_chunk_data(m, real));
	cur.prev_offset = (size_t) nondet_u64();
	__CPROVER_assert(sm_contains(m, x, &cur) == sm_contains(m, x, NULL), "C4: stale offset, real start_idx");
}

#endif

#ifdef GEN_LAYOUT
#include <stdio.h>
/* write smcursor_layouts.h: the serialized bytes of every layout */
int
main(void)
{
	int			l;
	size_t		i;

	printf("/* generated by: cc -DGEN_LAYOUT -I../../vendor smcursor_harness.c && ./a.out */\n");
	printf("static const size_t layout_len[4] = {");
	for (l = 0; l < 4; l++)
	{
		sm_t	   *m = layout_build(l);

		printf("%s%zu", l ? ", " : "", sm_get_size(m));
		sm_free(m);
	}
	printf("};\nstatic const uint8_t layout_bytes[4][256] = {\n");
	for (l = 0; l < 4; l++)
	{
		sm_t	   *m = layout_build(l);
		const uint8_t *d = sm_get_data(m);

		printf("\t{");
		for (i = 0; i < sm_get_size(m); i++)
			printf("%s%u", i ? "," : "", d[i]);
		printf("},\n");
		sm_free(m);
	}
	printf("};\n");
	return 0;
}
#endif
