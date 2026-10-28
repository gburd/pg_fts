/* pg_fts 1.14.2 -> 1.14.3
 *
 * No new or changed SQL objects: the fixes are in C.  The base script's
 * comment on fts_bm25's dfs argument changed (one entry per query term
 * occurrence, not per distinct term); an upgraded install keeps the old
 * comment text, which has no effect.
 *
 * No on-disk index format change (BM25_VERSION unchanged); no REINDEX.
 */
