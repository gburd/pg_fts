CREATE TABLE docs AS
SELECT 1 AS id, 'plain' AS kind, repeat('alpha beta gamma delta ', 6000) AS t                      -- 24,000 tokens
UNION ALL SELECT 2, 'html-tags-every-200b', string_agg('<a href="x' || g || '" class="c y z"> word' || g || ' and more text here ', '') FROM generate_series(1, 2000) g
UNION ALL SELECT 3, 'html-comments', string_agg('<!-- a comment with spaces ' || g || ' --> body' || g || ' text ', '') FROM generate_series(1, 3000) g
UNION ALL SELECT 4, 'urls-emails', string_agg('see https://ex.com/p?q=' || g || '&r=s and mail u' || g || '@ex.org now ', '') FROM generate_series(1, 2500) g
UNION ALL SELECT 5, 'hyphenated', string_agg('state-of-the-art ' || g || ' co-op re-entry well-known ', '') FROM generate_series(1, 4000) g
UNION ALL SELECT 6, 'cjk-no-space', repeat(convert_from('\xe6bca2e5ad97e69687e7aba0'::bytea, 'UTF8'), 3000) || repeat(' w', 17000)
UNION ALL SELECT 7, 'cjk-spaced', repeat(convert_from('\xe6bca2e5ad97'::bytea, 'UTF8') || ' ', 20000)
UNION ALL SELECT 8, 'script-style', string_agg('<script>var a' || g || ' = 1;</script> visible' || g || ' <style>.c{x:y}</style> ', '') FROM generate_series(1, 2500) g
UNION ALL SELECT 9, 'numbers', string_agg(g::text || '.5 ' || (g*3)::text || ' -' || g::text || ' ', '') FROM generate_series(1, 8000) g
UNION ALL SELECT 10, 'long-words', string_agg(repeat('x', 40) || g || ' ', '') FROM generate_series(1, 18000) g;
