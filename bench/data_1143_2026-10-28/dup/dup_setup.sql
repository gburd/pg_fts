-- 200 rows in a segment, 50 'fresh' rows pending (flush threshold off)
DROP TABLE IF EXISTS dp;
CREATE TABLE dp (id int, body text) WITH (autovacuum_enabled = off);
INSERT INTO dp SELECT g, 'old apple' FROM generate_series(1, 200) g;
CREATE INDEX dp_fts ON dp USING fts (to_ftsdoc('simple', body));
SET pg_fts.pending_flush_threshold = 0;
INSERT INTO dp SELECT g, 'fresh apple' FROM generate_series(201, 250) g;
SELECT (fts_index_stats('dp_fts')).*;
