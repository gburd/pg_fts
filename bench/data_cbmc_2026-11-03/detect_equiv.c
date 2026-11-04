/* For every block the writer can produce (bm25_write_postings: gaps|tfs[|dls]
 * packed back to back, bytelen = their sum), the new detection
 * (bm25_for_cols_fit) must give the same has_doclen_col and accept, exactly as
 * the 1.15.2 open-coded check did.  Exhaustive over cnt 1..128 and all three
 * column widths 0..64 (v3) / two widths (v4). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pg_fts_for.h"
static int old_check(const unsigned char *stream, unsigned bytelen, int cnt, int *hdc)
{
	int gl = bm25_for_bytelen(stream, cnt);
	int tl = (gl <= (int) bytelen) ? bm25_for_bytelen(stream + gl, cnt) : 0;
	int dl;
	*hdc = (gl + tl < (int) bytelen);
	dl = (*hdc && gl + tl <= (int) bytelen) ? bm25_for_bytelen(stream + gl + tl, cnt) : 0;
	return !((size_t) gl + tl + dl > (size_t) bytelen);
}
static int new_check(const unsigned char *stream, unsigned bytelen, int cnt, int *hdc)
{
	uint64 used2;
	if (!bm25_for_cols_fit(stream, bytelen, cnt, 2, &used2)) *hdc = 0;
	else *hdc = (used2 < (uint64) bytelen);
	return bm25_for_cols_fit(stream, bytelen, cnt, *hdc ? 3 : 2, NULL);
}
int main(void)
{
	static unsigned char buf[3 * (1 + (128 * 64 + 7) / 8) + 16];
	long n = 0, bad = 0;
	for (int cnt = 1; cnt <= 128; cnt++)
		for (int v3 = 0; v3 <= 1; v3++)
			for (int wg = 0; wg <= 64; wg++)
				for (int wt = 0; wt <= 64; wt++)
					for (int wd = 0; wd <= (v3 ? 64 : 0); wd++)
					{
						int len = 0, ho, hn, ao, an;
						memset(buf, 0, sizeof buf);
						buf[len] = wg; len += wg ? 1 + (cnt * wg + 7) / 8 : 1;
						buf[len] = wt; len += wt ? 1 + (cnt * wt + 7) / 8 : 1;
						if (v3) { buf[len] = wd; len += wd ? 1 + (cnt * wd + 7) / 8 : 1; }
						ao = old_check(buf, len, cnt, &ho);
						an = new_check(buf, len, cnt, &hn);
						n++;
						if (!ao || !an || ho != hn || hn != v3) {
							if (bad++ < 5) printf("cnt=%d v3=%d w=%d,%d,%d old=%d/%d new=%d/%d\n", cnt, v3, wg, wt, wd, ao, ho, an, hn);
						}
					}
	printf("%ld writer layouts, %ld disagreements\n", n, bad);
	return bad != 0;
}
