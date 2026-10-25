-- how many rows sit in slots freed by VACUUM (heap blocks below the table's high-water mark at refill time):
-- filler rows (n<0) placed into earlier blocks = slot reuse happened
SELECT format('filler rows %s, in reused slots (block < first filler-only region) %s, aborted-batch dead slots reused total ~ %s',
  count(*) FILTER (WHERE n < 0),
  count(*) FILTER (WHERE n < 0 AND (ctid::text::point)[0] < (SELECT max((ctid::text::point)[0]) FROM ag WHERE n > 0)),
  (SELECT count(*) FROM ag) - (SELECT count(DISTINCT (ctid::text::point)[0]) FROM ag) * 0)
FROM ag;
