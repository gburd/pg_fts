#!/bin/bash
# In-place upgrade 1.14.2 -> 1.14.3 on PG 17 and 18: create at 1.14.2 (release build, /nvme/iss/pg$M-v1142)
# with indexes (stored col + expression, sidecar on/off), pending rows; swap in the 1.14.3 .so + scripts on
# the same data dir; ALTER EXTENSION UPDATE TO '1.14.3'; counts == heap (>0), ranked top-k == before; the
# #9 short-dfs probe and #10 fts_index_df on the upgraded index; every version reaches 1.14.3.
# Adapted from bench/data_1142_2026-10-25/scripts/upg142.sh.
set -uo pipefail
G=/nvme/iss/gate; mkdir -p $G
exec > $G/upg143.log 2>&1
for M in 17 18; do
  OLD=/nvme/iss/pg$M-v1142; NEW=$G/upg-new$M; PORT=597$M
  [ -d $NEW ] && mv $NEW /nvme/trash_up_$RANDOM; cp -a /nvme/pg$M $NEW
  S=$G/upg-src-$M; [ -d $S ] && mv $S /nvme/trash_up_$RANDOM; mkdir -p $S; tar xzf $G/final.tgz -C $S
  (cd $S && make -s clean PG_CONFIG=$NEW/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$NEW/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$NEW/bin/pg_config >/dev/null 2>&1) || { echo "PG$M NEW BUILD FAIL"; continue; }
  cp $OLD/share/postgresql/extension/pg_fts--1.14.2.sql $NEW/share/postgresql/extension/ 2>/dev/null
  echo "PG$M old so $(md5sum $OLD/lib/postgresql/pg_fts.so | cut -c1-8) ($($OLD/bin/postgres --version)) new so $(md5sum $NEW/lib/postgresql/pg_fts.so | cut -c1-8) tree $(cat $S/GITREV); new edge: $(ls $NEW/share/postgresql/extension/pg_fts--1.14.2--1.14.3.sql); stale base 1.14.2 in tree: $(ls $S/pg_fts--1.14.2.sql 2>/dev/null | wc -l)"
  D=$G/upgdata$M; [ -d $D ] && mv $D /nvme/trash_up_$RANDOM
  $OLD/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
  $OLD/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$OLD/bin/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1"
  $P -c "CREATE EXTENSION pg_fts VERSION '1.14.2'"
  $P -c "CREATE TABLE u (id int PRIMARY KEY, live bool, body text, d ftsdoc)" \
     -c "INSERT INTO u SELECT g, g % 3 <> 0, 'alpha w' || (g % 97) || CASE WHEN g % 50 = 0 THEN ' rare' ELSE '' END, NULL FROM generate_series(1, 30000) g" \
     -c "UPDATE u SET d = to_ftsdoc('simple', body)" \
     -c "CREATE INDEX u_d ON u USING fts (d)" \
     -c "CREATE INDEX u_e ON u USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = off)" \
     -c "CREATE INDEX u_p ON u USING fts (to_ftsdoc('simple', body)) WHERE live" \
     -c "VACUUM ANALYZE u" -c "DELETE FROM u WHERE id % 7 = 0" -c "VACUUM u" \
     -c "SET pg_fts.pending_flush_threshold = 0" -c "INSERT INTO u SELECT g, true, 'alpha rare fresh', to_ftsdoc('simple', 'alpha rare fresh') FROM generate_series(30001, 30500) g" -c "ANALYZE u" >/dev/null
  q() { $1 -c "SET enable_seqscan=off" -c "$2" | tail -1; }
  b_cnt=$(q "$P" "SELECT count(*) FROM u WHERE d @@@ 'rare'::ftsquery"); b_top=$(q "$P" "SELECT string_agg(id::text, ',') FROM (SELECT id FROM u WHERE d @@@ 'rare'::ftsquery ORDER BY d <=> 'rare'::ftsquery, id LIMIT 20) s")
  b_df=$($P -c "SELECT fts_index_df('u_d', 'fresh | rare'::ftsquery)")
  echo "  at 1.14.2: ext $($P -c "select extversion from pg_extension where extname='pg_fts'") count(rare)=$b_cnt fts_index_df(fresh|rare)=$b_df"
  $OLD/bin/pg_ctl -D $D -w stop >/dev/null
  $NEW/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$NEW/bin/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1"
  $P -c "ALTER EXTENSION pg_fts UPDATE TO '1.14.3'"
  heap=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, 'rare'::ftsquery)")
  a_cnt=$(q "$P" "SELECT count(*) FROM u WHERE d @@@ 'rare'::ftsquery"); a_top=$(q "$P" "SELECT string_agg(id::text, ',') FROM (SELECT id FROM u WHERE d @@@ 'rare'::ftsquery ORDER BY d <=> 'rare'::ftsquery, id LIMIT 20) s")
  e_cnt=$(q "$P" "SELECT count(*) FROM u WHERE to_ftsdoc('simple', body) @@@ 'rare'::ftsquery")
  a_df=$($P -c "SELECT fts_index_df('u_d', 'fresh | rare'::ftsquery)")
  fresh_heap=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, 'fresh'::ftsquery)")
  dfs9=$($P -c "SELECT fts_bm25(to_ftsdoc('simple','alpha rare'), 'alpha | rare'::ftsquery, 1e12, 2, '{}'::float8[]) = fts_bm25(to_ftsdoc('simple','alpha rare'), 'alpha | rare'::ftsquery, 1e12, 2)")
  plan8=$($P -c "EXPLAIN (COSTS OFF) SELECT id FROM u WHERE live AND to_ftsdoc('simple', body) @@@ 'rare'::ftsquery ORDER BY to_ftsdoc('simple', body) <=> 'rare'::ftsquery LIMIT 5" | grep -c "Index Scan using u_p")
  echo "  after UPDATE: ext $($P -c "select extversion from pg_extension where extname='pg_fts'") count(rare) stored=$a_cnt expr=$e_cnt heap=$heap; fts_index_df(fresh|rare)=$a_df (fresh heap=$fresh_heap); #9 '{}'=NULL: $dfs9; #8 partial ordering scan: $plan8"
  ok=1; [ "$a_cnt" = "$heap" ] && [ "$e_cnt" = "$heap" ] && [ "$heap" -gt 0 ] && [ "$a_cnt" = "$b_cnt" ] && [ "$dfs9" = t ] && [ "$plan8" = 1 ] || ok=0; [ "$a_top" = "$b_top" ] && [ -n "$a_top" ] || ok=0
  case "$a_df" in "{$fresh_heap,"*) ;; *) ok=0;; esac
  $P -c "DELETE FROM u WHERE id % 11 = 0" -c "VACUUM u" -c "SELECT fts_vacuum('u_d')" >/dev/null
  w_cnt=$(q "$P" "SELECT count(*) FROM u WHERE d @@@ 'rare'::ftsquery"); w_heap=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, 'rare'::ftsquery)")
  [ "$w_cnt" = "$w_heap" ] && [ "$w_heap" -gt 0 ] || ok=0
  echo "  after VACUUM + fts_vacuum on 1.14.3: count $w_cnt heap $w_heap; top20 unchanged across upgrade: $([ "$a_top" = "$b_top" ] && echo yes || echo NO)"
  $P -c "CREATE DATABASE w"
  W="$NEW/bin/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 -d w"
  $W -c "CREATE EXTENSION pg_fts VERSION '1.14.2'" -c "ALTER EXTENSION pg_fts UPDATE" && echo "  fresh 1.14.2 -> $($W -c "select extversion from pg_extension where extname='pg_fts'")"
  echo "  update paths: $($W -c "SELECT count(*) FROM pg_extension_update_paths('pg_fts') WHERE target = '1.14.3' AND path IS NOT NULL") sources reach 1.14.3; unreachable: $($W -c "SELECT coalesce(string_agg(source, ','), 'none') FROM pg_extension_update_paths('pg_fts') WHERE target = '1.14.3' AND path IS NULL AND source <> '1.14.3'")"
  echo "  available base versions: $($W -c "SELECT string_agg(version, ',') FROM pg_available_extension_versions WHERE name='pg_fts' AND version IN ('1.14.2','1.14.3')")"
  $W -c "DROP EXTENSION pg_fts" -c "CREATE EXTENSION pg_fts" && echo "  fresh install default: $($W -c "select extversion from pg_extension where extname='pg_fts'")"
  echo "  PG$M UPGRADE $([ $ok = 1 ] && echo OK || echo FAIL)"
  $NEW/bin/pg_ctl -D $D -w stop >/dev/null
done
echo UPG143_DONE
