#!/usr/bin/env python3
"""mutate_sm.py <out.c> -- write a copy of vendor/sm.c with the 5.8.4
left-neighbour resume's "it really is the neighbour" check removed (the
smcursor_harness TEETH build).  The vendored file is never modified."""
import pathlib
import sys

src = (pathlib.Path(__file__).resolve().parents[2] / "vendor" / "sm.c").read_text()
check = """			if (idx >= __sm_load_idx(pp) &&
			    cur->prev_offset + SM_SIZEOF_OVERHEAD +
			    __sm_chunk_get_size(&pc) == cur->offset) {
				p = pp;
			}"""
if src.count(check) != 1:
    sys.exit("mutate_sm.py: the gap-resume check moved in vendor/sm.c; update the pattern")
mut = src.replace(check, """			(void) pc;
			p = pp;	/* TEETH: no neighbour or start check */""")
pathlib.Path(sys.argv[1]).write_text(mut)
