/*-------------------------------------------------------------------------
 *
 * codec_harness.c
 *		CBMC proof of the FOR bit-packing codec and the doclen byte
 *		(pg_fts_for.h, #included unmodified: the code under proof IS the
 *		shipped code).
 *
 *	PROPERTIES PROVED
 *
 *	harness_for (bound: n <= FOR_N values, any width 0..64):
 *	  F1  bm25_for_pack writes exactly 1 + ceil(n*w/8) bytes (w = bit width
 *	      of the column maximum; 1 byte when w == 0), never past them.
 *	  F2  bm25_for_bytelen of the packed column == bytes written.
 *	  F3  bm25_for_unpack returns the same length and reads only
 *	      [buf, buf + written): it decodes from a buffer of EXACTLY that
 *	      size, so --bounds-check fails on any over-read.  This covers the
 *	      1.9.0 8-byte-window fast path (width <= 56) and the 9-byte wide
 *	      path.
 *	  F4  unpack(pack(v)) == v, and bm25_for_get(buf, i) == v[i] for
 *	      every i (the hot-path random access agrees with the bulk decode).
 *
 *	harness_for_any (bound: n <= FOR_N, ANY width byte 0..255, ANY payload):
 *	  F5  on a column whose declared length 1 + ceil(n*w/8) fits the
 *	      buffer, unpack and get read only inside it, for every width
 *	      byte including corrupt ones (> 64).  This is the contract the
 *	      block decoders rely on after checking bytelen (the 0.3.4 class).
 *
 *	harness_doclen (bound: all 2^32 lengths, symbolic):
 *	  D1  fts_byte_to_doclen(fts_doclen_to_byte(x)) <= x: quantisation only
 *	      ever rounds a length DOWN.  The block-max bound uses the
 *	      quantised minimum length (wand_block_max_contrib), and BM25 is
 *	      decreasing in length, so this is what keeps that bound >= every
 *	      score it covers (see bound_harness.c).
 *	  D2  monotone: x <= y => q(x) <= q(y) (byte and decoded length).
 *	  D3  exact for x <= 7; q(x) > x/2 for x >= 8 (4 significant bits:
 *	      relative error < 1/8, stated loosely here as > half).
 *	  D4  decode is total and the encode/decode round trip is the identity
 *	      on bytes that encode produces (q(q(x)) == q(x)).
 *
 *	TEETH (run.sh): -DTEETH_FOR mis-sizes the decode buffer by one byte
 *	(F3 must fail); -DTEETH_DOCLEN asserts round-to-nearest instead of
 *	round-down (D1's negation must find a counterexample).
 *
 *	Run: cbmc codec_harness.c --function harness_for --unwind 70 ...
 *	     (see run.sh for the exact flags per entry point)
 *
 * IDENTIFICATION
 *	  test/cbmc/codec_harness.c
 *
 *-------------------------------------------------------------------------
 */
#include "cbmc_pg.h"
#include "../../pg_fts_for.h"

#ifndef FOR_N
#define FOR_N 3
#endif

/* bytes a column of n values at width w occupies */
static int
col_bytes(int n, int w)
{
	return (w == 0) ? 1 : 1 + (n * w + 7) / 8;
}

/*
 * n is fixed per run (-DFOR_N=1,2,3 in run.sh) so every buffer has a concrete
 * size: with a symbolic n the decode buffers become symbolic-size objects and
 * the SAT problem outgrows a 30 GB host at n = 2.  Buffer CONTENTS are left
 * uninitialised, which CBMC treats as fully nondeterministic.
 */
