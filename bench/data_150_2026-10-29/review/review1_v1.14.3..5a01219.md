# Release review 1 (independent sub-agent, read-only), v1.14.3..5a01219

Verbatim. Findings 1-4, 6, 8 fixed in 2e68acd; 5 left (measured win covers it); 7 into the CHANGELOG.

Findings first, then the checklist. I read the code only: nothing was built or run, as instructed. Severities that depend on PostgreSQL's own behaviour were worked out from the REL_17_STABLE / REL_18_STABLE sources in `~/ws/postgres/master`.

## Findings

**1. BLOCKER: I9's fallback cut can split a UTF-8 character, so text that indexed fine in 1.14.3 now raises an ERROR.** `pg_fts_tsanalyze.c:245-252`
- **Where:** if a 16,383-byte window has no ASCII whitespace byte, the code sets `end = start + FTS_PARSE_CHUNK` with no check for a character boundary. A long CJK paragraph with no spaces or newlines is a realistic case: 16,383 bytes is about 5,461 characters.
- **What fails:** the cut can leave chunk N ending in a truncated multibyte sequence, and chunk N+1 then starts with continuation bytes. On PG 17/18, when the database ctype is not C (for example en_US.UTF-8), `TParserInit` calls `char2wchar`. `mbstowcs` then returns -1, and `pg_verifymbstr(..., false)` raises "invalid byte sequence for encoding UTF8".
- **Effect:** `INSERT` into a table with an fts index over `to_ftsdoc(cfg, text)` fails, and so does a REINDEX of such an index. With a C ctype the conversion stops early instead, and older minors' `pg_mblen` can read one or two bytes past the end of `buf`.
- **What is safe:** the whitespace split itself. In every server-side multibyte encoding, ASCII bytes are never trail bytes, so cutting at `scanner_isspace` always lands on a character boundary.
- **Not verified by execution.** `long_positions.sql` only uses ASCII, and `pg_regress` may run in a C locale, which hides the failure. A test for `t/004_encodings.pl` would be `to_ftsdoc('simple', repeat('漢', 6000))` (18 kB, no whitespace) in a UTF-8 database with a non-C ctype.
- **Fix:** compute the window as `int lim = pg_mbcliplen(str + start, len - start, FTS_PARSE_CHUNK);`. Back off from `start + lim` looking for whitespace, and use `start + lim` (not `start + FTS_PARSE_CHUNK`) as the hard cut.

**2. SHOULD-FIX: I9 changes how some texts under 16,383 tokens are analysed, which the CHANGELOG says it does not.** `pg_fts_tsanalyze.c:236-245`, `pg_fts_tsanalyze.c:212`, `CHANGELOG.md:33`
- **Cause:** chunking starts on byte length (`len > 16383`), not token count. So every text over 16 kB is chunked, including the many with far fewer than 16,383 tokens, whose positions were never capped.
- **Where a whitespace split changes the default parser's tokens:**
  - a tag with spaces inside it (`<a href="x" class="y">`). An unclosed tag at the end of a chunk is re-read as words, so `a`, `href`, `x` become indexed tokens and positions shift.
  - an HTML comment `<!-- ... -->`.
  - `<script>`/`<style>` content. The parser's `ignore` state is lost at the boundary, so the content becomes indexed.
  - the hard cut from finding 1.
- **So these claims are false for those inputs:** "Splitting at whitespace leaves the default parser's token stream unchanged" (`pg_fts_tsanalyze.c:212`) and "Documents of up to 16,383 tokens are analyzed exactly as before" (`CHANGELOG.md:33`).
- **Fix:** parse the whole text once, as before. Only if `prs.pos > MAXENTRYPOS - 1` throw that result away and re-parse in chunks.
  - Every document 1.14.3 handled correctly then stays exactly as it was.
  - The tag, comment and hard-cut exposure shrinks to documents whose positions were already broken.
  - The only cost is a second parse of very long documents.
- Not verified by execution.

