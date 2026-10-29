# Re-review of 9ddb4b4..057fcc5 (fresh sub-agent, read-only)

Verbatim. Items 3 (mid-token start), 4 (fallback budget), 7, 8, 9 addressed in the next commit; 1, 2, 6 OK; 5 unmeasured.

**Re-review of `9ddb4b4..057fcc5` (`pg_fts_tsanalyze.c`, `sql/long_positions.sql`): no blockers, one SHOULD-FIX.** I read the code only. Nothing was built or run.

1. **OK: positions ≤ mapped tokens + `TSL_ADDPOS`.**
   - `prs->pos` goes up once per non-NULL `LexizeExec` result (ts_parse.c:404) and once per lexeme carrying `TSL_ADDPOS` (:434-435). In core, only the thesaurus sets that flag (dict_thesaurus.c:561).
   - Every result uses up at least one mapped token from the head of the work list: `RemoveHead` at :239, or `moveToWaste` at :319/:324.
   - `FTS_TOK_MAPPED` (`t > 0 && t < lenmap && map[t].len > 0`) is exactly the negation of the skip test at :195. Type ≤ 0 ends both loops.
   - Unmapped tokens can't change dictionary state. In multi-word mode they are skipped without calling the dictionary (:265-269).
   - Tokens with `lenlemm >= MAXSTRLEN` are dropped before lexize (:382). They are counted but take no position, so the count errs on the safe side.
   - The `type 0` / `isend` flush at the end of a chunk (:292) is the documented limit for a thesaurus phrase that crosses a cut.

2. **OK: the loop terminates and stays in bounds.**
   - `end > start` always holds: a cut must be `> start` (:446), `len > start`, and the fallback moves at least `pg_mblen ≥ 1` byte.
   - The retry halves `budget`, which only resets after a chunk is accepted (:503). So there are at most about 14 retries per chunk.
   - `ref[j - 1]` is safe because the loop requires `j > ti ≥ 0`.
   - `found = true` when `j >= nref` is correct from a verified start: the earlier look-ahead used `w == nref`, `wend = len` and `probe = false`, so the whole rest was checked.

3. **SHOULD-FIX: the "rest fits" shortcut is wrong when `start` is inside a token** (:413-430, :488-500).
   - **Scenario:** a fallback cut lands after a space inside a `<script>` body (one ignore-mode blank token), a tag or a comment. The tail of that token is then read as words, but `mapped` only counts reference tokens that start at or after `start`. So `j >= nref` can make `end = len` even though the chunk overflows.
   - Each halving retry re-parses the whole remainder. If at most one mapped reference token is left (for example 65 kB of script tail and then one word), the chunk is accepted at `budget == 1` with positions capped. That is the 1.14.3 bug again.
   - It is rare, because it needs a fallback first (64 rejected candidates).
   - **Fix:** take `found` only when `ref[ti].off == start`, so a mid-token start drops to the byte rule when `len - start > FTS_PARSE_CHUNK`. Separately, when a chunk overflows at `budget == 1` and is longer than `FTS_PARSE_CHUNK` bytes, cut by bytes instead of accepting the cap.

4. **NIT: the fallback ignores `budget`** (:467, :475).
   - With a parser that gives no token offsets plus a thesaurus, an overflowing fallback chunk is re-parsed unchanged about 14 times and then accepted capped. That is the same result as 1.15.0, just slower.
   - **Fix:** `lim = pg_mbcliplen(..., Min(budget, FTS_PARSE_CHUNK))` and test `len - start > lim`.
   - Taking `end = len` when `!found` and the remainder is ≤ 16,383 bytes is correct. It assumes positions ≤ bytes for the default parser. I believe that holds: hyphenated compounds and URLs give fewer than one position per byte. I did not prove it for every parser state.

5. **NIT: possible repeated large re-parses** (:441-463).
   - Each candidate re-parses the whole chunk and the look-ahead window, and a chunk bounded by positions can be megabytes. The worst case is about 128 parses per chunk, times 14 under thesaurus retries. Total work stays linear in the text size; it is not quadratic overall.
   - Repeated rejections need text like a hyphenated compound longer than the budget, or a custom parser that depends on context. A markup-heavy chunk usually passes on its first candidate, because the boundary token is a word outside ignore state.
   - Parsing can be cancelled: `TParserGet` calls `CHECK_FOR_INTERRUPTS` (wparser_def.c:1714).
   - Unmeasured.

6. **OK: buffers and growth.**
   - `buf`/`sbuf` is `len + 1` and every chunk or window is ≤ `len`.
   - `scratch` and `ref` both grow huge-safe in `fts_raw_tokens`. `check-alloc` passes it: the line contains `repalloc_huge`.
   - NIT: `int *cap *= 2` would overflow past 2^30 entries. That should be out of reach, since tokens ≤ ~bytes < 2^30, but I did not prove it.

7. **NIT: the memory figure in CHANGELOG and at :304.**
   - `sizeof(FtsRawTok)` is 12 (three ints, no padding), and MaxAllocSize/12 = 89,478,485 is correct arithmetic.
   - But capacity doubles from 1024. It goes 2^26 (805 MB) → 2^27 (1.61 GB), so the huge path is first taken at **67,108,865** tokens, not ~89M.
   - The CHANGELOG also leaves out that `scratch` is a second list of the same kind.
   - **Fix:** say "about 67M tokens" and mention both lists.

8. **NIT: stale header comment** (:210-215).
   - It still says "chunks of at most FTS_PARSE_CHUNK bytes … (those still cap, as before)". That is now false: chunks are bounded by positions and an overflow is retried.
   - The line at :215 also runs too long.

9. **Test: deterministic, reasoning only (unverified by execution).**
   - It uses fixed strings and the `simple` config. `client_min_messages = warning` hides the "word is too long" NOTICEs (ts_parse.c:382 fires for the 42 kB script blank and the 30 kB tag) and the DEBUG1 line.
   - Both `lpl` documents reach the chunked path (18,000 > 16,383). The first cut falls in the trailing `w` run, so the chunk holds the whole script or URI.
   - On 1.15.0, document 1 indexes `var`/`zz` (about 24.8k positions, `t`). That agrees with the CHANGELOG's 24,811.
   - **NIT:** for document 2, `quj*` does not distinguish 1.15.0 from the fix. On 1.15.0 the base64 run is a single ASCII word of 2,047 characters or more, so it is dropped as too long. 1.15.0 fails only through doclen (extra `img`, `src`, `data`, … words). Use `'img | src | data'` instead.
   - **NIT (AGENTS rule 9):** `script_words = 0` has no positive control. Add a count of `('v' || g)` with expected 5000.
   - Swapping the old `'var'` probe for the `a<g>` count is a real improvement. The old probe would also have passed on 1.15.0, because a cut after `var ` indexes `a<g>`, not `var`.
   - I did not run the "8 on 1.15.0" or "18,000 / 18,001 now" figures.

Not checked: nothing was executed. The CHANGELOG claims that the 32 probes are byte-identical, that the fallback never ran on them, and the 220 ms cost figure are all taken on trust.