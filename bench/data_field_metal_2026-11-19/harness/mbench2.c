/* Translation vs DRAM: single-thread pointer chase over N MiB with 4 KiB pages
 * (MADV_NOHUGEPAGE) and with THP (MADV_HUGEPAGE, faulted in and checked via
 * AnonHugePages).  If the slow hosts are slow only with 4 KiB pages, the extra
 * cost is in the (two-stage, virtualised) page walk, not in DRAM.
 * cc -O2 mbench2.c -o mbench2 ; ./mbench2 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <sched.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static long anonhuge_kb(void)
{
	FILE *f = fopen("/proc/self/smaps_rollup", "r"); char l[256]; long v = -1;
	while (f && fgets(l, sizeof l, f)) if (sscanf(l, "AnonHugePages: %ld kB", &v) == 1) break;
	if (f) fclose(f);
	return v;
}
static double run(size_t mib, int huge)
{
	size_t bytes = mib << 20, n = bytes / 64, i;
	size_t align = 2UL << 20;
	char *raw = mmap(NULL, bytes + align, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	uint64_t *buf = (uint64_t *) (((uintptr_t) raw + align - 1) & ~(align - 1));
	madvise(buf, bytes, huge ? MADV_HUGEPAGE : MADV_NOHUGEPAGE);
	memset(buf, 0, bytes);
	size_t *perm = malloc(n * sizeof(size_t)); uint64_t s = 88172645463325252ull;
	for (i = 0; i < n; i++) perm[i] = i;
	for (i = n - 1; i > 0; i--) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; size_t j = s % (i + 1); size_t t = perm[i]; perm[i] = perm[j]; perm[j] = t; }
	for (i = 0; i < n; i++) buf[perm[i] * 8] = (uint64_t) (perm[(i + 1) % n] * 8);
	free(perm);
	long ah = anonhuge_kb();
	uint64_t p = 0; long loads = 20000000, k;
	for (k = 0; k < 2000000; k++) p = buf[p];
	double best = 1e9;
	for (int r = 0; r < 3; r++) {
		double t0 = now();
		for (k = 0; k < loads; k++) p = buf[p];
		double v = (now() - t0) * 1e9 / loads; if (v < best) best = v;
	}
	if (p == 1) puts("");
	printf("chase %5zu MiB %s: %.1f ns/load (AnonHugePages %ld kB)\n", mib, huge ? "thp " : "4k  ", best, ah);
	munmap(raw, bytes + align);
	return best;
}
int main(void)
{
	cpu_set_t c; CPU_ZERO(&c); CPU_SET(0, &c); sched_setaffinity(0, sizeof c, &c);
	size_t sizes[] = { 64, 256, 1024, 4096 };
	for (int i = 0; i < 4; i++) { run(sizes[i], 0); run(sizes[i], 1); }
	return 0;
}
