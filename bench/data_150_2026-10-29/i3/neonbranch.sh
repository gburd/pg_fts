#!/bin/bash
# neonbranch.sh: the point-in-time half of neontest.sh, on a free port.  Restarts neon, starts main, branches at the
# recorded LSN (LSN1, after the index build, before the deletes), starts a compute on the branch, checks it.
set -uo pipefail
exec > /nvme/neonbranch.log 2>&1
N=/nvme/neon; NL="$N/target/release/neon_local"; PGB=$N/pg_install/v17/bin; cd $N
LSN1=$(grep -oE "branch at LSN [0-9A-F/]+" /nvme/neontest.log | awk '{print $4}'); echo "LSN1=$LSN1"
$NL start >/dev/null 2>&1; $NL endpoint start main >/dev/null 2>&1
$NL endpoint list
$NL endpoint stop atbuild >/dev/null 2>&1
ls .neon/endpoints/
# a fresh branch endpoint on a port nothing else uses
$NL timeline branch --branch-name atbuild2 --ancestor-branch-name main --ancestor-start-lsn $LSN1 2>&1 | tail -1
$NL endpoint create atb2 --branch-name atbuild2 --pg-version 17 --pg-port 56500 --external-http-port 56510 --internal-http-port 56511 2>&1 | tail -2
printf "shared_buffers = 16MB\nneon.file_cache_size_limit = 0\n" >> .neon/endpoints/atb2/postgresql.conf
$NL endpoint start atb2 2>&1 | tail -2
$NL endpoint list
P() { $PGB/psql -X -q -At -h 127.0.0.1 -p $PORT -U cloud_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
PORT=56500; ok=1
c=$(P -c "SELECT count(*) FROM t WHERE fts_match(d, 'rare'::ftsquery)"); echo "branch rare (heap) = $c (expect 4000: the count at LSN1)"; [ "$c" = 4000 ] || ok=0
for q in "'rare'" "'alpha & w7'" "'w3 | w5'" "'\"alpha beta\"'" "'fresh'" "'alpha & !w9'"; do
  hc=$(P -c "SELECT count(*) FROM t WHERE fts_match(d, $q::ftsquery)")
  i1=$(P -c "SET enable_seqscan = off" -c "SELECT count(*) FROM t WHERE d @@@ $q::ftsquery" | tail -1)
  i2=$(P -c "SET enable_seqscan = off" -c "SELECT count(*) FROM t WHERE to_ftsdoc('simple', body) @@@ $q::ftsquery" | tail -1)
  echo "  branch $q heap=$hc idx=$i1 expr=$i2"; [ "$hc" = "$i1" ] && [ "$hc" = "$i2" ] || ok=0
done
r1=$(P -c "SET enable_seqscan = off" -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM t WHERE d @@@ 'rare | w7'::ftsquery ORDER BY d <=> 'rare | w7'::ftsquery, id LIMIT 20) s" | tail -1)
r2=$(P -c "SET enable_seqscan = off" -c "SET enable_indexscan = off" -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM t, LATERAL (SELECT s.ndocs, s.avgdl, fts_index_df('t_d', 'rare | w7'::ftsquery) df FROM fts_index_stats('t_d') s) st WHERE fts_match(d, 'rare | w7'::ftsquery) ORDER BY fts_bm25(d, 'rare | w7'::ftsquery, st.ndocs, st.avgdl, st.df) DESC, id LIMIT 20) s" | tail -1)
echo "  branch ranked top-20 == oracle: $([ "$r1" = "$r2" ] && [ -n "$r1" ] && echo yes || echo NO)"; [ "$r1" = "$r2" ] && [ -n "$r1" ] || ok=0
echo "  branch segments $(P -c "select fts_index_nsegments('t_d')") ndocs $(P -c "select ndocs from fts_index_stats('t_d')")"
# write on the branch: an index on a branch must take inserts, a merge and a vacuum
P -c "INSERT INTO t SELECT g, 'branchonly rare', to_ftsdoc('simple', 'branchonly rare') FROM generate_series(400001, 400500) g" -c "SELECT fts_merge('t_d')" -c "VACUUM t" >/dev/null
b1=$(P -c "SET enable_seqscan = off" -c "SELECT count(*) FROM t WHERE d @@@ 'branchonly'::ftsquery" | tail -1); echo "  branch write+merge: branchonly=$b1 (expect 500)"; [ "$b1" = 500 ] || ok=0
PORT=55432; m=$(P -c "SET enable_seqscan = off" -c "SELECT count(*) FROM t WHERE d @@@ 'branchonly'::ftsquery" | tail -1); echo "  main sees the branch's rows: $m (expect 0)"; [ "$m" = 0 ] || ok=0
echo "pageserver walredo errors: $(grep -ciE 'walredo.*(error|fail)|could not apply|panic' .neon/pageserver_1/pageserver.log)"
echo "I3 NEON BRANCH RESULT: ok=$ok"
$NL stop >/dev/null 2>&1
echo NEONBRANCH_DONE
