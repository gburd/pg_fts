\pset footer off
CREATE EXTENSION IF NOT EXISTS pg_fts;
SELECT extversion FROM pg_extension WHERE extname='pg_fts';
-- fresh-session first statement: empty array
SELECT 'first_empty' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, '{}'::float8[]);
SELECT 'null' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2);
SELECT 'ref_500_1' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, ARRAY[500, 1]::float8[]);
SELECT 'short_500' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, ARRAY[500]::float8[]);
SELECT 'empty_after_500' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, '{}'::float8[]);
SELECT 'short_10' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, ARRAY[10]::float8[]);
SELECT 'empty_after_10' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, '{}'::float8[]);
SELECT 'opts_short_500' AS c, fts_bm25_opts(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, 1.2, 0.75, 'lucene', ARRAY[500]::float8[]);
SELECT 'opts_null' AS c, fts_bm25_opts(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, 1.2, 0.75, 'lucene', NULL);
SELECT 'opts_ref_500_1' AS c, fts_bm25_opts(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1000, 2, 1.2, 0.75, 'lucene', ARRAY[500,1]::float8[]);
-- large N widens the window
SELECT 'bigN_ref' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1e12, 2, ARRAY[123456789, 987654321]::float8[]);
SELECT 'bigN_empty' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1e12, 2, '{}'::float8[]);
SELECT 'bigN_null' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | beta'), 1e12, 2);
-- duplicate terms take two slots
SELECT 'alpha' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha'), 1000, 2);
SELECT 'alpha|alpha' AS c, fts_bm25(to_ftsdoc('simple', 'alpha beta'), to_ftsquery('simple', 'alpha | alpha'), 1000, 2);
