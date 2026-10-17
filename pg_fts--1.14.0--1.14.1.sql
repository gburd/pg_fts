/* pg_fts 1.14.0 -> 1.14.1
 *
 * No new or changed SQL objects.  C-level changes only: fts_matchsel no longer
 * estimates every row when the index has pending documents; VACUUM's cleanup
 * no longer grows the index when it cannot truncate (parallel VACUUM, or a
 * concurrent reader holding a lock on the index); bulkdelete's docid batch is
 * capped whatever maintenance_work_mem is.
 *
 * No on-disk index format change (BM25_VERSION unchanged): no REINDEX.
 */
