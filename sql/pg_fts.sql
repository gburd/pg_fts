CREATE EXTENSION pg_fts VERSION '0.3.4';

-- ftsdoc: analysis, output shows terms with term frequencies
SELECT to_ftsdoc('The quick brown fox, the QUICK fox!');
SELECT 'the quick brown fox'::ftsdoc;
SELECT to_ftsdoc('');                       -- empty doc
SELECT ftsdoc_length(to_ftsdoc('a b c a b a'));  -- doclen counts tokens

-- ftsquery: parsing and canonical output
SELECT 'quick & brown'::ftsquery;
SELECT 'quick | brown'::ftsquery;
SELECT '!slow'::ftsquery;
SELECT 'quick brown fox'::ftsquery;          -- implicit AND
SELECT to_ftsquery('(quick OR slow) AND fox');
SELECT to_ftsquery('quick and not slow');    -- keyword operators
SELECT 'QUICK'::ftsquery;                     -- folding

-- syntax errors
SELECT 'quick &'::ftsquery;                   -- dangling operator
SELECT '(quick'::ftsquery;                     -- unbalanced paren

-- @@@ match operator
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick'::ftsquery;         -- t
SELECT to_ftsdoc('the quick brown fox') @@@ 'slow'::ftsquery;          -- f
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick & fox'::ftsquery;   -- t
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick & slow'::ftsquery;  -- f
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick | slow'::ftsquery;  -- t
SELECT to_ftsdoc('the quick brown fox') @@@ '!slow'::ftsquery;         -- t
SELECT to_ftsdoc('the quick brown fox') @@@ '!fox'::ftsquery;          -- f
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick & !slow'::ftsquery; -- t

-- commutator form
SELECT 'quick'::ftsquery @@@ to_ftsdoc('the quick brown fox');         -- t

-- empty query matches nothing
SELECT to_ftsdoc('anything') @@@ ''::ftsquery;                         -- f

-- end-to-end: WHERE on a table, sequential scan
CREATE TABLE docs (id int, body text);
INSERT INTO docs VALUES
  (1, 'the quick brown fox'),
  (2, 'a slow green turtle'),
  (3, 'quick turtles are rare'),
  (4, 'brown bears and quick foxes');

SELECT id FROM docs
WHERE to_ftsdoc(body) @@@ 'quick & !turtle'::ftsquery
ORDER BY id;

SELECT id FROM docs
WHERE to_ftsdoc(body) @@@ '(quick | slow) & !fox'::ftsquery
ORDER BY id;

-- binary send/recv round-trip is exercised by COPY BINARY in the framework;
-- here just confirm send produces bytea without error.
SELECT octet_length(ftsdoc_send(to_ftsdoc('round trip test'))) > 0 AS ftsdoc_send_ok;
SELECT octet_length(ftsquery_send('a & (b | !c)'::ftsquery)) > 0 AS ftsquery_send_ok;

-- adversarial / edge cases: must not crash; must parse or error cleanly
SELECT to_ftsquery(repeat('(', 100) || 'a' || repeat(')', 100)) IS NOT NULL AS deep_nesting_ok;
SELECT '!!!!a'::ftsquery;                -- stacked NOT
SELECT '(((a)))'::ftsquery;              -- redundant parens
SELECT to_ftsquery('   ')::text AS whitespace_only;   -- empty query
SELECT to_ftsquery('a & & b');           -- double operator -> error
SELECT to_ftsquery('a | b & c');         -- precedence: & binds tighter than |
SELECT ftsdoc_length(to_ftsdoc(repeat('word ', 1000))) AS many_repeats_len;

DROP TABLE docs;

-- analyzer reusing an installed text search configuration.

-- english config stems and drops stopwords: 'running the races' -> run, race
SELECT to_ftsdoc('english'::regconfig, 'running the races quickly');
-- stopwords ('the','a','of') are removed by the english dictionary
SELECT to_ftsdoc('english'::regconfig, 'the cat and a dog');
-- doclen counts positions produced by the parser (stopwords still counted)
SELECT ftsdoc_length(to_ftsdoc('english'::regconfig, 'the quick brown fox'));
-- stemming makes a query match across inflections
SELECT to_ftsdoc('english'::regconfig, 'the foxes were running')
       @@@ 'fox & run'::ftsquery AS stemmed_match;

-- BM25 scoring.

-- score is positive when a query term is present, zero when absent
SELECT round(fts_bm25(to_ftsdoc('quick brown fox'), 'fox'::ftsquery,
                      1000, 4.0)::numeric, 4) AS present_gt_0;
SELECT fts_bm25(to_ftsdoc('quick brown fox'), 'turtle'::ftsquery,
                1000, 4.0) AS absent_is_0;

-- length normalization: same tf, longer doc scores lower
SELECT fts_bm25(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, 10.0)
     > fts_bm25(to_ftsdoc('fox ' || repeat('pad ', 40)), 'fox'::ftsquery, 1000, 10.0)
       AS shorter_scores_higher;

-- IDF: a rarer term (low df) contributes more than a common one (high df)
SELECT fts_bm25(to_ftsdoc('rare common'), 'rare'::ftsquery, 1000, 2.0, ARRAY[2.0])
     > fts_bm25(to_ftsdoc('rare common'), 'common'::ftsquery, 1000, 2.0, ARRAY[900.0])
       AS rare_scores_higher;

-- higher term frequency scores higher (saturating)
SELECT fts_bm25(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 3.0)
     > fts_bm25(to_ftsdoc('fox pad pad'), 'fox'::ftsquery, 1000, 3.0)
       AS more_tf_scores_higher;

-- BM25 variants.
-- all variants score presence > absence
SELECT variant,
       fts_bm25_opts(to_ftsdoc('quick fox'), 'fox'::ftsquery,
                     1000, 3.0, 1.2, 0.75, variant, ARRAY[10.0]) > 0 AS positive
FROM unnest(ARRAY['lucene','robertson','atire','bm25+','bm25l']) AS variant
ORDER BY variant;
-- bm25+ >= lucene for the same inputs (delta floor)
SELECT fts_bm25_opts(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, 5.0, 1.2, 0.75, 'bm25+', ARRAY[3.0])
     > fts_bm25_opts(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, 5.0, 1.2, 0.75, 'lucene', ARRAY[3.0])
       AS bm25plus_ge_lucene;
-- bm25l (rank_bm25 compatible: delta shift on the length-normalized tf) scores
-- a present term positively and 'l' is an accepted alias for it
SELECT fts_bm25_opts(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 5.0, 1.5, 0.75, 'bm25l', ARRAY[3.0]) > 0 AS bm25l_positive,
       fts_bm25_opts(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 5.0, 1.5, 0.75, 'bm25l', ARRAY[3.0])
     = fts_bm25_opts(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 5.0, 1.5, 0.75, 'l', ARRAY[3.0]) AS l_alias;
-- unknown variant errors
SELECT fts_bm25_opts(to_ftsdoc('x'), 'x'::ftsquery, 10, 1.0, 1.2, 0.75, 'bogus');

-- highlight and snippet.
SELECT fts_highlight('The quick brown fox jumped', 'quick | fox'::ftsquery,
                     '[', ']');
SELECT fts_snippet(
  'lorem ipsum dolor the quick brown fox jumps over the lazy dog etcetera etc',
  'quick & fox'::ftsquery, '<', '>', '...', 6);
-- no match: highlight returns the text unchanged
SELECT fts_highlight('nothing here matches', 'zebra'::ftsquery, '[', ']');

-- migration from tsquery.
-- boolean operators convert directly
SELECT tsquery_to_ftsquery('quick & brown'::tsquery);
SELECT tsquery_to_ftsquery('quick | brown'::tsquery);
SELECT tsquery_to_ftsquery('!slow & quick'::tsquery);
SELECT tsquery_to_ftsquery('(a | b) & !c'::tsquery);
-- phrase operator <-> converts faithfully to an ftsquery phrase
SELECT tsquery_to_ftsquery('quick <-> brown'::tsquery);
-- the tsquery -> ftsquery cast makes existing queries usable with @@@
SELECT to_ftsdoc('the quick brown fox') @@@ ('quick & fox'::tsquery)::ftsquery
       AS migrated_match;

-- prefix queries (term*).
SELECT 'quick*'::ftsquery;                        -- renders with the star
SELECT to_ftsdoc('the quicksand shifts') @@@ 'quick*'::ftsquery AS prefix_hit;
SELECT to_ftsdoc('slow and steady') @@@ 'quick*'::ftsquery AS prefix_miss;
SELECT to_ftsdoc('quick brown fox') @@@ 'qu* & fo*'::ftsquery AS prefix_and;
-- prefix works through the fts index too
CREATE TABLE pfx (id serial, d ftsdoc);
INSERT INTO pfx (d) VALUES (to_ftsdoc('quicksand')), (to_ftsdoc('quiche')),
                          (to_ftsdoc('slow'));
CREATE INDEX pfx_bm25 ON pfx USING fts (d);
SET enable_seqscan = off;
SELECT id FROM pfx WHERE d @@@ 'qui*'::ftsquery ORDER BY id;
RESET enable_seqscan;
DROP TABLE pfx;

-- index-maintained corpus statistics for BM25.
CREATE TABLE corpus (id serial, d ftsdoc);
INSERT INTO corpus (d)
SELECT to_ftsdoc('common ' || CASE WHEN g % 10 = 0 THEN 'rare' ELSE 'filler' END)
FROM generate_series(1, 100) g;
CREATE INDEX corpus_bm25 ON corpus USING fts (d);
-- stats reflect the corpus: 100 docs
SELECT ndocs, nterms FROM fts_index_stats('corpus_bm25');
-- 'rare' (df=10) scores higher than 'common' (df=100) using index df
SELECT fts_index_df('corpus_bm25', 'rare'::ftsquery) AS df_rare,
       fts_index_df('corpus_bm25', 'common'::ftsquery) AS df_common;
SELECT (SELECT fts_bm25(to_ftsdoc('common rare'), 'rare'::ftsquery,
                        s.ndocs, s.avgdl, fts_index_df('corpus_bm25', 'rare'::ftsquery)))
     > (SELECT fts_bm25(to_ftsdoc('common rare'), 'common'::ftsquery,
                        s.ndocs, s.avgdl, fts_index_df('corpus_bm25', 'common'::ftsquery)))
       AS rare_outranks_common
FROM fts_index_stats('corpus_bm25') s;
DROP TABLE corpus;

-- incremental index maintenance (pending list).
CREATE TABLE inc (id serial, d ftsdoc);
INSERT INTO inc (d) VALUES (to_ftsdoc('alpha beta')), (to_ftsdoc('gamma delta'));
CREATE INDEX inc_bm25 ON inc USING fts (d);
SET enable_seqscan = off;
-- rows present at build time are found via the main structure
SELECT id FROM inc WHERE d @@@ 'alpha'::ftsquery ORDER BY id;
-- INSERT after build must be immediately visible (no REINDEX) via pending list
INSERT INTO inc (d) VALUES (to_ftsdoc('alpha epsilon')), (to_ftsdoc('zeta'));
SELECT id FROM inc WHERE d @@@ 'alpha'::ftsquery ORDER BY id;   -- 1 and 3
SELECT id FROM inc WHERE d @@@ 'zeta'::ftsquery ORDER BY id;     -- 4 (pending only)
SELECT id FROM inc WHERE d @@@ 'alpha & !beta'::ftsquery ORDER BY id;  -- 3
-- ndocs reflects built + pending
SELECT ndocs FROM fts_index_stats('inc_bm25');
-- REINDEX merges pending into the main structure; results unchanged
REINDEX INDEX inc_bm25;
SELECT id FROM inc WHERE d @@@ 'alpha'::ftsquery ORDER BY id;
RESET enable_seqscan;
DROP TABLE inc;

