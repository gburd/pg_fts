/* Can the PUBLIC API leave a cursor whose (offset, start_idx) still validate
 * but whose prev_offset is no longer a chunk start, and then get a wrong
 * sm_contains answer?  Random maps, a cursor positioned by sm_contains, then a
 * random mutation (sm_add / sm_remove, cursor NOT reset -- a contract
 * violation sparsemap's self-validation comment says it tolerates), then
 * lookups compared with cursor-free ones. */
#define SPARSEMAP_PREFIX
#include "../../vendor/sm.c"
#include <stdio.h>
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int is_chunk_start(sm_t *m, size_t off)
{
	size_t n = __sm_get_chunk_count(m), o = 0, c;
	uint8_t *base = __sm_get_chunk_data(m, 0);
	for (c = 0; c < n; c++) {
		__sm_chunk_t ch;
		if (o == off) return 1;
		__sm_chunk_init(&ch, base + o + SM_SIZEOF_OVERHEAD);
		o += SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&ch);
	}
	return 0;
}
int main(void)
{
	long trials = 0, stale_hint = 0, wrong = 0;
	for (int t = 0; t < 300000; t++) {
		sm_t *m = sm_create(1 << 16);
		uint64_t B = 1 << 16, k;
		int nmem = 2 + rnd() % 12;
		for (k = 0; k < (uint64_t) nmem; k++)
			sm_add(m, B + rnd() % (8 * 2048));
		sm_cursor_t c = SM_CURSOR_INIT;
		(void) sm_contains(m, B + rnd() % (8 * 2048), &c);
		/* mutate WITHOUT resetting the cursor */
		uint64_t mv = B + rnd() % (8 * 2048);
		if (rnd() & 1) sm_add(m, mv); else sm_remove(m, mv);
		trials++;
		if (c.offset != SIZE_MAX && c.prev_offset != SIZE_MAX && !is_chunk_start(m, c.prev_offset))
			stale_hint++;
		for (int q = 0; q < 40; q++) {
			uint64_t x = B - 2048 + rnd() % (10 * 2048);
			sm_cursor_t c2 = c;
			if (sm_contains(m, x, &c2) != sm_contains(m, x, NULL)) {
				if (wrong++ < 3)
					printf("wrong answer: trial %d idx %lu after %s %lu\n", t, (unsigned long) x, "mutation", (unsigned long) mv);
				break;
			}
		}
		sm_free(m);
	}
	printf("%ld trials: cursor hint stale after a mutation in %ld; wrong answers in %ld\n", trials, stale_hint, wrong);
	return 0;
}
