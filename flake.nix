{
  description = "foyer — furnish a jj workspace on arrival";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Exact-version package source. Burrito needs an OTP version it publishes
    # precompiled ERTS for (see the release shell below); nixpkgs only ships the
    # latest patch. The multiverse serves any historical version, pinned in
    # multiverse.lock, and its fast path substitutes the prebuilt store path
    # from cache.nixos.org instead of building.
    multiverse.url = "github:fzakaria/nixpkgs-multiverse";
  };

  outputs =
    { self, nixpkgs, multiverse }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Variant that also passes the system string, for outputs that need to
      # reach into the multiverse's per-system attrs (the release devShell).
      forAllSystems' = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system} system);

      # One BEAM toolchain, used by the package, the devShell and the checks, so
      # every entry point builds against the same Elixir/Erlang pair.
      beamFor = pkgs: pkgs.beam.packages.erlang_28;
      elixirFor = pkgs: (beamFor pkgs).elixir_1_18;

      # The escript: a single self-contained BEAM executable named `foyer`.
      # No hex deps, so the build is a plain `mix escript.build` — no deps.nix,
      # no fixed-output derivation to keep in sync.
      mkFoyer =
        pkgs:
        let
          beam = beamFor pkgs;
          elixir = elixirFor pkgs;
          # The escript's RUNTIME erlang. Default nixpkgs erlang builds with the
          # wx/observer GUI, dragging wxwidgets + webkitgtk + gtk into the
          # closure (~1.1 GiB). A CLI escript needs none of that, so the wrapper
          # points at the minimal BEAM erlang (~190 MiB). The build toolchain
          # above stays full; only what the shipped binary references at run time
          # is trimmed.
          runtimeErlang = pkgs.beam_minimal.interpreters.erlang;
        in
        beam.mixRelease {
          pname = "foyer";
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self;
          mixNixDeps = { };

          nativeBuildInputs = [
            elixir
            pkgs.makeWrapper
          ];

          # mixRelease expects a Phoenix-style OTP release. foyer is a CLI, so we
          # override the build/install to produce an escript and wrap it with the
          # Erlang runtime it needs on PATH.
          #
          # `jj` is deliberately NOT bundled: foyer shells out to jj, but jj is
          # foyer's caller (the `jj foyer …` alias) and the user's own VCS — it
          # is expected on PATH already, like grep or bash. Vendoring it would
          # invert the dependency direction and bloat the closure by ~76 MiB.
          #
          # Built in the dev env on purpose: the escript needs no dependencies,
          # while :prod pulls in Burrito (the release-only dep). Keeping this
          # build dep-free is what lets mixNixDeps stay empty and hermetic.
          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            export MIX_ENV=dev
            mix escript.build
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -Dm755 foyer "$out/libexec/foyer"
            makeWrapper "$out/libexec/foyer" "$out/bin/foyer" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ runtimeErlang pkgs.bash ]} \
              --set-default LC_ALL C.UTF-8
            runHook postInstall
          '';

          # escripts need the Erlang runtime present at run time; the wrapper's
          # erl comes from the mixRelease closure.

          meta = {
            description = "Furnish a jj workspace on arrival: wrap `jj workspace add` and run the project's .foyer/setup.sh";
            license = pkgs.lib.licenses.mit;
            mainProgram = "foyer";
          };
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        foyer = mkFoyer pkgs;
        default = foyer;

        # A self-contained, one-command demo for trynix.dev (or any nix run).
        # Boot the store path in a browser VM and type `foyer-demo`: it seeds a
        # jj repo with a committed .foyer/setup.sh, runs `foyer create`, and
        # shows the furnished workspace. foyer + jujutsu ride in its PATH, so the
        # closure is all the VM needs — nothing else on the command line.
        foyer-demo = pkgs.writeShellApplication {
          name = "foyer-demo";
          runtimeInputs = [
            foyer
            pkgs.jujutsu
            pkgs.coreutils
          ];
          text = ''
            set -euo pipefail

            # A fresh VM has no jj identity; set one so commits work.
            export JJ_CONFIG="''${JJ_CONFIG:-/tmp/foyer-demo-jjconfig.toml}"
            cat > "$JJ_CONFIG" <<'EOF'
            [user]
            name = "foyer demo"
            email = "demo@foyer.example"
            EOF

            repo="''${1:-/tmp/foyer-demo}"
            rm -rf "$repo"
            mkdir -p "$repo"
            cd "$repo"

            echo "==> jj git init $repo"
            jj git init >/dev/null

            echo "==> writing a committed .foyer/setup.sh"
            mkdir -p .foyer
            cat > .foyer/setup.sh <<'EOF'
            #!/usr/bin/env bash
            # Runs in each NEW workspace with JJ_WORKSPACE_ROOT set.
            echo "  furnished $(basename "$JJ_WORKSPACE_ROOT")  (from .foyer/setup.sh)"
            EOF
            chmod +x .foyer/setup.sh
            jj describe -m "seed: add .foyer/setup.sh" >/dev/null
            # The setup script must be committed to appear in a new workspace,
            # because jj populates a new workspace from the parent revision.
            jj new >/dev/null

            echo
            echo "==> foyer create feature-x"
            foyer create feature-x
            echo
            echo "==> jj workspace list"
            jj workspace list
            echo
            echo "Done. The new workspace ran .foyer/setup.sh on arrival."
            echo "Poke around:  cd $repo  &&  foyer create another-one"
          '';
          meta.description = "One-command foyer demo: seed a jj repo and furnish a workspace";
        };
      });

      overlays.default = final: _prev: {
        foyer = mkFoyer final;
      };

      # Home-manager module: install the foyer CLI and wire the jj alias so
      #   jj foyer create feature-x
      # runs `jj util exec -- foyer create feature-x` with JJ_WORKSPACE_ROOT set.
      #
      # Import alongside your jujutsu module; the alias is merged into
      # programs.jujutsu.settings.aliases, so your existing aliases are kept.
      #
      #   imports = [ foyer.homeModules.foyer ];
      #   programs.foyer.enable = true;
      homeModules.foyer =
        {
          lib,
          config,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.foyer;
        in
        {
          options.programs.foyer = {
            enable = lib.mkEnableOption "foyer, the jj-workspace furnisher";

            package = lib.mkOption {
              type = lib.types.package;
              default = mkFoyer pkgs;
              defaultText = lib.literalExpression "foyer.packages.\${system}.default";
              description = "The foyer CLI package (provides the `foyer` executable).";
            };

            aliasName = lib.mkOption {
              type = lib.types.str;
              default = "foyer";
              description = ''
                The jj alias name. With the default, `jj foyer …` runs foyer.
                Set to another word to avoid a clash with an existing alias.
              '';
            };

            installJjAlias = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Write the `jj util exec` alias into programs.jujutsu.settings.
                Set false to install only the CLI and add the alias yourself.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];

            # `util exec -- <prog>` makes jj hand the remaining args to the
            # program instead of parsing them, and exports JJ_WORKSPACE_ROOT.
            programs.jujutsu.settings.aliases.${cfg.aliasName} = lib.mkIf cfg.installJjAlias [
              "util"
              "exec"
              "--"
              "${cfg.package}/bin/foyer"
            ];
          };
        };

      # `mix test` in the Nix sandbox against the pinned toolchain.
      checks = forAllSystems (pkgs: {
        tests =
          let
            elixir = elixirFor pkgs;
          in
          pkgs.stdenvNoCC.mkDerivation {
            name = "foyer-tests";
            src = self;
            nativeBuildInputs = [
              elixir
              (beamFor pkgs).erlang
            ];
            dontBuild = true;
            doCheck = true;
            checkPhase = ''
              export HOME="$TMPDIR"
              export MIX_ENV=test
              # Elixir wants a UTF-8 locale or it warns and can misbehave.
              export ELIXIR_ERL_OPTIONS="+fnu"
              mix test --color
            '';
            installPhase = "touch $out";
          };
      });

      devShells = forAllSystems' (
        pkgs: system:
        let
          # Burrito 1.6 requires EXACTLY zig 0.16.0 (strict equality). Pin the
          # explicit attr so a nixpkgs bump of the default `zig` cannot drift off
          # what Burrito demands.
          zig = pkgs.zig_0_16;

          # Exact OTP + Elixir from the multiverse. OTP 28.2 is the version
          # Burrito publishes precompiled ERTS for. `mv.version` resolves a
          # package at the revision that shipped it; nothing is built for a
          # version whose store path is already in cache.nixos.org.
          mv = multiverse.multiverse.${system};
          releaseErlang = mv.version "erlang" "28.2";
          releaseElixir = mv.version "elixir" "1.18.4";
        in
        {
          default = pkgs.mkShell {
            packages = [
              (elixirFor pkgs)
              (beamFor pkgs).erlang
              (beamFor pkgs).elixir-ls
              pkgs.jujutsu
              # For scripts/build-release.sh (Burrito): zig cross-compiles the
              # wrapper, xz packs the payload.
              zig
              pkgs.xz
            ];

            # Keep mix's caches inside the project so a devShell never writes to
            # the user's global ~/.mix / ~/.hex.
            shellHook = ''
              export MIX_HOME="$PWD/.nix-mix"
              export HEX_HOME="$PWD/.nix-hex"
              mkdir -p "$MIX_HOME" "$HEX_HOME"
              export PATH="$MIX_HOME/bin:$HEX_HOME/bin:$PATH"
            '';
          };

          # The release toolchain, one source of truth for scripts/build-release.sh.
          # CI runs `nix develop .#release -c scripts/build-release.sh`, so the
          # exact OTP (28.2, Burrito-published), Elixir, zig 0.16 and xz all come
          # from here — they cannot drift from what the build needs the way an
          # ad-hoc setup-beam/setup-zig pin did.
          release = pkgs.mkShell {
            packages = [
              releaseErlang
              releaseElixir
              zig
              pkgs.xz
            ];

            shellHook = ''
              export MIX_HOME="$PWD/.nix-mix"
              export HEX_HOME="$PWD/.nix-hex"
              mkdir -p "$MIX_HOME" "$HEX_HOME"
              export PATH="$MIX_HOME/bin:$HEX_HOME/bin:$PATH"
            '';
          };
        }
      );
    };
}
