/*-------------------------------------------------------------------------
 *
 * pg_fts_tsanalyze.c
 *		Analyzer that reuses PostgreSQL's existing text-search pipeline.
 *
 * Stage 2 of pg_fts.  Where pg_fts_analyze.c provides a minimal self-contained
 * tokenizer, this file makes the analyzer *pluggable* by binding an ftsdoc to
 * any installed text search configuration (pg_ts_config): the configured
 * parser and dictionary chain (snowball stemmers, ispell, synonyms, thesaurus,
 * stopwords) are run via parsetext(), and the resulting normalized lexemes are
 * folded into an ftsdoc.  No tokenizer or dictionary code is reimplemented --
 * this is the reuse the design calls for.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts_tsanalyze.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "pg_fts.h"
#include "catalog/pg_type.h"
#include "parser/scansup.h"
#include "tsearch/ts_cache.h"
#include "tsearch/ts_type.h"
#include "tsearch/ts_utils.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

/* qsort_arg comparator: elements are indices into a ParsedWord array (arg).
 * Ties on (text, len) break by token position so a distinct-term run comes out
 * with its positions ascending -- phrase_step requires each term's position
 * list to be ascending (this mirrors cmp_rawterm in pg_fts_analyze.c). */
typedef struct WordSortArg
{
	ParsedWord *words;
	const uint32 *pos;			/* true 1-based token ordinal of each word */
} WordSortArg;

static int
cmp_word_idx(const void *a, const void *b, void *arg)
{
	WordSortArg *sa = (WordSortArg *) arg;
	ParsedWord *words = sa->words;
	int			ia = *(const int *) a,
				ib = *(const int *) b;
	ParsedWord *wa = &words[ia];
	ParsedWord *wb = &words[ib];
	int			min = Min(wa->len, wb->len);
	int			c = memcmp(wa->word, wb->word, min);

	if (c != 0)
		return c;
	if (wa->len != wb->len)
		return wa->len - wb->len;
	/* same term: order by position so positions come out ascending */
	if (sa->pos[ia] < sa->pos[ib])
		return -1;
	if (sa->pos[ia] > sa->pos[ib])
		return 1;
	return 0;
}

/*
 * Build an ftsdoc from the words produced by parsetext().  The words are not
 * sorted and may contain duplicates and multiple variants per position, so we
 * sort, deduplicate and count term frequency, exactly like the simple
 * analyzer.  doclen is the number of token positions, which parsetext tracks
 * in prs->pos.  Per-token positions are stored (FTS_DOCF_POSITIONS) so phrase
 * and NEAR queries enforce adjacency on this path too; parsetext() fills each
 * ParsedWord.pos.pos with a 1-based token ordinal.
 */