-- quoted phrase queries via per-term positions.
-- phrase renders with <-> and round-trips
SELECT '"quick brown fox"'::ftsquery;
-- adjacency is enforced: "quick brown" matches, "quick fox" does not
SELECT to_ftsdoc('the quick brown fox') @@@ '"quick brown"'::ftsquery AS adj_hit;
SELECT to_ftsdoc('the quick brown fox') @@@ '"quick fox"'::ftsquery AS adj_miss;
SELECT to_ftsdoc('the quick brown fox') @@@ '"brown fox"'::ftsquery AS adj_hit2;
-- word order matters: "fox brown" does not match "...brown fox"
SELECT to_ftsdoc('the quick brown fox') @@@ '"fox brown"'::ftsquery AS order_miss;
-- three-word phrase
SELECT to_ftsdoc('the quick brown fox jumps') @@@ '"quick brown fox"'::ftsquery AS three_hit;
SELECT to_ftsdoc('quick red brown fox') @@@ '"quick brown fox"'::ftsquery AS three_miss;
-- phrase combined with boolean operators
SELECT to_ftsdoc('the quick brown fox') @@@ '"quick brown" & fox'::ftsquery AS combo;
-- phrase works through the fts index (recheck enforces adjacency)
CREATE TABLE ph (id serial, d ftsdoc);
INSERT INTO ph (d) VALUES (to_ftsdoc('quick brown fox')),
                          (to_ftsdoc('brown quick fox')),
                          (to_ftsdoc('quick brown bear'));
CREATE INDEX ph_bm25 ON ph USING fts (d);
SET enable_seqscan = off;
SELECT id FROM ph WHERE d @@@ '"quick brown"'::ftsquery ORDER BY id;   -- 1 and 3
RESET enable_seqscan;
DROP TABLE ph;

-- regconfig analyzer must also carry positions so phrase/NEAR enforce
-- adjacency (v0.2.1 bug: to_ftsdoc(regconfig,text) stored no positions, so
-- phrases silently degraded to AND).  'simple' config: no stemming/stopwords,
-- positions map 1:1 to input words.
-- adjacent phrase matches
SELECT to_ftsdoc('simple'::regconfig, 'quick brown fox')
       @@@ to_ftsquery('simple'::regconfig, '"quick brown"') AS cfg_adj_hit;   -- t
-- non-adjacent must NOT match (was t before the fix -- the bug -- now f)
SELECT to_ftsdoc('simple'::regconfig, 'quick red slow brown')
       @@@ to_ftsquery('simple'::regconfig, '"quick brown"') AS cfg_nonadj_miss; -- f
-- three-word phrase: only consecutive matches
SELECT to_ftsdoc('simple'::regconfig, 'a b c')
       @@@ to_ftsquery('simple'::regconfig, '"a b c"') AS cfg_three_hit;   -- t
SELECT to_ftsdoc('simple'::regconfig, 'a x b c')
       @@@ to_ftsquery('simple'::regconfig, '"a b c"') AS cfg_three_miss;  -- f
-- repeated term at non-sequential positions: "quick" at pos 1 and 3; the
-- per-term position list must be ascending [1,3] for phrase_step to work
SELECT to_ftsdoc('simple'::regconfig, 'quick brown quick fox')
       @@@ to_ftsquery('simple'::regconfig, '"quick brown"') AS cfg_rep_hit;   -- t
SELECT to_ftsdoc('simple'::regconfig, 'quick brown quick fox')
       @@@ to_ftsquery('simple'::regconfig, '"quick fox"') AS cfg_rep_hit2;    -- t
-- NEAR on the regconfig analyzer: within k true, beyond k false
SELECT to_ftsdoc('simple'::regconfig, 'quick brown red fox')
       @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick fox, 3)') AS cfg_near_hit;  -- t
SELECT to_ftsdoc('simple'::regconfig, 'quick brown red fox')
       @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick fox, 2)') AS cfg_near_miss; -- f
-- index-backed phrase on a regconfig-analyzed column: recheck must exclude
-- non-adjacent docs
CREATE TABLE phc (id serial, d ftsdoc);
INSERT INTO phc (d) VALUES
  (to_ftsdoc('simple'::regconfig, 'quick brown fox')),      -- 1: adjacent
  (to_ftsdoc('simple'::regconfig, 'quick red slow brown')), -- 2: not adjacent
  (to_ftsdoc('simple'::regconfig, 'quick brown bear'));     -- 3: adjacent
CREATE INDEX phc_bm25 ON phc USING fts (d);
SET enable_seqscan = off;
SELECT id FROM phc WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY id;   -- 1 and 3 only
RESET enable_seqscan;
DROP TABLE phc;

-- phrase adjacency must hold on a STORED (column-resident) ftsdoc that is long
-- enough for its positions[] region to land at a non-MAXALIGN'd byte offset.
-- Regression for the FTS_DOC_POSITIONS alignment bug: the accessor used
-- MAXALIGN() of an absolute pointer, which mismatched the analyzer's
-- offset-based layout once a detoasted/heap-read doc sat at a non-MAXALIGN'd
-- address -- positions[] then pointed at garbage and phrase/NEAR silently
-- degraded to AND on every stored ftsdoc (the short-doc tests above happened to
-- land aligned and did not catch it).  Each doc below has repeated filler terms
-- (so tf>1, several positions) plus the phrase at the end; the count must be
-- exactly the adjacent docs, not the larger AND-set.
CREATE TABLE phlong (id int, body text, d ftsdoc);
INSERT INTO phlong(id, body)
SELECT g,
       (SELECT string_agg('flr' || (s % 5), ' ') FROM generate_series(1, 17 + g) s)
       || CASE WHEN g % 2 = 0 THEN ' united states'          -- adjacent
               ELSE ' united middle states' END              -- not adjacent
