-- long_positions (1.15.0, ROADMAP I9): the configured analyzer kept token positions
-- past 16,383.  parsetext() stores each ordinal in a 16-bit field capped at 16,383,
-- so through 1.14.3 every token after the 16,383rd shared one position and a phrase
-- there never matched (PR #12).  Now long text is parsed in chunks under the cap and
-- each chunk's ordinals are offset; a text of one chunk is parsed as before.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
-- the ROADMAP example
SELECT to_ftsdoc('simple', repeat('filler ', 17000) || 'alpha beta') @@@ '"alpha beta"'::ftsquery AS past_cap_phrase,
       to_ftsdoc('simple', repeat('filler ', 17000) || 'alpha beta') @@@ '"beta alpha"'::ftsquery AS past_cap_reversed,
       ftsdoc_length(to_ftsdoc('simple', repeat('filler ', 17000) || 'alpha beta')) AS doclen;
-- a phrase at every offset around the first chunk boundary (16,383 bytes = 2,340
-- 'filler ' words): one of these straddles it, all must match, none reversed (this
-- is below the old cap, so 1.14.3 passes it too: it guards the chunking, not the cap)
SELECT count(*) FILTER (WHERE to_ftsdoc('simple', repeat('filler ', n) || 'alpha beta gamma ' || repeat('filler ', 50))
                          @@@ '"alpha beta gamma"'::ftsquery) AS phrase_ok,
       count(*) FILTER (WHERE to_ftsdoc('simple', repeat('filler ', n) || 'alpha beta gamma ' || repeat('filler ', 50))
                          @@@ '"gamma beta"'::ftsquery) AS reversed_matches,
       count(*) AS offsets
  FROM generate_series(2330, 2350) n;
-- NEAR distance across chunks, and a stemming configuration
SELECT to_ftsdoc('english', repeat('the running dogs ', 6000) || 'quick foxes jumped') @@@ '"quick fox jump"'::ftsquery AS english_past_cap,
       to_ftsdoc('simple', repeat('w ', 20000) || 'alpha x x beta') @@@ 'alpha <3> beta'::ftsquery AS near3,
       to_ftsdoc('simple', repeat('w ', 20000) || 'alpha x x beta') @@@ 'alpha <2> beta'::ftsquery AS near2;
-- the same positions as the unconfigured analyzer for plain words (which never capped)
SELECT to_ftsdoc('simple', repeat('filler ', 17000) || 'alpha beta')::text
     = to_ftsdoc(repeat('filler ', 17000) || 'alpha beta')::text AS same_as_unconfigured;
-- a text over 16 kB but under 16,383 tokens is parsed whole, as 1.14.3 did: an HTML
-- tag with spaces inside it, at every offset around byte 16,383, is a tag (not words)
-- and the value is the same at each offset as the same text without the padding shift
SELECT count(*) FILTER (WHERE to_ftsdoc('english', repeat('filler ', n) || '<a href="zzhref" class="zzclass"> word')
                          @@@ 'zzhref | zzclass'::ftsquery) AS tag_words_indexed,
       count(DISTINCT ftsdoc_length(to_ftsdoc('english', repeat('filler ', n) || '<a href="zzhref" class="zzclass"> word')) - n) AS doclen_shapes,
       count(*) AS offsets
  FROM generate_series(2330, 2350) n;
-- markup over 16,383 tokens (1.15.1, ROADMAP I9a): 1.15.0 cut the re-parse after any
-- whitespace, so a tag, comment or <script> body straddling a cut was read as words
-- (tag attribute names indexed, positions shifted).  Cuts are now whole-text parser token
-- boundaries; the values equal an unchunked position-wide parser's.
CREATE TABLE lpm AS
SELECT 1 AS id, string_agg('<a href="x' || g || '" class="c y z"> w' || g || ' v u t ', '') AS t FROM generate_series(1, 5000) g
UNION ALL SELECT 2, string_agg('<!-- a comment with spaces ' || g || ' --> b' || g || ' c d e ', '') FROM generate_series(1, 5000) g
UNION ALL SELECT 3, string_agg('<script>var a' || g || ' = 1;</script> v' || g || ' w x y <style>.c{x:y}</style> ', '') FROM generate_series(1, 5000) g;
ALTER TABLE lpm ADD COLUMN d ftsdoc;
UPDATE lpm SET d = to_ftsdoc('simple', t);
SELECT id, ftsdoc_length(d) AS doclen,
       d @@@ 'href | class'::ftsquery AS tag_words,
       d @@@ 'comment | spaces'::ftsquery AS comment_words
  FROM lpm ORDER BY id;
-- script bodies: none of the 5,000 identifiers inside <script> is indexed, every one of
-- the 5,000 words after it is (the positive control)
SELECT count(*) FILTER (WHERE d @@@ ('a' || g)::ftsquery) AS script_words,
       count(*) FILTER (WHERE d @@@ ('v' || g)::ftsquery) AS visible_words
  FROM lpm, generate_series(1, 5000) g WHERE id = 3;
-- markup longer than a chunk: a 40 kB <script> body and a 30 kB data: URI take no
-- positions, so the chunk holds them whole (the first review version cut inside the
-- script and indexed its contents: 28,500 positions instead of 18,000)
CREATE TABLE lpl AS
SELECT 1 AS id, repeat('w ', 9000) || '<script>' || repeat('var zz = 1; ', 3500) || '</script>' || repeat(' w', 9000) AS t
UNION ALL SELECT 2, repeat('w ', 9000) || '<img src="data:image/png;base64,' || repeat('QUJD', 7500) || '"> tail' || repeat(' w', 9000);
SELECT id, ftsdoc_length(to_ftsdoc('simple', t)) AS doclen,
       to_ftsdoc('simple', t) @@@ 'zz | var | img | src | data'::ftsquery AS markup_words
  FROM lpl ORDER BY id;
DROP TABLE lpl;
-- a phrase across every tag (positions not shifted): all 4,999
SELECT count(*) AS cross_tag_phrases FROM lpm, generate_series(1, 4999) g
 WHERE id = 1 AND d @@@ ('"t w' || (g + 1) || '"')::ftsquery;
DROP TABLE lpm;
-- a short text is unchanged (one chunk): the output of 1.14.3
SELECT to_ftsdoc('english', 'The quick brown fox jumps over the lazy dog; the dog sleeps.');
-- through an index with positions: a ranked phrase query past the cap
CREATE TABLE lp (id int, d ftsdoc);
INSERT INTO lp SELECT g, to_ftsdoc('simple', repeat('filler ', 17000) || CASE WHEN g % 2 = 0 THEN 'alpha beta' ELSE 'beta alpha' END)
  FROM generate_series(1, 6) g;
CREATE INDEX lp_fts ON lp USING fts (d) WITH (positions = on);
SET enable_seqscan = off;
SELECT array_agg(id ORDER BY id) AS phrase_rows FROM lp WHERE d @@@ '"alpha beta"'::ftsquery;
RESET enable_seqscan;
DROP TABLE lp;
