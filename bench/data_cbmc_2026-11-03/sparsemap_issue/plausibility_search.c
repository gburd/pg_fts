/* build: cc -O2 -std=gnu99 -I. plausibility_search.c -o x && ./x   (against the v5.8.4 sm.c / sm.h copied here) */
/* Would cheap plausibility checks on the hint make the gap resume safe?
 * Candidate checks (all O(1)): the word at the hint is chunk-aligned
 * (start % 2048 == 0), it is below the cached start, and start + capacity <=
 * cached start, in addition to v5.8.4's "ends exactly at the cached offset".
 * Search: random small maps; for EVERY byte offset h in the chunk stream that
 * is NOT a chunk start, and every cached chunk, does h pass all checks?  Any
 * hit means the plausibility checks alone are not a proof. */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
int main(void)
{
	long maps = 0, v584 = 0, plaus = 0;
	for (int t = 0; t < 200000; t++) {
		sm_t *m = sm_create(1 << 15);
		uint64_t B = 1 << 16;
		int n = 1 + rnd() % 40, mode = t % 4;
		for (int k = 0; k < n; k++) {
			uint64_t v = mode == 0 ? rnd() % (16 * 2048)            /* scattered */
			    : mode == 1 ? (rnd() % 16) * 2048 + (rnd() % 64)    /* low bits of chunks */
			    : mode == 2 ? (rnd() % 16) * 2048 + 2048 - 1 - rnd() % 64
			    : (rnd() % 16) * 2048 + (rnd() % 32) * 64;          /* one bit per vector */
			sm_add(m, B + v);
		}
		if (__sm_is_small(m)) { sm_free(m); continue; }
		maps++;
		size_t cnt = __sm_get_chunk_count(m), off[256], o = 0;
		uint8_t *base = __sm_get_chunk_data(m, 0);
		size_t stream_end = (size_t) m->m_data_used - SM_SIZEOF_OVERHEAD;
		for (size_t c = 0; c < cnt && c < 256; c++) {
			__sm_chunk_t ch; off[c] = o;
			__sm_chunk_init(&ch, base + o + SM_SIZEOF_OVERHEAD);
			o += SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&ch);
		}
		for (size_t c = 1; c < cnt && c < 256; c++) {
			uint64_t cstart = __sm_load_idx(base + off[c]);
			for (size_t h = 0; h + 16 <= off[c]; h += 8) {
				int real = 0;
				for (size_t d = 0; d < c; d++) if (off[d] == h) real = 1;
				if (real) continue;
				__sm_chunk_t pc; __sm_chunk_init(&pc, base + h + SM_SIZEOF_OVERHEAD);
				uint64_t ps = __sm_load_idx(base + h);
				int ends = h + SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&pc) == off[c];
				if (ends) v584++;
				if (ends && ps % 2048 == 0 && ps < cstart && ps + __sm_chunk_get_capacity(&pc) <= cstart) {
					if (plaus++ < 3) printf("map %d: hint %zu (not a chunk) passes all plausibility checks for cached chunk at %zu\n", t, h, off[c]);
				}
			}
		}
		(void) stream_end;
		sm_free(m);
	}
	printf("%ld chunk-mode maps: non-chunk hints passing v5.8.4's check: %ld; passing the plausibility checks too: %ld\n", maps, v584, plaus);
	return 0;
}
