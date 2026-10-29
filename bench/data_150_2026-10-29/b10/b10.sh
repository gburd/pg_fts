#!/bin/bash
# b10.sh: Codeberg #6 reporter's shape `rare83 & (10 terms)` (a rare term in ~83 docs, an OR of 10 common terms, no row
# matches both) on the reporter's 400k corpus (setup6 + 83 'build' rows), 1.14.3 (PGXN zip) vs 1.15.0 (final.tgz), PG17+18.
# Correctness first (top-10 ids equal across builds and to pg_fts.bestfirst=off), then median of 21 x 3 runs.
O=/nvme/b10; mkdir -p $O; exec > $O/b10.log 2>&1
cd $O; [ -f pg_fts-1.14.3.zip ] || curl -sfLO https://api.pgxn.org/dist/pg_fts/1.14.3/pg_fts-1.14.3.zip
cat > setup.sql <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS docs;
SELECT setseed(0.6);
CREATE TABLE docs (id bigint PRIMARY KEY, body text NOT NULL);
INSERT INTO docs
SELECT g, concat_ws(' ',
         'w' || (random()*2000)::int, 'w' || (random()*2000)::int,
         'w' || (random()*2000)::int, 'w' || (random()*2000)::int,
         CASE WHEN random() < 0.25 OR g = 123456 THEN 'apple' END,
         CASE WHEN random() < 0.25 THEN 'banana' END,
         CASE WHEN g = 123456 THEN 'rare' END,
         CASE WHEN g % 4819 = 7 THEN 'build' END)
FROM generate_series(1, 400000) g;
-- the reporter's shape returns 0 rows: no 'build' row holds any of the ten OR terms
UPDATE docs SET body = regexp_replace(body, '\m(apple|banana|w1|w2|w3|w4|w5|w6|w7|w8)\M', '', 'g') WHERE body ~ '\mbuild\M';
CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body));
VACUUM ANALYZE docs;
SELECT count(*) FILTER (WHERE body ~ '\mbuild\M') AS build_rows, md5(string_agg(body, '|' ORDER BY id)) FROM docs;
SQL
Q10="build & (apple | banana | w1 | w2 | w3 | w4 | w5 | w6 | w7 | w8)"
Q10b="rare & (apple | banana | w1 | w2 | w3 | w4 | w5 | w6 | w7 | w8)"
for M in 17 18; do for L in v1143 r150; do
  PFX=$O/pfx$M-$L; [ -d $PFX ] || cp -a /nvme/pg$M $PFX; B=$PFX/bin
  S=$O/src$M-$L; [ -d $S ] && mv $S /nvme/trash_b10_$RANDOM; mkdir -p $S
  if [ $L = v1143 ]; then (cd $S && unzip -q $O/pg_fts-1.14.3.zip); S=$S/pg_fts-1.14.3; else tar xzf /nvme/g150/final.tgz -C $S; fi
  (cd $S && make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1)
  D=$O/d$M-$L; P=56$M; [ $L = r150 ] && P=57$M
  [ -d $D ] && mv $D /nvme/trash_b10_$RANDOM; $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=2GB\njit=off\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  PS="$B/psql -X -q -h /tmp -p $P -U postgres -d postgres"
  echo "== PG$M $L so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8) $($PS -At -f setup.sql | tail -1)"
  for q in "$Q10" "$Q10b"; do
    r=$($PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT coalesce(string_agg(id::text, ','), '<none>') FROM (SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ '$q'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> '$q'::ftsquery LIMIT 10) s" | tail -1)
    w=$($PS -At -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SET pg_fts.bestfirst=off" -c "SELECT coalesce(string_agg(id::text, ','), '<none>') FROM (SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ '$q'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> '$q'::ftsquery LIMIT 10) s" | tail -1)
    h=$($PS -At -c "SELECT count(*) FROM docs WHERE fts_match(to_ftsdoc('simple', body), '$q'::ftsquery)")
    echo "  [$q] top10=$r walk_equal=$([ "$r" = "$w" ] && echo yes || echo NO) heap_matches=$h"
    for run in 1 2 3; do
      ms=$( { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "\\timing on"; for i in $(seq 25); do echo "\\o /dev/null"; echo "SELECT id FROM docs WHERE to_ftsdoc('simple', body) @@@ '$q'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> '$q'::ftsquery LIMIT 10;"; echo "\\o"; done; } | $PS 2>&1 | grep -oE 'Time: [0-9.]+' | awk '{print $2}' | tail -21 | sort -n | awk '{a[NR]=$1} END {print a[11]}')
      echo "    run $run median of 21 (after 4 warm): $ms ms"
    done
  done
  $B/pg_ctl -D $D -w stop >/dev/null
done; done
echo B10_DONE
