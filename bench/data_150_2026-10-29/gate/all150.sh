#!/bin/bash
# all150.sh: the full 1.15.0 gate on gx: old-arm build (v1.14.3 PGXN zip, sha256 f429f869...) -> main gate ->
# upgrade -> ASan (CI step extracted from ci.yml) -> per-commit (every commit v1.14.3..release, PG18 installcheck)
# -> nix flake (6 checks: installcheck/tap pg17/18 + tap-hooks pg17/18) -> 2 nix installcheck-pg17 --rebuild reruns.
# Every stage reports rc; GATE_SUMMARY lines at the end.  Inputs in /nvme/g150: final.tgz, c-<sha>.tgz,
# commits.txt, r20.bundle, pg_fts-1.14.3.zip.
G=/nvme/g150; cd $G
S=$(sha256sum pg_fts-1.14.3.zip | cut -c1-64)
[ "$S" = f429f8698e693b78089805fc123e7e18a9b05cddc71c109e20fcd333e69e2307 ] || { echo "OLD ZIP SHA MISMATCH $S"; exit 1; }
for M in 17 18; do
  O=$G/old$M; [ -d $O ] || cp -a /nvme/pg$M $O
  OS=$G/oldsrc$M; [ -d $OS ] && mv $OS /nvme/trash_o_$RANDOM; mkdir -p $OS; (cd $OS && unzip -q $G/pg_fts-1.14.3.zip && cd pg_fts-1.14.3 && make -s -j32 PG_CONFIG=$O/bin/pg_config >/dev/null 2>&1 && make -s install PG_CONFIG=$O/bin/pg_config >/dev/null 2>&1) || { echo "OLD BUILD FAIL PG$M"; exit 1; }
  echo "old arm PG$M: $(grep default_version $OS/pg_fts-1.14.3/pg_fts.control) so=$(md5sum $O/lib/postgresql/pg_fts.so | cut -c1-8)"
done
echo "tree $(tar xzf $G/final.tgz -O GITREV); commits: $(cat $G/commits.txt | tr '\n' ' ')"
bash /tmp/g/gate150.sh; echo "GATE_SUMMARY main rc=$? $(grep -E 'installcheck rc|summary:|tap rc|hooks tap rc|^Result|check-alloc|check-ascii|docs:|fuzz rc|ALL CLEAN|coverage rc|rerun|oom' $G/gate150.log | tr '\n' ' ')"
bash /tmp/g/upg150.sh; echo "GATE_SUMMARY upgrade $(grep -c 'UPGRADE OK' $G/upg150.log) of 2 UPGRADE OK"
bash /tmp/g/asan150.sh; echo "GATE_SUMMARY asan rc=$?"
COMMITS="$(cat $G/commits.txt)" bash /tmp/g/percommit150.sh; echo "GATE_SUMMARY percommit rc=$? $(grep -cE ' rc=0 ' $G/percommit150.log) green"
bash /tmp/g/nixgate150.sh $G/r20.bundle final > $G/nix150.log 2>&1; echo "GATE_SUMMARY nix rc=$? $(grep -E '^nix build rc' $G/nix150.log)"
. ~/.nix-profile/etc/profile.d/nix.sh
cd /nvme/nixgate-final && echo "nix tree $(git log -1 --format=%h)"
for i in 1 2; do
  nix --extra-experimental-features 'nix-command flakes' build .#checks.x86_64-linux.installcheck-pg17 -L --no-link --rebuild > $G/nixrep17-$i.log 2>&1
  echo "GATE_SUMMARY nix pg17 rerun $i rc=$? $(grep -E 'tests (passed|failed)' $G/nixrep17-$i.log | sed 's/.*> //' | tr '\n' ' ')"
done
echo ALL150_DONE