void
harness_for(void)
{
	uint64		vals[FOR_N];
	uint64		out[FOR_N];
	unsigned char packbuf[1 + (FOR_N * 64 + 7) / 8];
	unsigned char *exact;
	const int	n = FOR_N;
	int			i,
				w,
				wrote;
	uint64		maxv = 0;

	for (i = 0; i < n; i++)
	{
		vals[i] = nondet_u64();
		if (vals[i] > maxv)
			maxv = vals[i];
	}
	w = bm25_bitwidth(maxv);
	__CPROVER_assert(w >= 0 && w <= 64, "bitwidth in [0,64]");

	wrote = bm25_for_pack(vals, n, packbuf);
	__CPROVER_assert(wrote == col_bytes(n, w), "F1: pack writes 1 + ceil(n*w/8)");
	__CPROVER_assert(bm25_for_bytelen(packbuf, n) == wrote, "F2: bytelen == written");

	/* F3: decode from a buffer of exactly `wrote` bytes */
#ifdef TEETH_FOR
	__CPROVER_assume(wrote >= 2);
	exact = cbmc_palloc(wrote - 1);
	memcpy(exact, packbuf, wrote - 1);
#else
	exact = cbmc_palloc(wrote);
	memcpy(exact, packbuf, wrote);
#endif
	__CPROVER_assert(bm25_for_unpack(exact, n, out) == wrote, "F3: unpack consumes written");
	for (i = 0; i < n; i++)
	{
		__CPROVER_assert(out[i] == vals[i], "F4: unpack(pack(v)) == v");
		__CPROVER_assert(bm25_for_get(exact, i) == vals[i], "F4: get(i) == v[i]");
	}
	free(exact);
}

/* F5, valid widths: any width byte 0..64, any payload, exact-size column */
void
harness_for_any(void)
{
	uint64		out[FOR_N];
	const int	n = FOR_N;
	int			w = nondet_int();
	int			i;
	unsigned char *buf;

	__CPROVER_assume(w >= 0 && w <= 64);
	buf = cbmc_palloc(col_bytes(n, w));
	buf[0] = (unsigned char) w;
	(void) bm25_for_unpack(buf, n, out);
	for (i = 0; i < n; i++)
		(void) bm25_for_get(buf, i);
	free(buf);
}

/*
 * F5, corrupt widths (> 64): every value takes the 9-byte wide path.  No
 * shipped reader passes such a column to unpack/get without first proving
 * that its byte length fits (bm25_decode_term's column check), so the
 * precondition is the same: the declared 1 + ceil(n*w/8) bytes exist.
 * One width per run (-DCORRUPT_W): 65, 128 and 255 in run.sh.
 */
#ifndef CORRUPT_W
#define CORRUPT_W 65
#endif

void
harness_for_corrupt_width(void)
{
	uint64		out[FOR_N];
	const int	n = FOR_N;
	int			i;
	unsigned char *buf = cbmc_palloc(col_bytes(FOR_N, CORRUPT_W));

	buf[0] = (unsigned char) CORRUPT_W;
	(void) bm25_for_unpack(buf, n, out);
	for (i = 0; i < n; i++)
		(void) bm25_for_get(buf, i);
	free(buf);
}

void
harness_doclen(void)
{
	uint32		x = nondet_u32();
	uint32		y = nondet_u32();
	uint8		bx = fts_doclen_to_byte(x);
	uint32		qx = fts_byte_to_doclen(bx);

#ifdef TEETH_DOCLEN
	/* wrong claim: quantisation never loses anything */
	__CPROVER_assert(qx == x, "TEETH: quantisation is exact (must FAIL)");
#endif
	__CPROVER_assert(qx <= x, "D1: quantised length <= exact length");
	if (x <= y)
	{
		__CPROVER_assert(bx <= fts_doclen_to_byte(y), "D2: byte monotone");
		__CPROVER_assert(qx <= fts_byte_to_doclen(fts_doclen_to_byte(y)),
						 "D2: decoded length monotone");
	}
	if (x <= 7)
		__CPROVER_assert(qx == x, "D3: exact below 8");
	else
		__CPROVER_assert(qx > x / 2, "D3: within a factor of two");
	__CPROVER_assert(fts_doclen_to_byte(qx) == bx, "D4: q(q(x)) == q(x)");
}

void
harness_doclen_total(void)
{
	/* D4: every byte decodes without UB (shift by e-1 <= 30) */
	uint8		b = nondet_u8();
	uint32		v = fts_byte_to_doclen(b);

	(void) v;
}