FROM generate_series(1, 8) g;
UPDATE phlong SET d = to_ftsdoc('simple'::regconfig, body);
-- stored-column adjacency: exactly the even ids (the adjacent phrase)
SELECT id FROM phlong
WHERE d @@@ to_ftsquery('simple'::regconfig, '"united states"') ORDER BY id;   -- 2,4,6,8
-- and the stored value must agree with a fresh re-analysis of the same body
SELECT bool_and(
         (d @@@ to_ftsquery('simple'::regconfig, '"united states"'))
         = (to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"'))
       ) AS stored_matches_fresh FROM phlong;   -- t
DROP TABLE phlong;

-- external-content indexing via an expression index.
-- The bm25 index stores only postings (no document text), so indexing
-- to_ftsdoc(body) over a plain text column is the external-content model:
-- the text lives in the table, the index derives ftsdoc from it.
CREATE TABLE articles (id serial, body text);
INSERT INTO articles (body) VALUES
  ('the quick brown fox'),
  ('lazy dogs sleep'),
  ('quick foxes are clever');
CREATE INDEX articles_bm25 ON articles USING fts (to_ftsdoc(body));
SET enable_seqscan = off;
-- query against the expression index; text is fetched from the table only
-- for returned rows
SELECT id, body FROM articles
WHERE to_ftsdoc(body) @@@ 'quick'::ftsquery ORDER BY id;
SELECT id FROM articles
WHERE to_ftsdoc(body) @@@ '"quick brown"'::ftsquery ORDER BY id;
RESET enable_seqscan;
DROP TABLE articles;

-- fuzzy (term~k) and regex (/re/) queries.
-- fuzzy: 'quick'~1 matches 'quikc'? no (2 edits); matches 'quic' (1 delete)
SELECT to_ftsdoc('the quic brown fox') @@@ 'quick~1'::ftsquery AS fuzzy_hit;
SELECT to_ftsdoc('the slow green turtle') @@@ 'quick~1'::ftsquery AS fuzzy_miss;
-- default k is 2: 'kwik' is 3 edits from 'quick', so 'quick~' (k=2) misses
SELECT to_ftsdoc('kwik search') @@@ 'quick~'::ftsquery AS fuzzy_default_k;
-- fuzzy renders with ~k
SELECT 'color~2'::ftsquery;
-- regex: /^qu/ matches a term starting with qu
SELECT to_ftsdoc('the quick brown fox') @@@ '/^qu/'::ftsquery AS regex_hit;
SELECT to_ftsdoc('lazy dog') @@@ '/^qu/'::ftsquery AS regex_miss;
-- regex renders with slashes
SELECT '/ab.*cd/'::ftsquery;
-- fuzzy combined with boolean
SELECT to_ftsdoc('the quic brown fox') @@@ 'quick~1 & fox'::ftsquery AS combo;
-- fuzzy/regex work through the fts index (recheck applies the exact test)
CREATE TABLE fz (id serial, d ftsdoc);
INSERT INTO fz (d) VALUES (to_ftsdoc('quick')), (to_ftsdoc('quic')),
                          (to_ftsdoc('slow'));
CREATE INDEX fz_bm25 ON fz USING fts (d);
SET enable_seqscan = off;
SELECT id FROM fz WHERE d @@@ 'quick~1'::ftsquery ORDER BY id;   -- 1 and 2
SELECT id FROM fz WHERE d @@@ '/^qu/'::ftsquery ORDER BY id;      -- 1 and 2
RESET enable_seqscan;
DROP TABLE fz;

-- BM25F: multi-field weighting.
-- a term in the (heavily weighted) title scores higher than the same term in
-- only the body
SELECT fts_bm25f(ARRAY[to_ftsdoc('postgres'), to_ftsdoc('other text here')],
                'postgres'::ftsquery, ARRAY[5.0, 1.0], 1000, ARRAY[2.0, 3.0], ARRAY[10.0])
     > fts_bm25f(ARRAY[to_ftsdoc('other title'), to_ftsdoc('postgres here')],
                'postgres'::ftsquery, ARRAY[5.0, 1.0], 1000, ARRAY[2.0, 3.0], ARRAY[10.0])
       AS title_weight_wins;
-- absent term scores 0
SELECT fts_bm25f(ARRAY[to_ftsdoc('a'), to_ftsdoc('b')],
                'zebra'::ftsquery, ARRAY[2.0, 1.0], 100, ARRAY[1.0, 1.0]) AS absent_zero;
-- a match in either field contributes
SELECT fts_bm25f(ARRAY[to_ftsdoc('nothing'), to_ftsdoc('found fox')],
                'fox'::ftsquery, ARRAY[2.0, 1.0], 100, ARRAY[2.0, 2.0], ARRAY[5.0]) > 0
       AS body_match_scores;
-- mismatched array lengths error
SELECT fts_bm25f(ARRAY[to_ftsdoc('a')], 'a'::ftsquery, ARRAY[1.0,2.0], 10, ARRAY[1.0]);

-- Background merge of the pending list.
CREATE TABLE mrg (id serial, d ftsdoc);
INSERT INTO mrg (d) VALUES (to_ftsdoc('alpha beta'));
CREATE INDEX mrg_bm25 ON mrg USING fts (d);
INSERT INTO mrg (d) VALUES (to_ftsdoc('alpha gamma')), (to_ftsdoc('delta'));
-- before merge: 2 docs pending
SELECT ndocs FROM fts_index_stats('mrg_bm25');
SET enable_seqscan = off;
SELECT id FROM mrg WHERE d @@@ 'alpha'::ftsquery ORDER BY id;   -- 1, 2
-- explicit merge folds pending into the main structure
SELECT fts_merge('mrg_bm25') AS merged;
-- after merge: same results, and a term from a formerly-pending doc now has df
SELECT id FROM mrg WHERE d @@@ 'alpha'::ftsquery ORDER BY id;   -- still 1, 2
SELECT id FROM mrg WHERE d @@@ 'delta'::ftsquery ORDER BY id;   -- 3
SELECT fts_index_df('mrg_bm25', 'alpha'::ftsquery) AS df_alpha_after_merge;
-- merging again is a no-op (nothing pending)
SELECT fts_merge('mrg_bm25') AS merged_again;
RESET enable_seqscan;
DROP TABLE mrg;

-- Index-only BM25 top-k search (fts_search).
CREATE TABLE srch (id serial, body text, d ftsdoc);
INSERT INTO srch (body, d) VALUES
  ('quick quick quick fox', to_ftsdoc('quick quick quick fox')),
  ('quick brown fox', to_ftsdoc('quick brown fox')),
  ('a slow turtle', to_ftsdoc('a slow turtle')),
  ('quick', to_ftsdoc('quick'));
CREATE INDEX srch_bm25 ON srch USING fts (d);
-- top-k by index-only score: doc with tf(quick)=3 ranks first
SELECT s.id, round(r.score::numeric, 3) AS score
FROM fts_search('srch_bm25', 'quick'::ftsquery, 10) r
JOIN srch s ON s.ctid = r.ctid
ORDER BY r.score DESC, s.id;
-- k limits the result set
SELECT count(*) AS topk_count
FROM fts_search('srch_bm25', 'quick'::ftsquery, 2) r;
-- multi-term query accumulates per-term contributions
SELECT count(*) AS multiterm
FROM fts_search('srch_bm25', 'quick | brown'::ftsquery, 10) r;
DROP TABLE srch;

-- Trigram pre-filter for fuzzy matching: correctness must be unchanged.
-- longer terms (>k trigrams) use the trigram filter
SELECT to_ftsdoc('development environment') @@@ 'developer~3'::ftsquery AS trgm_fuzzy_hit;
SELECT to_ftsdoc('completely unrelated words') @@@ 'developer~3'::ftsquery AS trgm_fuzzy_miss;
-- exact-distance edge: 'running' within 2 of 'runnick'? (n->c,g->k = 2 subst)
SELECT to_ftsdoc('the running man') @@@ 'runnink~2'::ftsquery AS edge_hit;
-- short terms (<=k trigrams) fall back to full scan, still correct
SELECT to_ftsdoc('cat hat bat') @@@ 'rat~1'::ftsquery AS short_hit;
SELECT to_ftsdoc('dog log fog') @@@ 'rat~1'::ftsquery AS short_miss;

-- MVCC: fts_search must return only tuples visible to the snapshot.
CREATE TABLE viz (id serial, d ftsdoc);
INSERT INTO viz (d) VALUES (to_ftsdoc('apple')), (to_ftsdoc('apple')),
                          (to_ftsdoc('apple')), (to_ftsdoc('apple'));
CREATE INDEX viz_bm25 ON viz USING fts (d);
-- delete two rows; their postings remain in the index until merge/reindex
DELETE FROM viz WHERE id IN (2, 3);
-- fts_search must skip the dead tuples (returns 2 live rows, not 4)
SELECT count(*) AS live_only
FROM fts_search('viz_bm25', 'apple'::ftsquery, 100) r
JOIN viz v ON v.ctid = r.ctid;
-- and the raw SRF itself returns only visible ctids
SELECT count(*) AS srf_live FROM fts_search('viz_bm25', 'apple'::ftsquery, 100);
DROP TABLE viz;

-- Posting compression: correctness under many clustered docids + merge.
CREATE TABLE cmp (id serial, d ftsdoc);
INSERT INTO cmp (d) SELECT to_ftsdoc('common term here')
FROM generate_series(1, 500);
CREATE INDEX cmp_bm25 ON cmp USING fts (d);
-- all 500 rows match the compressed posting list
SELECT count(*) AS all_match
FROM fts_search('cmp_bm25', 'common'::ftsquery, 1000) r JOIN cmp c ON c.ctid = r.ctid;
-- incremental inserts (pending) + merge preserve the full posting list
INSERT INTO cmp (d) SELECT to_ftsdoc('common term here') FROM generate_series(1, 100);
SELECT fts_merge('cmp_bm25');
SELECT count(*) AS after_merge
FROM fts_search('cmp_bm25', 'common'::ftsquery, 2000) r JOIN cmp c ON c.ctid = r.ctid;
DROP TABLE cmp;

-- WAND top-k: multi-term query returns correct top-k in descending score.
CREATE TABLE wnd (id serial, d ftsdoc);
INSERT INTO wnd (d) VALUES
  (to_ftsdoc('alpha alpha alpha beta')),   -- high alpha tf
  (to_ftsdoc('alpha beta beta beta')),     -- high beta tf
  (to_ftsdoc('alpha beta')),               -- both, low tf
  (to_ftsdoc('gamma only')),               -- neither
  (to_ftsdoc('alpha')),                    -- alpha only
  (to_ftsdoc('beta'));                     -- beta only
CREATE INDEX wnd_bm25 ON wnd USING fts (d);
-- top-2 for 'alpha | beta': the two docs matching both terms should lead
SELECT w.id
FROM fts_search('wnd_bm25', 'alpha | beta'::ftsquery, 3) r
JOIN wnd w ON w.ctid = r.ctid
ORDER BY r.score DESC, w.id;
-- scores are monotonically non-increasing (WAND returns them sorted)
SELECT bool_and(s >= lead_s) AS descending
FROM (SELECT r.score AS s, lead(r.score) OVER (ORDER BY r.score DESC) AS lead_s
      FROM fts_search('wnd_bm25', 'alpha | beta'::ftsquery, 10) r) q
WHERE lead_s IS NOT NULL;
DROP TABLE wnd;

-- Lazy block-max WAND: correct top-k over a multi-page posting list.
CREATE TABLE lazy (id serial, d ftsdoc);
-- 2000 docs of 'term': posting list spans many pages; one doc has high tf
INSERT INTO lazy (d) SELECT to_ftsdoc('term') FROM generate_series(1, 2000);
INSERT INTO lazy (d) VALUES (to_ftsdoc('term term term term term'));  -- id 2001
CREATE INDEX lazy_bm25 ON lazy USING fts (d);
-- top-1 must be the high-tf doc (id 2001), found via block-max skipping
SELECT l.id
FROM fts_search('lazy_bm25', 'term'::ftsquery, 1) r JOIN lazy l ON l.ctid = r.ctid;
-- top-3 all correct and the whole list is searchable
SELECT count(*) AS matched
FROM fts_search('lazy_bm25', 'term'::ftsquery, 5000) r JOIN lazy l ON l.ctid = r.ctid;
DROP TABLE lazy;

-- Lexical anomaly detection (fts_anomalous_docs): the rare-token (low-df) tail.
-- Corpus of 500 common-word docs, plus 3 docs each carrying a unique 'zqxjkN'
-- token.  The 3 injected docs are the only lexically-anomalous ones.
CREATE TABLE anom (id serial, d ftsdoc);
INSERT INTO anom (d) SELECT to_ftsdoc('the common ordinary boilerplate text')
FROM generate_series(1, 500);
INSERT INTO anom (d) VALUES
  (to_ftsdoc('the common text zqxjk1')),
  (to_ftsdoc('ordinary boilerplate zqxjk2')),
  (to_ftsdoc('common text zqxjk3'));
CREATE INDEX anom_bm25 ON anom USING fts (d);
-- top-3 anomalies are exactly the 3 injected docs, and rarest_term is the token
SELECT a.id, a.d::text AS doc, r.rarest_term, r.min_df
FROM fts_anomalous_docs('anom_bm25', 3) r
JOIN anom a ON a.ctid = r.ctid
ORDER BY r.score DESC, a.id;
-- their scores are the highest in the corpus (a common-only doc scores lower):
-- the min anomaly score of the 3 injected docs exceeds any other doc's score
SELECT bool_and(inj.score > others.maxscore) AS injected_lead
FROM (SELECT min(r.score) AS score
      FROM fts_anomalous_docs('anom_bm25', 3) r) inj,
     (SELECT coalesce(max(r.score), 0) AS maxscore
      FROM fts_anomalous_docs('anom_bm25', 1000) r
      WHERE r.rarest_term NOT LIKE 'zqxjk%') others;
-- every zqxjk token has df=1 (unique), so min_df is 1 for the injected docs
SELECT count(*) AS df1_hits
FROM fts_anomalous_docs('anom_bm25', 3) r
WHERE r.rarest_term LIKE 'zqxjk%' AND r.min_df = 1;
-- k limits the result set
SELECT count(*) AS topk_count
FROM fts_anomalous_docs('anom_bm25', 2) r;
-- max_df filter: with max_df=0 no term qualifies as rare -> no rows
SELECT count(*) AS none_when_maxdf_0
FROM fts_anomalous_docs('anom_bm25', 100, 0) r;
-- max_df=1 admits only the unique tokens -> exactly the 3 injected docs
SELECT count(*) AS three_when_maxdf_1
FROM fts_anomalous_docs('anom_bm25', 100, 1) r;
-- a common-only doc is never flagged (all its terms are high-df)
SELECT count(*) AS common_flagged
FROM fts_anomalous_docs('anom_bm25', 100, 1) r
JOIN anom a ON a.ctid = r.ctid
WHERE a.d::text = 'the common ordinary boilerplate text';
DROP TABLE anom;
-- empty index returns no rows
CREATE TABLE anom_empty (id serial, d ftsdoc);
CREATE INDEX anom_empty_bm25 ON anom_empty USING fts (d);
SELECT count(*) AS empty_rows FROM fts_anomalous_docs('anom_empty_bm25', 10);
DROP TABLE anom_empty;

-- NEAR(a b, k): proximity within k tokens.
-- 'quick ... fox' are 3 tokens apart in 'the quick brown red fox'
SELECT to_ftsdoc('the quick brown red fox') @@@ 'NEAR(quick fox, 3)'::ftsquery AS near_hit;
SELECT to_ftsdoc('the quick brown red fox') @@@ 'NEAR(quick fox, 2)'::ftsquery AS near_miss;
-- adjacent terms satisfy any k>=1
SELECT to_ftsdoc('the quick brown fox') @@@ 'NEAR(quick brown, 1)'::ftsquery AS near_adj;
-- three-term NEAR chains the proximity
SELECT to_ftsdoc('alpha beta gamma delta') @@@ 'NEAR(alpha beta gamma, 2)'::ftsquery AS near3;
-- NEAR combines with boolean operators
SELECT to_ftsdoc('the quick brown red fox jumps') @@@ 'NEAR(quick fox, 3) & jumps'::ftsquery AS near_combo;
-- malformed NEAR errors (single term); NEAR without k defaults to 10
SELECT 'NEAR(onlyone, 2)'::ftsquery;
SELECT to_ftsdoc('a b c') @@@ 'NEAR(a c)'::ftsquery AS near_default_k;

-- FSM page recycling: repeated merges reuse freed blocks (no unbounded growth).
CREATE TABLE recyc (id serial, d ftsdoc);
INSERT INTO recyc (d) SELECT to_ftsdoc('term' || (g % 50)) FROM generate_series(1, 500) g;
CREATE INDEX recyc_bm25 ON recyc USING fts (d);
-- churn: insert + merge several times; each merge frees the old blocks
DO $$
BEGIN
  FOR i IN 1..5 LOOP
    INSERT INTO recyc (d) SELECT to_ftsdoc('term' || (g % 50)) FROM generate_series(1, 200) g;
    PERFORM fts_merge('recyc_bm25');
  END LOOP;
END $$;
-- after churn the index is still correct
SELECT count(*) > 0 AS still_matches
FROM fts_search('recyc_bm25', 'term1'::ftsquery, 5000) r JOIN recyc x ON x.ctid = r.ctid;
-- size stays bounded across churn (freed blocks recycled, not leaked); the
-- bound includes the trigram index pages rebuilt on each merge.
SELECT pg_relation_size('recyc_bm25') < 800 * 8192 AS size_bounded;
DROP TABLE recyc;

-- amcanorderbyop: ORDER BY col <=> query LIMIT k uses an index ordering scan.
CREATE TABLE ord (id serial, d ftsdoc);
INSERT INTO ord (d) VALUES
  (to_ftsdoc('quick quick quick fox')),   -- highest tf(quick)
  (to_ftsdoc('quick brown fox')),
  (to_ftsdoc('a slow turtle')),
  (to_ftsdoc('quick'));                    -- short doc, high length-norm score
CREATE INDEX ord_bm25 ON ord USING fts (d);
SET enable_seqscan = off;
-- the plan should be an index scan ordered by the distance operator (no Sort)
EXPLAIN (COSTS OFF)
SELECT id FROM ord WHERE d @@@ 'quick'::ftsquery
ORDER BY d <=> 'quick'::ftsquery LIMIT 2;
-- results ordered by relevance (ascending distance)
SELECT id FROM ord WHERE d @@@ 'quick'::ftsquery
ORDER BY d <=> 'quick'::ftsquery LIMIT 3;
RESET enable_seqscan;
DROP TABLE ord;

-- On-disk trigram index: fuzzy/regex through the index over many docs.
-- The trigram funnel narrows candidates (sparsemap postings); recheck refines.
CREATE TABLE trgm (id serial, d ftsdoc);
INSERT INTO trgm (d) SELECT to_ftsdoc('document' || g) FROM generate_series(1, 1000) g;
INSERT INTO trgm (d) VALUES (to_ftsdoc('documemt42'));   -- id 1001, 1 edit from document42
CREATE INDEX trgm_bm25 ON trgm USING fts (d);
SET enable_seqscan = off;
-- fuzzy: finds the exact 'document42' (id 43: 'document42') and the typo (1001)
SELECT count(*) AS fuzzy_via_trigram
FROM trgm t WHERE t.d @@@ 'document42~2'::ftsquery;
-- regex through the trigram index
SELECT count(*) AS regex_via_trigram
FROM trgm t WHERE t.d @@@ '/document4[0-9]$/'::ftsquery;
-- regex with alternation/anchors: literal-run tiling extracts 'document'
SELECT count(*) AS regex_anchored
FROM trgm t WHERE t.d @@@ '/^document(4|5)2$/'::ftsquery;   -- document42, document52
RESET enable_seqscan;
DROP TABLE trgm;

-- Adaptive-k ordering scan: consuming more than the initial batch (64) must
-- grow k and return the full ordered set correctly across the boundary.
CREATE TABLE bigord (id serial, d ftsdoc);
INSERT INTO bigord (d) SELECT to_ftsdoc('term extra' || (g % 3)) FROM generate_series(1, 300) g;
CREATE INDEX bigord_bm25 ON bigord USING fts (d);
SET enable_seqscan = off;
-- all 300 match 'term'; requesting 200 crosses the initial k=64 batch
SELECT count(*) AS got, bool_and(s >= lead_s) AS ordered_ok
FROM (SELECT r.score AS s, lead(r.score) OVER (ORDER BY r.score DESC) AS lead_s
      FROM (SELECT id, d <=> 'term'::ftsquery AS score FROM bigord
            WHERE d @@@ 'term'::ftsquery
            ORDER BY d <=> 'term'::ftsquery LIMIT 200) r) q;
RESET enable_seqscan;
DROP TABLE bigord;

-- the fts index access method.

CREATE TABLE idxdocs (id serial, d ftsdoc);
INSERT INTO idxdocs (d) VALUES
  (to_ftsdoc('the quick brown fox')),
  (to_ftsdoc('a slow green turtle')),
  (to_ftsdoc('quick turtles are rare')),
  (to_ftsdoc('brown bears and quick foxes'));

CREATE INDEX idxdocs_bm25 ON idxdocs USING fts (d);

-- force index usage and confirm the plan uses a bitmap scan on our AM
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT id FROM idxdocs WHERE d @@@ 'quick'::ftsquery ORDER BY id;

-- results must match a sequential @@@ evaluation
SELECT id FROM idxdocs WHERE d @@@ 'quick'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ 'quick & fox'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ 'quick | slow'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ 'quick & !fox'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ '!turtle'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ '(quick | slow) & !fox'::ftsquery ORDER BY id;
RESET enable_seqscan;

DROP TABLE idxdocs;

-- Config-normalized query: to_ftsquery(regconfig, text) must stem query terms
-- to match a doc indexed with the same config (the EC2 benchmark fault).
-- 'postgres' stems to 'postgr'; a raw ftsquery misses, a config query matches
SELECT to_ftsdoc('english'::regconfig, 'postgres databases') @@@ 'postgres'::ftsquery
       AS raw_query_misses;
SELECT to_ftsdoc('english'::regconfig, 'postgres databases')
       @@@ to_ftsquery('english'::regconfig, 'postgres')
       AS config_query_matches;
-- multi-term config query with operators
SELECT to_ftsdoc('english'::regconfig, 'running quickly through fields')
       @@@ to_ftsquery('english'::regconfig, 'run & quick')
       AS stemmed_and;
-- config query renders the stemmed terms
SELECT to_ftsquery('english'::regconfig, 'databases running')::text AS stemmed_render;

-- Segmented architecture: queries must span multiple segments correctly.
CREATE TABLE seg (id serial, d ftsdoc);
INSERT INTO seg(d) SELECT to_ftsdoc('alpha doc'||g) FROM generate_series(1,100) g;
CREATE INDEX seg_bm25 ON seg USING fts (d);          -- segment 0
INSERT INTO seg(d) SELECT to_ftsdoc('beta doc'||g) FROM generate_series(1,50) g;
SELECT fts_merge('seg_bm25');                          -- flush -> segment 1
INSERT INTO seg(d) SELECT to_ftsdoc('alpha more'||g) FROM generate_series(1,30) g;
SELECT fts_merge('seg_bm25');                          -- flush -> segment 2
SET enable_seqscan = off;
SELECT count(*) AS alpha_spans_segs FROM seg WHERE d @@@ 'alpha'::ftsquery;  -- 130
SELECT count(*) AS beta_one_seg FROM seg WHERE d @@@ 'beta'::ftsquery;        -- 50
SELECT ndocs AS total_docs FROM fts_index_stats('seg_bm25');                  -- 180
SELECT count(*) AS ranked_across_segs
FROM (SELECT id FROM seg WHERE d @@@ 'alpha'::ftsquery
      ORDER BY d <=> 'alpha'::ftsquery LIMIT 5) x;                            -- 5
RESET enable_seqscan;
DROP TABLE seg;

-- Tiered merge: many flushes create many segments; merge compacts them so the
-- segment count stays bounded while results are preserved.
CREATE TABLE tier (id serial, d ftsdoc);
INSERT INTO tier(d) SELECT to_ftsdoc('common w'||(g%20)) FROM generate_series(1,100) g;
CREATE INDEX tier_bm25 ON tier USING fts (d);
DO $$ BEGIN FOR i IN 1..10 LOOP
  INSERT INTO tier(d) SELECT to_ftsdoc('common x'||(g%20)) FROM generate_series(1,20) g;
  PERFORM fts_merge('tier_bm25');
END LOOP; END $$;
SET enable_seqscan = off;
SELECT count(*) AS all_docs FROM tier WHERE d @@@ 'common'::ftsquery;   -- 300
SELECT ndocs FROM fts_index_stats('tier_bm25');                          -- 300
SELECT fts_index_nsegments('tier_bm25') <= 8 AS segments_bounded;        -- t (compacted)
RESET enable_seqscan;
DROP TABLE tier;

-- FOR-128 block posting codec: a term spanning many 128-doc blocks and pages
-- decodes correctly and block-max WAND top-k matches a full scan+sort.
CREATE TABLE blk (id serial, d ftsdoc);
INSERT INTO blk(d) SELECT to_ftsdoc('pop '||repeat('pop ',(g%7))||'w'||g)
  FROM generate_series(1,3000) g;      -- 'pop' in 3000 docs, >20 blocks/page
CREATE INDEX blk_bm25 ON blk USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS pop_ct FROM blk WHERE d @@@ 'pop'::ftsquery;   -- 3000
-- WAND top-10 distances equal a full seqscan sort's top-10 distances
CREATE TEMP TABLE w AS SELECT round((d <=> 'pop'::ftsquery)::numeric,6) dist
  FROM blk WHERE d @@@ 'pop'::ftsquery ORDER BY dist LIMIT 10;
SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_seqscan = on;
CREATE TEMP TABLE f AS SELECT round((d <=> 'pop'::ftsquery)::numeric,6) dist
  FROM blk WHERE d @@@ 'pop'::ftsquery ORDER BY dist LIMIT 10;
SELECT (SELECT array_agg(dist ORDER BY dist) FROM w)
     = (SELECT array_agg(dist ORDER BY dist) FROM f) AS wand_scores_match_fullsort;
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE blk;

-- Sparse dictionary block index (FST-equivalent point lookup): a many-page
-- dictionary routes exact lookups to the right page; first/middle/last/absent
-- terms all resolve correctly, and df via the seek path is exact.
CREATE TABLE voc (id serial, d ftsdoc);
INSERT INTO voc(d) SELECT to_ftsdoc('term'||lpad(g::text,5,'0')||' shared')
  FROM generate_series(1,8000) g;      -- 8000 distinct terms -> multi-page dict
CREATE INDEX voc_bm25 ON voc USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS first_term  FROM voc WHERE d @@@ 'term00001'::ftsquery;  -- 1
SELECT count(*) AS mid_term    FROM voc WHERE d @@@ 'term04000'::ftsquery;  -- 1
SELECT count(*) AS last_term   FROM voc WHERE d @@@ 'term08000'::ftsquery;  -- 1
SELECT count(*) AS absent_term FROM voc WHERE d @@@ 'termzzzzz'::ftsquery;  -- 0
SELECT count(*) AS shared_all  FROM voc WHERE d @@@ 'shared'::ftsquery;     -- 8000
SELECT fts_index_df('voc_bm25','term04000'::ftsquery) AS df_mid;            -- {1}
-- block index survives an insert+flush (new segment gets its own index)
INSERT INTO voc(d) SELECT to_ftsdoc('term'||lpad(g::text,5,'0')||' shared')
  FROM generate_series(8001,8100) g;
SELECT fts_merge('voc_bm25');
SELECT count(*) AS after_flush FROM voc WHERE d @@@ 'term08050'::ftsquery;  -- 1
RESET enable_seqscan;
DROP TABLE voc;

-- Block-Max WAND (BMW): the block-max skip prunes whole 128-blocks that cannot
-- beat the current top-k threshold, and the exact top-k is unchanged.
CREATE TABLE bmw (id serial, d ftsdoc);
INSERT INTO bmw(d) SELECT to_ftsdoc('alpha '||
    CASE WHEN g%50=0 THEN repeat('beta ',5) ELSE '' END||'w'||g)
  FROM generate_series(1,12000) g;
CREATE INDEX bmw_bm25 ON bmw USING fts (d);
SET enable_seqscan = off;
CREATE TEMP TABLE bmw_top AS SELECT round((d <=> 'alpha beta'::ftsquery)::numeric,6) dist
  FROM bmw WHERE d @@@ 'alpha beta'::ftsquery ORDER BY dist LIMIT 10;
SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_seqscan = on;
CREATE TEMP TABLE bmw_all AS SELECT round((d <=> 'alpha beta'::ftsquery)::numeric,6) dist
  FROM bmw WHERE d @@@ 'alpha beta'::ftsquery ORDER BY dist LIMIT 10;
SELECT (SELECT array_agg(dist ORDER BY dist) FROM bmw_top)
     = (SELECT array_agg(dist ORDER BY dist) FROM bmw_all) AS bmw_exact_topk;
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE bmw;

-- Levenshtein-automaton fuzzy: matches EXACTLY the dictionary terms within k
-- edits (no trigram over-generation), verified against core levenshtein.
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE TABLE fz (id serial, body text, d ftsdoc);
INSERT INTO fz(body) SELECT 'document'||g||' filler' FROM generate_series(1,5000) g;
UPDATE fz SET d = to_ftsdoc(body);
CREATE INDEX fz_bm25 ON fz USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS dfa_fuzzy FROM fz WHERE d @@@ 'document42~2'::ftsquery;
SET enable_seqscan = on; SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT count(*) AS ground_truth FROM fz
WHERE EXISTS (SELECT 1 FROM unnest(string_to_array(body,' ')) t
              WHERE levenshtein_less_equal(t,'document42',2) <= 2);
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE fz;
DROP EXTENSION fuzzystrmatch;

-- MaxScore top-k (chosen for queries with >=4 terms): identical exact top-k to
-- a full scan+sort, doing less work as low-impact terms become non-essential.
CREATE TABLE ms (id serial, d ftsdoc);
INSERT INTO ms(d) SELECT to_ftsdoc(
  (CASE WHEN g%2=0 THEN 'alpha ' ELSE '' END)||
  (CASE WHEN g%3=0 THEN 'beta ' ELSE '' END)||
  (CASE WHEN g%5=0 THEN 'gamma ' ELSE '' END)||
  (CASE WHEN g%7=0 THEN 'delta ' ELSE '' END)||
  (CASE WHEN g%11=0 THEN 'epsilon ' ELSE '' END)||'w'||g)
  FROM generate_series(1,20000) g;
CREATE INDEX ms_bm25 ON ms USING fts (d);
SET enable_seqscan = off;
CREATE TEMP TABLE mtop AS SELECT round((d <=> 'alpha beta gamma delta epsilon'::ftsquery)::numeric,6) dist
  FROM ms WHERE d @@@ 'alpha beta gamma delta epsilon'::ftsquery ORDER BY dist LIMIT 20;
SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_seqscan = on;
CREATE TEMP TABLE mall AS SELECT round((d <=> 'alpha beta gamma delta epsilon'::ftsquery)::numeric,6) dist
  FROM ms WHERE d @@@ 'alpha beta gamma delta epsilon'::ftsquery ORDER BY dist LIMIT 20;
SELECT (SELECT array_agg(dist ORDER BY dist) FROM mtop)
     = (SELECT array_agg(dist ORDER BY dist) FROM mall) AS maxscore_exact_topk;
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE ms;

-- Tombstones: VACUUM must remove deleted docs from the index so the index-only
-- scan and fts_count (which trust the visibility map) never report a
-- vacuumed-and-reused heap slot, and a later merge must physically drop them.
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE tomb (id int primary key, d ftsdoc);
INSERT INTO tomb SELECT g, to_ftsdoc('alpha doc'||g) FROM generate_series(1,100) g;
CREATE INDEX tomb_bm25 ON tomb USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS c_before FROM tomb WHERE d @@@ 'alpha'::ftsquery;         -- 100
DELETE FROM tomb WHERE id <= 40;
VACUUM tomb;
SELECT count(*) AS c_after FROM tomb WHERE d @@@ 'alpha'::ftsquery;          -- 60
SELECT fts_count('tomb_bm25','alpha'::ftsquery) AS fc_after;                 -- 60
-- delete-all + vacuum + reuse: the reused slots must NOT match 'alpha'
DELETE FROM tomb;
VACUUM tomb;
INSERT INTO tomb SELECT g, to_ftsdoc('beta doc'||g) FROM generate_series(1,60) g;
VACUUM tomb;
SELECT count(*) AS alpha_reused FROM tomb WHERE d @@@ 'alpha'::ftsquery;     -- 0
SELECT count(*) AS beta_reused FROM tomb WHERE d @@@ 'beta'::ftsquery;       -- 60
SELECT fts_count('tomb_bm25','beta'::ftsquery) AS beta_reused_fc;            -- 60
RESET enable_seqscan;
DROP TABLE tomb;

-- oversized document: an analyzed ftsdoc larger than one pending page must be
-- indexed as its own segment rather than rejected
CREATE TABLE bigdoc (id int, d ftsdoc);
CREATE INDEX bigdoc_bm25 ON bigdoc USING fts (d);
INSERT INTO bigdoc SELECT 1, to_ftsdoc(string_agg('term'||g||'x', ' '))
  FROM generate_series(1,4000) g;
INSERT INTO bigdoc VALUES (2, to_ftsdoc('small doc with term500x here'));
SET enable_seqscan=off;
SELECT count(*) AS big_term500 FROM bigdoc WHERE d @@@ 'term500x'::ftsquery;   -- 2
SELECT count(*) AS big_term3999 FROM bigdoc WHERE d @@@ 'term3999x'::ftsquery; -- 1
RESET enable_seqscan;
DROP TABLE bigdoc;

-- parallel index build (amcanbuildparallel): a parallel-built index must return
-- exactly what a serial build does.  Force workers with a zero scan threshold.
CREATE TABLE pbuild (id int, d ftsdoc);
INSERT INTO pbuild SELECT g, to_ftsdoc('common term'||(g%200)||' doc'||g)
  FROM generate_series(1,20000) g;
SET min_parallel_table_scan_size = 0;
SET max_parallel_maintenance_workers = 2;
CREATE INDEX pbuild_bm25 ON pbuild USING fts (d);
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
SET enable_seqscan = off;
SELECT fts_count('pbuild_bm25', 'common'::ftsquery) AS all_docs;      -- 20000
SELECT fts_count('pbuild_bm25', 'term7'::ftsquery) AS term7;          -- 100
SELECT count(*) AS ranked FROM (SELECT id FROM pbuild WHERE d @@@ 'common'::ftsquery
  ORDER BY d <=> 'common'::ftsquery LIMIT 10) x;                      -- 10
RESET enable_seqscan;
DROP TABLE pbuild;

-- fts_vacuum: full compaction + tail truncation.  A parallel build
-- leaves dead source-segment pages; fts_vacuum reclaims them and truncates the
-- file, and the contents are unchanged afterward.
CREATE TABLE vac (id int, d ftsdoc);
INSERT INTO vac SELECT g, to_ftsdoc('common term'||(g%200)||' doc'||g)
  FROM generate_series(1,20000) g;
SET min_parallel_table_scan_size = 0;
SET max_parallel_maintenance_workers = 2;
CREATE INDEX vac_bm25 ON vac USING fts (d);
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
SET enable_seqscan = off;
SELECT fts_count('vac_bm25', 'common'::ftsquery) AS before_all;       -- 20000
SELECT fts_vacuum('vac_bm25') IS NOT NULL AS vacuumed;               -- t
SELECT fts_count('vac_bm25', 'common'::ftsquery) AS after_all;        -- 20000
SELECT fts_count('vac_bm25', 'term7'::ftsquery) AS after_term7;       -- 100
SELECT fts_index_nsegments('vac_bm25') AS nseg_after;                 -- 1
RESET enable_seqscan;
DROP TABLE vac;

-- COUNT pushdown CustomScan (transparent count(*) WHERE @@@ answered from the
-- index).  The plan is a Custom Scan (FtsCount); the count matches fts_count;
-- and it must NOT trigger when the shape is unsupported (extra qual, GROUP BY).
CREATE TABLE cnt (id int, body text);
INSERT INTO cnt SELECT g, 'common '||CASE WHEN g%4=0 THEN 'quarter ' ELSE '' END||'w'||(g%100)
  FROM generate_series(1,10000) g;
CREATE INDEX cnt_bm25 ON cnt USING fts(to_ftsdoc('english',body));
ANALYZE cnt;
SET enable_seqscan=off;
SELECT count(*) = fts_count('cnt_bm25', to_ftsquery('english','common')) AS count_matches
  FROM cnt WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','common');
SELECT count(*) AS quarter_cnt FROM cnt WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','quarter');  -- 2500
-- the bare count(*) plan is a Custom Scan (FtsCount)
EXPLAIN (COSTS OFF) SELECT count(*) FROM cnt
  WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','common');
-- an extra qual disables the pushdown (falls back to Aggregate over a scan)
EXPLAIN (COSTS OFF) SELECT count(*) FROM cnt
  WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','common') AND id > 5;
RESET enable_seqscan;
DROP TABLE cnt;

-- ============================================================================
-- Ranked index scan must respect boolean AND/NOT/PHRASE structure.
-- The `<=>` ordering scan flattened the query to its terms and ranked the
-- disjunction, so AND/NOT queries could return docs that fail `@@@` (e.g.
-- `a & !b` ranking docs that contain b).  Every doc a ranked scan returns must
-- satisfy `@@@`.  The AM ordering path (bm25_gettuple) is only reached when the
-- planner picks an "Index Scan ... Order By" on the fts index -- that needs a
-- stored ftsdoc column (not an expression index) AND the `WHERE d @@@ q`
-- restriction alongside `ORDER BY d <=> q`.  Without both, the planner falls
-- back to a Seq Scan + Sort over the `<=>` operator (which never enters the AM
-- candidate path), so we assert the plan first, then assert zero violations.
CREATE TABLE bp (id serial, d ftsdoc);
INSERT INTO bp(d) SELECT to_ftsdoc('alpha gamma d'||g)       FROM generate_series(1,40) g;  -- alpha, no beta
INSERT INTO bp(d) SELECT to_ftsdoc('alpha beta d'||g)        FROM generate_series(1,40) g;  -- alpha AND beta
INSERT INTO bp(d) SELECT to_ftsdoc('beta delta d'||g)        FROM generate_series(1,40) g;  -- beta, no alpha
INSERT INTO bp(d) SELECT to_ftsdoc('alpha beta gamma d'||g)  FROM generate_series(1,20) g;  -- all three
CREATE INDEX bp_fts ON bp USING fts (d);
ANALYZE bp;
SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexscan=on;
-- the plan MUST be the AM ordering Index Scan (no Sort); otherwise the filter
-- code is never exercised and the test would silently pass on the buggy engine.
EXPLAIN (COSTS OFF) SELECT id FROM bp WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 20;
-- NOT: `alpha & !beta` ranked top-20 must contain NO doc with beta (0 violations).
SELECT count(*) AS not_violations FROM (
  SELECT d FROM bp WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 20
) s WHERE NOT (s.d @@@ 'alpha & !beta'::ftsquery);
-- AND: `alpha & beta & gamma` ranked top-20 must contain only docs with all three.
SELECT count(*) AS and3_violations FROM (
  SELECT d FROM bp WHERE d @@@ 'alpha & beta & gamma'::ftsquery
  ORDER BY d <=> 'alpha & beta & gamma'::ftsquery LIMIT 20
) s WHERE NOT (s.d @@@ 'alpha & beta & gamma'::ftsquery);
-- every ranked row must satisfy @@@ for the AND query (retrieval == match set).
SELECT count(*) AS and_atatat_violations FROM (
  SELECT id, d FROM bp WHERE d @@@ 'alpha & beta'::ftsquery
  ORDER BY d <=> 'alpha & beta'::ftsquery LIMIT 20
) s WHERE NOT (s.d @@@ 'alpha & beta'::ftsquery);
-- grow-k must terminate and return all matches when LIMIT exceeds the match
-- count: only 40 docs satisfy `alpha & !beta`, so LIMIT 500 returns exactly 40.
SELECT count(*) AS not_all_matches FROM (
  SELECT d FROM bp WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 500
) s;
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
DROP TABLE bp;

-- ----------------------------------------------------------------------------
-- Ranked index scan must ALSO enforce PHRASE/NEAR adjacency and FUZZY/REGEX
-- edit-distance -- not just boolean AND/NOT.  bm25_collect_matches returns the
-- over-generated set (PHRASE = AND-set with adjacency unenforced; fuzzy/regex =
-- trigram-funnel candidates) with recheck=true.  The bitmap @@@ path resolves
-- this with an executor recheck; the ranked <=> scan has none, so the AM must
-- recheck the exact @@@ test against the heap ftsdoc before ranking.  Before
-- the fix, a ranked `"quick brown"` over the rows below returned all 20
-- non-adjacent "quick red slow brown" docs; it must now return 0.
CREATE TABLE rp (id serial, d ftsdoc);
-- 20 NON-adjacent docs (both terms present, not consecutive): the AND-set, and
-- the phrase-recheck must reject every one.
INSERT INTO rp(d) SELECT to_ftsdoc('simple'::regconfig, 'quick red slow brown d'||g)
  FROM generate_series(1,20) g;
-- 5 ADJACENT docs ("quick brown" consecutive): the true phrase matches.
INSERT INTO rp(d) SELECT to_ftsdoc('simple'::regconfig, 'quick brown fox d'||g)
  FROM generate_series(1,5) g;
CREATE INDEX rp_fts ON rp USING fts (d);
ANALYZE rp;
SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexscan=on;
-- plan MUST be the AM ordering Index Scan (no Sort), else the recheck code is
-- never exercised and a buggy engine would pass silently.
EXPLAIN (COSTS OFF) SELECT id FROM rp
  WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, '"quick brown"') LIMIT 50;
