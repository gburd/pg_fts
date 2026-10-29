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
#include "mb/pg_wchar.h"
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
 * Its own counter (prs.pos) is a full int32.
 *
 * The text is parsed whole, exactly as before.  Only when that parse ran past
 * the cap is the result discarded and the text parsed again in chunks of at
 * most FTS_PARSE_CHUNK bytes -- a token is at least one byte, so no ordinal
 * inside a chunk reaches the cap, unless a thesaurus expands one word into
 * several positions (those still cap, as before) -- each chunk's ordinals
 * offset by the positions of the chunks before it.  So a document whose positions 1.14.3 got
 * right is analyzed identically.  Since 1.15.1 (CHANGELOG, ROADMAP I9a) a
 * chunk is bounded by positions -- only a token of a type the configuration
 * maps to dictionaries takes one -- and ends at a token boundary of the
 * configured parser verified to reproduce the whole text's raw tokens on both
 * sides (fts_cut_reproduces): 1.15.0 cut every 16,383 bytes after whitespace
 * and split tags, comments and <script> bodies into words.  The fallback (no
 * verified cut within 64 candidates, or a parser whose tokens do not point
 * into its input) is that 1.15.0 rule: after the last whitespace byte (ASCII
 * whitespace is never part of a multibyte character), or at the last whole
 * character (pg_mbcliplen).  A multi-word thesaurus phrase that straddles a
 * cut is not matched across it.
 */
#define FTS_PARSE_CHUNK (MAXENTRYPOS - 1)

/* parse str[0..len) into prs (appending), returning the words' true ordinals in
 * *wposp (grown with prs->words), offset by base; returns the positions used */
static uint32
fts_parse_into(Oid cfgId, ParsedText *prs, uint32 **wposp, int *capwpos,
			   const char *str, int len, uint32 base, char *buf)
{
	int			first = prs->curwords;
	int			i;

	/* parsetext wants a writable, NUL-terminated buffer */
	memcpy(buf, str, len);
	buf[len] = '\0';
	prs->pos = 0;
	parsetext(cfgId, prs, buf, len);
	if (prs->curwords > *capwpos)
	{
		*capwpos = prs->lenwords;
		*wposp = (uint32 *) repalloc(*wposp, sizeof(uint32) * *capwpos);	/* alloc-ok: grows with prs->lenwords (palloc-bounded) */
	}
	for (i = first; i < prs->curwords; i++)
		(*wposp)[i] = base + prs->words[i].pos.pos;
	if ((uint64) base + (uint64) prs->pos > FTS_POS_ORD_MASK)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("ftsdoc document has too many token positions")));
	return (uint32) prs->pos;
}

/*
 * The configured parser's raw token stream (no dictionaries), for choosing chunk
 * cuts (CHANGELOG 1.15.1, ROADMAP I9a).  A token is (type, byte offset, length)
 * relative to the parsed buffer.  Returns false if the parser hands back a
 * token that does not point into the buffer (a custom parser may return a
 * normalized copy): offsets are then unknown and the caller cannot verify cuts.
 */
typedef struct FtsRawTok
{
	int			type;
	int			off;
	int			len;
} FtsRawTok;

static bool
fts_raw_tokens(TSParserCacheEntry *prsobj, char *buf, int len,
			   FtsRawTok **toks, int *ntok, int *cap)
{
	void	   *prsdata;
	char	   *lemm = NULL;
	int			lenlemm = 0;
	int			type;
	bool		ok = true;

	*ntok = 0;
	prsdata = DatumGetPointer(FunctionCall2(&prsobj->prsstart,
											PointerGetDatum(buf),
											Int32GetDatum(len)));
	while ((type = DatumGetInt32(FunctionCall3(&prsobj->prstoken,
											   PointerGetDatum(prsdata),
											   PointerGetDatum(&lemm),
											   PointerGetDatum(&lenlemm)))) > 0)
	{
		/* in the integer domain: no pointer is formed from lenlemm (AGENTS 16) */
		if (lemm < buf || lemm > buf + len || lenlemm < 0 ||
			(Size) lenlemm > (Size) ((buf + len) - lemm))
		{
			ok = false;
			break;
		}
		if (*ntok == *cap)
		{
			Size		sz;

			*cap *= 2;
			sz = sizeof(FtsRawTok) * (Size) *cap;
			/* one entry per token of the text: past 1 GB for a text of ~89M tokens */
			*toks = (FtsRawTok *) (sz > MaxAllocSize ? repalloc_huge(*toks, sz) : repalloc(*toks, sz));
		}
		(*toks)[*ntok].type = type;
		(*toks)[*ntok].off = (int) (lemm - buf);
		(*toks)[*ntok].len = lenlemm;
		(*ntok)++;
	}
	FunctionCall1(&prsobj->prsend, PointerGetDatum(prsdata));
	return ok;
}

