/* w585: build tombstone maps the way pg_fts bulkdelete does (sm_create + sorted sm_add_many_grow of carried
 * tombstones, then of new dead docids, repeated over VACUUM rounds) with sparsemap 5.8.5, and write each
 * serialized blob + the member list.  Docids: blk * 291 + off, off 1..291, like bm25_tid_to_docid. */
#define SPARSEMAP_PREFIX v585_
#define SM_EXPOSE_STRUCT
#include "sm585.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint64_t rng = 88172645463325252ULL;
static uint64_t xr(void){ rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }
static int cmp(const void *a, const void *b){ uint64_t x=*(const uint64_t*)a, y=*(const uint64_t*)b; return x<y?-1:x>y; }
int main(int argc, char **argv){
  int nmaps = atoi(argv[1]); FILE *out = fopen(argv[2], "wb"); rng ^= (uint64_t) atoi(argv[3]);
  for (int m = 0; m < nmaps; m++) {
    int shape = xr() % 6; uint64_t nblk = 1 + xr() % (shape == 0 ? 4 : (xr() % 4 == 0 ? 200000 : 5000));
    int rows = 1 + xr() % 120; /* rows per heap page */
    double p = (shape==1) ? 0.9 : (shape==2) ? 0.001 : (shape==3) ? 0.5 : (shape==4) ? 0.0125 : (double)(xr()%1000)/1000.0;
    sm_t *map = sm_create(256); uint64_t *all = NULL; size_t nall = 0, cap = 0;
    uint8_t *seen = calloc((nblk * 291 + 300) / 8 + 1, 1);
    int rounds = 1 + xr() % 4;
    for (int r = 0; r < rounds; r++) {
      uint64_t *nw = NULL; size_t nn = 0, nc = 0;
      /* contiguous dead ranges sometimes (shape 5: bulk delete of a block range) */
      uint64_t lo = (shape==5) ? xr() % nblk : 0, hi = (shape==5) ? lo + 1 + xr() % 5000 : nblk;
      if (hi > nblk) hi = nblk;
      for (uint64_t b = lo; b < hi; b++) for (int o = 1; o <= rows; o++) {
        if ((double)(xr() % 1000000) / 1e6 >= p) continue;
        uint64_t d = b * 291 + o;
        if (seen[d >> 3] & (1u << (d & 7))) continue;
        seen[d >> 3] |= (uint8_t) (1u << (d & 7));
        if (nn == nc) { nc = nc ? nc*2 : 1024; nw = realloc(nw, nc * 8); }
        nw[nn++] = d;
      }
      if (nn && !sm_add_many_grow(&map, nw, nn)) { fprintf(stderr, "add_many failed\n"); return 2; }
      for (size_t i = 0; i < nn; i++) { if (nall == cap) { cap = cap ? cap*2 : 1024; all = realloc(all, cap*8); } all[nall++] = nw[i]; }
      free(nw);
    }
    qsort(all, nall, 8, cmp);
    uint64_t sz = sm_get_size(map);
    fwrite(&sz, 8, 1, out); fwrite(sm_get_data(map), 1, sz, out);
    uint64_t n = nall; fwrite(&n, 8, 1, out); fwrite(all, 8, nall, out);
    free(all); free(seen); sm_free(map);
  }
  fclose(out); return 0;
}
