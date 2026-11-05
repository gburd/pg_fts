/* the pg_fts S3 pattern: ~23.7k scattered tombstones over a 1.9M-row docid space (blk*291+off), one ascending
 * sm_contains per live docid of a common term's postings (every ~3rd docid), one cursor; best of 9 */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
#include <time.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1e3 + t.tv_nsec/1e6; }
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
int main(void)
{
	const uint64_t span = 1900000ull / 50 * 291;	/* ~50 rows per heap page */
	uint64_t n = 23750, *ids = malloc(n * 8), i, hits = 0;
	for (i = 0; i < n; i++) ids[i] = rnd() % span;
	sm_t *m = sm_create(256); sm_add_many_grow(&m, ids, n);
	double best = 1e9, bestq = 1e9;
	for (int r = 0; r < 9; r++) {
		sm_cursor_t c = SM_CURSOR_INIT; double t0 = now();
		for (uint64_t q = 0; q < span; q += 3) hits += sm_contains(m, q, &c);
		double ms = now() - t0; if (ms < best) best = ms;
		/* a top-10-like pass: 5,000 ascending lookups from a random start (a fresh cursor each) */
		t0 = now();
		for (int s = 0; s < 200; s++) { sm_cursor_t c2 = SM_CURSOR_INIT; uint64_t q0 = rnd() % span; for (int k = 0; k < 25; k++) hits += sm_contains(m, q0 + k * 7, &c2); }
		ms = now() - t0; if (ms < bestq) bestq = ms;
	}
	printf("%s: full ascending pass %.3f ms; 200 fresh-cursor short runs %.3f ms (hits %lu)\n", SM_VERSION_STRING, best, bestq, (unsigned long) hits);
	return 0;
}