-- PHRASE: ranked top-50 must contain ZERO non-adjacent docs (was 20 pre-fix).
SELECT count(*) AS phrase_violations FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, '"quick brown"') LIMIT 50
) s WHERE NOT (s.d @@@ to_ftsquery('simple'::regconfig, '"quick brown"'));
-- and it returns exactly the 5 true adjacent matches (grow-k terminates even
-- though the exact set (5) is far smaller than the AND-set (25)).
SELECT count(*) AS phrase_matches FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, '"quick brown"') LIMIT 500
) s;
-- NEAR: within-k admits, beyond-k rejects, all on the ranked path.
-- "quick" and "brown" are adjacent in the 5 rows (distance 1) and 3 apart in
-- the 20 rows ("quick red slow brown").  NEAR(...,3) admits all 25; NEAR(...,1)
-- admits only the 5 adjacent ones.
SELECT count(*) AS near3_matches FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 3)')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 3)') LIMIT 500
) s;
SELECT count(*) AS near1_matches FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)') LIMIT 500
) s;
SELECT count(*) AS near1_violations FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)') LIMIT 500
) s WHERE NOT (s.d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)'));
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
DROP TABLE rp;

-- ----------------------------------------------------------------------------
-- Positional postings (WITH positions=on): phrase/NEAR answered DIRECTLY from
-- the posting lists (no heap recheck).  The results MUST be identical to the
-- recheck path (positions=off), and the phrase set MUST be smaller than the
-- AND set.  Same corpus shape as the cliff repro: an adjacent phrase, a
-- co-occurring-but-not-adjacent set, and noise.
CREATE TABLE pos_on  (id serial, body text);
CREATE TABLE pos_off (id serial, body text);
INSERT INTO pos_on(body)
SELECT CASE WHEN g % 3 = 0 THEN 'alpha united states beta d'||g          -- adjacent phrase
            WHEN g % 3 = 1 THEN 'alpha united middle states beta d'||g   -- AND, not phrase
            ELSE 'gamma delta noise d'||g END                           -- neither
