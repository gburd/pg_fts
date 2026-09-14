/* pg_fts 1.7.0 -> 1.7.1
 *
 * No SQL-visible changes.  C-level only:
 *   - the pd_lower bounds guard added in 1.7.0 for the merge's dict walk is now
 *     applied at ALL EIGHT page-read sites (including bm25_free_segment), via one
 *     shared helper.  1.7.0 fixed a single instance of the defect.
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
