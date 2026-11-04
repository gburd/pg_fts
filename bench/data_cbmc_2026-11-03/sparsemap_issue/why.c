/* build: cc -O2 -std=gnu99 -I. why.c -o x && ./x   (against the v5.8.4 sm.c / sm.h copied here) */
/* Which conditions does the CBMC counterexample hint pass? layout: chunks at 0,24,48 */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
int main(void)
{
	sm_t *m = sm_create(4096);
	sm_add(m, 32768 + 5); sm_add(m, 34816 + 5); sm_add(m, 36864 + 5);
	uint8_t *base = __sm_get_chunk_data(m, 0);
	for (size_t i = 0; i < 72; i += 8) {
		uint64_t w; memcpy(&w, base + i, 8);
		printf("byte %2zu: %016llx (%llu)\n", i, (unsigned long long) w, (unsigned long long) w);
	}
	size_t hint = 16;
	uint8_t *pp = base + hint; __sm_chunk_t pc; __sm_chunk_init(&pc, pp + SM_SIZEOF_OVERHEAD);
	printf("hint 16: start read as %llu (aligned to 2048: %s), size computed %zu, hint+8+size = %zu (cached offset 48), capacity %zu\n",
	       (unsigned long long) __sm_load_idx(pp), __sm_load_idx(pp) % 2048 ? "no" : "yes", __sm_chunk_get_size(&pc), hint + 8 + __sm_chunk_get_size(&pc), __sm_chunk_get_capacity(&pc));
	return 0;
}
