#!/bin/bash
# race.sh <name> <prefix-name> <port> <flush_thr> <secs> <W>
# 1.14.1 hardening: pending rows deleted / aborted / COPY-failed / shifted-retried while autovacuum, a VACUUM loop,
# fts_merge and inline flushes (small pending_flush_threshold) race; slots reused by filler rows.
# A REPEATABLE READ checker compares index scan vs fts_match in ONE snapshot throughout.
N=$1; X=$2; PORT=$3; FT=$4; SECS=$5; W=$6
PFX=/nvme/fp/$X; OUT=/nvme/fp/out-$N; mkdir -p $OUT; R=$OUT/result.txt; : > $R
PSQL="$PFX/bin/psql -h /tmp -p $PORT -U postgres -X -q postgres"
bash /tmp/pgc.sh $X $N $PORT init || exit 1
cat >> /nvme/fp/d-$N/postgresql.conf <<CONF
shared_buffers = 1GB
pg_fts.pending_flush_threshold = $FT
autovacuum_naptime = 1s
autovacuum_vacuum_cost_delay = 0
CONF
bash /tmp/pgc.sh $X $N $PORT start || exit 1
$PSQL <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION pg_fts;
CREATE TABLE rc (id bigserial PRIMARY KEY, k int, message text) WITH (autovacuum_vacuum_threshold = 50,
  autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_insert_threshold = 200, autovacuum_vacuum_insert_scale_factor = 0);
INSERT INTO rc (k, message) SELECT 0, 'base row number ' || g FROM generate_series(1, 20000) g;
CREATE INDEX rc_fts ON rc USING fts (to_ftsdoc('english', message));
CREATE FUNCTION hot(lo int, hi int) RETURNS TABLE (k int, message text) LANGUAGE sql AS
 $$ SELECT g, CASE WHEN g % 2 = 0 THEN 'Move visibility map memory ordering comments ' || g
                   ELSE 'Clean up usage of hash any extended ' || g END FROM generate_series(lo, hi) g $$;
