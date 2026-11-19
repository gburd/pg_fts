/* r590: open each 5.8.5-written blob with 5.9.0 exactly as bm25_sm_open_checked does (sm_open on a private copy,
 * then sm_validate and sm_get_size == stored length), and check membership against the list: contains on every
 * member (ascending cursor and random), next_member walk equality, cardinality, maximum. */
#define SPARSEMAP_PREFIX v590_
#define SM_EXPOSE_STRUCT
#include "sm590.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv){
  FILE *in = fopen(argv[1], "rb"); uint64_t sz, n; long maps = 0, bad = 0, sizechg = 0, empty_chunks = 0;
  while (fread(&sz, 8, 1, in) == 1) {
    uint8_t *buf = malloc(sz ? sz : 8); if (fread(buf, 1, sz, in) != sz) return 3;
    if (fread(&n, 8, 1, in) != 1) return 3; uint64_t *all = malloc((n?n:1) * 8); if (fread(all, 8, n, in) != n) return 3;
    sm_t m; sm_open(&m, buf, sz); maps++;
    int ok = sm_validate(&m) && sm_get_size(&m) == sz;
    if (!ok) { sizechg++; fprintf(stderr, "map %ld: validate=%d size %zu -> %zu (n=%lu)\n", maps, sm_validate(&m), (size_t) sz, sm_get_size(&m), (unsigned long) n); }
    sm_cursor_t c = SM_CURSOR_INIT; uint64_t v = (uint64_t)-1; size_t k = 0;
    { sm_cursor_t cc = SM_CURSOR_INIT; for (size_t i = 0; i < n; i++) if (!sm_contains(&m, all[i], &cc)) { bad++; break; } }
    for (size_t i = 0; i < n && i < 7 * 300; i += 7) if (!sm_contains(&m, all[(i * 2654435761u) % n], NULL)) { bad++; break; }
    for (v = sm_next_member(&m, (uint64_t)-1, &c); v != SM_IDX_MAX; v = sm_next_member(&m, v, &c)) { if (k >= n || all[k] != v) { bad++; break; } k++; }
    if (k != n && !bad) bad++;
    if (sm_cardinality(&m) != n) bad++;
    if (n && sm_maximum(&m) != all[n-1]) bad++;
    /* non-members next to members */
    for (size_t i = 0; i < n && i < 2000; i++) { uint64_t x = all[i] + 1; if ((i+1 < n && all[i+1] == x)) continue; if (sm_contains(&m, x, NULL)) { bad++; break; } }
    free(buf); free(all);
  }
  printf("maps %ld  size-or-validate changes %ld  membership errors %ld\n", maps, sizechg, bad);
  return (bad || sizechg) ? 1 : 0;
}
