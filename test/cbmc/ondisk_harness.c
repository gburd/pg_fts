/*-------------------------------------------------------------------------
 *
 * ondisk_harness.c
 *		CBMC proofs that pg_fts's guards on untrusted page bytes keep every
 *		later read inside the buffer.  The page is a fully nondeterministic
 *		byte array: CBMC explores every header, count, width byte and length
 *		a torn, recycled or corrupt page can spell.
 *
 *	The property in every entry point is libdb's okitem guarantee: IF the
 *	guard accepts, THEN the reads the caller goes on to do are in bounds.
 *	--bounds-check and --pointer-check turn any out-of-bounds read into a
 *	failed property; --pointer-overflow-check additionally flags forming a
 *	pointer past the object from an untrusted integer (AGENTS.md rule 16).
 *
 *	harness_docvalid -- fts_doc_check (pg_fts_docvalid.h, #included: the
 *	  shipped validator).  If it returns 1 for a buffer of sz bytes, then
 *	  every entries[i], every lexeme slice [off, off+len) and, with
 *	  positions, every run [posoff, posoff+tf) of positions[] lies inside the
 *	  buffer -- the reads pg_fts_am.c and pg_fts_doc.c make next (the v0.3.3
 *	  pending-doc overflow).  Bound: nterms <= DV_TERMS, sz <= DV_SZ.
 *
 *	harness_page_data_end -- bm25_page_data_end (pg_fts_am.c, VERBATIM):
 *	  for any pd_lower, the end it returns lies in [contents, page+BLCKSZ].
 *	  The nine pd_lower bugs of 1.7.x were readers that skipped it.
 *
 *	harness_dict_walk -- the dictionary-page walk every lookup runs
 *	  (pg_fts_am_scan.c, e.g. bm25_lookup_term: bm25_dict_entry_fits,
 *	  VERBATIM, then MAXALIGN(offsetof(term) + termlen)).  If the guard
 *	  accepts an entry, its header fields and term[0..termlen) are inside
 *	  the page, and the walk terminates.  Bound: PG_SZ-byte page.
 *
 *	harness_block_decode -- bm25_decode_term's posting-block guard
 *	  (pg_fts_am.c: two-sided count clamp, stream+bytelen+posbytelen <= pend,
 *	  then gl+tl+dl <= bytelen) followed by the three bm25_for_unpack calls.
 *	  If the guards accept, the decode reads only page bytes.
 *
 *	harness_load_block -- wand_load_block (pg_fts_am_scan.c), the loader
 *	  under every ranked traversal: the page guard (bytelen + posbytelen fit
 *	  the page), then palloc(bytelen) + memcpy, then bm25_for_unpack of the
 *	  docid column and bm25_for_bytelen of the tf column FROM THE COPY, and
 *	  later bm25_for_get(blkbuf + tfoff, i) per scored posting.  The copy is
 *	  exactly bytelen bytes, so the property is that those reads stay
 *	  inside the copy.
 *
 *	TEETH: -DTEETH_ONESIDED reverts the decode-term count clamp to the
 *	shipped-0.3.4 one-sided form, with the column check of that era (the
 *	current column check rejects a negative count on its own, so it is
 *	reverted too) -- must FAIL; -DTEETH_PDLOWER drops the page_data_end upper
 *	check (must FAIL); the other TEETH_* are described at their entry point.
 *
 * IDENTIFICATION
 *	  test/cbmc/ondisk_harness.c
 *
 *-------------------------------------------------------------------------
 */
#include "cbmc_pg.h"
#include "../../pg_fts_for.h"
#include "../../pg_fts_docvalid.h"

/*
 * pg_fts_am.h has BM25_BLOCK_SIZE 128.  No guard below depends on its value
 * (the clamp maps any count outside [1, BM25_BLOCK_SIZE] to it), so the
 * harness uses 4 to keep the decode loops small; -DBM25_BLOCK_SIZE=128 checks
 * the shipped value at a higher unwind.
 */
#ifndef BM25_BLOCK_SIZE
#define BM25_BLOCK_SIZE 4
#endif

