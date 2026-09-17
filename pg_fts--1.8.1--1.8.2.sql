/* pg_fts 1.8.1 -> 1.8.2
 *
 * No SQL-visible changes.  C-level only:
 *   - the trigram blob reader's page-length computation now goes through the
 *     validated pd_lower helper (a 9th instance of the 1.7.0 defect class)
 *   - allocator state is a scoped struct; misuse is a hard error, not an Assert
 *   - bm25_collect_matches split into per-segment and pending-list evaluators
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
