#!/usr/bin/env python3
"""mutate_sm.py <out.c> -- write a copy of vendor/sm.c with the read cursor's
start-word check removed from __sm_get_chunk_offset: the fast path resumes at
cur->offset without checking that the word there is cur->start_idx.  That
check is what keeps a mispositioned cursor from starting the walk mid-chunk
(sparsemap 5.8.5, the fix for pg_fts ROADMAP I29), so smcursor_harness's
stale-offset property (harness_stale_offset) must FAIL on this copy.  The
vendored file is never modified."""
import pathlib
import sys

src = (pathlib.Path(__file__).resolve().parents[2] / "vendor" / "sm.c").read_text()
check = """		const __sm_idx_t at = __sm_load_idx(base + cur->offset);
		if (at == cur->start_idx) {"""
if src.count(check) != 1:
    sys.exit("mutate_sm.py: the cursor start-word check moved in vendor/sm.c; update the pattern")
mut = src.replace(check, """		const __sm_idx_t at = __sm_load_idx(base + cur->offset);
		(void) at;
		if (1) {	/* TEETH: no start-word check */""")
pathlib.Path(sys.argv[1]).write_text(mut)
