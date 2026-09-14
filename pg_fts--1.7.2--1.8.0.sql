/* pg_fts 1.7.2 -> 1.8.0
 *
 * No SQL-visible changes, but QUERY PARSING SEMANTICS CHANGE:
 *   - '-', '.' and '/' between two word characters are now part of the term, not
 *     operators.  to_ftsquery('pkg-config') was ('pkg' & !'config') -- a NOT clause
 *     that excluded the very documents being searched for -- and is now 'pkg-config'.
 *   - A leading '-' is still NOT; a standalone /regex/ still parses.
 *
 * Stored data is unaffected (the document analyzer already tokenized these the new
 * way).  No on-disk format change; no REINDEX required.  Applications that relied on
 * an intra-word '-' meaning NOT must use '!' or a space before the '-'.
 */
