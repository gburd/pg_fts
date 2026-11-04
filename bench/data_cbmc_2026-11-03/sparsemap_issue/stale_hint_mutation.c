/* build: cc -O2 -std=gnu99 -I. stale_hint_mutation.c -o x && ./x   (against the v5.8.4 sm.c / sm.h copied here) */
/* Can a cursor kept across a mutation (contract: undefined) make the NEXT
 * cursor-threaded insert (sm_add_grow_cursor -> __sm_coalesce_chunk's
 * left_hint) corrupt the map?  Oracle + sm_validate after every step. */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
#include <string.h>
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
#define SPAN (16 * 2048)
int main(void)
{
	static unsigned char o[SPAN];
	long trials = 0, corrupt = 0, wrong = 0;
	for (int t = 0; t < 300000; t++) {
		sm_t *m = sm_create(1 << 15);
		sm_cursor_t c = SM_CURSOR_INIT;
		uint64_t B = 1 << 16;
		memset(o, 0, sizeof o);
		for (int k = 0; k < 40; k++) {
			uint64_t v = rnd() % SPAN;
			int op = rnd() % 4;
			if (op == 0) { sm_remove(m, B + v); o[v] = 0; }		/* cursor NOT reset */
			else if (op == 1) { sm_add(m, B + v); o[v] = 1; }		/* cursor NOT reset */
			else { if (sm_add_grow_cursor(&m, B + v, &c) == SM_IDX_MAX) return 2; o[v] = 1; }
			if (!sm_validate(m)) { if (corrupt++ < 3) printf("trial %d step %d: sm_validate fails\n", t, k); break; }
		}
		for (uint64_t q = 0; q < SPAN; q += 7)
			if ((int) sm_contains(m, B + q, NULL) != o[q]) { if (wrong++ < 3) printf("trial %d: map differs from oracle at %llu\n", t, (unsigned long long) q); break; }
		trials++;
		sm_free(m);
	}
	printf("%ld trials (cursor kept across sm_add/sm_remove, then sm_add_grow_cursor): invalid maps %ld, wrong contents %ld\n", trials, corrupt, wrong);
	return 0;
}
