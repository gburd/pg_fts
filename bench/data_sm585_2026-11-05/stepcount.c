/* steps per lookup in the ascending gap pattern: count chunk-walk iterations by instrumenting via
 * the cursor offsets (offset advance between calls / avg chunk size) -- simpler: count calls to
 * __sm_chunk_get_size through a counter macro is invasive; instead measure ns per lookup for
 * (a) every lookup in a gap, (b) lookups that hit, for 5.8.4 and 5.8.5. */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
#include <time.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1e9 + t.tv_nsec; }
int main(void)
{
	uint64_t n = 20000, *ids = malloc(n * 8), i, h = 0; for (i = 0; i < n; i++) ids[i] = i * 3000 + 7;
	sm_t *m = sm_create(256); sm_add_many_grow(&m, ids, n);
	double bg = 1e18, bh = 1e18;
	for (int r = 0; r < 7; r++) {
		sm_cursor_t c = SM_CURSOR_INIT; double t0 = now();
		for (uint64_t q = 0; q < n * 3000; q += 100) h += sm_contains(m, q, &c);	/* 30 gap lookups per chunk */
		double t = (now() - t0) / (n * 30); if (t < bg) bg = t;
		c = (sm_cursor_t) SM_CURSOR_INIT; t0 = now();
		for (i = 0; i < n; i++) h += sm_contains(m, ids[i], &c);
		t = (now() - t0) / n; if (t < bh) bh = t;
	}
	printf("%s: %.2f ns per ascending gap lookup, %.2f ns per member lookup (h=%lu)\n", SM_VERSION_STRING, bg, bh, (unsigned long) h);
	return 0;
}
