# foyer

`foyer create <name>` runs `jj workspace add`, then runs the new workspace's
`.foyer/setup.sh` if it has one. Meant to canonicalize standard setup for things so automated tooling and agents can get going without having to encode a skill or some other terrible solution.

If you like jj workspaces and work in neovim, try [open-floorplan.nvim](https://github.com/ducharmemp/open-floorplan.nvim). Foyer support coming soon.

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
[**Run foyer in your browser**](https://trynix.dev/?path=/nix/store/as5lasfkj7z5wbkz4rg7qmpll0x95p6k-foyer-demo&cache=https://foyer.cachix.org%20foyer.cachix.org-1:xsCXcKqEATnlu%2BHrpG9CLZE6vaY0IS0kZLApVU3Q%2Fgk=)

The link opens [trynix.dev](https://trynix.dev), which boots a small Linux VM
in the browser tab — [QEMU compiled to
WebAssembly](https://github.com/ktock/qemu-wasm). At the
shell prompt, run:

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

| option            | effect                                                |
| ----------------- | ----------------------------------------------------- |
| `--to <dir>`      | destination (default: sibling `<repo>-<name>`)        |
| `--rev <revset>`  | parent revision(s) for the new working copy           |
| `--branch <name>` | base on bookmark `<name>@<remote>` (excludes `--rev`) |
| `--remote <r>`    | remote for `--branch` (default: `origin`)             |
| `-m <message>`    | description for the new working-copy commit           |
| `--no-furnish`    | create the workspace, skip `.foyer/setup.sh`          |

Run either directly, or as `jj foyer create <name>` — the home-manager module
installs that alias.

foyer requires `jj` on `PATH`.

## The setup script

If the new workspace contains an executable `.foyer/setup.sh`, foyer runs it
there with `JJ_WORKSPACE_ROOT` pointing at the workspace root. A typical one
activates the environment:

```bash
#!/usr/bin/env bash
# .foyer/setup.sh
direnv allow
```

The script has to be committed.

## The teardown script

`foyer remove <name>` is the reverse of `create`. It runs `jj workspace forget
<name>` first, then, if the directory holds an executable `.foyer/teardown.sh`,
runs it there with `JJ_WORKSPACE_ROOT` set.

Because we forget the workspace first, A teardown script can clean up
freely, including deleting its own directory:

```bash
#!/usr/bin/env bash
# .foyer/teardown.sh
rm -rf "$JJ_WORKSPACE_ROOT"    # self-removal, if you want it
```

foyer itself never deletes files.

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
macOS (Apple Silicon). 

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

Release binaries are built by `scripts/build-release.sh` if needed. It needs
Elixir/Erlang, Zig and xz. The Erlang OTP version must be one Burrito publishes
precompiled ERTS for (the CI workflow pins it); see `scripts/build-release.sh`
and `.github/workflows/release.yml`.

