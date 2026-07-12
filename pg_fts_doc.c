/*-------------------------------------------------------------------------
 *
 * pg_fts_doc.c
 *		Input/output and support functions for the ftsdoc type.
 *
 * ftsdoc input accepts either a canonical rendering (round-trips ftsdoc_out
 * exactly, including positions) or -- for the ergonomic 'raw text'::ftsdoc
 * cast -- an arbitrary string that is analyzed by the stage-1 tokenizer.
 *
 * Output renders the distinct terms with their term frequencies, and, when the
 * document carries token positions, each term's positions, in a stable,
 * human-readable form.  The canonical grammar is:
 *
 *	  doc     := token ( ' ' token )*
 *	  token   := qterm ':' tf [ '@' pos ( ',' pos )* ]
 *	  qterm   := '\'' ( any char, with '\'' and '\\' backslash-escaped )* '\''
 *	  tf, pos := unsigned decimal integer
 *
 * Examples:
 *
 *	  position-free:  'brown':1 'fox':2 'quick':1
 *	  with positions: 'brown':1@3 'fox':2@2,5 'quick':1@1
 *
 * The '@positions' suffix appears only when the document has stored positions;
 * a term's position count equals its tf.  This mirrors tsvector's rendering
 * closely enough to be familiar while making the (BM25-relevant) term frequency
 * explicit, which tsvector's output hides.
 *
 * ftsdoc_in re-parses this grammar back to a byte-identical FtsDoc, so
 * ftsdoc_in(ftsdoc_out(x)) = x for every x.  Any input that is not a complete
 * sequence of canonical tokens is treated as raw text and analyzed instead, so
 * 'the quick brown fox'::ftsdoc keeps working.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts_doc.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "pg_fts.h"
#include "catalog/pg_collation.h"
#include "lib/stringinfo.h"
#include "libpq/pqformat.h"
#include "regex/regex.h"
#include "utils/builtins.h"
#include "utils/varlena.h"

PG_FUNCTION_INFO_V1(ftsdoc_in);
PG_FUNCTION_INFO_V1(ftsdoc_out);
PG_FUNCTION_INFO_V1(ftsdoc_recv);
PG_FUNCTION_INFO_V1(ftsdoc_send);
PG_FUNCTION_INFO_V1(ftsdoc_length);

/*
 * fts_doc_is_valid -- structural self-consistency check for an FtsDoc whose
 * bytes came from an untrusted-at-read-time source (a pending index page, a
 * detoasted stored column).  The readers (pending-list flush and scan) cast
 * raw page bytes to FtsDoc and then walk entries[].len / .off / .tf / .posoff;
 * a torn page, a stale-format image, or any producing bug would otherwise turn
 * a bad length into a wild memcpy in add_posting (a _FORTIFY_SOURCE abort) or a
 * bad offset into an out-of-bounds positions/lexeme read in fts_doc_matches.
 * This confirms every derived offset stays within the varlena's own VARSIZE
 * before any of them is trusted.  `sz` is the total byte length available at
 * `doc` (VARSIZE for a detoasted datum, or the pending item's doclen).
 *
 * Returns true iff the header, the entries[] array, every term's lexeme slice,
 * and (when positions are present) the whole positions[] region and every
 * term's tf/posoff run fit inside `sz`, and the per-term tf counts sum to the
 * number of positions the layout has room for.  Cheap: one pass over entries.
 */
