#!/bin/bash
# I7 local gate: release (pgR112) vs I7 (pgF) on ONE data directory (no format change).
# Correctness: ranked ids + index scores identical on a band set, single- and multi-segment,
# after deletes, after a merge (directory rebuilt), with pg_fts.doclen_cache_mb=0 (cache off).
# Buffers per query reported for both.
set -uo pipefail
W=/tmp/upq111; D=$W/f121data; PORT=55482
[ -d $D ] && mv $D $D.old.$$
$W/pgR112/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=1GB\nmaintenance_work_mem=64MB\nautovacuum=off\n" >> $D/postgresql.conf
use() { for v in pgR112 pgF; do $W/$v/bin/pg_ctl -D $D -w stop -m fast >/dev/null 2>&1; done; $W/$1/bin/pg_ctl -D $D -l $D/log -w start >/dev/null; ARM=$1; }
P() { $W/$ARM/bin/psql -h /tmp -p $PORT -U postgres -X -q -At "$@"; }
use pgR112
P -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE d (id bigint PRIMARY KEY, t text)" >/dev/null || exit 1
# vocabulary large enough for a multi-page dictionary index: ~400k distinct terms
P -c "INSERT INTO d SELECT g, 'w' || (g % 97) || ' x' || (g % 13) || ' u' || g || ' v' || (g::bigint * 7919 % 400000) || ' ' || CASE WHEN g % 5 = 0 THEN 'rare' ELSE 'common' END || CASE WHEN g % 11 = 0 THEN ' hot dog' ELSE '' END FROM generate_series(1, 400000) g" >/dev/null
P -c "CREATE INDEX d_fts ON d USING fts (to_ftsdoc('simple', t)) WITH (positions = on)" -c "VACUUM ANALYZE d" >/dev/null
n=$(P -c "select count(*) from d"); [ "$n" = 400000 ] || { echo "SETUP FAILED rows=$n"; exit 1; }
QS=("rare" "common" "w5" "u12345" "v77" "rare & w5" "w1 | w2 | w3 | rare" "\"hot dog\"" "aaaa" "zzzz" "u399999" "v0")
gate() {  # $1 label
  local out=$W/f121_$1_$ARM.txt; : > $out
  for q in "${QS[@]}"; do
    P -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SET extra_float_digits=3" \
      -c "SELECT string_agg(id::text || ':' || round(s::numeric, 9)::text, ',' ORDER BY s, id) FROM (SELECT id, to_ftsdoc('simple', t) <=> '$q'::ftsquery s FROM d WHERE to_ftsdoc('simple', t) @@@ '$q'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> '$q'::ftsquery LIMIT 20) z" >> $out 2>&1
    P -c "SELECT count(*) FROM d WHERE to_ftsdoc('simple', t) @@@ '$q'::ftsquery" >> $out 2>&1
  done
  echo "$1 $ARM nseg=$(P -c "select fts_index_nsegments('d_fts')") md5=$(md5sum < $out | cut -c1-12) lines=$(wc -l < $out) errors=$(grep -c ERROR $out) nonempty_results=$(grep -c ':' $out) total_count=$(grep -v ':' $out | paste -sd+ | bc)"
}
bufs() {  # buffers for a rare k10, second execution
  for q in rare v77 "rare & w5"; do
    b=$(P -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT id FROM d WHERE to_ftsdoc('simple', t) @@@ '$q'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> '$q'::ftsquery LIMIT 10" -c "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT id FROM d WHERE to_ftsdoc('simple', t) @@@ '$q'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> '$q'::ftsquery LIMIT 10" | sed -n '/^Limit/,/^Planning/p' | grep -m1 "Buffers" | grep -o "hit=[0-9]*.*")
    echo -n "[$q] $b  "
  done; echo
}
for phase in one multi deleted merged; do
  case $phase in
    multi)  use pgR112; for i in 1 2 3; do P -c "INSERT INTO d SELECT 400000*$i+g, 'w' || (g % 97) || ' u' || (400000*$i+g) || ' v' || (g::bigint * 31 % 400000) || CASE WHEN g % 5 = 0 THEN ' rare' ELSE ' common' END FROM generate_series(1, 60000) g" -c "SELECT fts_merge('d_fts')" >/dev/null; done
            P -c "INSERT INTO d SELECT 900000+g, 'w3 rare u' || (900000+g) FROM generate_series(1, 5000) g" -c "VACUUM d" >/dev/null ;;
    deleted) use pgR112; P -c "DELETE FROM d WHERE id % 7 = 0" -c "VACUUM d" >/dev/null ;;
    merged) use pgR112; P -c "SELECT fts_merge('d_fts')" >/dev/null ;;
  esac
  for arm in pgR112 pgF; do use $arm; gate $phase; echo -n "  buffers $ARM: "; bufs; done
  cmp -s $W/f121_${phase}_pgR112.txt $W/f121_${phase}_pgF.txt && echo "  $phase: IDENTICAL" || { echo "  $phase: DIFFER"; diff $W/f121_${phase}_pgR112.txt $W/f121_${phase}_pgF.txt | head -6; }
done
# cache off (budget 0) must also be identical: the chain walk
use pgF; PGOPTIONS="-c pg_fts.doclen_cache_mb=0" gate nocache
cmp -s $W/f121_merged_pgR112.txt $W/f121_nocache_pgF.txt && echo "  nocache: IDENTICAL to release" || echo "  nocache: DIFFER"
# same backend, directory changes under it: a long-lived session sees the new segment's terms
use pgF
{ echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"
  echo "SELECT 'before', count(*) FROM (SELECT id FROM d WHERE to_ftsdoc('simple', t) @@@ 'newterm'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> 'newterm'::ftsquery LIMIT 10) z;"
  echo "INSERT INTO d SELECT 2000000+g, 'newterm rare' FROM generate_series(1, 300) g;"
  echo "SELECT fts_merge('d_fts');"
  echo "SELECT 'after', count(*) FROM (SELECT id FROM d WHERE to_ftsdoc('simple', t) @@@ 'newterm'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> 'newterm'::ftsquery LIMIT 10) z;"
  echo "SELECT 'after_rare', count(*) FROM (SELECT id FROM d WHERE to_ftsdoc('simple', t) @@@ 'rare'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> 'rare'::ftsquery LIMIT 1000) z;"; } | P -f - 2>&1 | grep -E "before|after|ERROR" | tr '\n' ' '; echo
echo "  release on the same: $(use pgR112; P -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT count(*) FROM (SELECT id FROM d WHERE to_ftsdoc('simple', t) @@@ 'rare'::ftsquery ORDER BY to_ftsdoc('simple', t) <=> 'rare'::ftsquery LIMIT 1000) z")"
use pgR112; $W/pgR112/bin/pg_ctl -D $D -w stop >/dev/null
echo I7_GATE_DONE
