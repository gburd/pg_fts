CREATE EXTENSION IF NOT EXISTS pg_fts;
SELECT to_ftsdoc('simple', 'fresh apple') @@@ 'fresh:D'::ftsquery AS d, to_ftsdoc('simple', 'fresh apple') @@@ 'fresh:A'::ftsquery AS a, to_ftsdoc('simple', 'fresh apple') @@@ 'fresh:ABCD'::ftsquery AS abcd;
