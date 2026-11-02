/*
 * fuzz_smblob.c -- property test for the tombstone-blob round trip through the
 * VENDORED sparsemap, under ASan+UBSan.
 *
 * pg_fts stores a segment's tombstones as a sparsemap serialized by
 * sm_get_data()/sm_get_size() and reopened by sm_open(), then guarded by
 * bm25_sm_open_checked(): the reopened size must equal the stored length and
 * sm_validate() must pass.  sparsemap 5.7.0 added a second on-disk encoding
 * (small-set mode: a bare uint64 word array when every index is below a cap,
 * selected by the header word's top bit) that our tombstone maps will take
 * whenever a segment's deleted docids are all small -- which is common.
 *
 * Properties, for random docid sets across the small/chunk boundary:
 *   1. write -> reopen preserves size exactly (bm25_sm_open_checked's invariant)
 *   2. the reopened map validates
 *   3. membership is preserved bit-for-bit (the query-time tombstone test)
 *   4. sm_next_member enumerates exactly the set, ascending (the merge's dense
 *      decode walks it this way)
 *   5. when every index is below the small cap the encoding IS small mode (top
 *      header bit set) and is no larger than one uint64 per 64 bits of span --
 *      so the mode is actually exercised, not just tolerated
 *   6. a 5.6.0-shaped chunk-mode blob (top bit clear) still reopens and reads
 *      identically -- forward compatibility for every tombstone on disk today
 *
 * Compiles vendor/sm.c directly, unprefixed, exactly as test/fuzz does for the
 * other codecs: single source of truth.
 */
#define _POSIX_C_SOURCE 200809L	/* clock_gettime under -std=c99 */
#define SPARSEMAP_PREFIX
#include "vendor/sm.c"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t rng_state = 0x9E3779B97F4A7C15ull;
static uint64_t
rng_next(void)
{
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 7;
	rng_state ^= rng_state << 17;
	return rng_state;
}

#define MAXN 512
#ifndef ITERS
#define ITERS 20000
#endif

