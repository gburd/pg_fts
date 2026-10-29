DROP TABLE IF EXISTS docs3;
CREATE TABLE docs3 AS
SELECT 1 AS id, 'long-script' AS kind, repeat('w ', 9000) || '<script>' || repeat('var zz = 1; ', 3500) || '</script>' || repeat(' w', 9000) AS t
UNION ALL SELECT 2, 'long-data-uri', repeat('w ', 9000) || '<img src="data:image/png;base64,' || repeat('QUJD', 7500) || '"> tail' || repeat(' w', 9000);