bool
fts_doc_is_valid(const FtsDocData *doc, Size sz)
{
	const FtsTermEntry *entries;
	Size		need;
	uint64		sumtf = 0;
	uint32		i;

	/* header must fit, and the declared VARSIZE must match the buffer we have */
	if (doc == NULL || sz < FTS_DOC_HDRSIZE)
		return false;
	if ((Size) VARSIZE(doc) > sz)
		return false;
	sz = VARSIZE(doc);			/* trust the smaller of the two from here */

	if (doc->version != FTS_DOC_VERSION)
		return false;

	/* header + entries[nterms] + lexbytes must fit */
	need = FTS_DOC_HDRSIZE + (Size) doc->nterms * sizeof(FtsTermEntry);
	if (need < FTS_DOC_HDRSIZE || need > sz)		/* overflow or overrun */
		return false;
	if (need + (Size) doc->lexbytes < need || need + (Size) doc->lexbytes > sz)
		return false;

	entries = FTS_DOC_ENTRIES(doc);
	for (i = 0; i < doc->nterms; i++)
	{
		/* each term's lexeme slice must lie within lexbytes */
		if ((Size) entries[i].off + entries[i].len < (Size) entries[i].off ||
			(Size) entries[i].off + entries[i].len > doc->lexbytes)
			return false;
		sumtf += entries[i].tf;
	}

	if (FTS_DOC_HAS_POS(doc))
	{
		/* the positions[] region (sumtf uint32s) must fit after the MAXALIGN'd
		 * header+entries+lexemes, and each term's [posoff, posoff+tf) run must
		 * lie within it. */
		Size		posbase = MAXALIGN(FTS_DOC_HDRSIZE +
								   (Size) doc->nterms * sizeof(FtsTermEntry) +
								   doc->lexbytes);

		if (posbase > sz)
			return false;
		if (sumtf > (uint64) ((sz - posbase) / sizeof(uint32)))
			return false;
		for (i = 0; i < doc->nterms; i++)
			if ((uint64) entries[i].posoff + entries[i].tf > sumtf)
				return false;
	}

	return true;
}


/*
 * fts_doc_build -- assemble an FtsDoc from parallel term arrays.
 *
 * terms[i]/lens[i] are the (already case-folded) term texts; tfs[i] the term
 * frequencies; when has_pos is true, positions[] holds the concatenated per-term
 * positions (tfs[i] of them for term i, in the order the terms appear) and the
 * result carries FTS_DOCF_POSITIONS.  Validates the on-disk invariants at this
 * trust boundary: terms strictly ascending and distinct, tf >= 1, and (with
 * positions) each term's positions strictly ascending.  errctx names the caller
 * for error messages ("ftsdoc" for text input, "binary ftsdoc" for recv).
 *
 * Mirrors fts_analyze_text's second pass and ftsdoc_recv's old assembly so the
 * layout is produced in exactly one style.
 */
static FtsDoc
fts_doc_build(uint32 nterms, char **terms, const int *lens, const uint32 *tfs,
			  bool has_pos, const uint32 *positions, const char *errctx)
{
	Size		lexbytes = 0;
	uint64		doclen = 0;
	uint64		npos = 0;
	Size		posbase;
	Size		total;
	FtsDoc		doc;
	FtsTermEntry *entries;
	char	   *lexemes;
	uint32		off = 0;
	uint32		pidx = 0;
	uint32		i;

	for (i = 0; i < nterms; i++)
	{
		if (lens[i] < 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("invalid %s: negative term length", errctx)));
		if (tfs[i] < 1)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("invalid %s: term frequency must be at least 1", errctx)));
		if (i > 0)
		{
			int			min = Min(lens[i - 1], lens[i]);
			int			c = memcmp(terms[i - 1], terms[i], min);

			if (c > 0 || (c == 0 && lens[i - 1] >= lens[i]))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
						 errmsg("invalid %s: terms must be sorted and distinct", errctx)));
		}
		lexbytes += lens[i];
		doclen += tfs[i];
		npos += tfs[i];
	}

	/* validate positions strictly ascending within each term */
	if (has_pos)
	{
		uint64		p = 0;

		for (i = 0; i < nterms; i++)
		{
			uint32		k;

			for (k = 0; k < tfs[i]; k++, p++)
			{
				if (k > 0 && positions[p] <= positions[p - 1])
					ereport(ERROR,
							(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
							 errmsg("invalid %s: positions must be ascending within a term", errctx)));
			}
		}
	}

	posbase = MAXALIGN(FTS_DOC_HDRSIZE +
					   (Size) nterms * sizeof(FtsTermEntry) + lexbytes);
	total = has_pos ? posbase + (Size) npos * sizeof(uint32) : posbase;
	doc = (FtsDoc) palloc0(total);
	SET_VARSIZE(doc, total);
	doc->version = FTS_DOC_VERSION;
	doc->flags = has_pos ? FTS_DOCF_POSITIONS : 0;
	doc->nterms = nterms;
	doc->doclen = (uint32) doclen;
	doc->lexbytes = lexbytes;

	entries = FTS_DOC_ENTRIES(doc);
	lexemes = FTS_DOC_LEXEMES(doc);
	for (i = 0; i < nterms; i++)
	{
		entries[i].off = off;
		entries[i].len = lens[i];
		entries[i].tf = tfs[i];
		entries[i].posoff = pidx;
		memcpy(lexemes + off, terms[i], lens[i]);
		off += lens[i];
		pidx += tfs[i];
	}
	if (has_pos)
	{
		uint32	   *dst = FTS_DOC_POSITIONS(doc);

		memcpy(dst, positions, (Size) npos * sizeof(uint32));
	}
	return doc;
}

