/*-------------------------------------------------------------------------
 *
 * cbmc_pg.h
 *		The minimal PostgreSQL vocabulary the CBMC harnesses need.
 *
 * The harnesses verify functions copied from the extension (each copy is
 * fenced VERBATIM ... END VERBATIM and checked against the source by
 * check_verbatim.py) or #included from its standalone headers
 * (pg_fts_for.h, pg_fts_docvalid.h).  Those functions use a handful of
 * PostgreSQL typedefs and macros; this header supplies them with the
 * backend's widths and semantics so the copies compile unchanged.  It does
 * not include postgres.h.
 *
 * IDENTIFICATION
 *	  test/cbmc/cbmc_pg.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef CBMC_PG_H
#define CBMC_PG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t uint8;
typedef uint16_t uint16;
typedef uint32_t uint32;
typedef uint64_t uint64;
typedef int32_t int32;
typedef size_t Size;
typedef uint32 BlockNumber;
#define UINT64CONST(x) ((uint64) x##ULL)
#define InvalidBlockNumber ((BlockNumber) 0xFFFFFFFF)
#define FLEXIBLE_ARRAY_MEMBER	/* empty */
#define Max(a, b) ((a) > (b) ? (a) : (b))
#define Min(a, b) ((a) < (b) ? (a) : (b))
#define lengthof(a) (sizeof(a) / sizeof((a)[0]))
#define unlikely(x) (x)
#define likely(x) (x)
#define MAXIMUM_ALIGNOF 8
#define TYPEALIGN(A, L) (((uintptr_t) (L) + ((A) - 1)) & ~((uintptr_t) ((A) - 1)))
#define MAXALIGN(L) TYPEALIGN(MAXIMUM_ALIGNOF, (L))

/* An allocation that cannot fail: palloc ERRORs instead of returning NULL. */
static inline void *
cbmc_palloc(size_t n)
{
	void	   *p = malloc(n > 0 ? n : 1);

	__CPROVER_assume(p != NULL);
	return p;
}

/* nondeterministic inputs */
uint8_t		nondet_u8(void);
uint16_t	nondet_u16(void);
uint32_t	nondet_u32(void);
uint64_t	nondet_u64(void);
int			nondet_int(void);
bool		nondet_bool(void);
double		nondet_double(void);

#endif							/* CBMC_PG_H */