/*
 * Does parsing str[from, to) alone reproduce exactly the whole text's tokens
 * ref[i..) that lie in that range (same types, offsets and lengths, none
 * missing)?  `from` and `to` are whole-text token starts (or the text's ends);
 * for a look-ahead `probe` only the tokens that end before `to` are compared.
 * scratch and sbuf (at least to - from + 1 bytes; the caller passes the
 * whole-text buffer, whose tokens are kept as offsets) are workspace.
 */
static bool
fts_cut_reproduces(TSParserCacheEntry *prsobj, const char *str, int from, int to,
				   const FtsRawTok *ref, int nref, int i, bool probe,
				   FtsRawTok **scratch, int *scap, char *sbuf)
{
	int			n,
				k;

	memcpy(sbuf, str + from, to - from);
	sbuf[to - from] = '\0';
	if (!fts_raw_tokens(prsobj, sbuf, to - from, scratch, &n, scap))
		return false;
	for (k = 0; k < n; k++)
	{
		/* a look-ahead probe ends where the text does not: tokens whose
		 * reference extends past its end are not comparable */
		if (probe && i + k < nref && ref[i + k].off + ref[i + k].len > to)
			return true;
		if (i + k >= nref || (*scratch)[k].type != ref[i + k].type ||
			(*scratch)[k].off + from != ref[i + k].off ||
			(*scratch)[k].len != ref[i + k].len)
			return false;
	}
	return probe || !(i + n < nref && ref[i + n].off < to);	/* a cut drops none at its end */
}