SQL
echo "start $(date -u +%T) ext $($PSQL -At -c "select extversion from pg_extension where extname='pg_fts'") thr=$FT W=$W secs=$SECS" >> $R
END=$(( $(date +%s) + SECS ))
worker() { # w
  local w=$1 i=0
  while [ $(date +%s) -lt $END ]; do
    i=$((i+1)); local n=$(( 20 + RANDOM % 280 )) a=$(( RANDOM % 7 )) base=$(( (w*1000000) + i*1000 ))
    case $a in
    0) echo "INSERT INTO rc (k, message) SELECT k, message FROM hot($base, $base+$n);" ;;
    1) echo "INSERT INTO rc (k, message) SELECT k, message FROM hot($base, $base+$n);"
       echo "DELETE FROM rc WHERE k BETWEEN $base AND $base+$n AND k % 3 <> 0;" ;;
    2) echo "BEGIN; INSERT INTO rc (k, message) SELECT k, message FROM hot($base, $base+$n); ROLLBACK;"
       echo "INSERT INTO rc (k, message) SELECT k, message FROM hot($base+1, $base+$n);" ;;
    3) echo "INSERT INTO rc (k, message) SELECT -1, 'zzfiller qqfiller ' || g FROM generate_series(1, $n*2) g;" ;;
    4) echo "\\set ON_ERROR_STOP 0"
       echo "COPY rc (k, message) FROM PROGRAM 'seq 1 2500 | awk ''{ if (\$1==2500) print \"bad\\tx\"; else print $base+(\$1 % 900) \"\\tMove visibility map memory ordering comments \" \$1 }''';" ;;
    5) echo "BEGIN; INSERT INTO rc (k, message) SELECT k, message FROM hot($base, $base+$n); DELETE FROM rc WHERE k BETWEEN $base AND $base+$n/2; COMMIT;" ;;
    6) echo "INSERT INTO rc (k, message) SELECT k, message FROM hot($base, $base+$n) ON CONFLICT DO NOTHING;"
       echo "DELETE FROM rc WHERE k BETWEEN $base AND $base+$n AND random() < 0.5;" ;;
    esac
  done | $PSQL > $OUT/w$w.log 2>&1
}
checker() {
  local c=0
  while [ $(date +%s) -lt $END ]; do
    c=$((c+1))
    $PSQL -At <<'SQL' >> $OUT/check.log 2>&1
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
SELECT 'IDX', count(*), count(*) FILTER (WHERE NOT fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map')))
  FROM (SELECT message FROM rc WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','visibility & map') OFFSET 0) s;
SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = on; SET LOCAL enable_indexscan = off;
SELECT 'TRU', count(*) FROM rc WHERE fts_match(to_ftsdoc('english', message), to_ftsquery('english','visibility & map'));
COMMIT;
SQL
    sleep 1
  done
}
for w in $(seq 1 $W); do worker $w & done
checker & CP=$!
( while [ $(date +%s) -lt $END ]; do sleep 3; $PSQL -c "VACUUM rc" 2>&1; done ) > $OUT/vac.log &
( while [ $(date +%s) -lt $END ]; do sleep 20; $PSQL -c "SELECT fts_merge('rc_fts')" 2>&1; done ) > $OUT/merge.log &
wait
echo "load done $(date -u +%T)" >> $R
$PSQL -c "VACUUM rc" -c "VACUUM rc"
$PSQL -c "INSERT INTO rc (k, message) SELECT -2, 'zzfiller qqfiller ' || g FROM generate_series(1, 100000) g"
# checker summary: snapshots where index != truth, or any false row
awk '/^IDX/{split($0,a,"|"); idx=a[2]; fp=a[3]} /^TRU/{split($0,b,"|"); n++; if (idx!=b[2] || fp!=0) {bad++; if (bad<=5) print "  MISMATCH idx="idx" false="fp" truth="b[2]}} END{print "checker snapshots " n " mismatching " bad+0}' $OUT/check.log >> $R
$PSQL -At -c "SELECT format('rows %s heap_pages %s n_dead %s autovac %s vac %s nseg %s', (SELECT count(*) FROM rc), pg_relation_size('rc')/8192, n_dead_tup, autovacuum_count, vacuum_count, fts_index_nsegments('rc_fts')) FROM pg_stat_user_tables WHERE relname='rc'" >> $R
for q in 'visibility & map' 'hash & extended' 'memory' 'clean' 'qqfiller' 'base'; do
 $PSQL -At -v q="$q" <<'SQL' >> $R
SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE TEMP TABLE pi AS SELECT ctid AS tid FROM rc WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', :'q');
SET enable_bitmapscan = on; SET enable_indexscan = off;
CREATE TEMP TABLE bm AS SELECT ctid AS tid FROM rc WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english', :'q');
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
CREATE TEMP TABLE tr AS SELECT ctid AS tid FROM rc WHERE fts_match(to_ftsdoc('english', message), to_ftsquery('english', :'q'));
SELECT format('%-17s truth %s | idxscan %s FP %s FN %s | bitmap %s FP %s FN %s | fts_count %s', :'q', (SELECT count(*) FROM tr),
 (SELECT count(*) FROM pi), (SELECT count(*) FROM (SELECT * FROM pi EXCEPT SELECT * FROM tr) x), (SELECT count(*) FROM (SELECT * FROM tr EXCEPT SELECT * FROM pi) x),
 (SELECT count(*) FROM bm), (SELECT count(*) FROM (SELECT * FROM bm EXCEPT SELECT * FROM tr) x), (SELECT count(*) FROM (SELECT * FROM tr EXCEPT SELECT * FROM bm) x),
 fts_count('rc_fts', to_ftsquery('english', :'q')));
SQL
done
grep -h "ERROR" $OUT/w*.log | grep -v 'invalid input syntax\|COPY rc' | sort | uniq -c | sort -rn | head -5 >> $R
grep -h "ERROR\|PANIC\|WARNING\|terminated by signal" /nvme/fp/d-$N/log | grep -v 'invalid input syntax\|canceling autovacuum\|COPY rc\|STATEMENT' | sort | uniq -c | sort -rn | head -5 >> $R
echo RACE_DONE >> $R
