/* Does sm_add_grow_cursor ever hand back a cursor whose prev_offset is not
 * a chunk start of the current map (while offset/start_idx still validate)?
 * And does a lookup or the next insert through such a cursor ever give a
 * wrong result?  Random ascending and non-ascending insert sequences against
 * an exact bit-array oracle.  Build against upstream sm.c:
 *   cc -O1 -std=gnu99 -I<sparsemap> grow_cursor_check.c -o g && ./g          */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int is_chunk_start(sm_t *m, size_t off)
{
	size_t n = __sm_get_chunk_count(m), o = 0, c;
	uint8_t *base;
	if (__sm_is_small(m) || n == 0) return 0;
	base = __sm_get_chunk_data(m, 0);
	for (c = 0; c < n; c++) {
		__sm_chunk_t ch;
		if (o == off) return 1;
		__sm_chunk_init(&ch, base + o + SM_SIZEOF_OVERHEAD);
		o += SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&ch);
	}
	return 0;
}
#define SPAN (64 * 2048)
int main(int argc, char **argv)
{
	long trials = argc > 1 ? atol(argv[1]) : 20000, bad_hint = 0, wrong = 0, steps = 0;
	static unsigned char oracle[SPAN];
	for (long t = 0; t < trials; t++) {
		sm_t *m = sm_create(64);
		sm_cursor_t c = SM_CURSOR_INIT;
		uint64_t base = 1 << 20, k, n = 5 + rnd() % 200, last = 0;
		int ascending = t % 3 != 0;
		memset(oracle, 0, sizeof oracle);
		for (k = 0; k < n; k++) {
			uint64_t v = ascending ? (last += 1 + (rnd() % 4 ? rnd() % 3000 : rnd() % 3)) % SPAN : rnd() % SPAN;
			if (sm_add_grow_cursor(&m, base + v, &c) == SM_IDX_MAX) { printf("add failed\n"); return 2; }
			oracle[v] = 1;
			steps++;
			if (c.offset != SIZE_MAX && c.prev_offset != SIZE_MAX && !is_chunk_start(m, c.prev_offset)) {
				if (bad_hint++ < 3)
					printf("trial %ld step %lu: cursor prev_offset %zu is not a chunk start (offset %zu start %lu)\n",
					       t, (unsigned long) k, c.prev_offset, c.offset, (unsigned long) c.start_idx);
			}
			/* a lookup through a COPY of the threaded cursor, and the map, against the oracle */
			{
				uint64_t q = rnd() % SPAN;
				sm_cursor_t c2 = c;
				int a = sm_contains(m, base + q, &c2), b = oracle[q];
				if (a != b && wrong++ < 3)
					printf("trial %ld: sm_contains(%lu) via threaded cursor = %d, truth %d\n", t, (unsigned long) q, a, b);
			}
		}
		/* full check of the final map without a cursor */
		for (k = 0; k < SPAN; k += 1 + rnd() % 64)
			if ((int) sm_contains(m, base + k, NULL) != oracle[k]) { if (wrong++ < 3) printf("trial %ld: final map wrong at %lu\n", t, (unsigned long) k); break; }
		sm_free(m);
	}
	printf("%ld trials, %ld inserts: cursor hint not a chunk start after an insert: %ld; wrong answers: %ld\n", trials, steps, bad_hint, wrong);
	return wrong != 0;
}
