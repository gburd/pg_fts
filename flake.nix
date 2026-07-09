{
  description = "pg_fts — BM25 full-text search for PostgreSQL (bm25 index access method)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # PostgreSQL majors this extension supports and nixpkgs packages.
        # PG 17 and 18 are the released, packaged targets; 19/20 devel are
        # exercised in CI and on the buildfarm hosts, not from nixpkgs.
        pgVersions = {
          pg17 = pkgs.postgresql_17;
          pg18 = pkgs.postgresql_18 or pkgs.postgresql_17;
        };

        # Build pg_fts against a given postgresql package via its bundled PGXS.
        # In nixpkgs the pg_config binary lives in the `.pg_config` output.
        buildFor = postgresql:
          pkgs.stdenv.mkDerivation {
            pname = "pg_fts";
            version = "0.2.2";
            src = ./.;

            nativeBuildInputs = [ postgresql.pg_config pkgs.clang ];
            buildInputs = [ postgresql ];

            # PGXS honours PG_CONFIG; point it at this postgresql.  nixpkgs builds
            # PostgreSQL with clang, so PGXS defaults CC=clang — provide it.
            makeFlags = [ "PG_CONFIG=${postgresql.pg_config}/bin/pg_config" ];

            # Install into $out so nixpkgs' postgresql .withPackages can pick it up.
            # PGXS emits pg_fts.so (Linux) or pg_fts.dylib (macOS); glob covers both.
            installPhase = ''
              runHook preInstall
              install -D -m 755 -t $out/lib pg_fts.so 2>/dev/null || \
                install -D -m 755 -t $out/lib pg_fts.dylib
              install -D -m 644 -t $out/share/postgresql/extension pg_fts.control
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.0--0.2.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.1--0.2.2.sql
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Full-text search with BM25/BM25F ranking and a dedicated bm25 index AM";
              homepage = "https://github.com/gburd/pg_fts";
              license = licenses.postgresql;
              platforms = postgresql.meta.platforms;
            };
          };

        packages = builtins.mapAttrs (_: pg: buildFor pg) pgVersions;

        # A postgresql with pg_fts installed, for running the extension's own
        # regression/isolation/TAP suite the way `make installcheck` expects.
        pgWith = pg: pg.withPackages (_: [ (buildFor pg) ]);

        # `make installcheck` needs a running server + the test harness perl
        # module IPC::Run (for TAP) and the isolation tester (bundled with PG).
        checkFor = pg:
          pkgs.stdenv.mkDerivation {
            name = "pg_fts-installcheck-${pg.version}";
            src = ./.;
            nativeBuildInputs = [ (pgWith pg) pg.pg_config pkgs.perl pkgs.perlPackages.IPCRun ];
            dontInstall = true;
            buildPhase = ''
              export PGDATA=$TMPDIR/pgdata
              export PGHOST=$TMPDIR
              export PGPORT=5432
              initdb -U postgres --no-locale --encoding=UTF8 >/dev/null
              pg_ctl -D "$PGDATA" -o "-k $TMPDIR -c listen_addresses=localhost" -w start
              # REGRESS + ISOLATION run via PGXS installcheck against the running server.
              make installcheck \
                PG_CONFIG=${pg.pg_config}/bin/pg_config \
                PGHOST=$TMPDIR PGUSER=postgres PGPORT=$PGPORT \
                || { cat regression.diffs 2>/dev/null; cat output_iso/regression.diffs 2>/dev/null; exit 1; }
              pg_ctl -D "$PGDATA" -w stop
              touch $out
            '';
          };
      in
      {
        packages = packages // {
          default = packages.pg17;
        };

        # `nix flake check` builds every PG target and runs its installcheck.
        checks = packages // {
          installcheck-pg17 = checkFor pgVersions.pg17;
          installcheck-pg18 = checkFor pgVersions.pg18;
        };

        devShells.default = pkgs.mkShell {
          name = "pg_fts-dev";
          # PG 17 by default; `PG_CONFIG=$(pg18-config) make` to switch.
          packages = [
            pgVersions.pg17
            pgVersions.pg17.pg_config
            pkgs.gcc
            pkgs.gnumake
            pkgs.perl
            pkgs.perlPackages.IPCRun # TAP tests (t/*.pl)
            pkgs.libxml2 # xmllint, for doc validation (nix run .#docs)
            pkgs.clang-tools # clang-format / clangd for editing the C
          ];
          shellHook = ''
            echo "pg_fts dev shell — PostgreSQL ${pgVersions.pg17.version} on PATH"
            echo "  make PG_CONFIG=\$(command -v pg_config)      # build"
            echo "  nix flake check                              # build+test all PG majors"
            echo "  nix run .#docs                               # validate doc/pg_fts.sgml"
          '';
        };

        # Validate the SGML docbook fragment.  doc/pg_fts.sgml is a DocBook
        # <sect1> fragment (as PostgreSQL's own supplied-module docs are), not a
        # standalone XML document, so it uses SGML entities like &mdash; and has
        # no DTD — xmllint --recover checks tag well-formedness and ignores the
        # undefined-entity noise.  The full PG docbook->HTML stack is ~half a GB.
        # ponytail: well-formedness only; wire the full docbook stack if we ever
        # ship rendered HTML from the flake.
        apps.docs = {
          type = "app";
          program = "${pkgs.writeShellScript "pg_fts-docs" ''
            set -e
            echo "Validating doc/pg_fts.sgml (tag well-formedness)..."
            ${pkgs.libxml2}/bin/xmllint --noout --recover doc/pg_fts.sgml 2>/dev/null \
              && echo "OK: doc/pg_fts.sgml tags are well-formed."
          ''}";
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
