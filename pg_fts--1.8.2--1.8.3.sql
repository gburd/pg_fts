/* pg_fts 1.8.2 -> 1.8.3
 *
 * No SQL-visible changes.  C-level only:
 *   - two deadlocks under concurrent insert + VACUUM fixed (the insert path's
 *     full-directory merge ran without the maintenance mutex; a live page could be
 *     handed out as merge output)
 *   - merges reuse pages freed by earlier merges: bulk-ingest growth eliminated on
 *     row-per-transaction ingest
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
