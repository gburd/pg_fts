/* Shared-cache-line cost: T threads, pinned one per core, each doing an atomic
 * fetch-add (LSE ldadd, what PG's pg_atomic_fetch_add / LWLock use) on ONE shared
 * 64-byte line, vs on a private line.  ns per op, median thread.  Tells whether
 * the slow hosts are slow specifically at contended atomics on a hot line --
 * which is what a buffer header pin and a buffer content lock are.
 * cc -O2 -pthread -march=armv8.2-a mbench3.c -o mbench3 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static _Alignas(64) _Atomic uint32_t shared_line[16];
static _Alignas(64) _Atomic uint32_t priv[64][16];
static _Atomic int go;
typedef struct { int cpu, shared, gap; double ns; } A;
static void *w(void *a_)
{
	A *a = a_; cpu_set_t s; CPU_ZERO(&s); CPU_SET(a->cpu, &s); pthread_setaffinity_np(pthread_self(), sizeof s, &s);
	_Atomic uint32_t *p = a->shared ? &shared_line[0] : &priv[a->cpu][0];
	while (!atomic_load(&go)) ;
	long n = 2000000; volatile uint64_t sink = 0;
	double t0 = now();
	for (long i = 0; i < n; i++) {
		atomic_fetch_add_explicit(p, 1, memory_order_acq_rel);
		for (int g = 0; g < a->gap; g++) sink += g;	/* work between accesses */
	}
	a->ns = (now() - t0) * 1e9 / n;
	return NULL;
}
static int cmpd(const void *x, const void *y) { double a = *(const double *) x, b = *(const double *) y; return a < b ? -1 : a > b; }
static double run(int T, int shared, int gap)
{
	pthread_t t[64]; A a[64]; double v[64];
	atomic_store(&go, 0);
	for (int i = 0; i < T; i++) { a[i].cpu = i; a[i].shared = shared; a[i].gap = gap; pthread_create(&t[i], NULL, w, &a[i]); }
	usleep(20000); atomic_store(&go, 1);
	for (int i = 0; i < T; i++) { pthread_join(t[i], NULL); v[i] = a[i].ns; }
	qsort(v, T, sizeof(double), cmpd);
	return v[T / 2];
}
int main(void)
{
	int ncpu = (int) sysconf(_SC_NPROCESSORS_ONLN);
	int Ts[] = { 1, 2, 4, 8, 16 };
	for (int g = 0; g <= 200; g += 200)
		for (int i = 0; i < 5 && Ts[i] <= ncpu; i++)
			printf("atomic gap=%d T=%2d shared %7.1f ns/op   private %6.1f ns/op\n", g, Ts[i], run(Ts[i], 1, g), run(Ts[i], 0, g));
	return 0;
}
