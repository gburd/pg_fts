DROP TABLE IF EXISTS ds;
CREATE TABLE ds (id bigserial, body text) WITH (autovacuum_enabled = off);
INSERT INTO ds (body) SELECT 'old apple w' || (g % 50) FROM generate_series(1, 2000) g;
CREATE INDEX ds_fts ON ds USING fts (to_ftsdoc('simple', body));