FROM generate_series(1, 600) g;
INSERT INTO pos_off(body) SELECT body FROM pos_on;
CREATE INDEX pos_on_idx  ON pos_on  USING fts (to_ftsdoc('simple'::regconfig, body)) WITH (positions = on);
CREATE INDEX pos_off_idx ON pos_off USING fts (to_ftsdoc('simple'::regconfig, body));  -- default off
ANALYZE pos_on; ANALYZE pos_off;
SET enable_seqscan = off;
-- phrase count from positions == phrase count from recheck (identical answer)
SELECT
  (SELECT count(*) FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) AS pos_on_phrase,
  (SELECT count(*) FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) AS pos_off_phrase;
-- phrase count is STRICTLY less than the AND count (adjacency really enforced)
SELECT
  (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) <
  (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'united & states')) AS phrase_lt_and;
-- the matched id SET is identical between the positional and recheck indexes:
-- the symmetric difference of the two match sets must be empty (0).
SELECT
  (SELECT count(*) FROM (
     SELECT id FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')
     EXCEPT
     SELECT id FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) d1)
+ (SELECT count(*) FROM (
     SELECT id FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')
     EXCEPT
     SELECT id FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) d2)
  AS phrase_symdiff;  -- 0: the two index shapes agree exactly
-- fts_count on the positional index equals the phrase (adjacency) count
SELECT fts_count('pos_on_idx', to_ftsquery('simple'::regconfig, '"united states"'))
     = (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"'))
     AS fts_count_phrase_ok;
-- NEAR on positions: within-k admits the co-occurring 'united ... states' too
SELECT
  (SELECT count(*) FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'NEAR(united states, 2)')) =
  (SELECT count(*) FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'NEAR(united states, 2)')) AS near_pos_eq_recheck;
