/* pg_fts 1.12.1 -> 1.13.0
 *
 * No new or changed SQL objects.  C-level changes only: compound proximity
 * operators (w/N, p/N, <N>, <->, <0>) in the ftsquery grammar and binary
 * format, positional evaluation of proximity under AND / NOT, ranked scans
 * over pending documents and expansion-only matches, stricter binary query
 * input, character-based fuzzy edit distance (GitHub PR #12).
 *
 * No on-disk index format change (BM25_VERSION unchanged): no REINDEX.
 */
