/* pg_fts 1.7.1 -> 1.7.2
 *
 * No SQL-visible changes.  C-level only:
 *   - the insert-time merge is gated on segment pressure instead of running after
 *     every insert, cutting index growth under bulk ingest by ~31%
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
