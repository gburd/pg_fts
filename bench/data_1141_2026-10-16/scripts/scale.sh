#!/bin/bash
# Second scale for the VACUUM-growth fix: 600k rows (10x scenario C/E), CIC build, PG 18.6.
# E: reader holds AccessShareLock across 3 serial VACUUMs, then one alone.  P: 3 parallel VACUUMs
# (two btrees), then one serial.  Arms: released 1.14.0 vs the final tree.
set -uo pipefail
TAG=$1; PORT=$2; R=/nvme/b3/repro
if [ $TAG = final ]; then
  PFX=$R/pg-final; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
  S=/nvme/b3/src-final; [ -d $S ] && mv $S /nvme/trash_sc_$RANDOM; mkdir -p $S; tar xzf /nvme/b3/final.tgz -C $S; cd $S
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j8 PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
fi
B=$R/pg-$TAG/bin
echo "$TAG so $(md5sum $R/pg-$TAG/lib/postgresql/pg_fts.so | cut -c1-8) $(cat /nvme/b3/src-final/GITREV 2>/dev/null)"
for SC in E P; do
  D=/nvme/b3/scale-$TAG-$SC; $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; [ -d $D ] && mv $D /nvme/trash_sc_$RANDOM
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\nshared_buffers=2GB\nmaintenance_work_mem=256MB\nmax_parallel_maintenance_workers=4\nmax_worker_processes=16\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
  $P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE m (id int PRIMARY KEY, body text, a int, b text)" \
     -c "INSERT INTO m SELECT g, (SELECT string_agg('w' || ((g * 7 + i * 13) % 50000), ' ') FROM generate_series(1, 30) i), g % 1000, md5(g::text) FROM generate_series(1, 600000) g" \
     -c "ALTER TABLE m SET (parallel_workers = 4)" -c "CREATE INDEX CONCURRENTLY m_fts ON m USING fts (to_ftsdoc('simple', body))" \
     -c "CREATE INDEX m_b ON m (b)" -c "CREATE INDEX m_ab ON m (a, b)" -c "VACUUM ANALYZE m" >/dev/null
  sz() { $P -c "select pg_relation_size('m_fts')/8192"; }
  line="[$TAG $SC] nseg $($P -c "select fts_index_nsegments('m_fts')") start $(sz)"
  for i in 1 2 3; do
    $P -c "DELETE FROM m WHERE id % 97 = $i" >/dev/null
    if [ $SC = E ]; then
      $P -c "BEGIN" -c "SET enable_seqscan=off" -c "SELECT count(*) FROM m WHERE to_ftsdoc('simple',body) @@@ 'w30'::ftsquery" -c "SELECT pg_sleep(600)" -c "COMMIT" >/dev/null 2>&1 &
      rp=$!; sleep 1
      t0=$(date +%s); e=$($P -c 'VACUUM (PARALLEL 0) m' 2>&1 | grep -c ERROR); line="$line | reader#$i $(sz) ($(( $(date +%s)-t0 ))s)"
      $P -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(600)%' AND pid <> pg_backend_pid()" >/dev/null; wait $rp 2>/dev/null
    else
      t0=$(date +%s); e=$($P -c 'SET min_parallel_index_scan_size = 0' -c 'VACUUM (PARALLEL 2) m' 2>&1 | grep -c ERROR); line="$line | par#$i $(sz)$([ $e -gt 0 ] && echo '(ERR)') ($(( $(date +%s)-t0 ))s)"
    fi
  done
  $P -c "DELETE FROM m WHERE id % 97 = 9" >/dev/null; $P -c 'VACUUM (PARALLEL 0) m' >/dev/null 2>&1; line="$line | serial-alone $(sz)"
  $P -c "DELETE FROM m WHERE id % 97 = 10" >/dev/null; $P -c 'VACUUM (PARALLEL 0) m' >/dev/null 2>&1; line="$line | serial-alone#2 $(sz)"
  echo "$line | idx=$($P -c "set enable_seqscan=off; select count(*) from m where to_ftsdoc('simple',body) @@@ 'w30'::ftsquery") heap=$($P -c "select count(*) from m where fts_match(to_ftsdoc('simple',body),'w30'::ftsquery)")"
  $B/pg_ctl -D $D -m fast -w stop >/dev/null
done
echo SCALE_DONE
