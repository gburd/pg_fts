#!/bin/bash
# diff.sh <prefix> <port> <label> <outfile>
PFX=$1; PORT=$2; L=$3; O=$4
PSQL="$PFX/bin/psql -h /tmp -p $PORT -U postgres -X postgres"
{
echo "=== DIFF $L $(date -u +%FT%TZ)"
$PSQL -At -c "SELECT 'ext '||extversion FROM pg_extension WHERE extname='pg_fts'" \
  -c "SELECT format('rows %s heap_pages %s index_MB %s nseg %s', (SELECT count(*) FROM ag), pg_relation_size('ag')/8192, pg_relation_size('idx_ag_msg_fts')/1048576, fts_index_nsegments('idx_ag_msg_fts'))" \
  -c "SELECT format('n_dead_tup %s autovac %s vac %s', n_dead_tup, autovacuum_count, vacuum_count) FROM pg_stat_user_tables WHERE relname='ag'"
$PSQL -q -c "DROP TABLE IF EXISTS truthdoc" -c "SET max_parallel_workers_per_gather = 8" -c "CREATE UNLOGGED TABLE truthdoc AS SELECT ctid AS tid, to_ftsdoc('english', message) AS d FROM ag"
$PSQL -At -c "SET enable_seqscan=off; SET enable_indexscan=off; EXPLAIN (COSTS OFF) SELECT ctid FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','vacuum')" \
  -c "SET enable_seqscan=off; SET enable_bitmapscan=off; EXPLAIN (COSTS OFF) SELECT ctid FROM ag WHERE to_ftsdoc('english', message) @@@ to_ftsquery('english','vacuum')"
for q in "vacuum" "autovacuum" "visibility & map" "hash & index" "freeze" "index" "replication" "planner" "wal" "lock" "fix" "bug"; do
  $PSQL -At -v q="$q" -f /tmp/diff1.sql
done
echo "=== END $L $(date -u +%FT%TZ)"
} >> $O 2>&1
