/* repro_wrong_answer.c -- sm_contains returns a wrong answer through a
 * cursor whose cached chunk validates but whose prev_offset hint is not a
 * chunk start.  Against upstream sparsemap v5.8.4 sm.c:
 *   cc -std=gnu99 -fsanitize=address,undefined -I. repro_wrong_answer.c -o r && ./r
 * Expected (bug): "with cursor 0, without 1 -> DIFFER" for hint 16, exit 1. */
#define SM_EXPOSE_STRUCT 1
#include "sm.c"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
	sm_t *m = sm_create(4096);
	const uint64_t B = 32768, C = 2048;	/* chunk mode (above the small-set cap) */
	uint64_t x = 32773;			/* a member: B + 5 */
	sm_cursor_t cur = SM_CURSOR_INIT;
	int differ = 0;
	/* three adjacent chunks, one member each; chunks sit at byte offsets 0, 24, 48 */
	sm_add(m, B + 5);
	sm_add(m, B + C + 5);
	sm_add(m, B + 2 * C + 5);
	/* a lookup in chunk 3 caches it: offset 48, start 36864, prev_offset 24 */
	(void) sm_contains(m, 38479, &cur);
	printf("cursor after sm_contains(38479): offset=%zu start_idx=%llu prev_offset=%zu\n",
	       cur.offset, (unsigned long long) cur.start_idx, cur.prev_offset);
	for (size_t hint = 0; hint <= 40; hint += 8) {
		sm_cursor_t c = cur;
		c.prev_offset = hint;
		int a = sm_contains(m, x, &c), b = sm_contains(m, x, NULL);
		printf("prev_offset=%2zu: sm_contains(%llu) with cursor %d, without %d -> %s\n",
		       hint, (unsigned long long) x, a, b, a == b ? "agree" : "DIFFER");
		differ |= a != b;
	}
	sm_free(m);
	return differ;
}
