#!/bin/bash
# walcc2.sh: proof that wal_consistency_checking actually checked pg_fts's records (AGENTS rule 9: 0 vs 0 proves
# nothing).  PG17 primary (generic checking) + standby; churn workload; pg_waldump over exactly the churn's LSN range:
# the number of Generic records, and how many carry a consistency-check image (pg_waldump prints "apply: no" for an
# image kept only for the check).  Then a NEGATIVE control: the same standby setup with the check on, and one index
# page corrupted on the PRIMARY with a non-WAL write -- the next GenericXLog record on that page must make the standby
# report "inconsistent page found" (the check has teeth).
set -uo pipefail
O=/nvme/walcc; exec > $O/walcc2.log 2>&1
B=/nvme/g150/pfx17/bin; PP=58317; SP=58417; P=$O/p2; S=$O/s2
for d in $P $S; do $B/pg_ctl -D $d -m immediate -w stop >/dev/null 2>&1; [ -d $d ] && mv $d /nvme/trash_wc_$RANDOM; done
$B/initdb -D $P -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=$PP\nunix_socket_directories='/tmp'\nlisten_addresses=''\nwal_level=replica\nwal_consistency_checking='generic'\nmax_wal_senders=4\nhot_standby=on\nshared_buffers=256MB\nmax_wal_size=8GB\nwal_keep_size=8GB\n" >> $P/postgresql.conf
echo "local replication all trust" >> $P/pg_hba.conf
$B/pg_ctl -D $P -l $P/log -w start >/dev/null
$B/pg_basebackup -h /tmp -p $PP -U postgres -D $S -R -X stream >/dev/null 2>&1; sed -i "s/^port=$PP/port=$SP/" $S/postgresql.conf
$B/pg_ctl -D $S -l $S/log -w start >/dev/null
Q="$B/psql -X -q -At -h /tmp -p $PP -U postgres -v ON_ERROR_STOP=1"
$Q -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE t (id int PRIMARY KEY, body text, d ftsdoc)"
L0=$($Q -c "SELECT pg_current_wal_insert_lsn()")
$Q -c "INSERT INTO t SELECT g, 'alpha w' || (g % 97) || CASE WHEN g % 50 = 0 THEN ' rare' ELSE '' END, NULL FROM generate_series(1, 50000) g" \
   -c "UPDATE t SET d = to_ftsdoc('simple', body)" -c "CREATE INDEX t_d ON t USING fts (d) WITH (positions = on)" \
   -c "DELETE FROM t WHERE id % 11 = 0" -c "VACUUM t" -c "SET pg_fts.pending_flush_threshold = 300" \
   -c "INSERT INTO t SELECT g, 'fresh rare', to_ftsdoc('simple', 'fresh rare') FROM generate_series(50001, 60000) g" \
   -c "SELECT fts_merge('t_d')" -c "SELECT fts_vacuum('t_d')" >/dev/null
L1=$($Q -c "SELECT pg_current_wal_insert_lsn()"); $Q -c "SELECT pg_switch_wal()" >/dev/null
sleep 3
echo "churn WAL $L0 .. $L1"
$B/pg_waldump -p $P/pg_wal -s $L0 -e $L1 --stats=record 2>/dev/null | grep -E "^Generic|^Total|Type" | head -6
gen=$($B/pg_waldump -p $P/pg_wal -s $L0 -e $L1 -r Generic 2>/dev/null | wc -l)
chk=$($B/pg_waldump -p $P/pg_wal -s $L0 -e $L1 -r Generic -b 2>/dev/null | grep -c "for WAL verification")
echo "Generic records in the churn: $gen; block images kept only for the consistency check ('for WAL verification'): $chk"
for i in $(seq 1 120); do r=$($B/psql -X -At -h /tmp -p $SP -U postgres -c "SELECT pg_last_wal_replay_lsn() >= '$L1'::pg_lsn"); [ "$r" = t ] && break; sleep 1; done
echo "standby replayed: $r; 'inconsistent page' in standby log: $(grep -c 'inconsistent page' $S/log)"
# negative control: flip a byte in the data area of index block 1 on the primary behind PostgreSQL's back (the buffer
# is evicted first so the next read sees the change), then cause a GenericXLog record on that page (an insert into the
# pending list on block 1 is not guaranteed; instead re-run a merge, which rewrites the metapage = block 0)
$Q -c "CHECKPOINT"
F=$P/$($Q -c "SELECT pg_relation_filepath('t_d')")
$B/pg_ctl -D $P -m fast -w stop >/dev/null
python3 - "$F" <<'PY'
import sys
import struct
f=open(sys.argv[1],'r+b'); f.seek(0); pg=f.read(8192)
lower,upper=struct.unpack_from('<HH',pg,12)
off=(24+lower)//2      # mid segs[]: an unused segment slot (1 live segment), below pd_lower, not touched by an insert
assert off < lower, (off, lower)
f.seek(off); b=f.read(1); f.seek(off); f.write(bytes([b[0]^0x01])); f.close()
print("metapage pd_lower=%d pd_upper=%d; flipped one bit of byte %d (an unused segs[] slot)" % (lower, upper, off))
PY
$B/pg_ctl -D $P -l $P/log -w start >/dev/null
L2=$($Q -c "SELECT pg_current_wal_insert_lsn()")
$Q -c "SET pg_fts.pending_flush_threshold = 0" -c "INSERT INTO t VALUES (99999, 'x', to_ftsdoc('simple', 'x'))" >/dev/null 2>&1; echo "write after corruption rc=$?"
L3=$($Q -c "SELECT pg_current_wal_insert_lsn()")
sleep 5
echo "records of that write touching block 0 of t_d:"; $B/pg_waldump -p $P/pg_wal -s $L2 -e $L3 -b 2>/dev/null | grep -B1 -A3 "Generic" | grep -E "Generic|blk 0|FPW|image" | head -8
echo "NEGATIVE CONTROL: standby 'inconsistent page' lines: $(grep -c 'inconsistent page' $S/log); standby alive: $($B/pg_ctl -D $S status >/dev/null 2>&1 && echo yes || echo no)"
grep -m2 "inconsistent page" $S/log
$B/pg_ctl -D $S -m immediate -w stop >/dev/null 2>&1; $B/pg_ctl -D $P -m immediate -w stop >/dev/null 2>&1
echo WALCC2_DONE