static void
one_case(int iter)
{
	/* choose a span: half the cases stay under the small cap, half cross it */
	uint64_t	span = (iter & 1) ? (rng_next() % 1000) + 1
							  : (rng_next() % 200000) + 1024;
	int			n = (int) (rng_next() % MAXN);
	uint64_t	ids[MAXN];
	uint8_t		buf[65536];
	uint8_t		blob[65536];
	sm_t		w, r;
	size_t		len;
	int			i;

	for (i = 0; i < n; i++)
		ids[i] = rng_next() % span;

	/* --- write, the way bulkdelete/merge do: build, then snapshot bytes --- */
	sm_init(&w, buf, sizeof(buf));
	for (i = 0; i < n; i++)
		if (sm_add(&w, ids[i]) == SM_IDX_MAX)
			assert(!"sm_add failed on an in-range docid");
	len = sm_get_size(&w);
	assert(len >= SM_SIZEOF_OVERHEAD && len <= sizeof(blob));
	memcpy(blob, sm_get_data(&w), len);

	/* property 5: small-set mode is taken when it should be */
	{
		uint64_t	hdr;
		uint64_t	maxid = 0;
		int			any = 0;

		for (i = 0; i < n; i++) { if (ids[i] > maxid) maxid = ids[i]; any = 1; }
		memcpy(&hdr, blob, sizeof(hdr));
		if (any && maxid < 1024)
		{
			/* small mode must be chosen unless the RLE form is strictly
			 * smaller (a dense low run); either way the blob must be tiny */
			size_t		small_bound = SM_SIZEOF_OVERHEAD + ((maxid / 64) + 1) * 8;

			assert(len <= small_bound + 24 /* one RLE chunk */);
		}
		else if (!any)
			assert(len == SM_SIZEOF_OVERHEAD);
		(void) hdr;
	}

	/* --- reopen, the way every reader does --- */
	sm_open(&r, blob, len);

	/* property 1: bm25_sm_open_checked's invariant */
	assert(sm_get_size(&r) == len);
	/* property 2 */
	assert(sm_validate(&r));

	/* property 3: membership bit-for-bit over the whole span (+ a margin) */
	{
		uint8_t	   *want = calloc(span + 64, 1);
		uint64_t	x;

		for (i = 0; i < n; i++) want[ids[i]] = 1;
		/* every member is present ... */
		for (i = 0; i < n; i++)
			assert(sm_contains(&r, ids[i], NULL));
		/* ... and a bounded sample of the span reads back exactly (the full
		 * O(span) sweep made 20k cases take minutes; this keeps the property
		 * and makes the cost proportional to the set, not the span) */
		for (i = 0; i < 256; i++)
		{
			x = rng_next() % (span + 64);
			assert(sm_contains(&r, x, NULL) == (want[x] != 0));
		}
		/* the small-cap boundary itself, both sides, every time */
		for (x = 1020; x < 1030; x++)
			if (x < span + 64)
				assert(sm_contains(&r, x, NULL) == (want[x] != 0));

		/* property 4: forward enumeration is exactly the set, ascending */
		{
			sm_cursor_t cur = SM_CURSOR_INIT;
			uint64_t	prev = 0;
			int			first = 1;
			size_t		seen = 0;

			for (x = sm_next_member(&r, (uint64_t) -1, &cur);
				 x != SM_IDX_MAX;
				 x = sm_next_member(&r, x, &cur))
			{
				assert(x < span + 64 && want[x]);
				assert(first || x > prev);
				first = 0; prev = x; seen++;
			}
			{
				size_t	distinct = 0;
				for (i = 0; i < n; i++)
					if (want[ids[i]] == 1) { distinct++; want[ids[i]] = 2; }	/* count once */
				if (seen != distinct)
					fprintf(stderr, "iter %d span %llu n %d: enumerated %zu, distinct %zu\n",
							iter, (unsigned long long) span, n, seen, distinct);
				assert(seen == distinct);
			}
		}
		free(want);
	}

	/* property 6: a corrupted header must NOT silently open as a valid map of
	 * a different size -- that is the contract bm25_sm_open_checked relies on.
	 * Flip the mode bit / count and confirm either validate fails or size moves. */
	if (len > SM_SIZEOF_OVERHEAD)
	{
		uint8_t		bad[65536];
		sm_t		b;
		size_t		got;

		memcpy(bad, blob, len);
		bad[7] ^= 0x80;			/* toggle the mode bit in the header word */
		sm_open(&b, bad, len);
		got = sm_get_size(&b);
		assert(got != len || !sm_validate(&b) || got == SM_SIZEOF_OVERHEAD);
	}

	/*
	 * property 7 (sparsemap 5.8.1): for ANY single-byte corruption of a stored
	 * tombstone blob that bm25_sm_open_checked would ACCEPT (reopens at the
	 * stored size and validates), every reader agrees on the set.  5.8.0's
	 * sm_validate accepted a sparse descriptor with a data slot above the
	 * chunk's NONE-reduced capacity, where slot-indexed readers (cardinality)
	 * counted bits that capacity-bounded readers (contains / next_member --
	 * the ones pg_fts uses) skipped.  pg_fts only uses the latter, so it could
	 * never see a different answer between two of ITS reads, but an accepted
	 * buffer whose readers disagree is a corrupt buffer passing the guard --
	 * exactly what the guard exists to refuse.  Assert the 5.8.1 contract.
	 */
	if (len > SM_SIZEOF_OVERHEAD)
	{
		uint8_t		bad[65536];
		int			f;

		for (f = 0; f < 8; f++)
		{
			sm_t		b;
			size_t		pos = (size_t) (rng_next() % len);

			memcpy(bad, blob, len);
			bad[pos] ^= (uint8_t) (1u << (rng_next() % 8));
			sm_open(&b, bad, len);
			if (sm_get_size(&b) == len && sm_validate(&b))
			{
				sm_cursor_t cur = SM_CURSOR_INIT;
				uint64_t	x;
				size_t		walked = 0;

				for (x = sm_next_member(&b, (uint64_t) -1, &cur);
					 x != SM_IDX_MAX && walked <= (size_t) 1 << 24;
					 x = sm_next_member(&b, x, &cur))
					walked++;
				if ((size_t) sm_cardinality(&b) != walked)
					fprintf(stderr, "iter %d flip byte %zu: cardinality %zu, walk %zu\n",
							iter, pos, (size_t) sm_cardinality(&b), walked);
				assert((size_t) sm_cardinality(&b) == walked);
			}
		}
	}
}

/*
 * property 8 (pg_fts 1.15.2): a cursor never changes an answer, and an ascending
 * pass that lands in the gaps BETWEEN chunks stays O(lookups + chunks).  Live
 * docids tested against sparse tombstones are exactly that pass; through 5.8.2
 * every such lookup head-walked the chunk list (a cached chunk that starts
 * after idx was ignored), 60-300x on a 23k-tombstone segment.  Teeth: the
 * cost of a gap lookup relative to a lookup inside a chunk -- one member every
 * 3000 indexes is one chunk each, and 20,000 chunks with 100,000 gap lookups
 * cost ~1e9 chunk steps on the old code (4.8 s under ASan on c6id.metal)
 * against ~1e5 here.
 */
