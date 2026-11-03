/* pg_fts 1.15.1 -> 1.15.2
 *
 * No new or changed SQL objects: both fixes are in C (tombstone lookups no
 * longer walk the tombstone set from its start, ROADMAP I25; the block-max
 * WAND skip no longer passes the pivot, ROADMAP I26).  No on-disk index
 * format change (BM25_VERSION unchanged); no REINDEX.
 */
