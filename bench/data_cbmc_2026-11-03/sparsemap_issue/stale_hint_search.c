/* build: cc -O2 -std=gnu99 -I. stale_hint_search.c -o x && ./x   (against the v5.8.4 sm.c / sm.h copied here) */
/* Targeted search: adjacent chunks with ONE member each (the CBMC layout),
 * cursor positioned in a later chunk, then ONE mutation that grows or
 * shrinks an EARLIER chunk by a vector (offsets of later chunks shift) without
 * resetting the cursor, then lookups across the map through the cursor. */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
static uint64_t rs = 0x2545F4914F6CDD1Dull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
int main(void)
{
	const uint64_t B = 32768, C = 2048;
	long trials = 0, wrong = 0;
	for (int t = 0; t < 2000000; t++) {
		sm_t *m = sm_create(4096);
		int nch = 2 + rnd() % 5, i;
		for (i = 0; i < nch; i++) {
			int per = 1 + rnd() % 3;
			for (int j = 0; j < per; j++) sm_add(m, B + i * C + rnd() % C);
		}
		sm_cursor_t c = SM_CURSOR_INIT;
		(void) sm_contains(m, B + (nch - 1) * C + rnd() % C, &c);
		/* mutate an earlier chunk */
		uint64_t mv = B + (rnd() % (nch - 1)) * C + rnd() % C;
		if (rnd() & 1) sm_add(m, mv); else sm_remove(m, mv);
		trials++;
		for (int q = 0; q < 64; q++) {
			uint64_t x = B + rnd() % (nch * C);
			sm_cursor_t c2 = c;
			if (sm_contains(m, x, &c2) != sm_contains(m, x, NULL)) {
				if (wrong++ < 5) printf("trial %d: wrong answer at %llu after mutating %llu\n", t, (unsigned long long) x, (unsigned long long) mv);
				break;
			}
		}
		sm_free(m);
	}
	printf("%ld trials: wrong answers through a kept cursor: %ld\n", trials, wrong);
	return 0;
}