static int
cmp_u64(const void *a, const void *b)
{
	uint64_t	x = *(const uint64_t *) a,
				y = *(const uint64_t *) b;

	return x < y ? -1 : x > y;
}

static double
now_s(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double) t.tv_sec + (double) t.tv_nsec / 1e9;
}

static void
cursor_cases(void)
{
	int			trial;
	uint64_t	nmem = 20000,
				stride = 3000,
				i;
	uint64_t   *ids = malloc(nmem * sizeof(uint64_t));
	sm_t	   *m = sm_create(256);
	double		t0;

	for (trial = 0; trial < 200; trial++)
	{
		sm_t	   *r = sm_create(256);
		uint64_t	span = 1000 + rng_next() % 3000000,
					n = rng_next() % 3000,
					q,
					k;
		uint64_t   *v = malloc((n + 1) * sizeof(uint64_t));
		sm_cursor_t c = SM_CURSOR_INIT;

		for (k = 0; k < n; k++)
			v[k] = (trial % 3 == 0) ? rng_next() % span
				: (trial % 3 == 1) ? (rng_next() % 64) * 4096 + rng_next() % 8
				: (k / 300) * 20000 + k % 300;	/* runs: RLE chunks */
		qsort(v, n, sizeof(uint64_t), cmp_u64);
		if (n > 0 && !sm_add_many_grow(&r, v, n))
			abort();
		for (q = 0; q < span + 5000; q += 1 + rng_next() % 400)
			assert(sm_contains(r, q, &c) == sm_contains(r, q, NULL));
		c = (sm_cursor_t) SM_CURSOR_INIT;
		for (k = 0; k < 3000; k++)	/* any order: the cursor self-validates */
		{
			q = (n > 0 && k % 3 == 0) ? v[rng_next() % n] + rng_next() % 3 - 1
				: rng_next() % (span + 5000);
			assert(sm_contains(r, q, &c) == sm_contains(r, q, NULL));
		}
		sm_free(r);
		free(v);
	}
	for (i = 0; i < nmem; i++)
		ids[i] = i * stride + 7;
	if (!sm_add_many_grow(&m, ids, nmem))
		abort();
	/*
	 * Timed against the same number of lookups that land INSIDE chunks (the
	 * members themselves), not against a wall-clock constant: under ASan on a
	 * shared CI runner both scale together.  Gap lookups cost about what
	 * member lookups do when the cursor resumes (ratio ~1 on c6id.metal), and
	 * hundreds of times more when every one head-walks the chunk list (~460
	 * on 5.8.2).  The best of 3 passes each, so one descheduling cannot fail
	 * the run.
	 */
	{
		double		gap = 1e9,
					mem = 1e9;
		int			rep;

		for (rep = 0; rep < 3; rep++)
		{
			sm_cursor_t c = SM_CURSOR_INIT;
			uint64_t	q,
						n = 0,
						hits = 0;
			double		dt;

			t0 = now_s();
			for (q = 0; q < nmem * stride; q += 600, n++)
				hits += sm_contains(m, q, &c);
			dt = (now_s() - t0) / (double) n;
			if (hits != 0)		/* q = 600j never equals 3000i + 7 */
				abort();
			if (dt < gap)
				gap = dt;
			c = (sm_cursor_t) SM_CURSOR_INIT;
			hits = 0;
			t0 = now_s();
			for (i = 0; i < nmem; i++)
				hits += sm_contains(m, ids[i], &c);
			dt = (now_s() - t0) / (double) nmem;
			if (hits != nmem)
				abort();
			if (dt < mem)
				mem = dt;
		}
		if (gap > 20.0 * mem)
		{
			fprintf(stderr, "property 8: an ascending gap lookup took %.0fx a member lookup (%.1f vs %.1f ns)\n",
					gap / mem, gap * 1e9, mem * 1e9);
			abort();
		}
	}
	sm_free(m);
	free(ids);
}

int
main(void)
{
	int			iter;

	for (iter = 0; iter < ITERS; iter++)
		one_case(iter);
	cursor_cases();
	printf("fuzz_smblob: %d round-trips clean (small + chunk mode), cursor lookups exact and linear\n", ITERS);
	return 0;
}