static FtsDoc
ftsdoc_from_parsed(ParsedText *prs, const uint32 *wpos, uint32 doclen, uint8 label)
{
	WordSortArg sa;
	int			nw = prs->curwords;
	ParsedWord *words = prs->words;
	int		   *order;
	int			i;
	int			ndistinct = 0;
	Size		lexbytes = 0;
	FtsDoc		doc;
	Size		posbase;
	Size		total;
	int			npos;
	FtsTermEntry *entries;
	char	   *lexemes;
	uint32	   *positions;
	uint32		off;
	uint32		pidx;

	if (nw == 0)
	{
		total = FTS_DOC_HDRSIZE;
		doc = (FtsDoc) palloc0(total);
		SET_VARSIZE(doc, total);
		doc->version = FTS_DOC_VERSION;
		doc->flags = 0;
		doc->nterms = 0;
		doc->doclen = 0;
		doc->lexbytes = 0;
		return doc;
	}

	/* index-sort words by (text, len, pos) without disturbing the array */
	order = (int *) palloc(nw * sizeof(int));
	for (i = 0; i < nw; i++)
		order[i] = i;
	sa.words = words;
	sa.pos = wpos;
	qsort_arg(order, nw, sizeof(int), cmp_word_idx, &sa);

	for (i = 0; i < nw;)
	{
		int			run = 1;
		ParsedWord *w = &words[order[i]];

		while (i + run < nw)
		{
			ParsedWord *n = &words[order[i + run]];
			int			min = Min(w->len, n->len);
			int			c = memcmp(w->word, n->word, min);

			if (c == 0)
				c = w->len - n->len;
			if (c != 0)
				break;
			run++;
		}
		lexbytes += w->len;
		ndistinct++;
		i += run;
	}

	total = FTS_DOC_HDRSIZE +
		(Size) ndistinct * sizeof(FtsTermEntry) + lexbytes;
	/* one stored position per token; npos == nw (sum of tf over all terms) */
	npos = nw;
	posbase = MAXALIGN(total);
	total = posbase + (Size) npos * sizeof(uint32);
	if (total > MaxAllocSize)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("ftsdoc document is too large"),
				 errdetail("An ftsdoc value is limited to %zu bytes; this document needs %zu.",
						   (Size) MaxAllocSize, total)));
	doc = (FtsDoc) palloc0(total);
	SET_VARSIZE(doc, total);
	doc->version = FTS_DOC_VERSION;
	doc->flags = FTS_DOCF_POSITIONS;
	doc->nterms = ndistinct;
	doc->doclen = doclen;
	doc->lexbytes = lexbytes;

	entries = FTS_DOC_ENTRIES(doc);
	lexemes = FTS_DOC_LEXEMES(doc);
	positions = FTS_DOC_POSITIONS(doc);
	off = 0;
	pidx = 0;
	ndistinct = 0;
	for (i = 0; i < nw;)
	{
		int			run = 1;
		int			k;
		ParsedWord *w = &words[order[i]];

		while (i + run < nw)
		{
			ParsedWord *n = &words[order[i + run]];
			int			min = Min(w->len, n->len);
			int			c = memcmp(w->word, n->word, min);

			if (c == 0)
				c = w->len - n->len;
			if (c != 0)
				break;
			run++;
		}
		entries[ndistinct].off = off;
		entries[ndistinct].len = w->len;
		entries[ndistinct].tf = run;
		entries[ndistinct].posoff = pidx;
		memcpy(lexemes + off, w->word, w->len);
		off += w->len;
		/* cmp_word_idx broke ties by pos, so this run is already ascending */
		for (k = 0; k < run; k++)
			positions[pidx++] = FTS_POS_MAKE(wpos[order[i + k]], label);
		ndistinct++;
		i += run;
	}
	if (label != 0)
		doc->flags |= FTS_DOCF_WEIGHTS;

	return doc;
}

/*
 * fts_analyze_with_config -- analyze text using a specific TS configuration.
 *
 * Positions (CHANGELOG 1.15.0, ROADMAP I9): parsetext() stores each token's
 * ordinal in a 16-bit field capped at MAXENTRYPOS - 1 = 16,383, so through
 * 1.14.3 every token past the 16,383rd shared that position and a phrase
 * starting there could not match (the unconfigured analyzer was not capped).
 * Its own counter (prs.pos) is a full int32.  So text that could hold more
 * than FTS_PARSE_CHUNK tokens is parsed in chunks of at most that many bytes
 * -- a token is at least one byte, so no ordinal inside a chunk reaches the
 * cap -- split at whitespace, and each chunk's ordinals are offset by the
 * positions of the chunks before it.  A text no longer than one chunk is
 * parsed exactly as before.  Splitting at whitespace leaves the default
 * parser's token stream unchanged; a multi-word dictionary (thesaurus) phrase
 * that straddles a chunk boundary is not matched across it.
 */
#define FTS_PARSE_CHUNK (MAXENTRYPOS - 1)

