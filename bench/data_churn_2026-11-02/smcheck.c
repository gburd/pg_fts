/* smcheck.c: sm_contains(map, idx, &cursor) must equal sm_contains(map, idx, NULL) for every lookup, for
 * ascending sequences (the contract) and for arbitrary ones (the cursor self-validates), over random maps that
 * mix sparse chunks, dense runs and RLE chunks.  Exit 1 on the first mismatch. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include "sm.h"
static uint64_t rs = 88172645463325252ULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int cmp64(const void *a, const void *b) { uint64_t x = *(const uint64_t *) a, y = *(const uint64_t *) b; return x < y ? -1 : x > y; }
int main(void)
{
	long checked = 0; int trial;
	for (trial = 0; trial < 400; trial++) {
		sm_t *m = sm_create(256); uint64_t span = 1000 + rnd() % 3000000, n = rnd() % 4000, i, *ids;
		int mode = trial % 4;
		ids = malloc((n + 1) * sizeof(uint64_t));
		for (i = 0; i < n; i++) {
			if (mode == 0) ids[i] = rnd() % span;                       /* sparse */
			else if (mode == 1) ids[i] = (rnd() % 64) * 4096 + rnd() % 8; /* clustered */
			else if (mode == 2) ids[i] = i;                              /* one dense run (RLE) */
			else ids[i] = (i / 300) * 20000 + i % 300;                   /* several runs */
		}
		qsort(ids, n, sizeof(uint64_t), cmp64);
		if (n && !sm_add_many_grow(&m, ids, n)) { fprintf(stderr, "add failed\n"); return 2; }
		{	/* ascending, with repeats */
			sm_cursor_t c = SM_CURSOR_INIT; uint64_t q = 0;
			while (q < span + 5000) {
				if (sm_contains(m, q, &c) != sm_contains(m, q, NULL)) { printf("MISMATCH asc trial %d idx %llu\n", trial, (unsigned long long) q); return 1; }
				checked++; q += rnd() % 97 == 0 ? 0 : 1 + rnd() % 500;
			}
		}
		{	/* arbitrary order: the cursor must still never give a wrong answer */
			sm_cursor_t c = SM_CURSOR_INIT; int k;
			for (k = 0; k < 4000; k++) {
				uint64_t q = rnd() % (span + 5000);
				if (k % 3 == 0 && n) q = ids[rnd() % n] + (rnd() % 3) - 1;
				if (sm_contains(m, q, &c) != sm_contains(m, q, NULL)) { printf("MISMATCH any trial %d idx %llu\n", trial, (unsigned long long) q); return 1; }
				checked++;
			}
		}
		sm_free(m); free(ids);
	}
	printf("smcheck OK: %ld lookups, cursor == no-cursor (version %s)\n", checked, SM_VERSION_STRING);
	return 0;
}
