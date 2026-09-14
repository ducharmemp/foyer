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

          # Build from a filtered source: only the files the release actually
          # depends on. Editing README, .github, flake.nix, or tests then does
          # NOT change foyer's store hash — so the trynix demo link (a hardcoded
          # store path) survives doc and CI commits, and only moves when the
          # code or locked deps change. Verified: a README-only edit no longer
          # rebuilds foyer.
          foyerSrc = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./lib
              ./lib_prod
              ./mix.exs
              ./mix.lock
            ];
          };
        in
        beam.mixRelease {
          pname = "foyer";
          # Fixed version (not the git rev) so the store hash depends only on
          # the filtered source above, not on which commit built it. Keeps the
          # trynix demo path stable across non-code commits.
          version = "0.1.0";
          src = foyerSrc;
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

            # mix escript.build writes `#!/usr/bin/env escript` as the shebang.
            # That needs the file /usr/bin/env to exist at exec time — true on a
            # normal distro, but NOT in a bare nix environment (a scratch/distroless
            # container, or a trynix VM whose only non-/nix paths are what its init
            # creates). Rewrite it to the absolute escript path so foyer runs with
            # no /usr/bin/env present at all.
            #
            # An escript is a shebang line followed by a binary zip archive, so
            # substituteInPlace refuses it ("Input null bytes"). Patch only line 1
            # with sed, leaving the archive untouched.
            sed -i '1s|^#!.*escript$|#!${runtimeErlang}/bin/escript|' "$out/libexec/foyer"
            grep -q "^#!${runtimeErlang}/bin/escript\$" "$out/libexec/foyer" \
              || { echo "shebang patch did not apply"; exit 1; }

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

            hooks =
              let
                # One hook is a script foyer runs on every workspace. Give it
                # EITHER `text` (an inline body) OR `source` (a path to an
                # existing script file) — exactly one, enforced by an assertion
                # below. `name` fixes the file name (and therefore the run
                # order, which is by name); it defaults to the list index, so
                # unnamed hooks run in the order written.
                hookType = lib.types.submodule {
                  options = {
                    name = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "File-name suffix for this hook (run order is by name). Defaults to the list index.";
                    };
                    text = lib.mkOption {
                      type = lib.types.nullOr lib.types.lines;
                      default = null;
                      description = ''
                        The hook script body, inline. A `#!/usr/bin/env bash`
                        shebang is added if the text has none. Mutually exclusive
                        with `source`.
                      '';
                    };
                    source = lib.mkOption {
                      type = lib.types.nullOr lib.types.path;
                      default = null;
                      description = ''
                        Path to an existing script file to install as the hook,
                        verbatim (no shebang is added). Use it to reference a
                        script you already keep on disk, or one another Nix
                        expression produces (for example `pkgs.writeShellScript`).
                        Mutually exclusive with `text`.
                      '';
                    };
                  };
                };
              in
              {
                create = lib.mkOption {
                  type = lib.types.listOf hookType;
                  default = [ ];
                  example = lib.literalExpression ''[ { text = "direnv allow"; } { source = ./my-hook.sh; } ]'';
                  description = ''
                    User-global hooks run on every `foyer create`, after the
                    project's `.foyer/setup.sh`. Each runs in the new workspace
                    with `JJ_WORKSPACE_ROOT` set. A failing hook is a warning,
                    never fatal.
                  '';
                };

                remove = lib.mkOption {
                  type = lib.types.listOf hookType;
                  default = [ ];
                  example = lib.literalExpression ''[ { text = "my-cleanup"; } { source = ./teardown.sh; } ]'';
                  description = ''
                    User-global hooks run on every `foyer remove`, before the
                    project's `.foyer/teardown.sh` (so a self-deleting teardown
                    never strands them). Each runs in the workspace with
                    `JJ_WORKSPACE_ROOT` set. A failing hook is a warning, never
                    fatal.
                  '';
                };
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

            # Write each configured hook to an executable script under
            # $XDG_CONFIG_HOME/foyer/hooks/<event>/, which is where foyer's
            # Foyer.Hooks looks. The file name is `<NN>-<name>`, where NN is the
            # list index, zero-padded to a width that holds the whole list, so
            # foyer's file-name sort matches the list order for any hook count.
            # foyer runs every executable there in file-name order.
            #
            # A hook is EITHER inline (`text`, shebang added when absent) or a
            # file reference (`source`, installed verbatim). The mutual
            # exclusion is asserted below, so here a set `source` decides the
            # form and `text` is the fallback.
            xdg.configFile = lib.mkMerge (
              lib.concatLists (
                lib.mapAttrsToList (
                  event: hooks:
                  let
                    # Pad wide enough that lexicographic sort equals numeric
                    # order. Without this, "100-x" sorts before "20-x" ("-" is
                    # below "0"), which would reorder a list of 10+ hooks.
                    width = builtins.stringLength (toString (builtins.length hooks * 10));
                  in
                  lib.imap0 (
                    i: hook:
                    let
                      idx = lib.fixedWidthNumber width (i * 10 + 10);
                      fname = "${idx}-${if hook.name != null then hook.name else toString i}";
                      hasShebang = hook.text != null && lib.hasPrefix "#!" hook.text;
                      # A `source` hook is installed verbatim; a `text` hook gets
                      # a bash shebang when it has none.
                      content =
                        if hook.source != null then
                          { source = hook.source; }
                        else
                          { text = if hasShebang then hook.text else "#!/usr/bin/env bash\n${hook.text}"; };
                    in
                    {
                      "foyer/hooks/${event}/${fname}" = content // { executable = true; };
                    }
                  ) hooks
                ) { create = cfg.hooks.create; remove = cfg.hooks.remove; }
              )
            );

            # A hook must set exactly one of `text` / `source`. Neither leaves
            # nothing to install; both is ambiguous. Catch it at build time with
            # a clear message rather than writing a surprising file.
            assertions = lib.concatLists (
              lib.mapAttrsToList (
                event: hooks:
                lib.imap0 (
                  i: hook:
                  let
                    label = if hook.name != null then hook.name else toString i;
                    setCount = (if hook.text != null then 1 else 0) + (if hook.source != null then 1 else 0);
                  in
                  {
                    assertion = setCount == 1;
                    message = "programs.foyer.hooks.${event} hook '${label}' must set exactly one of `text` or `source` (it sets ${toString setCount}).";
                  }
                ) hooks
              ) { create = cfg.hooks.create; remove = cfg.hooks.remove; }
            );
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
