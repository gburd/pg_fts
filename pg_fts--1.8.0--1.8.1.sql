/* pg_fts 1.8.0 -> 1.8.1
 *
 * No SQL-visible changes.  C-level only:
 *   - fts_count()/COUNT pushdown: one visibility-map lookup per run of matches on a
 *     heap page instead of one per matching tuple, and one tuple slot per call
 *     instead of one per probed tuple.  Counts are unchanged.
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