FtsDoc
fts_analyze_with_config(Oid cfgId, const char *str, int len, uint8 label)
{
	ParsedText	prs;
	FtsDoc		doc;
	uint32	   *wpos;
	int			capwpos;
	uint32		base;
	char	   *buf;

	/* the word array as to_tsvector sizes it (to_tsany.c: clamped to MaxAllocSize) */
	prs.lenwords = Min(Max(len / 6, 16), (int) (MaxAllocSize / sizeof(ParsedWord)));
	prs.curwords = 0;
	prs.pos = 0;
	prs.words = (ParsedWord *) palloc(sizeof(ParsedWord) * prs.lenwords);
	capwpos = prs.lenwords;
	wpos = (uint32 *) palloc(sizeof(uint32) * capwpos);	/* alloc-ok: grows with prs.lenwords (palloc-bounded) */
	buf = (char *) palloc(len + 1);

	base = fts_parse_into(cfgId, &prs, &wpos, &capwpos, str, len, 0, buf);
	if (base > MAXENTRYPOS - 1)
	{
		/* past the cap: parse again in chunks (the first parse is discarded) */
		TSConfigCacheEntry *cfg = lookup_ts_config_cache(cfgId);
		TSParserCacheEntry *prsobj = lookup_ts_parser_cache(cfg->prsId);
		int			start = 0;
		int			i;
		int			ti = 0;		/* first whole-text token at or after start */
		int			ncap = 1024,
					scap = 1024,
					nref = 0;
		int			budget = FTS_PARSE_CHUNK;	/* positions a chunk may use */
		FtsRawTok  *ref = (FtsRawTok *) palloc(sizeof(FtsRawTok) * ncap);	/* alloc-ok: initial; grown huge-safe in fts_raw_tokens */
		FtsRawTok  *scratch = (FtsRawTok *) palloc(sizeof(FtsRawTok) * scap);	/* alloc-ok: as above */
		bool		haveref;

/* a token of a type the configuration maps to dictionaries: the only kind that
 * takes a position (blanks, tags, a <script> body in the parser's ignore state
 * take none) */
#define FTS_TOK_MAPPED(t) ((t) > 0 && (t) < cfg->lenmap && cfg->map[(t)].len > 0)

		for (i = 0; i < prs.curwords; i++)
			pfree(prs.words[i].word);	/* the dictionaries' lexemes, as to_tsany.c frees them */
		prs.curwords = 0;
		base = 0;
		/* the whole text's raw token stream: the reference every cut must reproduce */
		memcpy(buf, str, len);
		buf[len] = '\0';
		haveref = fts_raw_tokens(prsobj, buf, len, &ref, &nref, &ncap);
		while (start < len)
		{
			int			end = len;
			int			first = prs.curwords;
			uint32		used;
			bool		found = false;

			if (haveref)
			{
				int			j,
							mapped = 0,
							tries = 0;

				while (ti < nref && ref[ti].off < start)
					ti++;
				/* after a fallback cut, start is inside a token: every
				 * candidate's chunk would begin with a partial token */
				if (ti < nref && ref[ti].off != start)
					tries = 64;
				/*
				 * The chunk ends before the token that would take position
				 * budget + 1: a chunk is bounded by positions, not bytes, so
				 * markup that takes none (a long <script> body, a tag with a
				 * large data: URI) fits in one chunk whatever its length.
				 */
				for (j = ti; j < nref; j++)
				{
					if (FTS_TOK_MAPPED(ref[j].type) && ++mapped > budget)
						break;
				}
				if (j >= nref)
					found = true;	/* the rest of the text fits: end = len */
				/*
				 * Otherwise cut at the start of a whole-text token, the latest
				 * one that fits, whose cut reproduces the whole text's tokens
				 * on both sides: the chunk itself, and a look-ahead window
				 * after it (a cut inside <script> loses the parser's ignore
				 * state, so the next chunk would tokenize differently).  A tag
				 * or comment is one token, so a token boundary never splits it.
				 */
				for (; !found && j > ti && tries < 64; j--, tries++)
				{
					int			cut = ref[j].off;
					int			w,
								wmapped = 0,
								wend;

					if (cut <= start)
						break;
					if (ref[j - 1].off == cut)
						continue;	/* a compound and its first part share an offset: try the first only */
					/* the look-ahead: the next chunk's worth of positions, ending at a token start */
					for (w = j; w < nref; w++)
						if (FTS_TOK_MAPPED(ref[w].type) && ++wmapped > budget)
							break;
					wend = (w < nref) ? ref[w].off : len;
					if (wend <= cut)
						wend = len;
					if (fts_cut_reproduces(prsobj, str, start, cut, ref, nref, ti, false,
										   &scratch, &scap, buf) &&
						fts_cut_reproduces(prsobj, str, cut, wend, ref, nref, j, wend < len,
										   &scratch, &scap, buf))
					{
						end = cut;
						found = true;
					}
				}
			}
			if (!found && len - start > FTS_PARSE_CHUNK)
			{
				/*
				 * No verified cut (or a parser without token offsets): at most
				 * FTS_PARSE_CHUNK bytes, after the last whitespace, as 1.15.0
				 * did -- a token is at least one byte, so the positions fit.
				 * Markup that straddles this cut is read as words.
				 */
				int			lim = pg_mbcliplen(str + start, len - start, FTS_PARSE_CHUNK);

				elog(DEBUG1, "pg_fts analyzer: no verified chunk cut after byte %d of %d; cutting after whitespace",
					 start, len);
				end = start + lim;
				while (end > start && !scanner_isspace(str[end - 1]))
					end--;
				if (end == start)
					end = start + lim;	/* no whitespace: the last whole character */
				if (end == start)
					end = start + pg_mblen(str + start);	/* lim 0: an embedded NUL (C callers only) */
			}
			used = fts_parse_into(cfgId, &prs, &wpos, &capwpos, str + start, end - start, base, buf);
			if (used > MAXENTRYPOS - 1 && budget > 1 && end - start > 1)
			{
				/*
				 * The chunk took more positions than it has tokens (a thesaurus
				 * substitution adds positions), so some were capped: undo it
				 * and retry with half the budget.
				 */
				for (i = first; i < prs.curwords; i++)
					pfree(prs.words[i].word);
				prs.curwords = first;
				budget /= 2;
				continue;
			}
			base += used;
			start = end;
			budget = FTS_PARSE_CHUNK;
		}
#undef FTS_TOK_MAPPED
		pfree(ref);
		pfree(scratch);
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
