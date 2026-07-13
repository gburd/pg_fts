/*-------------------------------------------------------------------------
 *
 * pg_fts_docvalid.h
 *		Pure structural validator for an on-disk FtsDoc image.
 *
 * This is the exact logic of fts_doc_is_valid() (see pg_fts_doc.c) factored out
 * as standalone C with NO PostgreSQL dependencies, so it can be exercised by
 * the standalone fuzz/corruption harness (test/fuzz/) while remaining the
 * single source of truth: pg_fts_doc.c's fts_doc_is_valid() is a thin wrapper
 * that reads VARSIZE in its proper backend context and calls fts_doc_check()
 * here.  This mirrors how pg_fts_for.h is shared with test/hegel/.
 *
 * The struct layout (FtsDocData / FtsTermEntry) and the alignment/version
 * constants MUST stay byte-identical to pg_fts.h.  They are duplicated here (as
 * plain uint32) rather than #including pg_fts.h because pg_fts.h pulls in
 * postgres.h.  A compile-time check in pg_fts_doc.c (see the static asserts
 * there) guards against drift.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts_docvalid.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_FTS_DOCVALID_H
#define PG_FTS_DOCVALID_H

#include <stddef.h>
#include <stdint.h>

/*
 * PostgreSQL's c.h defines these; only supply them when compiled outside the
 * backend.  Key off MAXALIGN, which is defined by c.h.
 */
#ifndef MAXALIGN
#define FTS_DV_MAXALIGN(LEN)	(((size_t) (LEN) + 7) & ~((size_t) 7))	/* MAXIMUM_ALIGNOF == 8 */
#else
#define FTS_DV_MAXALIGN(LEN)	MAXALIGN(LEN)
#endif

/* Layout constants, kept identical to pg_fts.h. */
#define FTS_DV_VERSION			3
#define FTS_DV_FLAG_POSITIONS	0x0001

/*
 * Mirror of FtsTermEntry / FtsDocData.  Fixed-width fields, no PG types, so the
 * offsets and sizes are identical to the backend struct (which uses the same
 * fixed widths).  int32 vl_len_ leads, matching the varlena header word.
 */
typedef struct FtsDvTermEntry
{
	uint32_t	off;
	uint32_t	len;
	uint32_t	tf;
	uint32_t	posoff;
} FtsDvTermEntry;

typedef struct FtsDvDocData
{
	int32_t		vl_len_;
	uint16_t	version;
	uint16_t	flags;
	uint32_t	nterms;
	uint32_t	doclen;
	uint32_t	lexbytes;
	/* FtsDvTermEntry entries[] follows */
} FtsDvDocData;

#define FTS_DV_HDRSIZE			offsetof(FtsDvDocData, lexbytes) + sizeof(uint32_t)

/*
 * fts_doc_check -- the pure validator body.
 *
 * `base` points at the FtsDoc image; `sz` is the total bytes readable there;
 * `varsize` is the declared varlena size (VARSIZE), read by the caller in its
 * proper context (backend: the VARSIZE macro; fuzzer: the little-endian 4B
 * header).  Returns nonzero iff the header, entries[], every term's lexeme
 * slice, and (with positions) the whole positions[] region and every term's
 * tf/posoff run fit inside the buffer, and the tf counts sum to at most the
 * positions the layout has room for.  NEVER reads outside [base, base+sz).
 *
 * This is a straight transcription of the fts_doc_is_valid() body; the only
 * change is that VARSIZE is passed in rather than read from a PG macro.
 */
static inline int
fts_doc_check(const void *base, size_t sz, uint32_t varsize)
{
	const FtsDvDocData *doc = (const FtsDvDocData *) base;
	const FtsDvTermEntry *entries;
	size_t		hdrsize = FTS_DV_HDRSIZE;
	size_t		need;
	uint64_t	sumtf = 0;
	uint32_t	i;

	/* header must fit, and the declared VARSIZE must match the buffer we have */
	if (doc == NULL || sz < hdrsize)
		return 0;
	if ((size_t) varsize > sz)
		return 0;
	sz = varsize;				/* trust the smaller of the two from here */

	if (doc->version != FTS_DV_VERSION)
		return 0;

	/* header + entries[nterms] + lexbytes must fit */
	need = hdrsize + (size_t) doc->nterms * sizeof(FtsDvTermEntry);
	if (need < hdrsize || need > sz)	/* overflow or overrun */
		return 0;
	if (need + (size_t) doc->lexbytes < need || need + (size_t) doc->lexbytes > sz)
		return 0;

	entries = (const FtsDvTermEntry *) ((const char *) doc + hdrsize);
	for (i = 0; i < doc->nterms; i++)
	{
		/* each term's lexeme slice must lie within lexbytes */
		if ((size_t) entries[i].off + entries[i].len < (size_t) entries[i].off ||
			(size_t) entries[i].off + entries[i].len > doc->lexbytes)
			return 0;
		sumtf += entries[i].tf;
	}

	if ((doc->flags & FTS_DV_FLAG_POSITIONS) != 0)
	{
		/* positions[] (sumtf uint32s) must fit after the MAXALIGN'd
		 * header+entries+lexemes, and each term's [posoff, posoff+tf) run must
		 * lie within it. */
		size_t		posbase = FTS_DV_MAXALIGN(hdrsize +
											   (size_t) doc->nterms * sizeof(FtsDvTermEntry) +
											   doc->lexbytes);

		if (posbase > sz)
			return 0;
		if (sumtf > (uint64_t) ((sz - posbase) / sizeof(uint32_t)))
			return 0;
		for (i = 0; i < doc->nterms; i++)
			if ((uint64_t) entries[i].posoff + entries[i].tf > sumtf)
				return 0;
	}

	return 1;
}

#endif							/* PG_FTS_DOCVALID_H */
