#!/bin/bash
# mk.sh <commit-ish> <out.tgz> : full tracked tree of a commit (or the working tree if commit-ish = WT) + GITREV
cd ~/ws/pg_fts; C=$1; OUT=$2
if [ "$C" = WT ]; then
  { git ls-files; git ls-files --others --exclude-standard | grep -v "^bench/\|unison"; git ls-files --others --ignored --exclude-standard sql expected t specs 2>/dev/null; } | sort -u > /tmp/kiwi/rm/lsf.txt
  echo "WT+$(git rev-parse --short HEAD)" > GITREV; echo GITREV >> /tmp/kiwi/rm/lsf.txt
  tar czf $OUT -T /tmp/kiwi/rm/lsf.txt; mv GITREV /tmp/kiwi/trash_gr_$RANDOM
else
  D=$(mktemp -d); git worktree add -q --detach $D/w $C || exit 1
  ( cd $D/w && git rev-parse --short HEAD > GITREV && { git ls-files; echo GITREV; } > /tmp/kiwi/rm/lsf.txt && tar czf $OUT -T /tmp/kiwi/rm/lsf.txt )
  git worktree remove --force $D/w; mv $D /tmp/kiwi/trash_$RANDOM
fi
echo "$OUT: $(tar xzf $OUT -O GITREV) $(tar tzf $OUT | wc -l) files"