/*
 * Try to parse `in` as the canonical grammar (see the file header).  Returns
 * the reconstructed FtsDoc on success, or NULL if `in` is not a complete
 * sequence of canonical tokens (caller then treats it as raw text).  A string
 * that clearly *looks* canonical (starts with a quoted term followed by ':')
 * but is malformed raises an error rather than silently falling back, so a
 * corrupt dump is rejected loudly at this trust boundary.
 */
static FtsDoc
fts_doc_parse_canonical(const char *in)
{
	const char *p = in;
	uint32		cap = 4;
	uint32		nterms = 0;
	char	  **terms = (char **) palloc(cap * sizeof(char *));
	int		   *lens = (int *) palloc(cap * sizeof(int));
	uint32	   *tfs = (uint32 *) palloc(cap * sizeof(uint32));
	StringInfoData term;
	uint32		poscap = 8;
	uint32		npos = 0;
	uint32	   *positions = (uint32 *) palloc(poscap * sizeof(uint32));
	bool		has_pos = false;
	bool		seen_any = false;
	FtsDoc		result;

	initStringInfo(&term);

	/* leading whitespace: an all-blank/empty string is the empty doc only if it
	 * is truly empty; otherwise let raw analysis handle it. */
	if (*p == '\0')
		return NULL;			/* empty string -> raw (analyzes to 0 terms) */

	for (;;)
	{
		uint32		tf;
		const char *save;

		/* skip a single separating space between tokens (and any run) */
		while (*p == ' ')
			p++;
		if (*p == '\0')
			break;

		/* a token must begin with a quote to be canonical */
		if (*p != '\'')
		{
			if (!seen_any)
				return NULL;	/* not canonical at all -> raw text */
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("malformed ftsdoc literal"),
					 errdetail("expected a quoted term at \"%s\".", p)));
		}

		/* parse quoted term, unescaping \' and \\ */
		save = p;
		p++;					/* opening quote */
		resetStringInfo(&term);
		for (;;)
		{
			if (*p == '\0')
			{
				if (!seen_any)
					return NULL;	/* unterminated -> treat whole as raw */
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
						 errmsg("malformed ftsdoc literal"),
						 errdetail("unterminated quoted term at \"%s\".", save)));
			}
			if (*p == '\\')
			{
				if (p[1] == '\0')
				{
					if (!seen_any)
						return NULL;
					ereport(ERROR,
							(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
							 errmsg("malformed ftsdoc literal"),
							 errdetail("trailing backslash in quoted term.")));
				}
				appendStringInfoChar(&term, p[1]);
				p += 2;
				continue;
			}
			if (*p == '\'')
			{
				p++;			/* closing quote */
				break;
			}
			appendStringInfoChar(&term, *p);
			p++;
		}

		/* a bare quoted lexeme with no ':' tf is not canonical: only bail to raw
		 * before the first token; after that it is a hard error. */
		if (*p != ':')
		{
			if (!seen_any)
				return NULL;
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("malformed ftsdoc literal"),
					 errdetail("expected ':' after term at \"%s\".", p)));
		}
		p++;					/* colon */

		/* term frequency: one or more digits, no sign */
		if (*p < '0' || *p > '9')
		{
			if (!seen_any)
				return NULL;
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("malformed ftsdoc literal"),
					 errdetail("expected term frequency after ':' at \"%s\".", p)));
		}
		tf = 0;
		while (*p >= '0' && *p <= '9')
		{
			uint64		next = (uint64) tf * 10 + (*p - '0');

			if (next > 0x7fffffff)	/* keep well below uint32 overflow / sane cap */
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
						 errmsg("ftsdoc term frequency out of range")));
			tf = (uint32) next;
			p++;
		}

		/* grow term arrays if needed */
		if (nterms == cap)
		{
			cap *= 2;
			terms = (char **) repalloc(terms, cap * sizeof(char *));
			lens = (int *) repalloc(lens, cap * sizeof(int));
			tfs = (uint32 *) repalloc(tfs, cap * sizeof(uint32));
		}
		terms[nterms] = (char *) palloc(Max(term.len, 1));
		memcpy(terms[nterms], term.data, term.len);
		lens[nterms] = term.len;
		tfs[nterms] = tf;

		/* optional '@' positions, must supply exactly tf of them */
		if (*p == '@')
		{
			uint32		k;

			has_pos = true;
			p++;
			for (k = 0; k < tf; k++)
			{
				uint32		v;

				if (k > 0)
				{
					if (*p != ',')
						ereport(ERROR,
								(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
								 errmsg("malformed ftsdoc literal"),
								 errdetail("expected %u positions for tf=%u.", tf, tf)));
					p++;
				}
				if (*p < '0' || *p > '9')
					ereport(ERROR,
							(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
							 errmsg("malformed ftsdoc literal"),
							 errdetail("expected a position at \"%s\".", p)));
				v = 0;
				while (*p >= '0' && *p <= '9')
				{
					uint64		next = (uint64) v * 10 + (*p - '0');

					if (next > 0x7fffffff)
						ereport(ERROR,
								(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
								 errmsg("ftsdoc position out of range")));
					v = (uint32) next;
					p++;
				}
				if (npos == poscap)
				{
					poscap *= 2;
					positions = (uint32 *) repalloc(positions, poscap * sizeof(uint32));
				}
				positions[npos++] = v;
			}
			/* a trailing ',' or extra digits means more than tf positions */
			if (*p == ',')
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
						 errmsg("malformed ftsdoc literal"),
						 errdetail("more than tf=%u positions for a term.", tf)));
		}
		else if (has_pos)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("malformed ftsdoc literal"),
					 errdetail("positions must be given for every term or none.")));

		nterms++;
		seen_any = true;

		/* after a token, only a space or end-of-string is legal */
		if (*p != ' ' && *p != '\0')
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
					 errmsg("malformed ftsdoc literal"),
					 errdetail("unexpected trailing text at \"%s\".", p)));
	}

	if (!seen_any)
		return NULL;

	result = fts_doc_build(nterms, terms, lens, tfs, has_pos, positions, "ftsdoc");
	pfree(term.data);
	return result;
}

