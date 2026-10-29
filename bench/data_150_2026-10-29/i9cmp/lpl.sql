CREATE TABLE lpl AS
SELECT 1 AS id, repeat('w ', 9000) || '<script>' || repeat('var zz = 1; ', 3500) || '</script>' || repeat(' w', 9000) AS t
UNION ALL SELECT 2, repeat('w ', 9000) || '<img src="data:image/png;base64,' || repeat('QUJD', 7500) || '"> tail' || repeat(' w', 9000);
SELECT id, ftsdoc_length(to_ftsdoc('simple', t)) AS doclen,
       to_ftsdoc('simple', t) @@@ 'zz | var | quj*'::ftsquery AS markup_words
  FROM lpl ORDER BY id;
DROP TABLE lpl;
