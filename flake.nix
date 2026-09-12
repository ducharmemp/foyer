{
  description = "foyer — furnish a jj workspace on arrival";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

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
          # override the build/install to produce an escript and wrap it so `jj`
          # (the runtime dependency it shells out to) is always on PATH.
          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            export MIX_ENV=prod
            mix escript.build
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -Dm755 foyer "$out/libexec/foyer"
            makeWrapper "$out/libexec/foyer" "$out/bin/foyer" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ beam.erlang pkgs.jujutsu pkgs.bash ]}
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
              mix test --color
            '';
            installPhase = "touch $out";
          };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            (elixirFor pkgs)
            (beamFor pkgs).erlang
            (beamFor pkgs).elixir-ls
            pkgs.jujutsu
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
      });
    };
}
