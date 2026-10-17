#!/bin/bash
# fix (PG18 pg-fix, PG17 pg17-fix) + mutants built from the fix tree with one guard removed (PG18 and PG17)
set -uo pipefail
mk() { # $1 prefix-dir $2 base pg $3 srcdir $4 sed-script (or empty)
  local PFX=$1 BASE=$2 S=$3
  [ -d $PFX ] || cp -a $BASE $PFX
  [ -d $S ] && mv $S /nvme/trash_src_$RANDOM; mkdir -p $S; tar xzf /nvme/b3/fix.tgz -C $S; cd $S
  [ -n "$4" ] && python3 -c "$4"
  make -s clean PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1; make -s -j32 PG_CONFIG=$PFX/bin/pg_config 2>&1 | grep -E "error|warning:" | head
  make -s install PG_CONFIG=$PFX/bin/pg_config >/dev/null 2>&1 && echo "$PFX so=$(md5sum $PFX/lib/postgresql/pg_fts.so | cut -c1-8)"
}
MUTA='
s=open("pg_fts_am.c").read(); a="""	if (IsInParallelMode() &&
		!CheckRelationLockedByMe(index, AccessExclusiveLock, true))
		return false;
"""; assert s.count(a)==1; open("pg_fts_am.c","w").write(s.replace(a,""))'
MUTB='
s=open("pg_fts_am.c").read(); a="""		if (!CheckRelationLockedByMe(index, AccessExclusiveLock, true))
		{
			prevblocks = RelationGetNumberOfBlocks(index);
			break;
		}
"""; assert s.count(a)==1; open("pg_fts_am.c","w").write(s.replace(a,""))'
MUT3='
s=open("pg_fts_am_scan.c").read(); i=s.index("bm25_estimate_matchfrac(Oid indexoid, FtsQuery q)\n{"); j=s.index("\n}\n", i)
s=s[:i]+"""bm25_estimate_matchfrac(Oid indexoid, FtsQuery q)
{
	Relation	index;
	BM25MetaPageData meta;
	double		n,
				hits,
				frac;

	index = index_open(indexoid, AccessShareLock);
	if (index->rd_rel->relam != get_index_am_oid("fts", true))
	{
		index_close(index, AccessShareLock);
		return -1.0;
	}
	bm25_read_meta(index, &meta);
	n = meta.ndocs < 1.0 ? 1.0 : meta.ndocs;
	hits = bm25_query_maxhits(index, q, n);
	index_close(index, AccessShareLock);
	frac = hits / n;
	if (frac < 0.0)
		frac = 0.0;
	if (frac > 1.0)
		frac = 1.0;
	return frac;"""+s[j:]; open("pg_fts_am_scan.c","w").write(s)'
mk /nvme/b3/repro/pg-fix2 /nvme/pg18 /nvme/b3/src-fix2 ""
mk /nvme/b3/pg17-fix2 /nvme/pg17 /nvme/b3/src17-fix2 ""
mk /nvme/b3/repro/pg-mutB2 /nvme/pg18 /nvme/b3/src-mutB2 "$MUTB"
mk /nvme/b3/repro/pg-mut32 /nvme/pg18 /nvme/b3/src-mut32 "$MUT3"
mk /nvme/b3/pg17-mutB2 /nvme/pg17 /nvme/b3/src17-mutB2 "$MUTB"
echo MUTANTS_DONE
