# pg_fts -- standalone PGXS build
#
# Build against an installed PostgreSQL (>= 17):
#     make PG_CONFIG=/path/to/pg_config
#     make install PG_CONFIG=/path/to/pg_config
#     make installcheck PG_CONFIG=/path/to/pg_config   # regression + isolation
#
# PG_CONFIG defaults to whatever `pg_config` is on PATH.

MODULE_big = pg_fts
OBJS = \
	$(WIN32RES) \
	pg_fts_analyze.o \
	pg_fts_tsanalyze.o \
	pg_fts_doc.o \
	pg_fts_query.o \
	pg_fts_rank.o \
	pg_fts_am.o \
	pg_fts_customscan.o \
	pg_fts_aux.o \
	pg_fts_migrate.o \
	pg_fts_trgm.o \
	vendor/sm.o \
	pg_fts_match.o

EXTENSION = pg_fts
DATA = pg_fts--0.1.0.sql
PGFILEDESC = "pg_fts - full-text search with BM25 ranking"

REGRESS = pg_fts
ISOLATION = bm25_concurrency bm25_cic
TAP_TESTS = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Vendored sparsemap uses C99 mixed declarations and its own /* FALLTHROUGH */
# comment convention (not recognized by -Wimplicit-fallthrough=5); suppress those
# warnings for it only (public symbols are namespaced to __pg_bm25_* via
# pg_fts_sm.h).
vendor/sm.o: CFLAGS += -Wno-declaration-after-statement -Wno-implicit-fallthrough
