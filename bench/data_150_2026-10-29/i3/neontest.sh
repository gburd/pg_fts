#!/bin/bash
# neontest.sh -- ROADMAP I3: pg_fts on a compute/storage-separated backend (Neon, built from source).  The compute keeps
# no data files of its own: a page it evicts is rebuilt by the pageserver from WAL (its own walredo postgres, generic_redo
# for GenericXLog records).  A custom AM whose WAL could not be redone off-node returns wrong pages there.
#  1. pg_fts 1.15.0 built against Neon's PG 17; compute with shared_buffers=16MB and no local file cache, so index pages
#     are evicted and re-fetched from the pageserver during the workload itself;
#  2. workload: stored + expression indexes (positions on/off), 200k docs, deletes, VACUUM, fts_merge, pending inserts with
#     inline flushes, fts_vacuum; after each stage index counts == seq-scan counts (> 0) and ranked top-20 == oracle;
#  3. restart the compute (every page then comes from the pageserver) and re-check;
#  4. branch at an LSN recorded mid-workload, start a compute there, and check the index at that point in time.
# Log /nvme/neontest.log; ends NEONTEST_DONE.  ok=1 at the end iff every check passed.
set -uo pipefail
exec > /nvme/neontest.log 2>&1
export CARGO_HOME=/nvme/cargo RUSTUP_HOME=/nvme/rustup
N=/nvme/neon; NL="$N/target/release/neon_local"; PGB=$N/pg_install/v17/bin
cd $N
T=/nvme/ftssrc; [ -d $T ] && mv $T /nvme/trash_nt_$RANDOM; mkdir -p $T; tar xzf /nvme/final.tgz -C $T
(cd $T && make -s -j16 PG_CONFIG=$PGB/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$PGB/pg_config >/dev/null 2>&1) || { echo FTS_BUILD_FAIL; exit 1; }
echo "pg_fts tree $(cat $T/GITREV) $(grep default_version $T/pg_fts.control) against $($PGB/postgres --version); so=$(md5sum $($PGB/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
[ -d .neon ] && { $NL stop >/dev/null 2>&1; mv .neon /nvme/trash_nt_$RANDOM; }
$NL init > /nvme/nl_init.log 2>&1 || { tail -5 /nvme/nl_init.log; exit 1; }
$NL start > /nvme/nl_start.log 2>&1 || { tail -5 /nvme/nl_start.log; exit 1; }
$NL tenant create --set-default > /nvme/nl_tenant.log 2>&1 || { tail -5 /nvme/nl_tenant.log; exit 1; }
cat /nvme/nl_tenant.log
$NL endpoint create main --pg-version 17 --pg-port 55432 >/dev/null 2>&1 || { echo ENDPOINT_CREATE_FAIL; exit 1; }
CONF=$(ls -d .neon/endpoints/main)/postgresql.conf
printf "shared_buffers = 16MB\nneon.file_cache_size_limit = 0\nmax_wal_size = 4GB\n" >> $CONF
$NL endpoint start main > /nvme/nl_ep.log 2>&1 || { tail -5 /nvme/nl_ep.log; exit 1; }
P() { $PGB/psql -X -q -At -h 127.0.0.1 -p ${PORT:-55432} -U cloud_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
echo "compute: $(P -c 'select version()' | cut -c1-60); shared_buffers $(P -c 'show shared_buffers'); file cache $(P -c 'show neon.file_cache_size_limit' 2>&1)"
ok=1
chk() {  # chk <label>: index vs seq-scan counts and ranked top-20 vs oracle, every index form
  L=$1; bad=0; out=""
  for q in "'rare'" "'alpha & w7'" "'w3 | w5'" "'\"alpha beta\"'" "'fresh'" "'alpha & !w9'"; do
    hc=$(P -c "SELECT count(*) FROM t WHERE fts_match(d, $q::ftsquery)")
    for form in "d" "to_ftsdoc('simple', body)"; do
      ic=$(P -c "SET enable_seqscan = off" -c "SELECT count(*) FROM t WHERE $form @@@ $q::ftsquery" | tail -1)
      [ "$ic" = "$hc" ] || { bad=1; out="$out MISMATCH[$form $q idx=$ic heap=$hc]"; }
    done
    out="$out $q=$hc"
  done
  hc=$(P -c "SELECT count(*) FROM t WHERE fts_match(d, 'rare'::ftsquery)"); [ "$hc" -gt 0 ] || { bad=1; out="$out ZERO"; }
  r1=$(P -c "SET enable_seqscan = off" -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM t WHERE d @@@ 'rare | w7'::ftsquery ORDER BY d <=> 'rare | w7'::ftsquery, id LIMIT 20) s" | tail -1)
  r2=$(P -c "SET enable_seqscan = off" -c "SET enable_indexscan = off" -c "SELECT string_agg(id::text, ',') FROM (SELECT id FROM t, LATERAL (SELECT s.ndocs, s.avgdl, fts_index_df('t_d', 'rare | w7'::ftsquery) df FROM fts_index_stats('t_d') s) st WHERE fts_match(d, 'rare | w7'::ftsquery) ORDER BY fts_bm25(d, 'rare | w7'::ftsquery, st.ndocs, st.avgdl, st.df) DESC, id LIMIT 20) s" | tail -1)
  [ "$r1" = "$r2" ] && [ -n "$r1" ] || { bad=1; out="$out RANKED_MISMATCH"; }
  echo "CHECK $L: $([ $bad = 0 ] && echo OK || echo FAIL)$out; segments $(P -c "select fts_index_nsegments('t_d')"); index blocks $(P -c "select pg_relation_size('t_d')/8192")"
  [ $bad = 0 ] || ok=0
}
P -c "CREATE EXTENSION pg_fts"
P -c "CREATE TABLE t (id int PRIMARY KEY, body text, d ftsdoc)"
P -c "INSERT INTO t SELECT g, 'alpha w' || (g % 97) || ' w' || (g % 13) || CASE WHEN g % 50 = 0 THEN ' rare' ELSE '' END || CASE WHEN g % 7 = 0 THEN ' alpha beta' ELSE '' END || ' pad' || (g % 1000), NULL FROM generate_series(1, 200000) g"
P -c "UPDATE t SET d = to_ftsdoc('simple', body)"
P -c "CREATE INDEX t_d ON t USING fts (d) WITH (positions = on)" -c "CREATE INDEX t_e ON t USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar = off)" -c "VACUUM ANALYZE t"
chk built
LSN1=$(P -c "SELECT pg_current_wal_insert_lsn()"); C1=$(P -c "SELECT count(*) FROM t WHERE fts_match(d, 'rare'::ftsquery)")
P -c "DELETE FROM t WHERE id % 11 = 0" -c "VACUUM t"
chk deleted_vacuumed
P -c "SET pg_fts.pending_flush_threshold = 500" -c "INSERT INTO t SELECT g, 'fresh rare alpha beta w' || (g % 97), to_ftsdoc('simple', 'fresh rare alpha beta w' || (g % 97)) FROM generate_series(200001, 230000) g"
chk pending_flushed
P -c "SELECT fts_merge('t_d')" -c "SELECT fts_merge('t_e')" >/dev/null
chk merged
P -c "DELETE FROM t WHERE id % 5 = 0" -c "VACUUM t" -c "SELECT fts_vacuum('t_d')" -c "SELECT fts_vacuum('t_e')" >/dev/null
chk fts_vacuumed
P -c "CHECKPOINT"
echo "== restart the compute: every page now comes from the pageserver"
$NL endpoint stop main >/dev/null 2>&1; $NL endpoint start main > /nvme/nl_ep2.log 2>&1 || { tail -5 /nvme/nl_ep2.log; exit 1; }
chk after_compute_restart
echo "== branch at LSN $LSN1 (after build, before deletes; rare count then $C1)"
$NL timeline branch --branch-name atbuild --ancestor-branch-name main --ancestor-start-lsn $LSN1 > /nvme/nl_branch.log 2>&1 || { tail -3 /nvme/nl_branch.log; ok=0; }
$NL endpoint create atbuild --branch-name atbuild --pg-version 17 --pg-port 55433 >/dev/null 2>&1
printf "shared_buffers = 16MB\nneon.file_cache_size_limit = 0\n" >> .neon/endpoints/atbuild/postgresql.conf
$NL endpoint start atbuild > /nvme/nl_ep3.log 2>&1 || { tail -5 /nvme/nl_ep3.log; ok=0; }
PORT=55433
c=$(P -c "SELECT count(*) FROM t WHERE fts_match(d, 'rare'::ftsquery)"); echo "branch rare (heap) = $c (expect $C1)"; [ "$c" = "$C1" ] || ok=0
chk branch_at_build_lsn
PORT=55432
P -c "INSERT INTO t SELECT g, 'late rare', to_ftsdoc('simple', 'late rare') FROM generate_series(300001, 300100) g"
PORT=55433; c2=$(P -c "SELECT count(*) FROM t WHERE d @@@ 'late'::ftsquery"); echo "branch sees main's later insert: $c2 rows (expect 0)"; [ "$c2" = 0 ] || ok=0
echo "pageserver log errors: $(grep -ciE 'error|panic' .neon/pageserver_1/pageserver.log 2>/dev/null) (walredo: $(grep -ciE 'walredo.*(error|fail)' .neon/pageserver_1/pageserver.log 2>/dev/null)); compute log errors: $(grep -cE 'ERROR|PANIC|FATAL' .neon/endpoints/main/compute.log 2>/dev/null)"
grep -iE "walredo.*(error|fail)|could not apply|panic" .neon/pageserver_1/pageserver.log 2>/dev/null | head -5
echo "I3 NEON RESULT: ok=$ok"
$NL stop >/dev/null 2>&1
echo NEONTEST_DONE
