#!/bin/bash
# Which index blocks does one rare (slovakia) k10 query touch, and how often per query?  Instrument
# with pg_buffercache usagecount is too coarse; instead count ReadBuffer per block via a
# temporary LOG probe is not available in the release binary -> use EXPLAIN BUFFERS by phase:
# (1) dict lookups only: fts_index_df (global df, dict_seek + dict page per segment)
# (2) whole ranked query
P="/nvme/pg17/bin/psql -h /tmp -U postgres -X -q -At"
for q in slovakia year; do
  $P -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$q') ORDER BY d <=> to_ftsquery('english','$q') LIMIT 10) s" | grep -m1 "Buffers"
  $P -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT fts_index_df('docs_idx', to_ftsquery('english','$q'))" | grep -m1 "Buffers"
done
# dictionary index chain length (pages) = how many index pages a dict_seek can walk
$P -c "SELECT count(*) FROM generate_series(1, (pg_relation_size('docs_idx')/8192)::int - 1) b" >/dev/null
