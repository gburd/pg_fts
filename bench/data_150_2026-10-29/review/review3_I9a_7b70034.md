# Review of the 1.15.1 fix 7b70034 (independent sub-agent, read-only)

Verbatim. Items 2, 4, 5, 6 (position-bounded chunks), 8, 9, 10, 11 (overflow retry), 12, 13 addressed in 057fcc5.

I found no BLOCKER. On the default parser the fix is exact: when a verified cut is found, each chunk's tokens are checked byte-for-byte against the whole-text pass, so a chunk is only parsed alone when that reproduces those tokens. There are three SHOULD-FIX items: the CHANGELOG cites a results file that is not in the tree, it says markup is "never split" when it can be, and a memory change makes very large texts fail that 1.15.0 handled.

I did not build or run anything. The test outcomes in item 9 are inferred from the archived 1.15.0 logs and from reading the code. Line numbers are from `git show 7b70034:pg_fts_tsanalyze.c`.

1. **OK — the parser contract and buffer reuse (`pg_fts_tsanalyze.c:271-306`, `:316-333`, `:374-376`).**
   - `prsd_start` → `TParserInit` (wparser_def.c:288) stores `str` and `len` and reads only `[0, len)`. It does not need a trailing NUL, never writes to the input, and returns `p->token = p->str + posbyte`, so tokens point into `buf`.
   - `*tlen = lenbytetoken` is a length in bytes. parsetext also treats `lenlemm` as bytes, so the API is bytes for every parser.
   - `prsend` → `TParserClose` frees the state stack, the `wstr`/`pgwstr` copies and the parser itself. It is called on the early-break path too (`:304`).
   - `ref[]` holds only offsets, and the parser is closed before `buf` is reused as `sbuf` (`:323`) or by `fts_parse_into`. Both copy from `str`, not from `buf`. Copies stay within `len + 1`, since `to` and `wend` are ≤ `len`. No pointers into `buf` stay live.

2. **NIT — the pointer validity check (`:289`).** `lemm + lenlemm > buf + len` builds a pointer from an integer the parser handed back before checking it, which is exactly what AGENTS rule 16 forbids. Fix: check in the integer domain, `lemm < buf || lemm > buf + len || lenlemm < 0 || lenlemm > (buf + len) - lemm`.

3. **OK — the cut-selection loop (`:399-424`).**
   - `ref[j+1]` is guarded by `j + 1 < nref` (`:401`).
   - The candidate loop requires `j > ti`, so `ref[j]` is always in range.
   - If `ti == nref`, or the first token after `start` is past `start + lim`, no candidate is tried and the code falls back.
   - `cut <= start` breaks out (`:409`); otherwise the cut moves forward, and the fallback always moves forward too. It cannot loop forever.
   - `cut = ref[j].off ≤ start + lim ≤ start + 16,383` holds for any token order, so the byte bound is kept.
   - `wend` is a whole-text token start, or `len` for the tail, which is fine because that pass is parser-only.
   - The verification is exact: lengths are compared, so any reference token that straddles the cut (a hyphenated compound, a URL with its host) is rejected. The "none dropped" check (`:332`) is correct.

4. **NIT — duplicate offsets (`:403-405`).** The default parser emits tokens at the same offset: a hyphenated compound and its first part, or a URL and its host. A candidate `j` with `ref[j-1].off == cut` is either rejected by the look-ahead, wasting one of the 64 tries, or makes the next chunk fail its own check and fall back. Fix: `if (ref[j-1].off == cut) continue;`, so only the first token at an offset is tried.

5. **NIT — the look-ahead's own end (`:412-416`).** The window is parsed as if the text ended at `wend`. When `wend` lands inside a compound or a URL, its last token comes out different and a good cut is rejected. When `w == j`, `wend` is an arbitrary byte cut. Neither can produce wrong output, only extra tries or a fallback. Fix: ignore mismatches on window tokens whose reference token extends past `wend`.

6. **SHOULD-FIX — markup longer than the look-ahead is still split (`:403-439`, CHANGELOG).** No token starts inside a `<script>`/`<style>` body, a comment, or a tag of more than about 16 KB, so no cut there can be verified.
   - What happens: the cut moves to just before the element. The next chunk then has only rejected candidates, falls back to the 1.15.0 rule, and indexes the body as words.
   - How common: inline scripts and styles over 16 KB, and large `data:` URIs inside tags, are common in real HTML. None of the 28 probes contained one.
   - Correctness is not the issue here; a body this long gets the 1.15.0 behaviour. The CHANGELOG sentence "A tag or comment is one token, so it is never split" overclaims.
   - Doc fix: state the limit, roughly "markup elements under about 16 KB".
   - Code fix: limit a chunk by positions, not bytes. Only token types with `cfg->map[type].len > 0` produce positions, so a script body produces none and can sit whole inside one chunk. This would also remove the "a token is at least one byte" assumption (item 11).
   - Also: nothing reports when the fallback is used. A `DEBUG1` message or a counter would make it visible.

