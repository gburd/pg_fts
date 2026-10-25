/* pg_fts 1.14.1 -> 1.14.2
 *
 * No new or changed SQL objects and no C change: a documentation and safety
 * release.  An index that took writes under 1.10.0 or earlier can return rows
 * that do not match, and miss rows that do, after an in-place upgrade; this
 * script cannot repair that.  REINDEX such an index (CHANGELOG 1.14.2 has the
 * check query).
 *
 * No on-disk index format change (BM25_VERSION unchanged).
 */
