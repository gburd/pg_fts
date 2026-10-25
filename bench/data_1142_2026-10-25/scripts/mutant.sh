#!/bin/bash
# mutant.sh: build the 1.14.1 tree with bm25_bulkdelete's leading pending flush removed into its own prefix
set -e
P=/nvme/fp/pg18-mut; S=/nvme/fp/src-mut-pg18
[ -d $P ] || cp -a /nvme/pg18 $P
[ -d $S ] && mv $S /nvme/trash_$RANDOM
mkdir -p $S && tar xzf /nvme/fp/fp_rel1141.tgz -C $S && cd $S
python3 - <<'PY'
p='pg_fts_am.c'; s=open(p).read()
old="\t(void) bm25_flush_pending(index);\n\t{\n\t\tBuffer\t\tmb = bm25_readbuf(index, BM25_METAPAGE_BLKNO);\n\n\t\tLockBuffer(mb, BUFFER_LOCK_SHARE);\n\t\tbm25_check_meta"
assert s.count(old)==1, s.count(old)
s=s.replace(old, "\t/* MUTANT: (void) bm25_flush_pending(index); */\n\t{\n\t\tBuffer\t\tmb = bm25_readbuf(index, BM25_METAPAGE_BLKNO);\n\n\t\tLockBuffer(mb, BUFFER_LOCK_SHARE);\n\t\tbm25_check_meta")
open(p,'w').write(s)
PY
echo "mutant markers: $(grep -c 'MUTANT: (void) bm25_flush_pending' pg_fts_am.c)"
make -s clean PG_CONFIG=$P/bin/pg_config >/dev/null 2>&1 || true; make -s -j16 PG_CONFIG=$P/bin/pg_config > build.log 2>&1; make -s install PG_CONFIG=$P/bin/pg_config >> build.log 2>&1
echo MUTANT_INSTALLED
