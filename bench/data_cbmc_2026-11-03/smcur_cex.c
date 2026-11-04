/* Native replay of the CBMC counterexample for smcursor_harness C3, layout 1
 * (adjacent chunks at 32768, 34816, 36864; members +5 each).  A cursor left by
 * a lookup at 38479 caches chunk 3 (offset 48, prev_offset 24); then its
 * prev_offset is set to an arbitrary value, here 16 (not a chunk start). */
#define SPARSEMAP_PREFIX
#include "../../vendor/sm.c"
#include <stdio.h>
int main(int argc, char **argv)
{
	sm_t *m = sm_create(4096);
	uint64_t B = 32768, C = 2048, x = argc > 2 ? strtoull(argv[2], 0, 10) : 32773;
	size_t po = argc > 1 ? strtoull(argv[1], 0, 10) : 16;
	sm_cursor_t cur = SM_CURSOR_INIT;
	sm_add(m, B + 5); sm_add(m, B + C + 5); sm_add(m, B + 2 * C + 5);
	(void) sm_contains(m, 38479, &cur);
	printf("after lookup 38479: offset=%zu start=%lu prev=%zu\n", cur.offset, (unsigned long) cur.start_idx, cur.prev_offset);
	cur.prev_offset = po;
	int a = sm_contains(m, x, &cur), b = sm_contains(m, x, NULL);
	printf("prev_offset=%zu x=%lu: with cursor %d, without %d -> %s\n", po, (unsigned long) x, a, b, a == b ? "agree" : "DIFFER");
	return a != b;
}
