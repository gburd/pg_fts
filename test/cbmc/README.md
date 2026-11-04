# CBMC proofs (`test/cbmc/`)

[CBMC](https://www.cprover.org/cbmc/) checks a C function against **every** input
within a stated bound and either proves the property or prints a counterexample.
These harnesses prove properties of pg_fts's own code where a test can only sample:
the ranked traversals, the BM25 bounds they prune with, the guards on bytes read off a
page, the query-shape shortcuts, the codecs, the sparsemap cursor and the shared
doclen protocol.  The style follows `~/ws/libdb/test/cbmc` (single-threaded parsers and
algorithms) and `~/ws/libxtc/test/cbmc` (interleavings).

A proof holds **up to its bound**: it is complete for every input inside it and says
nothing beyond it.  Each harness states its bound in its header comment.

## Running

```sh
bash test/cbmc/run.sh                 # everything but the two slow sets (~1.5 h serial)
CBMC_SLOW=1 CBMC_FP=1 bash test/cbmc/run.sh   # also MaxScore and the symbolic IEEE proofs
bash test/cbmc/run.sh codec ondisk    # only harness files whose name matches
```

Needs `cbmc` (validated with 6.6.0, Debian 13's package) and `python3`.  Several
proofs need 20-60 GB of memory; run them on an r6id.8xlarge-class host, not a laptop.
Exit status is non-zero if a proof fails, if a planted bug is **not** caught, or if a
copied function has drifted from the source.

## Code under proof is the shipped code

A harness either `#include`s the shipped header or source (`pg_fts_for.h`,
`pg_fts_docvalid.h`, `vendor/sm.c`), or copies a function **verbatim** between

    /* VERBATIM <source-file> <function> */
    ...
    /* END VERBATIM */

and `check_verbatim.py` (run first by `run.sh`) compares each copy with the source,
ignoring whitespace and comments.  Change a copied function and the run fails until the
harness is updated with it.  Only the surroundings are modelled: page bytes, cursors,
`palloc`.  Each harness says what is modelled and what is not.

## Every proof has teeth

A proof that cannot fail proves nothing.  Each property is also run against a
**mutant** with a historical bug planted back in (`-DTEETH_*`), and `run.sh` requires
that run to FAIL.  Most of the mutants are bugs pg_fts actually shipped.

## The harnesses

| Harness | Code | Proves | Bound | Teeth (must fail) |
|---|---|---|---|---|
| `traversal_harness.c` | `fts_search_bmw`, `fts_search_maxscore` (verbatim) over a model cursor | the result equals the brute-force top-k: same documents, scores and order (score descending, then TID), for any posting layout and **any** sound block and term bounds | BMW: 2 terms x 3-4 docs, blocks of 2, k = 1, 2 (verified); MaxScore: 4 terms x 3 docs, k = 1 (`CBMC_SLOW=1`: no verdict after 2 h, 13 GB); integer scores 1-2 | the 1.3.0-1.15.1 "always make progress" pivot clamp (ROADMAP I26); the 1.10.0 suffix-sum essential split (caught in ~20 min) |
| `bound_harness.c` + `bound_exhaustive.c` | `wand_block_max_contrib` (verbatim), the best-first bound, `wand_contrib_cur`'s expression | every block bound >= the score of every posting it covers, **in IEEE doubles**; the writer's effective min length and the reader's re-quantisation only lower it | the native sweep: every tf <= 16, length <= 4096, block max tf, v3 and v4, at 2,000 corpus shapes (run.sh; 11.1G cases at 10,000 shapes found none); the CBMC proof with tf/length symbolic and fixed (avgdl, idf) is `CBMC_FP=1` (did not finish in 90 min per shape on minisat) | the 1.9.x exact-min-length bound on a v4 segment; the 1.15.2 BMW operation order (one ulp low; found here) |
| `ondisk_harness.c` | `fts_doc_check`, `bm25_page_data_end`, `bm25_dict_entry_fits`, `bm25_doclen_block_fits` (verbatim or included), the block guards of `bm25_decode_term` and `wand_load_block` | if a guard accepts, every read the caller then does is inside the buffer, and no pointer is formed past it from an on-disk integer | any 96-byte page, any FtsDoc image up to 96 bytes with <= 2 terms | the pre-1.7.1 pd_lower read; the 0.3.4 one-sided count clamp; the 1.15.2 dictionary guard, column checks and doclen-sidecar guard (found here) |
| `query_harness.c` | `query_and_operands`, `bm25_required_term_absent`, `bool_gate_may_admit`, `bool_gate_driver`, `eval_not_parity`, `bool_gate_admits` (verbatim) | a skipped segment, a refused walk and a driver choice never drop a matching document; NOT parity is right | every well-formed AND/OR/NOT query of <= 7 items, every document and segment term set | NOT let through the I19b shape test (the review's mutant); no odd-NOT clearing; a NOT operand as the driver |
| `codec_harness.c` | `pg_fts_for.h` (included) | FOR pack/unpack/get round-trip and byte counts; reads stay in the column for any width byte the readers accept; the doclen byte rounds down, is monotone and is exact below 8 | n = 1, 2, 3, 8 values of any width 0-64; corrupt widths 65, 128, 255; all 2^32 lengths | a decode buffer one byte short; "quantisation is exact" |
| `smcursor_harness.c` | `vendor/sm.c` (included) | a read cursor never changes an answer: `sm_contains(m, i, &c) == sm_contains(m, i, NULL)` for ascending, arbitrary and any-cursor-state lookups (any hint that is a chunk of the map), including the 5.8.4 gap resume | 4 map layouts serialized by the library (scattered one-per-chunk, adjacent, RLE run then gap then sparse, single chunk), opened as pg_fts opens a stored blob; every index from a chunk before the map to past its end | the gap resume without its neighbour check (`mutate_sm.py`); and a FINDING, expected to fail: a hint that is not a chunk start (ROADMAP I29) |
| `shdoclen_harness.c` | model of `pg_fts_shdoclen.c`'s slot transitions | no use after free, no double unpin, no leak at quiescence, refcount exact | one slot; two scans and a retiring, evicting merge; every interleaving | retire ignoring readers; unref also unpinning |

## Findings

The proofs found these in shipped code; each is fixed in the same change and listed in
the CHANGELOG under Unreleased:

- `wand_load_block`, the loader under every ranked traversal, decoded FOR columns whose
  sizes come from on-page width bytes without checking them against the block's length.
  One corrupt byte made a ranked query read past its copy of the block (reproduced
  end-to-end; `t/003_corruption.pl` now covers it).  The doclen sidecar readers and
  `bm25_decode_term`'s own column check had the same class of gap.
- Five dictionary walks skipped `bm25_dict_entry_fits`, and several guards formed a
  pointer past the page from an on-disk integer before comparing it.  (An independent
  review of the fix then found two trigram directory walks, the fuzzy lookahead and the
  dictionary-index walks with the same gaps, and that the first version of the loader
  fix mis-read 1.5.0-1.5.2 merged segments; all fixed, `t/003` covers the last.)
- The block-max WAND bound was one ulp below the score of its own (max tf, min length)
  posting in about 0.02% of shapes (operation order).

## Not covered

- The real cursor's page decode under the traversals: `traversal_harness.c` models it,
  `ondisk_harness.c` proves its guards.
- `fts_search_bestfirst_n`, `fts_search_and_bestfirst`, `fts_search_driven` and the
  dense path; phrase and NEAR evaluation; the analyzers; MVCC and the planner.
- The shared-doclen harness is a model: if the transitions in `pg_fts_shdoclen.c`
  change, it must change with them (it says so at the top).
