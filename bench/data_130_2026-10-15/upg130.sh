#!/bin/bash
# In-place upgrade qualification for pg_fts 1.13.0: an index BUILT by released 1.12.1 (with
# tombstones, positions=on) is opened by the 1.13.0 binary on the same data dir, no REINDEX;
# ALTER EXTENSION UPDATE; writes on 1.13.0; REINDEX on 1.13.0.  At each step: index count ==
# heap count via fts_match() (no operator, so no index and no count pushdown; > 0); fts_search top-20 == exhaustive per-term reference sum (dense path);
# best-first on == off; ORDER BY returns 20 rows.
set -uo pipefail
W=/nvme/upq; mkdir -p $W; cd $W
for d in pg121b pg13c; do [ -d $W/$d ] || cp -a /nvme/pg17 $W/$d; done
[ -d $W/pg_fts-1.12.1 ] && mv $W/pg_fts-1.12.1 $W/pg_fts-1.12.1.old.$$
unzip -qo /tmp/pg_fts-1.12.1.zip
(cd pg_fts-1.12.1 && make -s PG_CONFIG=$W/pg121b/bin/pg_config -j8 >/dev/null 2>&1 && make -s PG_CONFIG=$W/pg121b/bin/pg_config install >/dev/null 2>&1) || { echo BUILD112_FAIL; exit 1; }
[ -d $W/tree130 ] && mv $W/tree130 $W/tree130.old.$$
mkdir $W/tree130; tar xzf /tmp/fts_tree.tgz -C $W/tree130
(cd tree130 && make -s PG_CONFIG=$W/pg13c/bin/pg_config -j8 >/dev/null 2>&1 && make -s PG_CONFIG=$W/pg13c/bin/pg_config install >/dev/null 2>&1) || { echo BUILD112_FAIL; exit 1; }
echo "1.12.1 so: $(md5sum $W/pg121b/lib/postgresql/pg_fts.so | cut -c1-8)  1.13.0 so: $(md5sum $W/pg13c/lib/postgresql/pg_fts.so | cut -c1-8)  tree: $(cat $W/tree130/GITREV)"
echo "upgrade edge installed: $(ls $W/pg13c/share/postgresql/extension/ | grep -c 'pg_fts--1.12.1--1.13.0.sql')"
D=$W/upgdata130; [ -d $D ] && mv $D $D.old.$$
$W/pg121b/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55496\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=1GB\nmaintenance_work_mem=512MB\n" >> $D/postgresql.conf
$W/pg121b/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$W/pg121b/bin/psql -h /tmp -p 55496 -U postgres -X -q -At"
echo "built with ext $($P -c "CREATE EXTENSION pg_fts" -c "SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"
$P -c "CREATE TABLE u (id bigint, d ftsdoc)" -c "INSERT INTO u (id) SELECT g FROM generate_series(1, 300000) g" >/dev/null
$P -c "UPDATE u SET d = to_ftsdoc('simple', 'w' || (id % 97) || ' x' || (id % 13) || ' ' || repeat('pad ', (id % 31)::int) || CASE WHEN id % 5 = 0 THEN 'rare' ELSE 'common' END || CASE WHEN id % 11 = 0 THEN ' hot dog' WHEN id % 11 = 1 THEN ' dog hot' ELSE '' END)" >/dev/null
$P -c "VACUUM FULL u" -c "CREATE INDEX u_fts ON u USING fts (d) WITH (positions = on)" -c "VACUUM ANALYZE u" >/dev/null
$P -c "DELETE FROM u WHERE id % 3 = 0" -c "VACUUM u" >/dev/null
echo "1.12.1 built + deleted: nseg=$($P -c "select fts_index_nsegments('u_fts')") live=$($P -c "select count(*) from u")"
$W/pg121b/bin/pg_ctl -D $D -w stop >/dev/null

