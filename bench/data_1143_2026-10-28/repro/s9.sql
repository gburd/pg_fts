CREATE EXTENSION IF NOT EXISTS pg_fts;
SELECT fts_bm25(d, q, 1e12, 20, '{}'::float8[]) AS empty, fts_bm25(d, q, 1e12, 20) AS nul,
       fts_bm25(d, q, 1e12, 20, ARRAY[1e9]::float8[]) = fts_bm25(d, q, 1e12, 20, array_prepend(1e9::float8, array_fill(1::float8, ARRAY[1999]))) AS short_eq
  FROM (SELECT to_ftsdoc('simple', string_agg('t' || g, ' ')) AS d,
               to_ftsquery('simple', string_agg('t' || g, ' | ')) AS q
          FROM generate_series(1, 2000) g) s;
