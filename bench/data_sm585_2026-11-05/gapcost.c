/* the e509319 cost case: 100,000 ascending gap lookups over 20,000 one-member chunks */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
#include <time.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1e3 + t.tv_nsec/1e6; }
int main(void)
{
	const uint64_t nmem = 20000, stride = 3000; uint64_t *ids = malloc(nmem * 8), hits = 0, q;
	sm_t *m = sm_create(256); sm_cursor_t c = SM_CURSOR_INIT;
	for (uint64_t i = 0; i < nmem; i++) ids[i] = i * stride + 7;
	sm_add_many_grow(&m, ids, nmem);
	double best = 1e9;
	for (int r = 0; r < 5; r++) { c = (sm_cursor_t) SM_CURSOR_INIT; double t0 = now(); for (q = 0; q < nmem * stride; q += 600) hits += sm_contains(m, q, &c); double ms = now() - t0; if (ms < best) best = ms; }
	printf("%s: best of 5, 100,000 ascending gap lookups: %.3f ms (hits %lu)\n", SM_VERSION_STRING, best, (unsigned long) hits);
	return 0;
}