/* ---- harness_docvalid ---------------------------------------------------- */

#ifndef DV_TERMS
#define DV_TERMS 2
#endif
#ifndef DV_SZ
#define DV_SZ 96
#endif

void
harness_docvalid(void)
{
	size_t		sz = nondet_u32();
	unsigned char *buf;
	const FtsDvDocData *doc;
	const FtsDvTermEntry *entries;
	size_t		i;
	uint32_t	varsize = nondet_u32();

	__CPROVER_assume(sz >= 1 && sz <= DV_SZ);
	buf = cbmc_palloc(sz);
	__CPROVER_assume(buf != NULL);
	for (i = 0; i < sz; i++)
		buf[i] = nondet_u8();
	doc = (const FtsDvDocData *) buf;
	if (sz >= FTS_DV_HDRSIZE)
		__CPROVER_assume(doc->nterms <= DV_TERMS);

	if (!fts_doc_check(buf, sz, varsize))
	{
		free(buf);
		return;
	}
	/* accepted: the reads the backend makes next */
	entries = (const FtsDvTermEntry *) (buf + FTS_DV_HDRSIZE);
	__CPROVER_assert(__CPROVER_r_ok(entries, doc->nterms * sizeof(FtsDvTermEntry)),
					 "entries[] inside the image");
	for (i = 0; i < doc->nterms; i++)
	{
		const char *lex = (const char *) &entries[doc->nterms];	/* FTS_DOC_LEXEMES */

		__CPROVER_assert(__CPROVER_r_ok(lex + entries[i].off, entries[i].len),
						 "lexeme slice inside the image");
		if (doc->flags & FTS_DV_FLAG_POSITIONS)
		{
			/* FTS_DOC_POSITIONS: base + MAXALIGN(hdr + entries + lexbytes) */
			const uint32_t *pos = (const uint32_t *)
			(buf + FTS_DV_MAXALIGN(FTS_DV_HDRSIZE +
								   (size_t) doc->nterms * sizeof(FtsDvTermEntry) +
								   doc->lexbytes));

			__CPROVER_assert(__CPROVER_r_ok(pos + entries[i].posoff,
											(size_t) entries[i].tf * sizeof(uint32_t)),
							 "positions run inside the image");
		}
	}
	free(buf);
}

/* ---- page vocabulary ----------------------------------------------------- */

#ifndef PG_SZ
#define PG_SZ 96				/* a small page: header + a few entries */
#endif
#define BLCKSZ PG_SZ
typedef char *Page;
typedef struct PageHeaderData
{
	uint64		pd_lsn;
	uint16		pd_checksum;
	uint16		pd_flags;
	uint16		pd_lower;
	uint16		pd_upper;
	uint16		pd_special;
	uint16		pd_pagesize_version;
	uint32		pd_prune_xid;
} PageHeaderData;
typedef PageHeaderData *PageHeader;
#define SizeOfPageHeaderData (sizeof(PageHeaderData))
#define PageGetContents(page) ((char *) (page) + MAXALIGN(SizeOfPageHeaderData))

#ifndef TEETH_PDLOWER
/* VERBATIM pg_fts_am.c bm25_page_data_end */
static inline char *
bm25_page_data_end(Page page)
{
	Size		contents = (Size) ((char *) PageGetContents(page) - (char *) page);
	uint32		lower = ((PageHeader) page)->pd_lower;

	if ((Size) lower > (Size) BLCKSZ || (Size) lower < contents)
		return (char *) page + contents;
	return (char *) page + lower;
}
/* END VERBATIM */
#else
/* mutant: the 1.7.0-era read that trusted pd_lower's upper end */
static char *
bm25_page_data_end(Page page)
{
	Size		contents = (Size) ((char *) PageGetContents(page) - (char *) page);
	uint32		lower = ((PageHeader) page)->pd_lower;

	if ((Size) lower < contents)
		return (char *) page + contents;
	return (char *) page + lower;
}
#endif