FtsDoc
fts_analyze_with_config(Oid cfgId, const char *str, int len, uint8 label)
{
	ParsedText	prs;
	FtsDoc		doc;
	uint32	   *wpos;
	int			capwpos;
	uint32		base = 0;
	int			start = 0;
	char	   *buf;

	prs.lenwords = Max(Min(len, FTS_PARSE_CHUNK) / 6, 16);
	prs.curwords = 0;
	prs.pos = 0;
	prs.words = (ParsedWord *) palloc(sizeof(ParsedWord) * prs.lenwords);
	capwpos = prs.lenwords;
	wpos = (uint32 *) palloc(sizeof(uint32) * capwpos);	/* alloc-ok: grows with prs.lenwords (palloc-bounded) */
	buf = (char *) palloc(Min(len, FTS_PARSE_CHUNK) + 1);

	while (start < len)
	{
		int			end = len;
		int			first = prs.curwords;
		int			i;

		if (len - start > FTS_PARSE_CHUNK)
		{
			/* end after the last whitespace byte inside the chunk; a chunk
			 * with none (one 16 kB "word") is cut where it is */
			end = start + FTS_PARSE_CHUNK;
			while (end > start && !scanner_isspace(str[end - 1]))
				end--;
			if (end == start)
				end = start + FTS_PARSE_CHUNK;
		}
		/* parsetext wants a writable, NUL-terminated buffer */
		memcpy(buf, str + start, end - start);
		buf[end - start] = '\0';
		prs.pos = 0;
		parsetext(cfgId, &prs, buf, end - start);
		if (prs.curwords > capwpos)
		{
			capwpos = prs.lenwords;
			wpos = (uint32 *) repalloc(wpos, sizeof(uint32) * capwpos);	/* alloc-ok: as above */
		}
		for (i = first; i < prs.curwords; i++)
			wpos[i] = base + prs.words[i].pos.pos;
		if ((uint64) base + (uint64) prs.pos > FTS_POS_ORD_MASK)
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("ftsdoc document has too many token positions")));
		base += (uint32) prs.pos;
		start = end;
	}

	doc = ftsdoc_from_parsed(&prs, wpos, base, label);

	if (prs.words)
		pfree(prs.words);
	pfree(wpos);
	pfree(buf);

	return doc;
}

PG_FUNCTION_INFO_V1(to_ftsdoc_byid);
PG_FUNCTION_INFO_V1(to_ftsdoc_from_tsvector);

/*
 * to_ftsdoc(tsvector) -- build an ftsdoc directly from an existing tsvector,
 * with no re-analysis of source text.  A tsvector is already the exact shape
 * an ftsdoc needs: lexemes sorted + distinct, each with an ascending position
 * list (1-based), so this is a straight structural map.  It is the adoption
 * on-ramp for a table that already materializes a tsvector column.
 *
 * Positions: a tsvector entry may be positionless (haspos=0, e.g. after
 * strip()) or carry positions.  ftsdoc positions are all-or-nothing per doc, so
 * we keep positions ONLY if EVERY entry has them; if any entry is positionless
 * we build a positions-off ftsdoc (tf = max(npos,1)), matching how a stripped
 * tsvector degrades.  A tsvector position of 0 ("unknown") is treated as
 * positionless for that entry.  Positions are taken via WEP_GETPOS (the 14-bit
 * position, weight bits dropped) and are already ascending + distinct within an
 * entry per tsvector's own invariants; fts_doc_build re-validates at the trust
 * boundary.
 */
