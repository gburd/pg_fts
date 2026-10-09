/* Host characterisation for bench/PLAN_TPS_VARIANCE_2026-10-09.md.
 *   ghz      : dependent-add chain, single core (effective clock)
 *   lat1     : DRAM pointer chase, 1 GiB, 4 KiB pages, 1 thread (ns/load)
 *   lat16    : the same on 16 threads at once, 256 MiB each (ns/load, median thread)
 *   bw16     : 16-thread streaming read, 1 GiB each pass (GB/s)
 *   c2c      : cache-line ping-pong round trip core 0 <-> core k, k = 1..N-1 (ns)
 * cc -O2 -pthread mbench.c -o mbench */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static void pin(int cpu) { cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s); pthread_setaffinity_np(pthread_self(), sizeof s, &s); }
static int cmpd(const void *a, const void *b) { double x = *(const double *) a, y = *(const double *) b; return x < y ? -1 : x > y; }

static void *alloc_nohuge(size_t sz)
{
	void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) { perror("mmap"); exit(1); }
	madvise(p, sz, MADV_NOHUGEPAGE);
	return p;
}

/* random cyclic permutation over cache-line-sized slots */
static uint64_t *make_chase(size_t bytes, uint64_t seed)
{
	size_t n = bytes / 64, i;
	uint64_t *buf = alloc_nohuge(bytes);
	size_t *perm = malloc(n * sizeof(size_t));
	for (i = 0; i < n; i++) perm[i] = i;
	for (i = n - 1; i > 0; i--) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; size_t j = seed % (i + 1); size_t t = perm[i]; perm[i] = perm[j]; perm[j] = t; }
	for (i = 0; i < n; i++) buf[perm[i] * 8] = (uint64_t) (perm[(i + 1) % n] * 8);
	free(perm);
	return buf;
}
static double chase(uint64_t *buf, long loads)
{
	uint64_t p = 0; double t0 = now(); long i;
	for (i = 0; i < loads; i++) p = buf[p];
	double t = now() - t0;
	if (p == 1) puts("");
	return t * 1e9 / loads;
}

typedef struct { int cpu; double res; size_t bytes; } Arg;
static void *lat_thread(void *a_)
{
	Arg *a = a_; pin(a->cpu);
	uint64_t *b = make_chase(a->bytes, 88172645463325252ull + a->cpu);
	chase(b, 2000000);
	a->res = chase(b, 20000000);
	munmap(b, a->bytes);
	return NULL;
}
static void *bw_thread(void *a_)
{
	Arg *a = a_; pin(a->cpu);
	size_t n = a->bytes / 8, i; uint64_t *b = alloc_nohuge(a->bytes), s = 0;
	for (i = 0; i < n; i++) b[i] = i;
	double t0 = now();
	for (int r = 0; r < 4; r++) for (i = 0; i < n; i += 8) s += b[i] + b[i + 1] + b[i + 2] + b[i + 3] + b[i + 4] + b[i + 5] + b[i + 6] + b[i + 7];
	a->res = 4.0 * a->bytes / (now() - t0) / 1e9;
	if (s == 1) puts("");
	munmap(b, a->bytes);
	return NULL;
}

static _Alignas(128) _Atomic uint64_t flag;
static void *pong(void *a_)
{
	Arg *a = a_; pin(a->cpu);
	for (long i = 0; i < 400000; i++) {
		while (atomic_load_explicit(&flag, memory_order_acquire) != (uint64_t) (2 * i + 1)) ;
		atomic_store_explicit(&flag, 2 * i + 2, memory_order_release);
	}
	return NULL;
}
static double c2c(int k)
{
	pthread_t t; Arg a = { k, 0, 0 };
	atomic_store(&flag, 0);
	pthread_create(&t, NULL, pong, &a);
	pin(0);
	double t0 = 0;
	for (long i = 0; i < 400000; i++) {
		if (i == 50000) t0 = now();
		atomic_store_explicit(&flag, 2 * i + 1, memory_order_release);
		while (atomic_load_explicit(&flag, memory_order_acquire) != (uint64_t) (2 * i + 2)) ;
	}
	double r = (now() - t0) * 1e9 / 350000;
	pthread_join(t, NULL);
	return r;
}

int main(void)
{
	int ncpu = (int) sysconf(_SC_NPROCESSORS_ONLN), i;
	/* effective clock: 4 independent dependent-add chains would overlap; use one */
	{
		pin(0); volatile uint64_t sink; uint64_t x = 1; long n = 2000000000L; double t0 = now();
		for (long j = 0; j < n; j++) __asm__ volatile("add %0, %0, #1" : "+r"(x));
		double t = now() - t0; sink = x; (void) sink;
		printf("ghz %.3f\n", n / t / 1e9);
	}
	{
		uint64_t *b = make_chase(1UL << 30, 1234567);
		chase(b, 2000000);
		double v[3]; for (i = 0; i < 3; i++) v[i] = chase(b, 20000000);
		qsort(v, 3, sizeof(double), cmpd);
		printf("lat1_ns %.1f\n", v[1]);
		munmap(b, 1UL << 30);
	}
	{
		pthread_t t[256]; Arg a[256]; double v[256];
		for (i = 0; i < ncpu; i++) { a[i].cpu = i; a[i].bytes = 256UL << 20; pthread_create(&t[i], NULL, lat_thread, &a[i]); }
		for (i = 0; i < ncpu; i++) { pthread_join(t[i], NULL); v[i] = a[i].res; }
		qsort(v, ncpu, sizeof(double), cmpd);
		printf("lat%d_ns median %.1f max %.1f\n", ncpu, v[ncpu / 2], v[ncpu - 1]);
		for (i = 0; i < ncpu; i++) { a[i].cpu = i; a[i].bytes = 1UL << 30; pthread_create(&t[i], NULL, bw_thread, &a[i]); }
		double tot = 0; for (i = 0; i < ncpu; i++) { pthread_join(t[i], NULL); tot += a[i].res; }
		printf("bw%d_gbs %.1f\n", ncpu, tot);
	}
	{
		double v[256]; int n = 0;
		printf("c2c_ns");
		for (i = 1; i < ncpu; i++) { v[n] = c2c(i); printf(" %.0f", v[n]); n++; }
		qsort(v, n, sizeof(double), cmpd);
		printf("\nc2c_ns median %.0f min %.0f max %.0f\n", v[n / 2], v[0], v[n - 1]);
	}
	return 0;
}
