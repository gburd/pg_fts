#!/bin/bash
# reviewer #1: index built by 1.16.0 while rows are recently dead (long half), then new code VACUUMs it
PS="./pg17/bin/psql -X -q -h /scratch/gburd/pgfts -p 5517 -At"
case $1 in
build)
$PS -d postgres -c "DROP DATABASE IF EXISTS rdo" -c "CREATE DATABASE rdo"; $PS -d rdo -c "CREATE EXTENSION pg_fts"
$PS -d rdo -c "CREATE TABLE t (id int PRIMARY KEY, body text) WITH (autovacuum_enabled=off)" -c "INSERT INTO t SELECT g, (SELECT string_agg('w' || ((g * 7 + s) % 500), ' ') FROM generate_series(1, CASE WHEN g % 2 = 0 THEN 10 ELSE 100 END) s) FROM generate_series(1, 4000) g"
( $PS -d rdo -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM t; SELECT pg_sleep(5); COMMIT;" >/dev/null ) & sleep 1
$PS -d rdo -c "DELETE FROM t WHERE id % 2 = 1" -c "CREATE INDEX t_on ON t USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=on)" -c "CREATE INDEX t_off ON t USING fts (to_ftsdoc('simple', body)) WITH (doclen_sidecar=off)"
wait
$PS -d rdo -c "SELECT i, 'built (old code)', ndocs, round(avgdl::numeric,3) FROM (VALUES ('t_on'),('t_off')) v(i), fts_index_stats(i::regclass)" ;;
check)
$PS -d rdo -c "VACUUM t" -c "SELECT i, 'VACUUM (new code)', ndocs, round(avgdl::numeric,3) FROM (VALUES ('t_on'),('t_off')) v(i), fts_index_stats(i::regclass)"
$PS -d rdo -c "SET enable_seqscan=off" -c "SELECT 'top score finite', bool_and(score > 0 AND score < 1e9) FROM fts_search('t_on', 'w5'::ftsquery, 10)"
$PS -d rdo -c "DELETE FROM t WHERE id % 10 = 0" -c "VACUUM t" -c "SELECT i, 'more deletes+VACUUM', ndocs, round(avgdl::numeric,3) FROM (VALUES ('t_on'),('t_off')) v(i), fts_index_stats(i::regclass)"
$PS -d rdo -c "SELECT fts_vacuum('t_on'), fts_vacuum('t_off')" -c "SELECT i, 'fts_vacuum', ndocs, round(avgdl::numeric,3) FROM (VALUES ('t_on'),('t_off')) v(i), fts_index_stats(i::regclass)" -c "SELECT 'truth', count(*), round(avg(ftsdoc_length(to_ftsdoc('simple',body)))::numeric,3) FROM t" ;;
esac
