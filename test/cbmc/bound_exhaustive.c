/*-------------------------------------------------------------------------
 *
 * bound_exhaustive.c
 *		Exhaustive native companion to bound_harness.c: B1/B2 over EVERY
 *		posting and block shape within the bound, at many corpus shapes, in
 *		the machine's IEEE doubles.  CBMC proves the same properties with
 *		tf, |D| and the block symbolic but avgdl and idf fixed (a symbolic
 *		corpus did not finish in 90 minutes); this enumerates the integers
 *		instead and sweeps (avgdl, idf), so the two cover each other.
 *
 *	For each (avgdl, idf), every block max tf mtf <= TF_MAX, every scored
 *	posting (tf <= mtf, tf <= dl <= DL_MAX) and every effective minimum length
 *	the writer can store for a block containing it (floor(mtf * r) for the
 *	posting's own ratio r = dl/tf, the largest, so the tightest bound), on v3
 *	(exact lengths) and v4 (quantised) segments: score <= BMW bound and
 *	score <= best-first bound.  Compiled with -DTEETH_BMW_ORDER it uses the
 *	1.15.2 BMW expression and must report violations.
 *
 *	cc -O2 bound_exhaustive.c -lm && ./a.out     (exit 0 = no violation)
 *
 * IDENTIFICATION
 *	  test/cbmc/bound_exhaustive.c
 *
 *-------------------------------------------------------------------------
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../pg_fts_for.h"

#ifndef TF_MAX
#define TF_MAX 16
#endif
#ifndef DL_MAX
#define DL_MAX 4096
#endif

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static double
urand(double lo, double hi)
{
	rs ^= rs << 13;
	rs ^= rs >> 7;
	rs ^= rs << 17;
	return lo + (hi - lo) * ((double) (rs >> 11) / 9007199254740992.0);
}

int
main(int argc, char **argv)
{
	int			ncorpus = argc > 1 ? atoi(argv[1]) : 400;
	const double k1 = 1.2,
				b = 0.75;
	long		checked = 0,
				bad = 0;
	int			ci;

	for (ci = 0; ci < ncorpus; ci++)
	{
		/* fixed extremes first, then random shapes */
		static const double fixed[][2] = {{2950.0268341933147, 3.106732490313113},
		{1.0, 1e-6}, {1.0, 40.0}, {1e6, 1e-6}, {1e6, 40.0}, {4.0, 18.0}};
		double		avgdl = ci < 6 ? fixed[ci][0] : urand(1.0, ci % 2 ? 5000.0 : 1e6);
		double		idf = ci < 6 ? fixed[ci][1] : urand(1e-6, 40.0);
		double		k1b_inv_avgdl = k1 * b / avgdl,
					k1_1mb = k1 * (1.0 - b),
					idf_k1p1 = idf * (k1 + 1.0);
		int			v4;

		for (v4 = 0; v4 <= 1; v4++)
		{
			uint32		mtf,
						tf,
						dl;

			for (mtf = 1; mtf <= TF_MAX; mtf++)
				for (tf = 1; tf <= mtf; tf++)
					for (dl = tf; dl <= DL_MAX; dl++)
					{
						uint32		sdl = v4 ? fts_byte_to_doclen(fts_doclen_to_byte(dl)) : dl;
						double		x = floor((double) mtf * ((double) sdl / (double) tf));
						uint32		stored = (uint32) x;
						double		mindl = (double) (v4 ? fts_byte_to_doclen(fts_doclen_to_byte(stored)) : stored);
						double		m = (double) mtf;
						double		score = idf_k1p1 * tf / (tf + k1_1mb + k1b_inv_avgdl * sdl);
#ifdef TEETH_BMW_ORDER
						double		bmw = idf * m * (k1 + 1.0) / (m + k1_1mb + k1b_inv_avgdl * mindl);
#else
						double		bmw = idf_k1p1 * m / (m + k1_1mb + k1b_inv_avgdl * mindl);
#endif
						double		bf = idf_k1p1 * m / (m + k1_1mb + k1b_inv_avgdl * mindl);

						checked++;
						if (score > bmw || score > bf)
						{
							if (bad++ < 3)
								printf("violation: avgdl=%.17g idf=%.17g v4=%d mtf=%u tf=%u dl=%u score=%.17g bmw=%.17g bf=%.17g\n",
									   avgdl, idf, v4, mtf, tf, dl, score, bmw, bf);
						}
					}
		}
	}
	printf("%ld (corpus, segment, block, posting) cases, %ld violations\n", checked, bad);
	return bad != 0;
}
