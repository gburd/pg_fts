-- ci/cov_corpus.sql -- drive the engine's scale/feature branches under the
-- instrumented coverage build with a moderate high-vocabulary corpus (hits the
-- same multi-segment / dict-index / merge / positions / WAND-deep / vacuum
-- paths as a huge corpus, without a multi-hour -O0 build).  Not part of the
-- regression suite; invoked only by ci/coverage.sh when COV_CORPUS=1.
CREATE EXTENSION IF NOT EXISTS pg_fts;
SET maintenance_work_mem = '16MB';        -- force multiple flush segments
SET max_parallel_maintenance_workers = 2; -- exercise the parallel build path

-- High-vocabulary heavy-tail corpus: ~60k docs, each a few common terms + many
-- doc-unique tokens (drives dict + dict-index + trigram + posting-block paths).
CREATE TABLE ccorp (id serial, body text);
INSERT INTO ccorp(body)
  SELECT 'common w'||(g%64)||' '||
         (CASE WHEN g%2=0 THEN 'alpha ' ELSE '' END)||
         (CASE WHEN g%3=0 THEN 'beta ' ELSE '' END)||
         (CASE WHEN g%5=0 THEN 'gamma ' ELSE '' END)||
         (CASE WHEN g%7=0 THEN 'delta ' ELSE '' END)||
         (SELECT string_agg('u'||g||'x'||k, ' ') FROM generate_series(1, 4 + (g%12)) k)
  FROM generate_series(1, 60000) g;

-- positions-ON expression index over a high-tf-capable corpus (positions build +
-- phrase-from-index + positions merge paths)
CREATE INDEX ccorp_pos ON ccorp USING fts (to_ftsdoc('english', body)) WITH (positions = on);
-- trigrams-ON index (trigram write + merge + regex/fuzzy read paths)
CREATE INDEX ccorp_trg ON ccorp USING fts (to_ftsdoc('simple', body)) WITH (trigrams = on);
-- default (plain-column stored ftsdoc) index for the count pushdown + KNN
ALTER TABLE ccorp ADD COLUMN d ftsdoc;
UPDATE ccorp SET d = to_ftsdoc('english', body);
CREATE INDEX ccorp_d ON ccorp USING fts (d);

SET enable_seqscan = off;
-- WAND (1-3 terms) and MaxScore (>=4 terms) ranked scans, shallow + deep k
SELECT count(*) FROM (SELECT id FROM ccorp WHERE d @@@ to_ftsquery('english','common') ORDER BY d <=> to_ftsquery('english','common') LIMIT 10) x;
SELECT count(*) FROM (SELECT id FROM ccorp WHERE d @@@ to_ftsquery('english','common') ORDER BY d <=> to_ftsquery('english','common') LIMIT 500) x;
SELECT count(*) FROM (SELECT id FROM ccorp WHERE d @@@ to_ftsquery('english','alpha | beta') ORDER BY d <=> to_ftsquery('english','alpha | beta') LIMIT 50) x;
SELECT count(*) FROM (SELECT id FROM ccorp WHERE d @@@ to_ftsquery('english','alpha | beta | gamma | delta | common') ORDER BY d <=> to_ftsquery('english','alpha | beta | gamma | delta | common') LIMIT 100) x;
-- boolean + NOT + phrase + prefix + fuzzy + regex (index paths)
SELECT count(*) FROM ccorp WHERE d @@@ to_ftsquery('english','alpha & beta');
SELECT count(*) FROM ccorp WHERE d @@@ to_ftsquery('english','common & !alpha');
SELECT count(*) FROM ccorp WHERE to_ftsdoc('english',body) @@@ 'w1*'::ftsquery;
SELECT count(*) FROM ccorp WHERE to_ftsdoc('simple',body) @@@ 'commin~1'::ftsquery;   -- fuzzy via trigram
SELECT count(*) FROM ccorp WHERE to_ftsdoc('simple',body) @@@ '/^comm/'::ftsquery;    -- regex via trigram
-- count pushdown, df, stats, nsegments, anomaly
SELECT count(*) FROM ccorp WHERE d @@@ to_ftsquery('english','common');
SELECT fts_index_df('ccorp_d','alpha'::ftsquery);
SELECT ndocs::int > 0 FROM fts_index_stats('ccorp_d');
SELECT fts_index_nsegments('ccorp_d');
SELECT count(*) FROM fts_anomalous_docs('ccorp_d', 20);
SELECT count(*) FROM fts_anomalous_docs('ccorp_d', 20, 100);
SELECT count(*) FROM fts_search('ccorp_d','common'::ftsquery, 200);
RESET enable_seqscan;

-- maintenance paths: incremental insert -> pending, merge, delete -> tombstone,
-- vacuum reclaim, oversized-doc segment.
INSERT INTO ccorp(d) SELECT to_ftsdoc('english','common alpha late insert '||g) FROM generate_series(1,2000) g;
SELECT fts_merge('ccorp_d') IS NOT NULL;
DELETE FROM ccorp WHERE id % 4 = 0;
VACUUM ccorp;
SELECT fts_vacuum('ccorp_d') IS NOT NULL;
-- oversized doc after build (own-segment path)
INSERT INTO ccorp(d) SELECT to_ftsdoc('english', repeat('common ',5)||(SELECT string_agg('big'||k,' ') FROM generate_series(1,5000) k));
SET enable_seqscan = off;
SELECT count(*) > 0 FROM ccorp WHERE d @@@ to_ftsquery('english','common');
RESET enable_seqscan;
DROP TABLE ccorp;