static char *
nondet_page(void)
{
	char	   *page = cbmc_palloc(PG_SZ);
	int			i;

	__CPROVER_assume(page != NULL);
	for (i = 0; i < PG_SZ; i++)
		page[i] = (char) nondet_u8();
	return page;
}

void
harness_page_data_end(void)
{
	char	   *page = nondet_page();
	char	   *end = bm25_page_data_end(page);

	__CPROVER_assert(end >= PageGetContents(page) && end <= page + PG_SZ,
					 "data end inside [contents, page + BLCKSZ]");
	free(page);
}

/* VERBATIM pg_fts_am.c bm25_fits */
static inline bool
bm25_fits(const void *p, Size n, const void *end)
{
	return (const char *) p <= (const char *) end &&
		(Size) ((const char *) end - (const char *) p) >= n;
}
/* END VERBATIM */

/* ---- harness_dict_walk --------------------------------------------------- */

typedef struct BM25DictEntry	/* pg_fts_am.h */
{
	uint32		termlen;
	uint32		df;
	uint32		max_tf;
	uint32		firstoffset;
	BlockNumber firstposting;
	char		term[FLEXIBLE_ARRAY_MEMBER];
} BM25DictEntry;

#ifndef TEETH_DICT_PTR
/* VERBATIM pg_fts_am.c bm25_dict_entry_fits */
static inline bool
bm25_dict_entry_fits(const BM25DictEntry *de, const char *end)
{
	Size		room;

	if ((const char *) de > end)
		return false;
	room = (Size) (end - (const char *) de);
	return room >= offsetof(BM25DictEntry, term) &&
		room - offsetof(BM25DictEntry, term) >= de->termlen;
}
/* END VERBATIM */
#else
/* mutant: the 1.15.2 form, which formed t + termlen past the page */
static inline bool
bm25_dict_entry_fits(const BM25DictEntry *de, const char *end)
{
	const char *t = (const char *) de + offsetof(BM25DictEntry, term);

	return t <= end && t + de->termlen <= end;
}
#endif

void
harness_dict_walk(void)
{
	char	   *page = nondet_page();
	char	   *ptr = PageGetContents(page);
	char	   *end = bm25_page_data_end(page);
	int			steps = 0;

	/* the loop of bm25_lookup_term (pg_fts_am_scan.c) */
	while (ptr < end)
	{
		BM25DictEntry *de = (BM25DictEntry *) ptr;
		Size		esize;

		if (!bm25_dict_entry_fits(de, end))
			break;
		esize = MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);
		__CPROVER_assert(__CPROVER_r_ok(de, offsetof(BM25DictEntry, term)),
						 "accepted entry header inside the page");
		__CPROVER_assert(__CPROVER_r_ok(de->term, de->termlen),
						 "accepted term text inside the page");
		ptr += esize;
		steps++;
	}
	__CPROVER_assert(steps <= PG_SZ / 24, "walk terminates");
	free(page);
}

/* ---- posting blocks ------------------------------------------------------ */

typedef struct BM25BlockHdr		/* pg_fts_am.h */
{
	uint32		count;
	uint32		max_tf;
	uint32		min_doclen;
	uint32		first_docid_hi;
	uint32		first_docid_lo;
	uint32		bytelen;
	uint32		posbytelen;
} BM25BlockHdr;

/*
 * bm25_decode_term's per-block guard and decode (pg_fts_am.c, the block loop:
 * the count clamp, the page-fit check, the column-fit check, the three
 * unpacks).  Transcribed in the order the code runs; the ereport/goto done
 * exits are `return`.
 */
