/* sm_next_member through a cursor whose offset is mispositioned (start_idx is a
 * real chunk start, offset any 8-byte position) vs cursor-free.  Their claim:
 * wrong answers on 5.8.4, none on 5.8.5. */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
int main(void)
{
	long n = 0, wrong = 0, unexplained = 0, atreal = 0;
	for (int t = 0; t < 20000; t++) {
		sm_t *m = sm_create(1 << 14);
		uint64_t B = 1 << 16;
		for (int k = 0; k < 2 + (int) (rnd() % 30); k++) sm_add(m, B + rnd() % (12 * 2048));
		if (__sm_is_small(m)) { sm_free(m); continue; }
		size_t end = (size_t) m->m_data_used - SM_SIZEOF_OVERHEAD, cnt = __sm_get_chunk_count(m), o = 0;
		uint8_t *base = __sm_get_chunk_data(m, 0);
		uint64_t starts[64]; int ns = 0;
		for (size_t c = 0; c < cnt && ns < 64; c++) { __sm_chunk_t ch; starts[ns++] = __sm_load_idx(base + o); __sm_chunk_init(&ch, base + o + SM_SIZEOF_OVERHEAD); o += SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&ch); }
		for (size_t off = 0; off + 8 <= end; off += 8)
			for (int s = 0; s < ns; s++) {
				uint64_t prev = starts[s] + rnd() % 2048;
				sm_cursor_t c = { off, starts[s], SIZE_MAX };
				n++;
				int real = 0; { size_t oo = 0; for (size_t cc = 0; cc < cnt; cc++) { __sm_chunk_t ch2; if (oo == off) real = 1; __sm_chunk_init(&ch2, base + oo + SM_SIZEOF_OVERHEAD); oo += SM_SIZEOF_OVERHEAD + __sm_chunk_get_size(&ch2); } }
				int fooled = __sm_load_idx(base + off) == starts[s];	/* the word at off equals the recorded start */
				if (sm_next_member(m, prev, &c) != sm_next_member(m, prev, NULL)) { wrong++; if (!fooled) unexplained++; if (real) atreal++; }
			}
		sm_free(m);
	}
	printf("%s: %ld lookups, %ld wrong; of them, word at offset != recorded start: %ld; offset was a real chunk start: %ld\n", SM_VERSION_STRING, n, wrong, unexplained, atreal);
	return 0;
}