Datum
ftsdoc_in(PG_FUNCTION_ARGS)
{
	char	   *in = PG_GETARG_CSTRING(0);
	FtsDoc		doc = fts_doc_parse_canonical(in);

	/* not canonical -> the ergonomic 'raw text'::ftsdoc cast: analyze it */
	if (doc == NULL)
		doc = fts_analyze_text(in, strlen(in));

	PG_RETURN_FTSDOC(doc);
}

static void
append_quoted_term(StringInfo buf, const char *term, int len)
{
	int			i;

	appendStringInfoChar(buf, '\'');
	for (i = 0; i < len; i++)
	{
		char		c = term[i];

		if (c == '\'' || c == '\\')
			appendStringInfoChar(buf, '\\');
		appendStringInfoChar(buf, c);
	}
	appendStringInfoChar(buf, '\'');
}

Datum
ftsdoc_out(PG_FUNCTION_ARGS)
{
	FtsDoc		doc = PG_GETARG_FTSDOC(0);
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	StringInfoData buf;
	uint32		i;

	initStringInfo(&buf);
	for (i = 0; i < doc->nterms; i++)
	{
		if (i > 0)
			appendStringInfoChar(&buf, ' ');
		append_quoted_term(&buf, FTS_DOC_TERMTEXT(doc, &entries[i]),
						   entries[i].len);
		appendStringInfo(&buf, ":%u", entries[i].tf);
		if (FTS_DOC_HAS_POS(doc))
		{
			const uint32 *pos = FTS_DOC_TERMPOS(doc, &entries[i]);
			uint32		k;

			for (k = 0; k < entries[i].tf; k++)
				appendStringInfo(&buf, k == 0 ? "@%u" : ",%u", pos[k]);
		}
	}

	PG_FREE_IF_COPY(doc, 0);
	PG_RETURN_CSTRING(buf.data);
}