-- plain (non-phrase) AND count is identical between on/off (positions invisible)
SELECT
  (SELECT count(*) FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'united & states')) =
  (SELECT count(*) FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'united & states')) AS and_on_eq_off;
RESET enable_seqscan;
-- multi-segment / pending: phrase must be correct across several segments (the
-- positional hits accumulate per-segment and are merged); insert more rows
-- after the index exists so they land in new segments / the pending list.
INSERT INTO pos_on(body)
SELECT CASE WHEN g % 2 = 0 THEN 'zeta united states omega e'||g
            ELSE 'zeta united gap states omega e'||g END
FROM generate_series(1, 300) g;
SET enable_seqscan = off;
SELECT fts_count('pos_on_idx', to_ftsquery('simple'::regconfig, '"united states"'))
     = (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"'))
     AS multiseg_phrase_ok;
RESET enable_seqscan;
-- fts_vacuum must still reclaim on the v3 positional format (P1 gate): delete
-- most rows, vacuum, assert the index shrinks.
DELETE FROM pos_on WHERE id % 3 <> 0;
SELECT fts_vacuum('pos_on_idx');
SELECT fts_merge('pos_on_idx');
-- phrase still correct after vacuum/merge carried positions through
SELECT count(*) > 0 AS phrase_survives_vacuum
  FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"');
DROP TABLE pos_on; DROP TABLE pos_off;

-- three-word positional phrase + NEAR must match the recheck path exactly (the
-- phrase_step chain over posting positions == the heap adjacency chain).
CREATE TABLE pos3 (id serial, body text);
INSERT INTO pos3(body) VALUES
 ('x quick brown fox y'),        -- adjacent 3-word
 ('quick brown cat'),            -- only 2 of 3
 ('quick red brown fox'),        -- not fully adjacent
 ('a quick brown fox');          -- adjacent 3-word
INSERT INTO pos3(body) SELECT 'noise d'||g FROM generate_series(1,200) g;
CREATE INDEX pos3_on  ON pos3 USING fts (to_ftsdoc('simple'::regconfig, body)) WITH (positions = on);
CREATE INDEX pos3_off ON pos3 USING fts (to_ftsdoc('simple'::regconfig, body));
SET enable_seqscan = off;
SELECT array_agg(id ORDER BY id) AS phrase3_ids
  FROM pos3 WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"quick brown fox"');  -- {1,4}
SELECT fts_count('pos3_on',  to_ftsquery('simple'::regconfig, '"quick brown fox"'))
     = fts_count('pos3_off', to_ftsquery('simple'::regconfig, '"quick brown fox"')) AS phrase3_on_eq_off;
SELECT fts_count('pos3_on',  to_ftsquery('simple'::regconfig, 'NEAR(quick brown fox, 2)'))
     = fts_count('pos3_off', to_ftsquery('simple'::regconfig, 'NEAR(quick brown fox, 2)')) AS near3_on_eq_off;
RESET enable_seqscan;
DROP TABLE pos3;

-- v2 index rejected with a REINDEX hint (format version bump 2 -> 3).  We can't
-- easily fabricate a v2 index here, but the version guard message is asserted
-- by the build-time check; the reloption round-trips through pg_class:
CREATE TABLE reloptt (id serial, d ftsdoc);
INSERT INTO reloptt(d) SELECT to_ftsdoc('a b c d'||g) FROM generate_series(1,5) g;
CREATE INDEX reloptt_idx ON reloptt USING fts (d) WITH (positions = on);
SELECT reloptions FROM pg_class WHERE relname = 'reloptt_idx';  -- {positions=on}
DROP TABLE reloptt;

-- FUZZY ranked scan: the trigram funnel over-generates candidates (recheck),
-- so the ranked scan must apply the exact edit-distance test.  All rows share
-- trigrams with the query term but only some are within edit distance 1.
CREATE TABLE rf (id serial, d ftsdoc);
INSERT INTO rf(d) VALUES
  (to_ftsdoc('document zulu')),   -- 1: exact "document" (edit distance 0)
  (to_ftsdoc('documemt zulu')),   -- 2: "documemt" (distance 1: t<-m... n->m)
  (to_ftsdoc('documenta zulu')),  -- 3: "documenta" (distance 1: trailing a)
  (to_ftsdoc('doc zulu')),        -- 4: "doc" shares trigrams, distance > 1
  (to_ftsdoc('dokumemt zulu'));   -- 5: "dokumemt" (distance 2) -- candidate, rejected
CREATE INDEX rf_fts ON rf USING fts (d);
ANALYZE rf;
SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexscan=on;
-- ranked `document~1`: every returned row must truly be within edit distance 1
-- (the funnel yields more candidates; the recheck drops docs 4 and 5).
SELECT count(*) AS fuzzy_violations FROM (
  SELECT d FROM rf WHERE d @@@ 'document~1'::ftsquery
  ORDER BY d <=> 'document~1'::ftsquery LIMIT 500
) s WHERE NOT (s.d @@@ 'document~1'::ftsquery);
-- ranked fuzzy/prefix/regex return a correct SUBSET of the @@@ matches, not the
-- identical set: the ranked WAND path builds cursors from the literal query term
-- (fts_query_terms), so a doc that matches only via a fuzzy/prefix/regex
-- EXPANSION (no posting for the literal term) is never generated as a ranked
-- candidate.  bm25_recheck_exact only ever shrinks, so every returned row is a
-- true match (fuzzy_violations = 0 above) but the ranked count can be < the
-- bitmap @@@ count.  Hence f, by design (a known limitation, documented in
-- CAPABILITIES.md / ROADMAP.md); use @@@ for exhaustive fuzzy/prefix retrieval.
SELECT (SELECT count(*) FROM (
          SELECT d FROM rf WHERE d @@@ 'document~1'::ftsquery
          ORDER BY d <=> 'document~1'::ftsquery LIMIT 500) s)
     = (SELECT count(*) FROM rf WHERE d @@@ 'document~1'::ftsquery)
     AS fuzzy_ranked_eq_bitmap;
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
DROP TABLE rf;


-- ============================================================================
-- Ranked <=> parity: the ordering index scan must return the same top-k SET
-- as an exact brute-force BM25 score sort (distinct scores => deterministic).
-- Guards the WAND/MaxScore recall + the 0.2.1 boolean-structure gate.
-- ranked <=> ordering scan must equal the fair brute-force BM25 top-k SET.
-- Distinct scores (unique tf per doc) => deterministic, no tie ambiguity.
-- Index MUST be flushed (VACUUM) so the ranked path covers all docs; pending
-- docs are intentionally not ranked (CAPABILITIES.md), so a flush is part of
-- the contract this test checks.
CREATE TABLE rankparity (id int, d ftsdoc);
-- unique alpha tf per doc (1..600) -> strictly distinct single-term scores;
-- every 4th doc also carries beta/delta/epsilon for OR/AND/4-term coverage.
INSERT INTO rankparity(id, d)
SELECT g, to_ftsdoc(repeat('alpha ', g) ||
       (CASE WHEN g % 4 = 0 THEN 'beta delta epsilon ' ELSE '' END))
FROM generate_series(1, 600) g;
-- rare term, distinct tf
INSERT INTO rankparity(id, d)
SELECT 10000+g, to_ftsdoc(repeat('gamma ', g)) FROM generate_series(1, 12) g;
CREATE INDEX rankparity_idx ON rankparity USING fts (d);
VACUUM rankparity;   -- flush: ranked path covers all docs
ANALYZE rankparity;

-- returns the number of index-top-k rows NOT in the fair-oracle top-k (expect 0)
CREATE OR REPLACE FUNCTION _rank_miss(qtext text, kk int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE nd float8; ad float8; dfs float8[]; ntie int; nmiss int;
BEGIN
  SELECT ndocs, avgdl INTO nd, ad FROM fts_index_stats('rankparity_idx');
  SELECT fts_index_df('rankparity_idx', qtext::ftsquery) INTO dfs;
  -- distinct-score guard: the test is only meaningful with 0 ties
  EXECUTE format($f$SELECT count(*) FROM (
     SELECT round(fts_bm25(d,%L::ftsquery,%s,%s,%L)::numeric,12) sc
     FROM rankparity WHERE d @@@ %L::ftsquery) z GROUP BY sc HAVING count(*)>1$f$,
     qtext,nd,ad,dfs,qtext) INTO ntie;
  IF COALESCE(ntie,0) <> 0 THEN
    RAISE EXCEPTION 'rank parity test corpus has % score ties for %', ntie, qtext;
  END IF;
  SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
  EXECUTE format($f$
    SELECT count(*) FROM (
      SELECT id FROM rankparity WHERE d @@@ %L::ftsquery
      ORDER BY d <=> %L::ftsquery LIMIT %s) ix
    WHERE ix.id NOT IN (
      SELECT id FROM rankparity WHERE d @@@ %L::ftsquery
      ORDER BY fts_bm25(d,%L::ftsquery,%s,%s,%L) DESC, id LIMIT %s)$f$,
    qtext, qtext, kk, qtext, qtext, nd, ad, dfs, kk) INTO nmiss;
  RETURN nmiss;
END $$;

SELECT _rank_miss('alpha',1)                          AS common_k1,   -- 0
       _rank_miss('alpha',10)                         AS common_k10,  -- 0
       _rank_miss('alpha',50)                         AS common_k50,  -- 0
       _rank_miss('alpha',100)                        AS common_k100, -- 0
       _rank_miss('gamma',10)                         AS rare_k10,    -- 0
       _rank_miss('alpha | beta',50)                  AS or_k50,      -- 0
       _rank_miss('alpha & beta',50)                  AS and_k50,     -- 0
       _rank_miss('alpha & beta & delta & epsilon',50) AS and4_k50;   -- 0 (MaxScore)

-- boolean-structure gate (v0.2.2 DocidFilter): AND/NOT top-k rows must satisfy @@@
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT count(*) AS and_bool_violations FROM (
  SELECT d FROM rankparity WHERE d @@@ 'alpha & beta'::ftsquery
  ORDER BY d <=> 'alpha & beta'::ftsquery LIMIT 50) x
WHERE NOT (x.d @@@ 'alpha & beta'::ftsquery);          -- 0
SELECT count(*) AS not_bool_violations FROM (
  SELECT d FROM rankparity WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 50) x
WHERE NOT (x.d @@@ 'alpha & !beta'::ftsquery);         -- 0

RESET enable_seqscan; RESET enable_bitmapscan;
DROP FUNCTION _rank_miss(text,int);
DROP TABLE rankparity;

-- ============================================================
-- ftsdoc I/O faithful round-trip (Codeberg #3).
--
--   ftsdoc_in(ftsdoc_out(x))    = x   (text)
--   ftsdoc_recv(ftsdoc_send(x)) = x   (binary, via COPY ... WITH (FORMAT binary))
--
-- ftsdoc has no '=' operator, so equality is byte-identity of the binary form:
-- ftsdoc_send now encodes version+nterms+doclen+has_pos+terms+tf+positions, so
-- equal send() output <=> semantically equal document (terms, tf AND positions).
-- Each property yields a single boolean sentinel; both must be t.
-- ============================================================
CREATE TEMP TABLE rt (id int, d ftsdoc);
INSERT INTO rt VALUES
  (1, to_ftsdoc('The quick brown fox, the QUICK fox!')),  -- positions, tf>1, multi-pos
  (2, to_ftsdoc('')),                                      -- empty (nterms=0)
  (3, to_ftsdoc('single')),                                -- one term
  (4, to_ftsdoc('a a a b')),                               -- repeats -> tf 3 with 3 positions
  (5, $$'br\'o\\wn':1@3 'f:o@x':2@4,7$$::ftsdoc),          -- escaped ' and \, literal : @ in lexeme
  (6, $$'caf\u00e9':1@1$$::ftsdoc),                        -- unicode-ish lexeme (bytes preserved)
  (7, $$'x':2@1,4 'y':1@9$$::ftsdoc);                      -- distinct terms, gaps in positions

-- text round-trip: parse of the canonical rendering equals the original.
SELECT bool_and(ftsdoc_send(ftsdoc_out(d)::text::ftsdoc) = ftsdoc_send(d)) AS text_roundtrip_ok
FROM rt;

-- binary round-trip: send then recv (COPY binary) equals the original.
COPY rt TO '/tmp/pg_fts_rt.bin' WITH (FORMAT binary);
CREATE TEMP TABLE rt2 (id int, d ftsdoc);
COPY rt2 FROM '/tmp/pg_fts_rt.bin' WITH (FORMAT binary);
SELECT bool_and(ftsdoc_send(a.d) = ftsdoc_send(b.d)) AS binary_roundtrip_ok
FROM rt a JOIN rt2 b USING (id);

-- the bare-string cast must still tokenize (not be parsed as canonical).
SELECT ftsdoc_out('the quick brown fox'::ftsdoc) AS bare_cast_still_analyzes;

-- malformed canonical input is rejected cleanly (no crash).  Detection rule:
-- input is canonical once a first complete 'term':tf token parses; a later
-- malformation is then a hard error (trust boundary).  Input that never
-- completes one token is treated as raw text instead (the bare-string cast),
-- so each case below carries a valid leading token to force the error path.
SELECT $$'ok':1 'unterminated:1$$::ftsdoc;             -- ERROR: unterminated quoted term
SELECT $$'ok':1 'a':0$$::ftsdoc;                       -- ERROR: tf must be >= 1
SELECT $$'b':1@2 'a':1@1$$::ftsdoc;                    -- ERROR: terms not sorted
SELECT $$'a':2@5,5$$::ftsdoc;                          -- ERROR: positions not ascending
SELECT $$'a':2@1$$::ftsdoc;                            -- ERROR: fewer positions than tf

DROP TABLE rt2;
DROP TABLE rt;

-- ============================================================================
-- Crash regression (issue: SIGABRT in add_posting / SIGSEGV in fts_doc_matches
-- on the pending-list + flush path with long punctuation-dense tokens).  The
-- readers now validate each pending document (fts_doc_is_valid) before trusting
-- its term offsets, so a malformed page is skipped with a WARNING instead of
-- crashing.  This exercises the valid long-token path end to end (build empty
-- -> pending insert -> @@@/count/phrase scan over pending -> VACUUM flush ->
-- scan again); it must complete and return stable counts, never crash.
-- ============================================================================
CREATE TABLE crashreg (id bigint, subject text, from_addr text, mid text);
CREATE INDEX crashreg_fts ON crashreg
  USING fts (to_ftsdoc('english'::regconfig,
    COALESCE(subject,'') || ' ' || COALESCE(from_addr,'') || ' ' || COALESCE(mid,'')))
  WITH (positions = on);
-- inserts go to the pending list (index already exists); long base64/msgid-like
-- single tokens (>64 bytes -> the hash-key chaining path) + a high-tf term.
INSERT INTO crashreg
SELECT g, 'Re: meeting notes ' || g,
       'user' || g || '@example.com',
       'rIdUrvZaMegl2LcXsPOkRgaQKN5dyOoMF4hWSNJ5h-H4fN-LT5ODLPwFRG7sutCKpAcAWzTs' || g || '=@pm.me'
FROM generate_series(1, 400) g;
SET enable_seqscan = off;
-- crash-2 path: count(*) pushdown + phrase over pending docs
SELECT count(*) AS pending_word_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','notes');
SELECT count(*) AS pending_phrase_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','"meeting notes"');
-- crash-1 path: flush the pending list into a segment
VACUUM crashreg;
-- same queries after the flush must return the same counts
SELECT count(*) AS flushed_word_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','notes');
SELECT count(*) AS flushed_phrase_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','"meeting notes"');
RESET enable_seqscan;
DROP TABLE crashreg;

-- ============================================================================
-- Crash regression (issue: SIGSEGV in fts_doc_matches <- bm25_collect_matches
-- <- bm25_gettuple, intermittent, in the SEGMENT posting-decode path).  Root
-- cause: bm25_decode_term read a block header's `count` from disk and unpacked
-- that many values into fixed 128-element stack arrays (gaps/tfs/dls) with no
-- bound check -- a torn/corrupt header with count > BM25_BLOCK_SIZE overflowed
-- the stack (the WAND loader already clamped; this decoder did not).  The fix
-- clamps count to BM25_BLOCK_SIZE and stops decoding a block whose declared
-- byte lengths run past the page.  This exercises the decoder over a large
-- multi-block posting list (df >> 128, with positions) through count/phrase
-- scans and a merge; it must complete with stable counts.
-- ============================================================================
CREATE TABLE decreg (id int, body text);
CREATE INDEX decreg_idx ON decreg USING fts (to_ftsdoc('simple', body)) WITH (positions = on);
-- 'common' appears in every row -> a df=4000 posting list spanning ~32 blocks;
-- 'alpha beta' phrase spans blocks too (positions decoded across block boundaries).
INSERT INTO decreg SELECT g, 'alpha beta common tok' || (g % 200) FROM generate_series(1, 4000) g;
VACUUM decreg;                              -- flush pending -> segment blocks
SELECT fts_merge('decreg_idx'::regclass);   -- one segment; longest posting lists
SET enable_seqscan = off;
SELECT count(*) AS common_df FROM decreg
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','common');
SELECT count(*) AS phrase_hits FROM decreg
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','"alpha beta"');
RESET enable_seqscan;
DROP TABLE decreg;

-- ============================================================================
-- Coverage: exercise paths the main suite misses (ftsquery binary recv, the
-- <=> commutator, a parallel-built index + parallel merge, and an empty-index
-- build).  These are all reachable via SQL and were previously untested.
-- ============================================================================
-- ftsquery binary send/recv round-trip (ftsquery_recv): COPY BINARY out+back.
CREATE TEMP TABLE qrt (id int, q ftsquery);
INSERT INTO qrt VALUES
  (1, 'alpha & beta'::ftsquery),
  (2, 'alpha | (beta & !gamma)'::ftsquery),
  (3, '"quick brown fox"'::ftsquery),
  (4, 'NEAR(alpha beta, 3)'::ftsquery),
  (5, 'quick* & alpha'::ftsquery);
COPY qrt TO '/tmp/pg_fts_qrt.bin' WITH (FORMAT binary);
CREATE TEMP TABLE qrt2 (id int, q ftsquery);
COPY qrt2 FROM '/tmp/pg_fts_qrt.bin' WITH (FORMAT binary);
SELECT bool_and(ftsquery_send(a.q) = ftsquery_send(b.q)) AS ftsquery_binary_roundtrip_ok
FROM qrt a JOIN qrt2 b USING (id);

-- the <=> distance commutator: query <=> doc must equal doc <=> query.
SELECT (to_ftsquery('quick') <=> to_ftsdoc('the quick brown fox'))
     = (to_ftsdoc('the quick brown fox') <=> to_ftsquery('quick')) AS commutator_ok;

-- parallel index build + parallel merge over a table big enough to split.
SET max_parallel_maintenance_workers = 2;
SET min_parallel_table_scan_size = 0;
CREATE TABLE parbuild (id int, body text);
INSERT INTO parbuild SELECT g, 'term'||(g%500)||' common alpha beta' FROM generate_series(1, 20000) g;
CREATE INDEX parbuild_idx ON parbuild USING fts (to_ftsdoc('simple', body));
SELECT fts_merge('parbuild_idx'::regclass) IS NOT NULL AS merged;
SET enable_seqscan = off;
SELECT count(*) AS par_hits FROM parbuild
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','common');
RESET enable_seqscan;
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
DROP TABLE parbuild;

-- empty-table index build (bm25_buildempty / a build with zero rows).
CREATE TABLE emptydoc (id int, body text);
CREATE INDEX emptydoc_idx ON emptydoc USING fts (to_ftsdoc('simple', body));
SELECT count(*) AS empty_hits FROM emptydoc
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','anything');
DROP TABLE emptydoc;

-- ============================================================================
-- Coverage: highlight/snippet, canonical ftsdoc parsing (positions + escapes +
-- error paths), ftsdoc binary recv WITH positions, and regex-query trigram
-- extraction -- functions the main suite exercises only lightly.
-- ============================================================================
-- fts_highlight / fts_snippet with default and custom markers + boolean/phrase.
SELECT fts_highlight('the quick brown fox jumps', 'quick & fox'::ftsquery) AS hl_default;
SELECT fts_highlight('the quick brown fox', 'quick'::ftsquery, '[', ']') AS hl_custom;
SELECT fts_highlight('nothing matches here', 'zzz'::ftsquery) AS hl_nomatch;
SELECT fts_snippet(repeat('alpha beta gamma delta ', 20) || 'needle tail',
                   'needle'::ftsquery) AS snip_default;
SELECT fts_snippet('short doc with needle', 'needle'::ftsquery,
                   '<<', '>>', ' ... ', 5) AS snip_custom;
SELECT fts_snippet('the quick brown fox', '"quick brown"'::ftsquery) AS snip_phrase;

-- canonical ftsdoc parsing: positions, repeated tf, escaped quote/backslash.
SELECT ($$'brown':1@3 'fox':2@2,5 'quick':1@1$$::ftsdoc)::text AS canon_positions;
SELECT ($$'a''b':1@1 'c\\d':1@2$$::ftsdoc)::text AS canon_escapes;
-- malformed canonical input -> clean errors (parser error branches).
SELECT $$'ok':1 'bad$$::ftsdoc;             -- unterminated quoted term
SELECT $$'ok':1 'x':abc$$::ftsdoc;          -- non-numeric tf
SELECT $$'z':1@ $$::ftsdoc;                 -- '@' with no positions

-- ftsdoc binary recv carrying positions (COPY BINARY of a positional doc).
CREATE TEMP TABLE drt (id int, d ftsdoc);
INSERT INTO drt VALUES (1, to_ftsdoc('alpha beta alpha gamma alpha')); -- alpha tf=3, positions
COPY drt TO '/tmp/pg_fts_drt.bin' WITH (FORMAT binary);
CREATE TEMP TABLE drt2 (id int, d ftsdoc);
COPY drt2 FROM '/tmp/pg_fts_drt.bin' WITH (FORMAT binary);
SELECT bool_and(ftsdoc_send(a.d) = ftsdoc_send(b.d)) AS doc_pos_binary_roundtrip_ok
FROM drt a JOIN drt2 b USING (id);

-- regex-query trigram extraction (fts_regex_trigrams) over varied patterns.
SELECT to_ftsdoc('the quicksand shifts') @@@ '/quick.*/'::ftsquery AS rx_star;
SELECT to_ftsdoc('color colour') @@@ '/colou?r/'::ftsquery AS rx_opt;
SELECT to_ftsdoc('cat bat hat') @@@ '/[cbh]at/'::ftsquery AS rx_class;
SELECT to_ftsdoc('foobar') @@@ '/foo|xyz/'::ftsquery AS rx_alt;

-- ============================================================================
-- Coverage: force the size-tiered segment merge (many small segments -> group
-- merge, bm25_merge_one_group / bm25_merge_group_to_seg) and a parallel index
-- build over a larger table (bm25_parallel_build_main), plus a delete/vacuum
-- compaction cycle (tombstone drop during merge).
-- ============================================================================
CREATE TABLE segmerge (id int, body text);
CREATE INDEX segmerge_idx ON segmerge USING fts (to_ftsdoc('simple', body));
-- many small INSERT batches, each flushed to its own segment via VACUUM, so a
-- later fts_merge has similarly-sized segments to group-merge.
DO $$
BEGIN
  FOR b IN 0..7 LOOP
    INSERT INTO segmerge SELECT b*1000 + g, 'common term'||((b*1000+g)%300)||' alpha'
      FROM generate_series(1, 1000) g;
    PERFORM fts_vacuum('segmerge_idx'::regclass);  -- flush this batch to a segment
  END LOOP;
END $$;
SELECT fts_merge('segmerge_idx'::regclass) IS NOT NULL AS grouped;   -- size-tiered group merge
-- delete a chunk + vacuum: tombstones must be dropped by the next merge.
DELETE FROM segmerge WHERE id % 3 = 0;
VACUUM segmerge;
SELECT fts_vacuum('segmerge_idx'::regclass) IS NOT NULL AS compacted;
SET enable_seqscan = off;
SELECT count(*) > 0 AS merge_hits FROM segmerge
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','common');
RESET enable_seqscan;
DROP TABLE segmerge;

-- parallel index build: a larger table + forced workers so the parallel build
-- leader/worker paths (bm25_parallel_build_main) actually run.
CREATE TABLE parbig (id int, body text);
INSERT INTO parbig SELECT g, 'word'||(g%1000)||' shared alpha beta gamma delta epsilon'
  FROM generate_series(1, 60000) g;
SET max_parallel_maintenance_workers = 3;
SET min_parallel_table_scan_size = 0;
SET maintenance_work_mem = '64MB';
ALTER TABLE parbig SET (parallel_workers = 3);
CREATE INDEX parbig_idx ON parbig USING fts (to_ftsdoc('simple', body));
SET enable_seqscan = off;
SELECT count(*) > 0 AS parbig_hits FROM parbig
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','shared');
RESET enable_seqscan;
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
RESET maintenance_work_mem;
DROP TABLE parbig;

-- ============================================================================
-- Coverage: the BM25 scoring functions (fts_bm25 / fts_bm25_opts / fts_bm25f)
-- across all variants and parameter paths -- pure scalar functions, so these
-- are deterministic and index-free.
-- ============================================================================
-- fts_bm25: default scoring, with and without an explicit per-term df array.
SELECT round(fts_bm25(to_ftsdoc('the quick brown fox'), 'quick & fox'::ftsquery,
                      1000.0, 12.0)::numeric, 4) AS bm25_default;
SELECT round(fts_bm25(to_ftsdoc('the quick brown fox'), 'quick'::ftsquery,
                      1000.0, 12.0, ARRAY[50.0])::numeric, 4) AS bm25_with_dfs;
SELECT fts_bm25(to_ftsdoc('no match here'), 'zzz'::ftsquery, 1000.0, 12.0) AS bm25_nomatch;

-- fts_bm25_opts: every variant + custom k1/b.
SELECT v AS variant,
       round(fts_bm25_opts(to_ftsdoc('the quick brown fox jumps'),
                           'quick & fox'::ftsquery,
                           1000.0, 12.0, 1.2, 0.75, v)::numeric, 4) AS score
FROM unnest(ARRAY['lucene','robertson','atire','bm25+','bm25l']) AS v
ORDER BY v;
-- non-default k1/b (parameter path).
SELECT round(fts_bm25_opts(to_ftsdoc('alpha beta alpha gamma'),
                           'alpha'::ftsquery, 500.0, 8.0, 2.0, 0.5, 'lucene')::numeric, 4)
       AS bm25_opts_tuned;

-- fts_bm25f: multi-field weighted scoring (title weighted higher than body).
SELECT round(fts_bm25f(
         ARRAY[to_ftsdoc('quick fox'), to_ftsdoc('the quick brown fox runs fast')],
         'quick & fox'::ftsquery,
         ARRAY[2.0, 1.0],          -- field weights (title x2, body x1)
         1000.0,
         ARRAY[3.0, 10.0])::numeric, 4) AS bm25f_score;
