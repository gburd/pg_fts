/* pg_fts 1.6.1 -> 1.7.0
 *
 * No SQL-visible changes.  This release is C-level only:
 *   - bounds-guard the dict-page walk in merge_source_load_page (a corrupt or
 *     recycled page's pd_lower made every merge / autovacuum cleanup / fts_vacuum
 *     fail with "invalid memory alloc request size", leaving the index permanently
 *     unvacuumable)
 *   - huge-allocation safety for the doclen resident array and bulkdelete's
 *     tombstone arrays
 *   - index cleanup no longer grows the index when its free space is not yet reusable
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
