#!/bin/bash
# instrumented builds of bm25_vacuum_compact: diagG = current tree (vacate only under AEL), diagN = gate removed
set -uo pipefail
INSTR='
s=open("pg_fts_am.c").read()
def rep(a,b):
    global s
    assert s.count(a)==1, a[:60]
    s=s.replace(a,b)
rep("""		CHECK_FOR_INTERRUPTS();		/* between passes: no lock/window held */
""","""		CHECK_FOR_INTERRUPTS();		/* between passes: no lock/window held */
		elog(LOG, "DIAG compact pass %d start nblocks=%u par=%d ael=%d", pass, RelationGetNumberOfBlocks(index), (int) IsInParallelMode(), (int) CheckRelationLockedByMe(index, AccessExclusiveLock, true));
""")
rep("""			packed = bm25_truncate_free_tail(index);
""","""			packed = bm25_truncate_free_tail(index);
			elog(LOG, "DIAG pack-first -> nblocks=%u packed=%u prev=%u", RelationGetNumberOfBlocks(index), packed, prevblocks);
""")
rep("""		nblocks = bm25_truncate_free_tail(index);
		if (nblocks < prevblocks)
			didwork = true;

		/* Converged""","""		nblocks = bm25_truncate_free_tail(index);
		elog(LOG, "DIAG vacate+pack -> nblocks=%u prev=%u", nblocks, prevblocks);
		if (nblocks < prevblocks)
			didwork = true;

		/* Converged""")
rep("""			nblocks = bm25_truncate_free_tail(index);
			if (nblocks < prevblocks)
				didwork = true;
			prevblocks = nblocks;
			break;""","""			nblocks = bm25_truncate_free_tail(index);
			elog(LOG, "DIAG compacted -> truncate nblocks=%u", nblocks);
			if (nblocks < prevblocks)
				didwork = true;
			prevblocks = nblocks;
			break;""")
rep("""				if (nblocks > 16 && freeblks > nblocks / 4 &&""","""				elog(LOG, "DIAG cleanup nblocks=%u freeblks=%u", nblocks, freeblks);
				if (nblocks > 16 && freeblks > nblocks / 4 &&""")
open("pg_fts_am.c","w").write(s)'
NOGATE='
s=open("pg_fts_am.c").read(); a="""		if (!CheckRelationLockedByMe(index, AccessExclusiveLock, true))
		{
			prevblocks = RelationGetNumberOfBlocks(index);
			break;
		}
"""; assert s.count(a)==1; open("pg_fts_am.c","w").write(s.replace(a,""))'
for v in diagG diagN; do
  PFX=/nvme/b3/repro/pg-$v; [ -d $PFX ] || cp -a /nvme/pg18 $PFX
  S=/nvme/b3/src-$v; [ -d $S ] && mv $S /nvme/trash_src_$RANDOM; mkdir -p $S; tar xzf /nvme/b3/fix.tgz -C $S; cd $S
  python3 -c "$INSTR"; [ $v = diagN ] && python3 -c "$NOGATE"
  grep -c "DIAG" pg_fts_am.c
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "error" | head
  make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; (cd /nvme/postgresql-18.6/contrib/pg_freespacemap && make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1)
  echo "$v so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8) DIAG-in-so=$(strings $PFX/lib/postgresql/pg_fts.so | grep -c 'DIAG ')"
done
sed -i 's/printf "port=$PORT\\nunix_socket_directories/printf "log_min_messages=info\\nport=$PORT\\nunix_socket_directories/' /tmp/vpdiag.sh
TAGS="diagG diagN" bash /tmp/vpdiag.sh
for v in diagG diagN; do for par in 1 0; do echo "---- $v par=$par"; grep -E "DIAG" /nvme/b3/vpd-$v-$par/log | sed 's/.*LOG: *//' | head -60; done; done
echo DIAG_DONE