7. **OK — is matching tokens enough for parsetext to match? (`:441`)** For one-token-at-a-time dictionaries, yes: parsetext's output depends only on the token stream plus the dictionary state (ts_parse.c:355-449). The `MAXSTRLEN` skip also works per token.
   - The chunk is checked on exactly the bytes parsetext will receive: the same `[start, cut)` copy with a NUL.
   - The only state the default parser carries from one token to the next is `prs->ignore`. `wanthost` is reset inside a single token. So the look-ahead is a heuristic for choosing the next cut, not what makes the output correct.
   - Remaining gap, already documented: a thesaurus phrase across a cut. Because 1.15.1 cuts at different places from 1.15.0, a thesaurus configuration can give different values from 1.15.0 even on plain text. The CHANGELOG line "values from plain text are unchanged" should say "except thesaurus configurations".

8. **SHOULD-FIX — memory (`:365`, `:296-297`).**
   - Each reference entry is 12 bytes and the array doubles with plain `repalloc`. Growing from 2^26 to 2^27 entries asks for 1.6 GB, which is over `MaxAllocSize` and raises an ERROR once a text passes 67,108,864 raw tokens.
   - Blank tokens count, so plain text has about 2 tokens per word: the error comes at about 33.5M words.
   - 1.15.0's own limit was `prs.words`, 24 bytes per word, which fails at about 44.7M words. Texts between roughly 33.5M and 44.7M words (about 200-300 MB) worked on 1.15.0 and now fail. The memory peak is also up by about 0.8 GB at that size.
   - The `alloc-ok: palloc-bounded` comment hides this regression.
   - Minimal fix: `FTS_REALLOC_MAYBE_HUGE`.
   - Better fix: read the whole-text parser lazily and keep only tokens in `[start, start + 2 × 16 KB]`. Its offsets only ever increase, so the memory becomes proportional to the window.
   - Separate, and not a regression: `TParserInit` allocates the wide-character copy of the whole text with plain `palloc`, as the first parsetext pass already did.

9. **NIT — the regression test (`sql/long_positions.sql`).** It fails on 1.15.0: the archived i9cmp2/i9cmp4 logs, run under `simple`, show doclen 20,077 / 20,045 / 20,019, `class` indexed, and 4,988 of 4,999 phrases.
   - Unverified: whether `'comment | spaces'` and `'var'` are true on 1.15.0. The 1.15.0 diff for doc 3 shows `a1256` and `1` leaking but not `var`, which may sit before the cut. Only doclen and the phrase count reliably separate the two versions.
   - Fix for doc 3: count `d @@@ ('a'||g)::ftsquery` over `g = 1..5000` and expect 0.
   - The test is deterministic: the input is ASCII, so locale and encoding do not matter.
   - Speed is unmeasured. The 4,999 phrase checks may decompress the stored value on every call, which could take seconds.
   - Gaps: no test reaches the fallback (for example a 40 KB `<script>`), and `english` is not tested.

10. **NIT — cost.** The happy path is about 5 parser passes against 2 in 1.15.0, which fits the measured 1.8x. The worst case is 64 tries × 2 parses of about 16 KB each per chunk, about 128x the parse volume.
    - That is linear when each chunk moves forward about 16 KB. If accepted cuts sit near `start`, it gets worse; I could not build an input that does this.
    - After a fallback cut that lands mid-token, every candidate in the next chunk fails on its first token: 64 wasted chunk parses. Fix: when the chunk's first token does not match `ref[ti]`, give up on the candidates at once.
    - The CHANGELOG timing covers only friendly documents. A fallback-heavy document is unmeasured.

11. **NIT — positions per chunk (`:441`; the assumption is from 1.15.0).** The bound "at most 16,383 bytes, so at most 16,383 positions" assumes less than one position per byte. On the default parser overlapping tokens peak at about 3/4: `a-b ` gives a compound plus two parts in 4 bytes. That is unverified exhaustively, and a custom parser could exceed it, in which case `LIMITPOS` silently caps the positions. Fix: check `prs->pos` per chunk in `fts_parse_into` and warn or re-cut when it exceeds `MAXENTRYPOS - 1`.

12. **SHOULD-FIX — the CHANGELOG cites evidence that is not in the tree.**
    - `bench/RESULTS_151_2026-10-29.md` exists neither at 7b70034 nor at HEAD, and has no line in `bench/INDEX.md`.
    - The "28 of 28 byte-identical on 1.15.1" claim and the 137.8 → 247.3 ms timing have no archived script or log. `bench/.../i9cmp/*.log` are the 1.15.0 runs only.
    - This breaks AGENTS rules 1 and 24. Add the file before tagging, or drop the claims.

13. **NIT — CHANGELOG wording.**
    - "PostgreSQL changed it inside both minor series": `ts_parse.c` (parsetext) has no commits between REL_17_0 and REL_17_10. The 17.x change was in `wparser_def.c` (the `pg_mblen_range` bounds check), which vendoring parsetext would not copy. The 18.x change (e251350573e, the per-lexeme length check) is between REL_18_0 and REL_18_6; I did not check which 18.x minor first shipped it.
    - "documents over 16,383 tokens" means over 16,383 positions.

Not checked: other callers of `fts_analyze_with_config`, and whether a custom parser returns offsets out of order. In that case the loop still keeps the byte bound and the verification falls back; it does not give wrong output. No severity above SHOULD-FIX applies.