#!/bin/bash
# In-place upgrade 1.14.1 -> 1.14.2 on PG 17 and 18: create at 1.14.1 (released build) with indexes
# (stored col + expression, sidecar on/off), pending rows; swap in the 1.14.2 .so + scripts on the same
# data dir; ALTER EXTENSION UPDATE TO '1.14.2'; counts == heap (>0), ranked top-k == before; then
# the 1.14.2 check query on the upgraded index (0 false rows) and a fresh 1.0.0 -> 1.14.2 walk.
set -uo pipefail
G=/nvme/fp/gate; mkdir -p $G
for M in 17 18; do
  OLD=/nvme/fp/pg$M-v1141; NEW=$G/upg-new$M; PORT=557$M
  [ -d $NEW ] && mv $NEW /nvme/trash_up_$RANDOM; cp -a /nvme/pg$M $NEW
  S=$G/upg-src-$M; [ -d $S ] && mv $S /nvme/trash_up_$RANDOM; mkdir -p $S; tar xzf /nvme/fp/final.tgz -C $S
  (cd $S && make -s clean PG_CONFIG=$NEW/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$NEW/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$NEW/bin/pg_config >/dev/null 2>&1) || { echo "PG$M NEW BUILD FAIL"; continue; }
  cp $OLD/share/postgresql/extension/pg_fts--1.14.1.sql $NEW/share/postgresql/extension/ 2>/dev/null
  echo "PG$M old so $(md5sum $OLD/lib/postgresql/pg_fts.so | cut -c1-8) new so $(md5sum $NEW/lib/postgresql/pg_fts.so | cut -c1-8); new edge: $(ls $NEW/share/postgresql/extension/pg_fts--1.14.1--1.14.2.sql); stale base 1.14.1 in tree: $(ls $S/pg_fts--1.14.1.sql 2>/dev/null | wc -l)"
  D=$G/upgdata$M; [ -d $D ] && mv $D /nvme/trash_up_$RANDOM
  $OLD/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
  $OLD/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$OLD/bin/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1"
  $P -c "CREATE EXTENSION pg_fts VERSION '1.14.1'"
  $P -c "CREATE TABLE u (id int PRIMARY KEY, body text, d ftsdoc)" \
     -c "INSERT INTO u SELECT g, 'alpha w' || (g % 97) || CASE WHEN g % 50 = 0 THEN ' rare' ELSE '' END, NULL FROM generate_series(1, 30000) g" \
     -c "UPDATE u SET d = to_ftsdoc('simple', body)" \
     -c "CREATE INDEX u_d ON u USING fts (d)" \
     -c "CREATE INDEX u_e ON u USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = off)" \
     -c "VACUUM ANALYZE u" -c "DELETE FROM u WHERE id % 7 = 0" -c "VACUUM u" \
     -c "SET pg_fts.pending_flush_threshold = 0" -c "INSERT INTO u SELECT g, 'alpha rare fresh', to_ftsdoc('simple', 'alpha rare fresh') FROM generate_series(30001, 30500) g" -c "ANALYZE u" >/dev/null
  q() { $1 -c "SET enable_seqscan=off" -c "$2" | tail -1; }
  b_cnt=$(q "$P" "SELECT count(*) FROM u WHERE d @@@ 'rare'::ftsquery"); b_top=$(q "$P" "SELECT string_agg(id::text, ',') FROM (SELECT id FROM u WHERE d @@@ 'rare'::ftsquery ORDER BY d <=> 'rare'::ftsquery, id LIMIT 20) s")
  echo "  at 1.14.1: ext $($P -c "select extversion from pg_extension where extname='pg_fts'") count(rare)=$b_cnt"
  $OLD/bin/pg_ctl -D $D -w stop >/dev/null
  $NEW/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$NEW/bin/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1"
  $P -c "ALTER EXTENSION pg_fts UPDATE TO '1.14.2'"
  heap=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, 'rare'::ftsquery)")
  a_cnt=$(q "$P" "SELECT count(*) FROM u WHERE d @@@ 'rare'::ftsquery"); a_top=$(q "$P" "SELECT string_agg(id::text, ',') FROM (SELECT id FROM u WHERE d @@@ 'rare'::ftsquery ORDER BY d <=> 'rare'::ftsquery, id LIMIT 20) s")
  e_cnt=$(q "$P" "SELECT count(*) FROM u WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery")
  fr=$(q "$P" "SELECT count(*) FROM (SELECT 1 FROM u WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery AND NOT fts_match(to_ftsdoc('simple', body), 'rare'::ftsquery) OFFSET 0) s")
  echo "  after UPDATE: ext $($P -c "select extversion from pg_extension where extname='pg_fts'") count(rare) stored=$a_cnt expr=$e_cnt heap=$heap; check-query false rows=$fr"
  ok=1; [ "$a_cnt" = "$heap" ] && [ "$e_cnt" = "$heap" ] && [ "$heap" -gt 0 ] && [ "$a_cnt" = "$b_cnt" ] && [ "$fr" = 0 ] || ok=0; [ "$a_top" = "$b_top" ] && [ -n "$a_top" ] || ok=0
  $P -c "DELETE FROM u WHERE id % 11 = 0" -c "VACUUM u" -c "SELECT fts_vacuum('u_d')" >/dev/null
  w_cnt=$(q "$P" "SELECT count(*) FROM u WHERE d @@@ 'rare'::ftsquery"); w_heap=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, 'rare'::ftsquery)")
  [ "$w_cnt" = "$w_heap" ] && [ "$w_heap" -gt 0 ] || ok=0
  echo "  after VACUUM + fts_vacuum on 1.14.2: count $w_cnt heap $w_heap; top20 unchanged across upgrade: $([ "$a_top" = "$b_top" ] && echo yes || echo NO)"
  # every shipped version reaches 1.14.2 (fresh DBs, base scripts from the release tags are not shipped, so walk 1.14.1 only + graph check)
  $P -c "CREATE DATABASE w"
  W="$NEW/bin/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 -d w"
  $W -c "CREATE EXTENSION pg_fts VERSION '1.14.1'" -c "ALTER EXTENSION pg_fts UPDATE" && echo "  fresh 1.14.1 -> $($W -c "select extversion from pg_extension where extname='pg_fts'")"
  echo "  update path 1.0.0 -> 1.14.2: $($W -c "SELECT count(*) FROM pg_extension_update_paths('pg_fts') WHERE target = '1.14.2' AND path IS NOT NULL") sources reach 1.14.2; unreachable: $($W -c "SELECT coalesce(string_agg(source, ','), 'none') FROM pg_extension_update_paths('pg_fts') WHERE target = '1.14.2' AND path IS NULL AND source <> '1.14.2'")"
  echo "  PG$M UPGRADE $([ $ok = 1 ] && echo OK || echo FAIL)"
  $NEW/bin/pg_ctl -D $D -w stop >/dev/null
done
echo UPG142_DONE