void
harness_block_decode(void)
{
	char	   *page = nondet_page();
	const char *pend = bm25_page_data_end(page);
	char	   *p = PageGetContents(page);
	BM25BlockHdr *bh;
	const unsigned char *stream;
	int			cnt;
	int			pos = 0;
	bool		has_doclen_col;
	uint64		gaps[BM25_BLOCK_SIZE],
				tfs[BM25_BLOCK_SIZE],
				dls[BM25_BLOCK_SIZE];

	if (!bm25_fits(p, sizeof(BM25BlockHdr), pend))
		return;
	bh = (BM25BlockHdr *) p;
	stream = (const unsigned char *) (bh + 1);
	cnt = (int) bh->count;
#ifdef TEETH_ONESIDED
	if (cnt > BM25_BLOCK_SIZE)	/* 0.3.4: misses a count >= 2^31 */
		cnt = BM25_BLOCK_SIZE;
#else
	if (bh->count == 0 || bh->count > (uint32) BM25_BLOCK_SIZE)
		cnt = BM25_BLOCK_SIZE;
#endif
	if ((uint64) bh->bytelen + bh->posbytelen > (uint64) ((const unsigned char *) pend - stream))
		return;
#if !defined(TEETH_DECODE_COLS) && !defined(TEETH_ONESIDED)
	{
		uint64		used2;

		if (!bm25_for_cols_fit(stream, bh->bytelen, cnt, 2, &used2))
			has_doclen_col = false;
		else
			has_doclen_col = (used2 < (uint64) bh->bytelen);
		if (!bm25_for_cols_fit(stream, bh->bytelen, cnt,
							   has_doclen_col ? 3 : 2, NULL))
			return;
	}
#else
	{
		/* 0.3.5..1.15.2: reads the tf width byte at stream[bytelen] when the
		 * docid column fills bytelen */
		int			gl = bm25_for_bytelen(stream, cnt);
		int			tl = (gl <= (int) bh->bytelen)
			? bm25_for_bytelen(stream + gl, cnt) : 0;
		int			dl;

		has_doclen_col = (gl + tl < (int) bh->bytelen);
		dl = (has_doclen_col && gl + tl <= (int) bh->bytelen)
			? bm25_for_bytelen(stream + gl + tl, cnt) : 0;
		if ((Size) gl + tl + dl > (Size) bh->bytelen)
			return;
	}
#endif
	pos += bm25_for_unpack(stream + pos, cnt, gaps);
	pos += bm25_for_unpack(stream + pos, cnt, tfs);
	if (has_doclen_col)
		pos += bm25_for_unpack(stream + pos, cnt, dls);
	__CPROVER_assert(stream + pos <= (const unsigned char *) pend, "decode stayed on the page");
	free(page);
}

/*
 * wand_load_block (pg_fts_am_scan.c): the page guard, the copy of exactly
 * bytelen payload bytes, the docid unpack from the copy, the tf column offset,
 * then (wand_contrib_cur) bm25_for_get on the tf column for a posting.
 */
void
harness_load_block(void)
{
	char	   *page = nondet_page();
	char	   *pend = bm25_page_data_end(page);
	char	   *p = PageGetContents(page);
	BM25BlockHdr *bh;
	const unsigned char *stream;
	unsigned char *blkbuf;
	uint64		gaps[BM25_BLOCK_SIZE];
	int			cnt,
				glen,
				tflen,
				cur;
	bool		has_doclen_col;
	bool		blk_no_dl = false;
	uint64		used2 = 0;

	if (!bm25_fits(p, sizeof(BM25BlockHdr), pend) || ((BM25BlockHdr *) p)->count == 0)
		return;
	bh = (BM25BlockHdr *) p;
	stream = (const unsigned char *) (bh + 1);
	cnt = (int) bh->count;
	if (bh->count == 0 || bh->count > (uint32) BM25_BLOCK_SIZE)
		cnt = BM25_BLOCK_SIZE;
	has_doclen_col = nondet_bool();	/* v3 (three columns) or v4 (two) segment */
#ifndef TEETH_LOADBLOCK
	if ((uint64) bh->bytelen + bh->posbytelen > (uint64) ((const unsigned char *) pend - stream) ||
		!bm25_for_cols_fit(stream, bh->bytelen, cnt, 2, &used2) ||
		(has_doclen_col && used2 < (uint64) bh->bytelen &&
		 !bm25_for_cols_fit(stream, bh->bytelen, cnt, 3, NULL)))
		return;
	blk_no_dl = has_doclen_col && used2 == (uint64) bh->bytelen;
#else
	/* 1.15.2: only the page-fit check; the columns were never sized */
	if (stream + (Size) bh->bytelen + (Size) bh->posbytelen > (const unsigned char *) pend)
		return;
#endif
	blkbuf = cbmc_palloc(bh->bytelen);	/* palloc(bh->bytelen) */
	__CPROVER_assume(blkbuf != NULL);
	memcpy(blkbuf, stream, bh->bytelen);
	glen = bm25_for_unpack(blkbuf, cnt, gaps);
	tflen = bm25_for_bytelen(blkbuf + glen, cnt);
	cur = nondet_int();
	__CPROVER_assume(cur >= 0 && cur < cnt);
	(void) bm25_for_get(blkbuf + glen, cur);	/* wand_contrib_cur's tf */
	if (has_doclen_col && !blk_no_dl)
		(void) bm25_for_get(blkbuf + glen + tflen, cur);	/* v3 inline |D| (wand_inline_dl) */
	{
		/* bestfirst / dense1 / bmw block decode: the whole tf column */
		uint64		tfs[BM25_BLOCK_SIZE];

		bm25_for_unpack(blkbuf + glen, cnt, tfs);
	}
	free(blkbuf);
	free(page);
}

