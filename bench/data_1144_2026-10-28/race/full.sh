#!/bin/bash
# full normal-build gate on a tree: installcheck (all REGRESS + ISOLATION) + TAP (12 files), PG17 + PG18
exec > /nvme/rm/full.log 2>&1
bash /tmp/rm/bt.sh /nvme/rm/i17.tgz full 0 "t/003_corruption.pl t/004_encodings.pl t/005_concurrency.pl t/006_concurrent_extend.pl t/007_segment_cap.pl t/008_vacuum_reclaim.pl t/010_vacuum_delete_heavy.pl t/011_shared_doclen.pl t/012_concurrent_flush.pl t/013_ranked_flush_race.pl t/014_flush_publish_window.pl t/015_cache_rebuild_error.pl"
echo FULL_DONE
