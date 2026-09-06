# Language-encoding review (2026-09-06)

Audit of pg_fts against the range of server encodings and locales PostgreSQL
users actually run. One genuine correctness bug found and fixed, one latent
robustness gap hardened, and the remaining behaviours characterised so the
contract is explicit rather than accidental.

## Method

Empirical, not code-reading: initdb'd real clusters per encoding/locale on EC2
and compared pg_fts against PostgreSQL's own `to_tsvector` on identical bytes.
Probe characters were supplied as `convert_from('\x..'::bytea, ENC)` so the test
material is exact and the test files stay pure ASCII.

## BUG FOUND AND FIXED: no case folding of non-ASCII on non-UTF-8 servers

`fold_token()` had two branches: UTF-8 (per-code-point Unicode lowercasing) and
everything else. The non-UTF-8 branch folded ASCII bytes and **passed every byte
>= 0x80 through unchanged**. Consequence: on any non-UTF-8 server encoding,
upper- and lower-case accented letters were DIFFERENT terms, so
case-insensitive search silently failed for all non-ASCII text.

Measured on LATIN1 with a real German locale (`de_DE.iso88591`), document
`Äpfel` (A-umlaut 0xC4) vs query `äpfel` (a-umlaut 0xE4):

| | doc term | query term | match |
|---|---|---|---|
| pg_fts BEFORE | `Äpfed` (0xC4) | `äpfed` (0xE4) | **false** |
| PostgreSQL `to_tsvector` | `äpfed` (0xE4) | `äpfed` (0xE4) | true |
| **pg_fts AFTER** | **`äpfed` (0xE4)** | `äpfed` (0xE4) | **true** |

So we diverged from PostgreSQL's own text search on exactly the deployments
most likely to be non-UTF-8: European LATIN1/WIN1252 databases.

**Fix:** the non-UTF-8 branch now delegates to `str_tolower(src, len,
DEFAULT_COLLATION_OID)` — the same locale/collation-aware primitive tsearch's
`lowerstr()` uses — so pg_fts produces byte-identical output to `to_tsvector` on
these servers. `str_tolower()` is not guaranteed length-preserving, so its result
is taken directly rather than folded in place.

## Behaviour under locale C is unchanged, and that is correct

On LATIN1/WIN1252 with `--locale C`, pg_fts still does NOT fold high bytes — and
neither can it: the C library has no case mapping for them under the C locale.
Note what PostgreSQL does there: `to_tsvector('simple', 'Äpfel')` yields `pfed`
— it "matches" only by **discarding the accented character entirely** (its parser
does not treat 0xC4/0xE4 as word characters under C). pg_fts preserves the
character instead, which loses less information. So under locale C the two
engines differ deliberately, and pg_fts's behaviour is the more conservative one.

This is now the documented contract: **non-ASCII case folding on a non-UTF-8
server follows the database locale, exactly as PostgreSQL's text search does.**

## HARDENED: unbounded read in the UTF-8 folding loop

The UTF-8 branch did:

```c
while (srcp < srcend) {
    int clen = pg_utf_mblen(srcp);
    pg_wchar lc = unicode_lowercase_simple(utf8_to_unicode(srcp));  /* reads clen bytes */
    ...
}
```

with **no check that `srcp + clen <= srcend`**. If a token's trailing character
were truncated, `utf8_to_unicode()` would read past the token.

Not currently reachable: `is_token_byte()` treats every byte >= 0x80 as a token
byte, so the tokenizer never splits a well-formed UTF-8 character, and pg_fts
imposes no term-length cap that could truncate one. It was therefore a latent
gap, not an active bug — but the bound is one comparison, so it is now explicit
(`if (srcp + clen > srcend) break;`).

## Verified as already correct

- **Install SQL is pure ASCII** — `make check-ascii` gates it, so
  `CREATE EXTENSION` succeeds on any server encoding. (Historically a UTF-8
  ellipsis in an `fts_snippet` default broke this; the gate exists because of
  that.)
- **Multibyte encodings**: EUC_JP round-trips (JIS X 0208 kanji), including the
  trap where a multibyte character's trailing byte falls in the ASCII range.
  Covered by `t/004_encodings.pl`.
- **UTF-8 multi-script**: covered by `sql/pg_fts.sql` + `sql/unicode_fold.sql`.
- **regconfig path**: `to_ftsdoc(regconfig, text)` delegates to PostgreSQL's
  encoding-aware `parsetext()`, so it was never affected by the fold bug.

## Test coverage added

`t/004_encodings.pl` gains a LATIN1 + ISO-8859-1-locale case asserting that an
upper-case accented document matches a lower-case query. It skips cleanly when
the host has no ISO-8859-1 locale (nix sandbox), and **runs for real on EC2**
where 121 such locales exist — verified: 15 tests pass there, and the
`enc_fold` cluster is genuinely created (not skipped).

Note the pre-existing LATIN1 probes only asserted exact-case round-trips
(`café` matching `café`), which is precisely why this bug survived: nothing
tested `CAFÉ` against `café`.

## Not changed (deliberate)

- **Stemming/stopwords** remain the caller's choice via `regconfig`
  (`to_ftsdoc('english', …)` stems; the no-config form only folds case). This is
  the documented split and matches `to_tsvector` vs `to_tsvector(config, …)`.
- **Client encoding** needs nothing: PostgreSQL converts to the server encoding
  before any pg_fts function sees a `text` datum.
- **ICU collations** are not consulted; `str_tolower` with the database default
  collation is what tsearch uses, and matching tsearch is the goal.
