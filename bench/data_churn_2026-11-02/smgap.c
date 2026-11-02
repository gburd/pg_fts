/* smgap.c: cost of sm_contains with a forward cursor when the queried indexes mostly fall in GAPS between chunks
 * (live docids between sparse tombstones).  Map: one member every STRIDE indexes (STRIDE > chunk capacity, so one
 * chunk per member).  Queries: every Q-th index ascending, one cursor for the whole pass (the WAND contract). */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include "sm.h"
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(int argc, char **argv)
{
	uint64_t nmem = argc > 1 ? strtoull(argv[1], 0, 10) : 20000, stride = argc > 2 ? strtoull(argv[2], 0, 10) : 2900;
	uint64_t q = argc > 3 ? strtoull(argv[3], 0, 10) : 600, span = nmem * stride, i, hits = 0, nq = 0, expect = 0;
	uint64_t *ids = malloc(nmem * sizeof(uint64_t));
	sm_t *m = sm_create(256);
	for (i = 0; i < nmem; i++) ids[i] = i * stride + 7;
	if (!sm_add_many_grow(&m, ids, nmem)) { fprintf(stderr, "add failed\n"); return 1; }
	{ /* cursor pass over ascending queries */
		sm_cursor_t c = SM_CURSOR_INIT; double t0 = now();
		for (i = 0; i < span; i += q) { nq++; if (sm_contains(m, i, &c)) hits++; if ((i - 7) % stride == 0 && i >= 7) expect++; }
		double t1 = now();
		/* control: the same pass with members themselves queried (lookups land INSIDE chunks) */
		sm_cursor_t c2 = SM_CURSOR_INIT; uint64_t h2 = 0; double t2 = now();
		for (i = 0; i < nmem; i++) if (sm_contains(m, ids[i], &c2)) h2++;
		double t3 = now();
		printf("version=%s members=%llu chunks~%llu span=%llu gap_queries=%llu hits=%llu(expect %llu) gap_pass=%.3f ms (%.1f ns/query)  in-chunk member pass=%.3f ms (%.1f ns/query, hits %llu)\n",
		       SM_VERSION_STRING, (unsigned long long) nmem, (unsigned long long) nmem, (unsigned long long) span, (unsigned long long) nq,
		       (unsigned long long) hits, (unsigned long long) expect, (t1 - t0) * 1e3, (t1 - t0) * 1e9 / nq, (t3 - t2) * 1e3, (t3 - t2) * 1e9 / nmem,
		       (unsigned long long) h2);
	}
	sm_free(m); free(ids); return 0;
}
