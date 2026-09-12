# foyer

`foyer create <name>` runs `jj workspace add`, then runs the new workspace's
`.foyer/setup.sh` if it has one. It exists so that creating a workspace and
getting it ready to work in are one command instead of two.

The name follows [open-floorplan.nvim](https://github.com/ducharmemp/open-floorplan.nvim),
where a repo is a floorplan and a workspace is a room. foyer is what you walk
through on the way in.

## Try it in your browser

<!-- The store path below is content-addressed. foyer is built from a
     filtered source (lib/, lib_prod/, mix.exs, mix.lock \u2014 see flake.nix
     foyerSrc), so doc/CI/flake commits do NOT change it. It moves only when
     the code or locked deps change, or on a flake.lock bump (nixpkgs/erlang).
     When it moves: the Cachix workflow prints the current path on every push
     to main ("Report demo store path"); update the ?path= here. Rebuild
     locally with:  nix build .#foyer-demo --print-out-paths
     The key's + and / are percent-encoded (%2B, %2F) because trynix parses
     the query with URLSearchParams, which would otherwise turn + into a
     space and drop the cache. -->
[**Boot foyer in a VM in your tab →**](https://trynix.dev/?path=/nix/store/7xxwfxf87qgwgnrskvlb21l6sc0il9ms-foyer-demo&cache=https://foyer.cachix.org%20foyer.cachix.org-1:xsCXcKqEATnlu%2BHrpG9CLZE6vaY0IS0kZLApVU3Q%2Fgk=)

[trynix.dev](https://trynix.dev) fetches foyer's closure from
[foyer.cachix.org](https://foyer.cachix.org) into an x86_64 Linux VM
([QEMU compiled to WebAssembly](https://github.com/ktock/qemu-wasm)) running in
your browser — nothing runs on a server. When the shell appears, type:

```
foyer-demo
```

That seeds a jj repo with a committed `.foyer/setup.sh`, runs
`foyer create feature-x`, and shows the furnished workspace. `foyer` and `jj`
are already on `PATH`, so you can keep going by hand afterwards.

## Use

```
foyer create <name> [options]
foyer remove <name> [--to <dir>]
```

`create` options:

| option           | effect                                          |
| ---------------- | ----------------------------------------------- |
| `--to <dir>`     | destination (default: sibling `<repo>-<name>`)  |
| `--rev <revset>` | parent revision(s) for the new working copy     |
| `-m <message>`   | description for the new working-copy commit     |
| `--no-furnish`   | create the workspace, skip `.foyer/setup.sh`    |

Run either directly, or as `jj foyer create <name>` — the home-manager module
installs that alias.

foyer requires `jj` on `PATH`: it drives jujutsu, it does not vendor it (the
`jj foyer` alias and any direct use run from an environment that already has
jj).

## The setup script

If the new workspace contains an executable `.foyer/setup.sh`, foyer runs it
there with `JJ_WORKSPACE_ROOT` pointing at the workspace root. A typical one
activates the environment:

```bash
#!/usr/bin/env bash
# .foyer/setup.sh
direnv allow
```

The script has to be committed. `jj workspace add` populates the new workspace
from the parent revision, so a script you have not committed yet won't be there
to run. This is deliberate: the setup that runs matches the revision checked
out, and it changes alongside the code that needs it.

## The teardown script

`foyer remove <name>` is the reverse of `create`. It runs `jj workspace forget
<name>` first, then, if the directory holds an executable `.foyer/teardown.sh`,
runs it there with `JJ_WORKSPACE_ROOT` set — same contract as setup.

The order matters. jj forgets the workspace before teardown runs, so the
directory is already untracked. A teardown script can therefore clean up
freely, including deleting its own directory:

```bash
#!/usr/bin/env bash
# .foyer/teardown.sh
rm -rf "$JJ_WORKSPACE_ROOT"    # self-removal, if you want it
```

foyer itself never deletes files. Without a teardown script, `remove` just
forgets the workspace and leaves the directory on disk (matching `jj workspace
forget`). Whether the directory survives is the script's decision.

## Install

### Home-manager (Nix)

```nix
{
  imports = [ inputs.foyer.homeModules.foyer ];
  programs.foyer.enable = true;   # installs the CLI + `jj foyer` alias
}
```

`programs.foyer.aliasName` renames the jj alias (default `"foyer"`).
`programs.foyer.installJjAlias = false` installs the CLI without touching your
jj config.

### Download a binary

Each release attaches self-contained binaries for Linux (x86_64, aarch64) and
macOS (Apple Silicon). They bundle the Erlang runtime, so nothing else needs to
be installed.

```sh
curl -LO https://github.com/ducharmemp/foyer/releases/latest/download/foyer-linux_amd64
chmod +x foyer-linux_amd64
./foyer-linux_amd64 help
```

Verify against the release's `SHA256SUMS` with `sha256sum -c`.

### Nix (without home-manager)

```sh
nix profile install github:ducharmemp/foyer   # escript; needs Erlang at runtime
```

## Develop

```sh
nix develop        # elixir, erlang, elixir-ls, jj, zig, xz
mix test
nix build .#foyer  # the escript
nix flake check    # tests in the sandbox
```

Release binaries are built by `scripts/build-release.sh`, which the GitHub
Actions release workflow only orchestrates — you can run it locally. It needs
Elixir/Erlang, Zig and xz. The Erlang OTP version must be one Burrito publishes
precompiled ERTS for (the CI workflow pins it); see `scripts/build-release.sh`
and `.github/workflows/release.yml`.

