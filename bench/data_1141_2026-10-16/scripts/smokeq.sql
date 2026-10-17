CREATE TABLE a (id int PRIMARY KEY, body text);
INSERT INTO a SELECT g,
  'alpha w' || (g % 60) || ' beta' || (CASE WHEN g % 3 = 0 THEN ' gamma' ELSE '' END)
    || ' united states of ' || (CASE WHEN g % 7 = 0 THEN 'america' ELSE 'europe' END)
  FROM generate_series(1, 4000) g;
CREATE INDEX a_on ON a USING fts (to_ftsdoc('simple', body)) WITH (positions=on);
SET enable_seqscan = off;
SELECT q, (SELECT count(*) FROM a WHERE to_ftsdoc('simple', body) @@@ q::ftsquery) AS n,
          (SELECT count(*) FROM a WHERE fts_match(to_ftsdoc('simple', body), q::ftsquery)) AS truth
FROM unnest(ARRAY['united <2> of','united w/3 america','alphx~1','united <2> states']) q;
DROP TABLE a;
