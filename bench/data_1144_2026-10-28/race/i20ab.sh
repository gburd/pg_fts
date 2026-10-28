#!/bin/bash
# I20 + I8 A/B, hooks builds: t/014 and t/015 on the 1.14.3+hooks control (must FAIL) and on the fix (must PASS);
# then the fix as a normal build: full installcheck + TAP (t/014, t/015 must SKIP).  PG17 + PG18.
mkdir -p /nvme/rm; exec > /nvme/rm/i20ab.log 2>&1
export PG_FTS_TEST_HOOKS_BUILD=1
bash /tmp/rm/bt.sh /nvme/rm/v1143hook.tgz v1143h 1 "t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl"
bash /tmp/rm/bt.sh /nvme/rm/i20.tgz i20h 1 "t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl t/013_ranked_flush_race.pl t/012_concurrent_flush.pl"
unset PG_FTS_TEST_HOOKS_BUILD
bash /tmp/rm/bt.sh /nvme/rm/i20.tgz i20 0 "t/003_corruption.pl t/004_encodings.pl t/005_concurrency.pl t/006_concurrent_extend.pl t/007_segment_cap.pl t/008_vacuum_reclaim.pl t/010_vacuum_delete_heavy.pl t/011_shared_doclen.pl t/012_concurrent_flush.pl t/013_ranked_flush_race.pl t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl"
echo I20AB_DONE
