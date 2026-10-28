#!/bin/bash
# A1: where the 2.19M stored-column build's time goes on this host (PG 17.10, 8 workers, mwm 8GB):
# DEBUG1 merge timings + a wall split.  Two builds, interleaved with nothing else.
B=/nvme/rm/pfx17-wk/bin; P="$B/psql -X -q -h /tmp -p 6317 -U postgres"
O=/nvme/rm/a1; mkdir -p $O
for r in 1 2; do
  $P -c "DROP INDEX IF EXISTS docs_fts2"
  L0=$(wc -l < /nvme/rm/dwk/log)
  s=$(date +%s.%N)
  $P -c "SET client_min_messages=warning" -c "SET log_min_messages=debug1" -c "CREATE INDEX docs_fts2 ON docs USING fts (d)"
  e=$(date +%s.%N)
  echo "run $r build_s=$(echo "$e - $s" | bc) size=$($P -At -c "select pg_relation_size('docs_fts2')") nseg=$($P -At -c "select fts_index_nsegments('docs_fts2')")"
  tail -n +$L0 /nvme/rm/dwk/log | grep -E "pg_fts build|merg|flushed|segments|pack|collapse" | cut -c1-220 > $O/build_log_$r.txt
  grep -cE "flushed segment" $O/build_log_$r.txt
  grep -E "merging|merged|pack|took|in [0-9.]+ s" $O/build_log_$r.txt | head -8
done
$P -c "DROP INDEX IF EXISTS docs_fts2"
echo A1PROF_DONE