$W/pg13c/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$W/pg13c/bin/psql -h /tmp -p 55496 -U postgres -X -q -At"
echo "1.13.0 binary started; ext SQL still $($P -c "select extversion from pg_extension where extname='pg_fts'")"
ok=0; bad=0
chk() {
  for t in common rare 'common | rare' w5 'rare & w5' 'w1 | w2 | w3 | rare' '"hot dog"'; do
    Q="to_ftsquery('simple','$t')"
    fs=$($P -c "SELECT string_agg(round(score::numeric,8)::text, ',' ORDER BY score DESC) FROM fts_search('u_fts', $Q, 20)" | tail -1)
    fs0=$($P -c "SET pg_fts.bestfirst = off" -c "SELECT string_agg(round(score::numeric,8)::text, ',' ORDER BY score DESC) FROM fts_search('u_fts', $Q, 20)" | tail -1)
    terms=$(echo "$t" | tr -d '"' | tr '|&' '  ' | xargs -n1 | sed "s/.*/'&'/" | paste -sd, -)
    ref=$($P -c "SET pg_fts.bestfirst = off" -c "SET pg_fts.dense_score_min_df = 1" -c "SELECT string_agg(round(s::numeric,8)::text, ',' ORDER BY s DESC) FROM (SELECT sum(x.score) s FROM unnest(ARRAY[$terms]) tt, LATERAL fts_search('u_fts', to_ftsquery('simple', tt), 1000000) x WHERE x.ctid IN (SELECT ctid FROM u WHERE d @@@ $Q) GROUP BY x.ctid ORDER BY 1 DESC LIMIT 20) z" | tail -1)
    cnt=$($P -c "SET enable_seqscan=off; SELECT count(*) FROM u WHERE d @@@ $Q"); truth=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, $Q)")
    ob=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT count(*) FROM (SELECT 1 FROM u WHERE d @@@ $Q ORDER BY d <=> $Q LIMIT 20) s")
    r1=$([ "$cnt" = "$truth" ] && [ "$cnt" -gt 0 ] && echo OK || echo BAD); r2=$([ -n "$fs" ] && [ "$fs" = "$ref" ] && echo OK || echo DIFF); r3=$([ "$fs" = "$fs0" ] && echo OK || echo DIFF); r4=$([ "$ob" = 20 ] && echo OK || echo BAD)
    for r in $r1 $r2 $r3 $r4; do [ $r = OK ] && ok=$((ok+1)) || bad=$((bad+1)); done
    echo "  $1 [$t]: count $cnt/$truth $r1 | top20 == ref $r2 | bestfirst on==off $r3 | orderby 20 rows $r4"
  done
}
chk "1.13.0 .so, 1.12.1 SQL"
$P -c "ALTER EXTENSION pg_fts UPDATE TO '1.13.0'" >/dev/null; echo "after ALTER: ext $($P -c "select extversion from pg_extension where extname='pg_fts'")"
chk "after ALTER EXTENSION"
c0=$($P -c "SET pg_fts.doclen_cache_mb = 0" -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM u WHERE d @@@ to_ftsquery('simple','rare') ORDER BY d <=> to_ftsquery('simple','rare'), id LIMIT 50) s" | tail -1)
c64=$($P -c "SET enable_seqscan=off" -c "SET enable_bitmapscan=off" -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM u WHERE d @@@ to_ftsquery('simple','rare') ORDER BY d <=> to_ftsquery('simple','rare'), id LIMIT 50) s" | tail -1)
[ -n "$c0" ] && [ "$c0" = "$c64" ] && { ok=$((ok+1)); echo "  dictdir cache on == off (rare top-50): OK"; } || { bad=$((bad+1)); echo "  dictdir cache on == off: DIFF"; }
$P -c "INSERT INTO u SELECT g, to_ftsdoc('simple','common new hot dog w5 ' || g) FROM generate_series(300001, 310000) g" >/dev/null
$P -c "DELETE FROM u WHERE id % 7 = 0" -c "VACUUM u" >/dev/null
$P -c "SELECT fts_merge('u_fts')" >/dev/null; $P -c "SELECT fts_vacuum('u_fts')" >/dev/null
echo "after insert+delete+vacuum+merge on 1.13.0: nseg=$($P -c "select fts_index_nsegments('u_fts')")"
chk "after 1.13.0 writes"
$P -c "REINDEX INDEX u_fts" >/dev/null; echo "after REINDEX on 1.13.0: nseg=$($P -c "select fts_index_nsegments('u_fts')") size=$($P -c "select pg_relation_size('u_fts')")"
chk "after 1.13.0 REINDEX"
$W/pg13c/bin/pg_ctl -D $D -w stop >/dev/null
echo "UPG_DONE checks ok=$ok bad=$bad"