/* ---- harness_doclen_block ------------------------------------------------ */

typedef struct BM25DoclenBlockHdr	/* pg_fts_am.c */
{
	uint32		count;
	uint32		first_docid_hi;
	uint32		first_docid_lo;
	uint32		gapbytes;
} BM25DoclenBlockHdr;

#ifndef TEETH_DOCLEN_GAPS
/* VERBATIM pg_fts_am.c bm25_doclen_block_fits */
static inline bool
bm25_doclen_block_fits(const BM25DoclenBlockHdr *bh, const char *end)
{
	const unsigned char *gapcol = (const unsigned char *) (bh + 1);
	Size		room;

	if ((const char *) gapcol > end)
		return false;
	room = (Size) (end - (const char *) gapcol);
	if ((uint64) bh->gapbytes + bh->count > room)
		return false;
	return bm25_for_cols_fit(gapcol, bh->gapbytes, (int) bh->count, 1, NULL);
}
/* END VERBATIM */
#else
/* mutant: the 1.5.0..1.15.2 guard -- the block fits, the gap column unsized */
static inline bool
bm25_doclen_block_fits(const BM25DoclenBlockHdr *bh, const char *end)
{
	return (const char *) (bh + 1) + bh->gapbytes + bh->count <= end;
}
#endif

/*
 * bm25_doclen_build_slots / bm25_doclen_cursor_load_page (pg_fts_am.c): the
 * header walk, the count check, the block guard, then the gap-column unpack
 * and the per-doc length bytes at (bh + 1) + gapbytes.
 */
void
harness_doclen_block(void)
{
	char	   *page = nondet_page();
	char	   *end = bm25_page_data_end(page);
	char	   *ptr = page + MAXALIGN(SizeOfPageHeaderData);
	int			steps = 0;

	while (bm25_fits(ptr, sizeof(BM25DoclenBlockHdr), end))
	{
		BM25DoclenBlockHdr *bh = (BM25DoclenBlockHdr *) ptr;
		uint64		gaps[BM25_BLOCK_SIZE];
		const uint8 *bytes;

		if (bh->count == 0 || bh->count > BM25_BLOCK_SIZE)
			break;
		if (!bm25_doclen_block_fits(bh, end))
			break;
		bm25_for_unpack((unsigned char *) (bh + 1), (int) bh->count, gaps);
		bytes = (const uint8 *) ((char *) (bh + 1) + bh->gapbytes);
		__CPROVER_assert(__CPROVER_r_ok(bytes, bh->count), "length bytes inside the page");
		ptr = (char *) MAXALIGN((char *) (bh + 1) + bh->gapbytes + bh->count);
		steps++;
	}
	__CPROVER_assert(steps <= PG_SZ / 16, "walk terminates");
	free(page);
}
