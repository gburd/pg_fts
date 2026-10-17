#!/bin/bash
# Item 5 mutant: final tree with bm25_check_nsegments a no-op; run t/003 on PG 18.6.
set -uo pipefail
PFX=/nvme/b3/pg18-mut5; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
T=/nvme/b3/mut5; [ -d $T ] && mv $T /nvme/trash_m5_$RANDOM; mkdir -p $T; tar xzf /nvme/b3/final_r2.tgz -C $T; cd $T
python3 - <<'PY'
p='pg_fts_am.c'; s=open(p).read()
old='	if (nsegments > BM25_MAX_SEGMENTS)\n		ereport(ERROR,'
assert old in s; s=s.replace(old,'	if (nsegments > BM25_MAX_SEGMENTS && false)\n		ereport(ERROR,',1); open(p,'w').write(s)
PY
echo "mutant marker: $(grep -c 'BM25_MAX_SEGMENTS && false' pg_fts_am.c)"
make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "error" | head -3; make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1
make PG_CONFIG=$PFX/bin/pg_config installcheck REGRESS= ISOLATION= PROVE_TESTS=t/003_corruption.pl > /nvme/b3/mut5-t003.log 2>&1; echo "mutant t/003 rc=$?"
grep -E "^not ok|^ok [0-9]+ - (metapage|a query over a metapage|the error names the impossible|VACUUM reports|REINDEX restores the correct 2000 after metapage)|Result|Failed|Dubious|died|server" /nvme/b3/mut5-t003.log | head -20
grep -hE "AddressSanitizer|segfault|terminated by signal|metapage" tmp_check/log/*003* 2>/dev/null | head -5
echo MUT5_DONE
