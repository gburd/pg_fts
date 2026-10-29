SET client_min_messages = warning;
DROP TABLE IF EXISTS lpm;
CREATE TABLE lpm AS
SELECT 1 AS id, string_agg('<a href="x' || g || '" class="c y z"> w' || g || ' v u t ', '') AS t FROM generate_series(1, 5000) g
UNION ALL SELECT 2, string_agg('<!-- a comment with spaces ' || g || ' --> b' || g || ' c d e ', '') FROM generate_series(1, 5000) g
UNION ALL SELECT 3, string_agg('<script>var a' || g || ' = 1;</script> v' || g || ' w x y <style>.c{x:y}</style> ', '') FROM generate_series(1, 5000) g;
ALTER TABLE lpm ADD COLUMN d ftsdoc;
UPDATE lpm SET d = to_ftsdoc('simple', t);
SELECT id, ftsdoc_length(d), d @@@ 'href | class'::ftsquery, d @@@ 'comment | spaces'::ftsquery, d @@@ 'var'::ftsquery FROM lpm ORDER BY id;
SELECT count(*) FROM lpm, generate_series(1, 4999) g WHERE id = 1 AND d @@@ ('"t w' || (g + 1) || '"')::ftsquery;
