#!/bin/bash
# churnrun.sh <arm: old|new> : the 2026-11-02 report's repro script verbatim (1.88M rows, 23,313 moves, sidecar off) on PG 18.6,
# plus avgdl vs table truth and VACUUM / fts_vacuum wall time per step.  old = v1.16.0 zip build, new = final.tgz.
set -u
ARM=$1; G=/nvme/g170; O=/nvme/churn170; mkdir -p $O; exec > $O/churn-$ARM.log 2>&1; cd $O
B=$G/churn-pfx-$ARM/bin; [ -d $G/churn-pfx-$ARM ] || cp -a /nvme/pg18 $G/churn-pfx-$ARM
S=$O/src-$ARM; [ -d $S ] && mv $S /nvme/trash_ch_$RANDOM; mkdir -p $S
if [ $ARM = old ]; then (cd $S && unzip -q $G/pg_fts-1.16.0.zip && mv pg_fts-1.16.0/* . ); else tar xzf $G/final.tgz -C $S; fi
(cd $S && make -s -j32 PG_CONFIG=$B/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$B/pg_config >/dev/null 2>&1) || { echo BUILD FAIL; exit 1; }
echo "arm=$ARM $(grep default_version $S/pg_fts.control) so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
D=$O/data-$ARM; P=6118; [ -d $D ] && { $B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1; mv $D /nvme/trash_ch_$RANDOM; }
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=8GB\nmaintenance_work_mem=2GB\njit=off\nautovacuum=off\nmax_wal_size=32GB\nlog_min_messages=info\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null || { echo START FAIL; exit 1; }
# the report's script, with an avgdl/N check and timing appended to each probe line
sed -e "s/RETURN format('%-50s segs %s  remove %s ms  vacuum %s ms  remove\/bestfirst=off %s ms',/RETURN format('%-50s segs %s  remove %s ms  vacuum %s ms  remove\/bestfirst=off %s ms  N %s\/%s avgdl %s\/%s',/" \
    -e "s/label, fts_index_nsegments('idx_own_fts'::regclass), a, b, c);/label, fts_index_nsegments('idx_own_fts'::regclass), a, b, c, (SELECT ndocs FROM fts_index_stats('idx_own_fts')), (SELECT count(*) FROM own), (SELECT round(avgdl::numeric,3) FROM fts_index_stats('idx_own_fts')), (SELECT round(avg(ftsdoc_length(to_ftsdoc('english'::regconfig, ((head || ' '::text) || own))))::numeric,3) FROM own));/" \
    -e 's/^VACUUM own;$/\\timing on\nVACUUM own;\n\\timing off/' \
    -e "s/^SELECT fts_vacuum('idx_own_fts'::regclass) \\\\gset$/\\\\timing on\nSELECT fts_vacuum('idx_own_fts'::regclass) \\\\gset\n\\\\timing off/" \
    -e "s/^SELECT fts_vacuum('idx_own_fts'::regclass) AS did \\\\gset$/\\\\timing on\nSELECT fts_vacuum('idx_own_fts'::regclass) AS did \\\\gset\n\\\\timing off/" \
    /tmp/g2/churn_repro.sql > $O/repro-$ARM.sql
echo "probe-patched: $(grep -c 'avgdl %s' $O/repro-$ARM.sql) timing-lines: $(grep -c '^\\timing on' $O/repro-$ARM.sql)"
date; $B/psql -X -h /tmp -p $P -U postgres -d postgres -v nrows=1880000 -v nmoves=23313 -At -f $O/repro-$ARM.sql; echo "psql rc=$?"; date
$B/pg_ctl -D $D -w stop >/dev/null
echo CHURN_${ARM}_DONE