/*
 * Binary receive/send.  The wire format is version-tagged and
 * architecture-neutral (fixed-width big-endian integers via pq_*), so it is
 * safe across replication and pg_dump -Fc.
 */
Datum
ftsdoc_recv(PG_FUNCTION_ARGS)
{
	StringInfo	buf = (StringInfo) PG_GETARG_POINTER(0);
	uint16		version;
	uint32		nterms;
	uint32		doclen;
	uint8		has_pos;
	FtsDoc		doc;
	uint32		i;
	char	  **terms;
	int		   *lens;
	uint32	   *tfs;
	uint32	   *positions = NULL;
	uint64		npos = 0;
	uint32		pidx = 0;

	version = (uint16) pq_getmsgint(buf, 2);
	/*
	 * Accept the current wire version (3, carries positions) and the previous
	 * one (2, position-free) so a binary dump (pg_dump -Fc) taken under an
	 * older pg_fts restores into this version.  A v2 message has no has_pos
	 * byte and no positions region.
	 */
	if (version != FTS_DOC_VERSION && version != 2)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("unsupported ftsdoc version number %u", version)));

	nterms = (uint32) pq_getmsgint(buf, 4);
	doclen = (uint32) pq_getmsgint(buf, 4);
	has_pos = (version >= 3) ? (uint8) pq_getmsgint(buf, 1) : 0;
	(void) doclen;				/* recomputed from tf in fts_doc_build */

	/*
	 * Guard against a hostile/corrupt binary message: each term contributes at
	 * least a 4-byte length + 4-byte tf, so nterms cannot exceed the remaining
	 * bytes / 8.  Rejects absurd counts before they reach palloc (overflow /
	 * OOM at a trust boundary).
	 */
	if (nterms > (uint32) (buf->len - buf->cursor) / 8)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("invalid ftsdoc: term count %u exceeds message size", nterms)));

	terms = (char **) palloc(Max(nterms, 1) * sizeof(char *));
	lens = (int *) palloc(Max(nterms, 1) * sizeof(int));
	tfs = (uint32 *) palloc(Max(nterms, 1) * sizeof(uint32));

	for (i = 0; i < nterms; i++)
	{
		const char *t;

		lens[i] = pq_getmsgint(buf, 4);
		tfs[i] = (uint32) pq_getmsgint(buf, 4);
		if (lens[i] < 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
					 errmsg("invalid ftsdoc term length")));
		t = pq_getmsgbytes(buf, lens[i]);
		terms[i] = (char *) palloc(Max(lens[i], 1));
		memcpy(terms[i], t, lens[i]);
		npos += tfs[i];
	}

	/*
	 * Positions region, when present.  Bound the total count the same way
	 * (each position is 4 bytes on the wire) before palloc, and read exactly
	 * sum(tf) of them, so a corrupt message can neither OOB-read nor OOM.
	 */
	if (has_pos)
	{
		if (npos > (uint64) (buf->len - buf->cursor) / 4)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
					 errmsg("invalid ftsdoc: position count exceeds message size")));
		positions = (uint32 *) palloc(Max((Size) npos, 1) * sizeof(uint32));
		for (i = 0; i < nterms; i++)
		{
			uint32		k;

			for (k = 0; k < tfs[i]; k++)
				positions[pidx++] = (uint32) pq_getmsgint(buf, 4);
		}
	}

	/* fts_doc_build enforces sorted/distinct terms, tf >= 1 and ascending
	 * positions -- the same guards as the text input path. */
	doc = fts_doc_build(nterms, terms, lens, tfs, has_pos != 0, positions,
						"binary ftsdoc");

	PG_RETURN_FTSDOC(doc);
}

