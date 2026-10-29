/* pg_fts 1.14.3 -> 1.15.0
 *
 * No new or changed SQL objects: the changes are in C (flush publish,
 * relcache cache rebuild, driven ranked AND, collect-path early exit,
 * partial-index count(*), configured-analyzer positions past 16,383).
 *
 * No on-disk index format change (BM25_VERSION unchanged); no REINDEX.
 * Stored ftsdoc columns and expression indexes built with a configuration
 * (to_ftsdoc(config, text)) keep the positions they were built with: a
 * document longer than 16,383 tokens gains its positions past that point
 * only when the column is recomputed or the index rebuilt (CHANGELOG).
 */
