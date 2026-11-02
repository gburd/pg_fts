#!/bin/bash
# run_e.sh: final-tree checks.  (1) ranked_tombstones on 1.15.1 and the final tree, PG17+18 (results = expected source);
# (2) bmw_block_end on 1.10.0; (3) churn.sh on the final tree; (4) perf profile of patch10 at S3 on the final tree.
bash /tmp/clean.sh >/dev/null 2>&1
O=/nvme/e; mkdir -p $O
for v in head:/nvme/churn/head.tgz fix4:/tmp/fix4.tgz; do L=${v%%:*}; T=${v##*:}
  for M in 17 18; do B=/nvme/pg$M/bin; PFX=$O/pfx$M-$L; [ -d $PFX ] || cp -a /nvme/pg$M $PFX
    S=$O/src-$L-$M; [ -d $S ] || { mkdir -p $S; tar xzf $T -C $S; }
    (cd $S && make -s -j16 PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1)
    D=$O/d$M-$L; P=68$M; [ $L = fix4 ] && P=69$M
    $PFX/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
    printf "port=$P\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
    $PFX/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
    $PFX/bin/psql -X -a -q -h /tmp -p $P -U postgres -d postgres < /tmp/ranked_tombstones.sql > $O/rt_${L}_$M.out 2>&1
    echo "== ranked_tombstones $L PG$M GITREV=$(cat $S/GITREV) ERRORs=$(grep -c ERROR $O/rt_${L}_$M.out) f=$(grep -cE '\| f( |$)|^ f$' $O/rt_${L}_$M.out)"
    $PFX/bin/pg_ctl -D $D -w stop >/dev/null
  done
done
echo "== diff head vs fix4 (PG17):"; diff $O/rt_head_17.out $O/rt_fix4_17.out && echo identical
echo "== diff PG17 vs PG18 (fix4):"; diff $O/rt_fix4_17.out $O/rt_fix4_18.out && echo identical
bash /tmp/r1b.sh /tmp/v1.10.0.tar.gz v110 2>&1 | grep -E "^==|diff_rc|^ +[0-9]"
cp /tmp/churn.sh /tmp/fix4.tgz /nvme/churn/; SO=fix4 SFX=_fix4 bash /nvme/churn/churn.sh
sed -e 's|src-fix3|src-fix4|g; s|prof3.log|prof4.log|; s|perf3_|perf4_|g' /nvme/churn/prof3.sh > /nvme/churn/prof4.sh; bash /nvme/churn/prof4.sh
echo E_DONE > /nvme/e/E_DONE
