/* pg_fts 1.15.2 -> 1.16.0
 *
 * No new or changed SQL objects: every change is in C (the on-page decode
 * guards found by the CBMC proofs, fts_vacuum's rewrite of a single packed
 * segment with tombstones, the per-backend tombstone memo, the collect-path
 * skip for an operand of plain-term readings, sparsemap 5.8.4).  No on-disk
 * index format change (BM25_VERSION unchanged); no REINDEX.
 */
