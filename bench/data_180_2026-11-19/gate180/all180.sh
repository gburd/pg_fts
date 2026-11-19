#!/bin/bash
# all180.sh: the full 1.18.0 gate: old-arm build (v1.17.0 PGXN zip, sha256 a93a86d5...) -> main gate ->
# upgrade -> ASan (CI step extracted from ci.yml) -> per-commit (every commit v1.17.0..release, PG18 installcheck)
# -> nix flake (6 checks: installcheck/tap pg17/18 + tap-hooks pg17/18) -> 2 nix installcheck-pg17 --rebuild reruns.
# Every stage reports rc; GATE_SUMMARY lines at the end.  Inputs in /nvme/g180: final.tgz, c-<sha>.tgz,
# commits.txt, r180.bundle, pg_fts-1.17.0.zip.
G=/nvme/g180; cd $G
S=$(sha256sum pg_fts-1.17.0.zip | cut -c1-64)
[ "$S" = a93a86d5312aa67399833a2855cb807e2db87c34102679ac2479793e95ab6fc7 ] || { echo "OLD ZIP SHA MISMATCH $S"; exit 1; }
for M in 17 18 19; do
  O=$G/old$M; [ -d $O ] || cp -a /nvme/pg$M $O
  OS=$G/oldsrc$M; [ -d $OS ] && mv $OS /nvme/trash_o_$RANDOM; mkdir -p $OS; (cd $OS && unzip -q $G/pg_fts-1.17.0.zip && cd pg_fts-1.17.0 && make -s -j32 PG_CONFIG=$O/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$O/bin/pg_config >/dev/null 2>&1) || { echo "OLD BUILD FAIL PG$M"; exit 1; }
  echo "old arm PG$M: $(grep default_version $OS/pg_fts-1.17.0/pg_fts.control) so=$(md5sum $O/lib/postgresql/pg_fts.so | cut -c1-8)"
done
echo "tree $(tar xzf $G/final.tgz -O ./GITREV); commits: $(cat $G/commits.txt | tr '\n' ' ')"
bash /tmp/g2/gate180.sh; echo "GATE_SUMMARY main rc=$? $(grep -E 'installcheck rc|summary:|tap rc|hooks tap rc|^Result|check-alloc|check-ascii|docs:|fuzz rc|ALL CLEAN|coverage rc|rerun|oom|TRAPs' $G/gate180.log | tr '\n' ' ')"
bash /tmp/g2/upg180.sh; echo "GATE_SUMMARY upgrade $(grep -c 'UPGRADE OK' $G/upg180.log) of 3 UPGRADE OK"
bash /tmp/g2/asan180.sh; echo "GATE_SUMMARY asan rc=$?"
COMMITS="$(cat $G/commits.txt)" bash /tmp/g2/percommit180.sh; echo "GATE_SUMMARY percommit rc=$? $(grep -cE ' rc=0 ' $G/percommit180.log) green"
bash /tmp/g2/nixgate180.sh $G/r180.bundle final > $G/nix180.log 2>&1; echo "GATE_SUMMARY nix rc=$? $(grep -E '^nix build rc' $G/nix180.log)"
. ~/.nix-profile/etc/profile.d/nix.sh
cd /nvme/nixgate-final && echo "nix tree $(git log -1 --format=%h)"
for i in 1 2; do
  nix --extra-experimental-features "nix-command flakes" build .#checks.$(uname -m)-linux.installcheck-pg17 -L --no-link --rebuild > $G/nixrep17-$i.log 2>&1
  echo "GATE_SUMMARY nix pg17 rerun $i rc=$? $(grep -E 'tests (passed|failed)' $G/nixrep17-$i.log | sed 's/.*> //' | tr '\n' ' ')"
done
echo ALL180_DONE