**3. NIT: a variable is now set but never read.** `pg_fts_customscan.c:562,578`
- `nquals` is still incremented, but its only reader (`nquals != 1`) was removed.
- clang (the flake's compiler) warns with `-Wunused-but-set-variable`, which breaks any `-Werror` build. Delete the variable.

**4. NIT: cost estimation in `bool_gate_driver` scales badly with query size.** `pg_fts_am_scan.c:6296-6306`
- The cost loop scans every cursor for every leaf: O(nitems × ncur), where ncur can reach nterms × 128 segments. A 1,000-term query is about 10^8 steps of planning work per execution. This is unmeasured.
- **Fix:** sum `df` per `termidx` in one pass over the cursors, then add up per leaf.

**5. NIT: I19b looks each plain operand up twice per segment.** `pg_fts_am_scan.c:1145-1150`
- `bm25_required_term_absent` calls `bm25_lookup_df`, and `bm25_eval_query` then calls `bm25_lookup_term` for the same terms again. The result is correct.
- The measured win already pays for this, so leave it unless profiling shows it.

**6. NIT: the I8 early attach is only safe because no builder accepts invalidations.** `pg_fts_am.c:2753`
- Once `rd_amcache` points at a chunk that is still being built, any relcache invalidation of the index during the build would free it under the builder.
- The current builders only call `ReadBuffer`, `RelationGetNumberOfBlocks`, `palloc` and `CHECK_FOR_INTERRUPTS`, none of which process invalidations, so it is safe today.
- Add a one-line comment saying builders must not open relations or take heavyweight locks.

**7. NIT: the CHANGELOG undersells I20.** With the old two-record flush, a crash between the two records left the flushed documents both in the published segment and on the pending list. The next flush then folded them into a second segment, a permanent duplicate. 1.15.0's single record closes that too, and the I20 entry could say so.

**8. NIT: the CI hooks step can leave the wrong build installed on PG 19.** `.github/workflows/ci.yml:94-116`
- Because of `continue-on-error`, a failure on PG 19 leaves the `-DPG_FTS_TEST_HOOKS` build installed for any later step in that job.
- No later test step exists now, so this is harmless today. Reinstalling the normal build in an `always()` step would make it robust.

## Checked and found correct

- **I20, callers:**
  - Build, parallel build and the oversized-insert path pass NULL and add `seg->ndocs`/`sumdoclen`. That is correct: an oversized insert returns before touching the metapage totals.
  - Only `bm25_flush_pending` passes `pc` and leaves the totals alone. That matches the old "add, then subtract" with less float drift.
  - Merges never call `bm25_meta_add_segment`.
- **I20, the pending list:**
  - Fields are only written on a successful attempt; a full-directory retry returns before touching `pc`.
  - Freed pages are released once each, after `bm25_add_segment_with_room` returns. `freenewtail` is set only in the success branch.
  - Inserters hold the metapage lock exclusively for their whole append, so the `npending == 0 && pendingtail == newtail` test cannot race them.
- **I20, locks and readers:** lock order is unchanged (metapage buffer only, under the maintenance lock every caller holds). A reader with an older metapage snapshot is protected by the generation bump, which happens before the frees, plus the FREED/XID gate in `bm25_page_recyclable`. No new recycle site.
- **I8:**
  - Both `*_add` builders do only `memcpy` between allocating `out` and swapping it in, so nothing can ERROR while neither chunk is attached. They swap before `pfree(dc)`.
  - `complete` is the only way to be served; all `rd_amcache` access goes through `bm25_doclendir_cache`.
  - The chunk is still one `palloc` in `CacheMemoryContext` (rule 21).
- **Test hooks:** every hook site and both GUC definitions are inside `#ifdef PG_FTS_TEST_HOOKS` (`pg_fts.h:189`, `pg_fts_customscan.c:787,872`, `pg_fts_am.c:2782,7411`). The Makefile and `buildFor` never set `COPT`, so a normal build contains none of it.
- **I19a, query decomposition:**
  - Postfix right child = `n-1` and the `start[]` ranges are correct.
  - Any operand containing a NOT has `pos = false` and can never drive.
  - PHRASE and weighted leaves never reach this path (the pure-boolean gate excludes them).
- **I19a, exactness:**
  - Every match holds a leaf of each positive root-AND operand, in its own segment, so the driver's postings cover every match.
  - Pending documents are merged by the caller.
- **I19a, same results as the BMW walk:**
  - Same `acc[termidx]` contributions, in the same cursor order (term, then segment), summed by `sum_term_order`.
  - Same admission rule and threshold updates.
  - BMW only prunes documents that could not be admitted, so both build the same heap.
  - Cleanup matches BMW's; there is one `CHECK_FOR_INTERRUPTS` per candidate with no lock held.
  - Tombstones are skipped through `wand_seek`/`wand_next`.
- **I19b:** a plain, unweighted VAL operand of the root AND with df 0 makes the segment's exact answer empty, so returning an empty set is correct for all three `bm25_eval_query` callers. A negated root result needs both operands negated, which never happens when a VAL is an operand.
- **I17a:**
  - `predicate_implied_by(others, indpred, false)` proves predicate ⇒ quals, and `predOK` proves quals ⇒ predicate. Strong implication in both directions makes the row sets equal.
  - `others` holds bare clauses, as the predicate argument requires.
  - Volatile quals are rejected. A Param or stable function cannot be proven from an immutable predicate.
  - RLS quals land in `others`, so the pushdown only happens when the policy is equivalent to the predicate. That count is exactly what RLS would return, so nothing is bypassed.
  - With several equivalent partial indexes, any of them gives the same count.
- **I9, other mechanics:**
  - `wpos` grows to `prs.lenwords`, which is always at least `curwords`.
  - The overflow check runs before the value is used.
  - `doclen` is the sum of each chunk's `prs.pos`.
  - Texts of 16,383 bytes or less take the identical code path and come out byte-identical.
- **MSVC casts:** both values are bounded (fuzzy distance at most `INT_MAX` per `ftsquery_recv`; term length at most 2,047 bytes), so the casts change no result.

## RELEASING.md storage checklist

- **GenericXLog only:** verified. Grepping the diff's added lines for `log_newpage|XLogInsert|smgrwrite` finds nothing.
- **Atomic publish:** verified by reading. The segment, generation and pending-list clear are one metapage record.
- **Standby-safe recycling:** verified. No new recycle site; frees go through `bm25_free_page` after the publish.
- **Recovery guard and privilege checks:** not applicable; there are no new SQL-callable functions.
- **Bounded miss on page-derived bytes:** verified. No new page decode; I19b reuses `bm25_lookup_df`, which already checks bounds.
- **Cancellation:** verified for `fts_search_driven`. The I9 loop relies on `CHECK_FOR_INTERRUPTS` inside `TParserGet`.
- **Corpus statistics:** verified for build, merge and flush.
- **On-disk format:** no change; `complete` is in memory only.
- **Rule 25 (base SQL rename):** verified; `pg_fts--1.14.3.sql` is gone and the control file says 1.15.0.
- **Rule 26 (new TAP tests in both gates):** verified; `t/014` and `t/015` are in `flake.nix` and `ci.yml`.
- **Full gate:** not run here (no builds allowed on this host). It is still required before tagging.

Not covered: findings 1 and 2 have not been run, and the HTML-tag behaviour at a chunk end was inferred from `wparser_def.c`'s tag states without tracing them in full. Finding 1 is the one to reproduce before tagging.