Datum
to_ftsdoc_from_tsvector(PG_FUNCTION_ARGS)
{
	TSVector	tsv = PG_GETARG_TSVECTOR(0);
	int			n = tsv->size;
	WordEntry  *we = ARRPTR(tsv);
	char	   *lexbase = STRPTR(tsv);
	char	  **terms;
	int		   *lens;
	uint32	   *tfs;
	uint32	   *positions = NULL;
	bool		has_pos = true;
	uint64		npos = 0;
	int			i;
	FtsDoc		doc;

	if (n == 0)
	{
		doc = fts_doc_build(0, NULL, NULL, NULL, false, NULL, "ftsdoc");
		PG_FREE_IF_COPY(tsv, 0);
		PG_RETURN_FTSDOC(doc);
	}

	/* first pass: decide positions-on/off + total position count */
	for (i = 0; i < n; i++)
	{
		int			np = POSDATALEN(tsv, &we[i]);

		if (np <= 0)
			has_pos = false;
		npos += (np > 0) ? (uint64) np : 1;
	}

	terms = (char **) palloc(n * sizeof(char *));
	lens = (int *) palloc(n * sizeof(int));
	tfs = (uint32 *) palloc(n * sizeof(uint32));
	if (has_pos)
		positions = (uint32 *) (npos * sizeof(uint32) > MaxAllocSize
							   ? MemoryContextAllocHuge(CurrentMemoryContext,
														npos * sizeof(uint32))
							   : palloc(npos * sizeof(uint32)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */

	{
		uint64		p = 0;

		for (i = 0; i < n; i++)
		{
			int			np = POSDATALEN(tsv, &we[i]);

			terms[i] = lexbase + we[i].pos;
			lens[i] = we[i].len;
			tfs[i] = (np > 0) ? (uint32) np : 1;
			if (has_pos)
			{
				WordEntryPos *pv = POSDATAPTR(tsv, &we[i]);
				int			k;

				/* tsvector weight (0..3 = D,C,B,A) maps directly to our label */
				for (k = 0; k < np; k++)
					positions[p++] = FTS_POS_MAKE(WEP_GETPOS(pv[k]),
												  WEP_GETWEIGHT(pv[k]));
			}
		}
	}

	doc = fts_doc_build((uint32) n, terms, lens, tfs, has_pos, positions,
						"ftsdoc");
	PG_FREE_IF_COPY(tsv, 0);
	PG_RETURN_FTSDOC(doc);
}

/* to_ftsdoc(regconfig, text) */
Datum
to_ftsdoc_byid(PG_FUNCTION_ARGS)
{
	Oid			cfgId = PG_GETARG_OID(0);
	text	   *in = PG_GETARG_TEXT_PP(1);
	FtsDoc		doc;

	doc = fts_analyze_with_config(cfgId,
								  VARDATA_ANY(in), VARSIZE_ANY_EXHDR(in), 0);
	PG_FREE_IF_COPY(in, 1);
	PG_RETURN_FTSDOC(doc);
}

PG_FUNCTION_INFO_V1(to_ftsdoc_byid_weight);

/* to_ftsdoc(regconfig, text, weight "char") -- tag every token position with
 * the weight label A/B/C/D so a query term can restrict to this field (zone). */
Datum
to_ftsdoc_byid_weight(PG_FUNCTION_ARGS)
{
	Oid			cfgId = PG_GETARG_OID(0);
	text	   *in = PG_GETARG_TEXT_PP(1);
	char		w = PG_GETARG_CHAR(2);
	FtsDoc		doc;

	if (w != 'A' && w != 'B' && w != 'C' && w != 'D' &&
		w != 'a' && w != 'b' && w != 'c' && w != 'd')
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("weight must be one of A, B, C, D")));
	doc = fts_analyze_with_config(cfgId, VARDATA_ANY(in), VARSIZE_ANY_EXHDR(in),
								  FTS_WEIGHT_LABEL(w));
	PG_FREE_IF_COPY(in, 1);
	PG_RETURN_FTSDOC(doc);
}

/*
 * fts_normalize_term -- run a single query term through a text-search config's
 * parser+dictionary pipeline and return its normalized lexeme (palloc'd), so a
 * query term matches the same stemmed/stopword-processed form the document
 * index stores.  Returns NULL and sets *outlen=0 if the term normalizes away
 * (e.g. it is a stopword), in which case the caller should drop it.  If the
 * term produces multiple lexemes only the first is used (query terms are single
 * words in stage-1 syntax).
 */
char *
fts_normalize_term(Oid cfgId, const char *term, int len, int *outlen)
{
	ParsedText	prs;
	char	   *buf;
	char	   *result = NULL;

	*outlen = 0;
	prs.lenwords = 4;
	prs.curwords = 0;
	prs.pos = 0;
	prs.words = (ParsedWord *) palloc(sizeof(ParsedWord) * prs.lenwords);

	buf = (char *) palloc(len + 1);
	memcpy(buf, term, len);
	buf[len] = '\0';
	parsetext(cfgId, &prs, buf, len);

	if (prs.curwords > 0)
	{
		result = (char *) palloc(prs.words[0].len);
		memcpy(result, prs.words[0].word, prs.words[0].len);
		*outlen = prs.words[0].len;
	}
	pfree(buf);
	if (prs.words)
		pfree(prs.words);
	return result;
}