Datum
ftsdoc_send(PG_FUNCTION_ARGS)
{
	FtsDoc		doc = PG_GETARG_FTSDOC(0);
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	StringInfoData buf;
	bool		has_pos = FTS_DOC_HAS_POS(doc);
	uint32		i;

	pq_begintypsend(&buf);
	pq_sendint16(&buf, doc->version);
	pq_sendint32(&buf, doc->nterms);
	pq_sendint32(&buf, doc->doclen);
	pq_sendint8(&buf, has_pos ? 1 : 0);
	for (i = 0; i < doc->nterms; i++)
	{
		pq_sendint32(&buf, entries[i].len);
		pq_sendint32(&buf, entries[i].tf);
		pq_sendbytes(&buf, FTS_DOC_TERMTEXT(doc, &entries[i]), entries[i].len);
	}
	if (has_pos)
	{
		for (i = 0; i < doc->nterms; i++)
		{
			const uint32 *pos = FTS_DOC_TERMPOS(doc, &entries[i]);
			uint32		k;

			for (k = 0; k < entries[i].tf; k++)
				pq_sendint32(&buf, pos[k]);
		}
	}

	PG_FREE_IF_COPY(doc, 0);
	PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/* ftsdoc_length(ftsdoc) -> int : total token count (doclen). Useful for BM25
 * length normalization later and handy for testing now. */
Datum
ftsdoc_length(PG_FUNCTION_ARGS)
{
	FtsDoc		doc = PG_GETARG_FTSDOC(0);
	uint32		doclen = doc->doclen;

	PG_FREE_IF_COPY(doc, 0);
	PG_RETURN_INT32((int32) doclen);
}

/*
 * fts_doc_lookup -- binary search for a term in a doc.
 * Returns the matching entry, or NULL.  Shared by the match evaluator.
 */
FtsTermEntry *
fts_doc_lookup(FtsDoc doc, const char *term, int termlen)
{
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	int			lo = 0;
	int			hi = (int) doc->nterms - 1;

	while (lo <= hi)
	{
		int			mid = (lo + hi) / 2;
		const char *mterm = FTS_DOC_TERMTEXT(doc, &entries[mid]);
		int			mlen = entries[mid].len;
		int			min = Min(mlen, termlen);
		int			c = memcmp(mterm, term, min);

		if (c == 0)
			c = mlen - termlen;

		if (c == 0)
			return &entries[mid];
		else if (c < 0)
			lo = mid + 1;
		else
			hi = mid - 1;
	}
	return NULL;
}

/*
 * fts_doc_has_prefix -- does any term in the doc start with the given prefix?
 * Terms are sorted, so binary-search the lower bound for the prefix, then
 * check whether the term there begins with it.
 */
bool
fts_doc_has_prefix(FtsDoc doc, const char *prefix, int prefixlen)
{
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	int			lo = 0;
	int			hi = (int) doc->nterms;

	if (prefixlen == 0)
		return doc->nterms > 0;

	/* lower_bound: first entry whose term >= prefix */
	while (lo < hi)
	{
		int			mid = (lo + hi) / 2;
		const char *mterm = FTS_DOC_TERMTEXT(doc, &entries[mid]);
		int			mlen = entries[mid].len;
		int			min = Min(mlen, prefixlen);
		int			c = memcmp(mterm, prefix, min);

		if (c == 0)
			c = mlen - prefixlen;	/* shorter sorts before */
		if (c < 0)
			lo = mid + 1;
		else
			hi = mid;
	}

	if (lo < (int) doc->nterms)
	{
		const char *mterm = FTS_DOC_TERMTEXT(doc, &entries[lo]);
		int			mlen = entries[lo].len;

		if (mlen >= prefixlen && memcmp(mterm, prefix, prefixlen) == 0)
			return true;
	}
	return false;
}

/*
 * fts_doc_has_fuzzy -- does any doc term lie within edit distance k of `term`?
 * Uses core's varstr_levenshtein_less_equal (bounded, so cheap for small k),
 * with two pre-filters to avoid the distance computation on most candidates:
 * a length filter (||cand|-|q|| <= k) and, when the query has more than k
 * trigrams (pigeonhole), a trigram-overlap filter.
 */
bool
fts_doc_has_fuzzy(FtsDoc doc, const char *term, int termlen, int k)
{
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	uint32		i;
	uint32		qtrg[FTS_MAX_TRIGRAMS];
	int			nqtrg;
	bool		use_trgm;

	/*
	 * Trigram pre-filter: a term within k edits of the query must share a
	 * trigram with it, provided the query has more than k trigrams (pigeonhole).
	 * When it does not, the filter is unsound, so we skip it and scan fully --
	 * results stay correct, only speed varies.
	 */
	nqtrg = fts_trigrams(term, termlen, qtrg, FTS_MAX_TRIGRAMS);
	use_trgm = (nqtrg > k);

	for (i = 0; i < doc->nterms; i++)
	{
		const char *cand = FTS_DOC_TERMTEXT(doc, &entries[i]);
		int			candlen = entries[i].len;
		int			d;

		/* length difference alone can exceed k -> skip without computing */
		if (abs(candlen - termlen) > k)
			continue;

		/* trigram pre-filter: skip candidates that share no trigram */
		if (use_trgm)
		{
			uint32		ctrg[FTS_MAX_TRIGRAMS];
			int			nctrg = fts_trigrams(cand, candlen, ctrg, FTS_MAX_TRIGRAMS);

			if (!fts_trigrams_overlap(qtrg, nqtrg, ctrg, nctrg))
				continue;
		}

		d = varstr_levenshtein_less_equal(term, termlen, cand, candlen,
										  1, 1, 1, k, true);
		if (d <= k)
			return true;
	}
	return false;
}

/*
 * fts_doc_has_regex -- does any doc term match the regular expression?
 * Uses core's cached regex engine (RE_compile_and_execute).  The regex is
 * matched against each stored (folded) term.
 */
bool
fts_doc_has_regex(FtsDoc doc, const char *re, int relen)
{
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	text	   *repat = cstring_to_text_with_len(re, relen);
	uint32		i;
	bool		found = false;

	for (i = 0; i < doc->nterms; i++)
	{
		const char *cand = FTS_DOC_TERMTEXT(doc, &entries[i]);
		int			candlen = entries[i].len;

		if (RE_compile_and_execute(repat, (char *) cand, candlen,
								   REG_ADVANCED, C_COLLATION_OID,
								   0, NULL))
		{
			found = true;
			break;
		}
	}
	pfree(repat);
	return found;
}
