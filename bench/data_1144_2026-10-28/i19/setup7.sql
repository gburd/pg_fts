-- reporter's corpus (Codeberg #6), made deterministic: setseed before random()
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS docs;
SELECT setseed(0.6);
CREATE TABLE docs (id bigint PRIMARY KEY, body text NOT NULL);
INSERT INTO docs
SELECT g, concat_ws(' ',
         'w' || (random()*2000)::int, 'w' || (random()*2000)::int,
         'w' || (random()*2000)::int, 'w' || (random()*2000)::int,
         CASE WHEN random() < 0.25 OR g = 123456 THEN 'apple' END,
         CASE WHEN random() < 0.25 THEN 'banana' END,
         CASE WHEN g = 123456 THEN 'rare' END)
FROM generate_series(1, 400000) g;
CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE docs;
SELECT count(*) AS n, count(*) FILTER (WHERE body ~ '\mapple\M') AS apple,
       count(*) FILTER (WHERE body ~ '\mbanana\M') AS banana, fts_index_nsegments('docs_fts') AS nseg,
       md5(string_agg(body, '|' ORDER BY id)) AS corpus_md5 FROM docs;
