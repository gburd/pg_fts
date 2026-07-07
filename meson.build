# meson.build for pg_fts (Windows / MSVC out-of-tree build)
#
# The primary build path is the PGXS Makefile (Linux, macOS, *BSD).  This
# meson recipe exists only for Windows/MSVC, where PostgreSQL itself is built
# with meson and PGXS is unavailable.
#
# PREREQUISITE (not yet satisfied on the test box): an MSVC-built PostgreSQL
# >= 17 built from source with the same Visual Studio toolchain
# (`meson setup ... && ninja install`).  A MinGW/Strawberry PostgreSQL will NOT
# work: it ships a GCC-flavored pg_config.h (HAVE_STRINGS_H=1,
# PG_INT128_TYPE=__int128) that MSVC cannot consume, and no postgres.lib backend
# import library to link against.  The pg_fts C sources are MSVC-clean (vendored
# sparsemap already carries full _MSC_VER shims, including _M_ARM64), so once a
# real MSVC PostgreSQL exists this recipe is the whole story.
#
# Build (from an "x64 Native Tools" prompt, or after vcvars64.bat):
#   meson setup build -Dpg_dir=C:/pgsql --buildtype=release
#   ninja -C build
#   ninja -C build install   # pg_fts.dll -> <pg>/lib, .control/.sql -> share/extension
#
# ponytail: build recipe only; the regress/isolation/TAP harness on Windows is
# separate PGXS-style plumbing, add when installcheck actually runs on Windows.

project('pg_fts', 'c',
  version: '0.1.0',
  default_options: ['c_std=c11', 'warning_level=2'])

pg_dir = get_option('pg_dir')            # e.g. C:/pgsql (MSVC-built PG >= 17)
pg_include_server = pg_dir / 'include' / 'server'
pg_lib            = pg_dir / 'lib'

cc = meson.get_compiler('c')

# The backend import library.  An MSVC PG build ships postgres.lib here.
postgres_lib = cc.find_library('postgres', dirs: [pg_lib], required: true)

incdirs = include_directories(
  pg_include_server,                     # <postgres.h>, fmgr.h, ...
  pg_include_server / 'port' / 'win32',  # win32 port shims
  pg_include_server / 'port' / 'win32_msvc',
  pg_dir / 'include',
)

# Mirrors the Makefile OBJS list.  pg_fts_am_scan.c, pg_fts_lev.c and
# pg_fts_trgm_index.c are #included into pg_fts_am.c (not separate TUs), so they
# are intentionally NOT listed here.
sources = files(
  'pg_fts_analyze.c',
  'pg_fts_tsanalyze.c',
  'pg_fts_doc.c',
  'pg_fts_query.c',
  'pg_fts_rank.c',
  'pg_fts_am.c',
  'pg_fts_customscan.c',
  'pg_fts_aux.c',
  'pg_fts_migrate.c',
  'pg_fts_trgm.c',
  'pg_fts_match.c',
  'vendor/sm.c',                         # already carries full _MSC_VER shims
)

# On MSVC the C99-mixed-decl / implicit-fallthrough warnings the Makefile
# suppresses for vendor/sm.o do not exist in the same form, so no per-file
# suppression is needed.
c_args = [
  '-DWIN32',
  '-D_CRT_SECURE_NO_WARNINGS',
]

pg_fts = shared_module('pg_fts',
  sources,
  include_directories: incdirs,
  dependencies: [postgres_lib],
  c_args: c_args,
  name_prefix: '',                       # -> pg_fts.dll, not libpg_fts.dll
  install: true,
  install_dir: pg_lib,
)

# Control + SQL script into share/extension.  Single install script for the
# 0.1.0 release (the private incremental upgrade series was collapsed).
install_data('pg_fts.control', install_dir: pg_dir / 'share' / 'extension')
install_data('pg_fts--0.1.0.sql', install_dir: pg_dir / 'share' / 'extension')
