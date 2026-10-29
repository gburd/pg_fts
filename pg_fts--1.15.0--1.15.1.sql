/* pg_fts 1.15.0 -> 1.15.1
 *
 * No new or changed SQL objects: the fix is in C (the configured
 * analyzer's chunked re-parse of documents over 16,383 tokens, ROADMAP
 * I9a).  No on-disk index format change (BM25_VERSION unchanged); no
 * REINDEX for the format.  A stored ftsdoc computed by 1.15.0 from markup
 * over 16,383 tokens should be recomputed (CHANGELOG 1.15.1).
 */
