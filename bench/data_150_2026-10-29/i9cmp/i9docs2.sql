DROP TABLE IF EXISTS docs2;
CREATE TABLE docs2 AS
SELECT 1 AS id, 'html-tags' AS kind, string_agg('<a href="x' || g || '" class="c y z"> w' || g || ' v u t ', '') AS t FROM generate_series(1, 5000) g
UNION ALL SELECT 2, 'html-comments', string_agg('<!-- a comment with spaces ' || g || ' --> b' || g || ' c d e ', '') FROM generate_series(1, 5000) g
UNION ALL SELECT 3, 'script-style', string_agg('<script>var a' || g || ' = 1;</script> v' || g || ' w x y <style>.c{x:y}</style> ', '') FROM generate_series(1, 5000) g
UNION ALL SELECT 4, 'mixed-markup', string_agg(CASE g % 3 WHEN 0 THEN '<p class="a b">' WHEN 1 THEN '<!-- n o p -->' ELSE '</p>' END || ' word' || g || ' and ' || 'https://e.com/a b@c.org ', '') FROM generate_series(1, 9000) g;
