# foyer

`foyer create <name>` runs `jj workspace add`, then runs the new workspace's
`.foyer/setup.sh` if it has one. It exists so that creating a workspace and
getting it ready to work in are one command instead of two.

The name follows [open-floorplan.nvim](https://github.com/ducharmemp/open-floorplan.nvim),
where a repo is a floorplan and a workspace is a room. foyer is what you walk
through on the way in.

## Use

```
foyer create <name> [options]
```

| option           | effect                                          |
| ---------------- | ----------------------------------------------- |
| `--to <dir>`     | destination (default: sibling `<repo>-<name>`)  |
| `--rev <revset>` | parent revision(s) for the new working copy     |
| `-m <message>`   | description for the new working-copy commit     |
| `--no-furnish`   | create the workspace, skip `.foyer/setup.sh`    |

Run it directly, or as `jj foyer create <name>` — the home-manager module
installs that alias.

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

## Install (home-manager)

```nix
{
  imports = [ inputs.foyer.homeModules.foyer ];
  programs.foyer.enable = true;   # installs the CLI + `jj foyer` alias
}
```

`programs.foyer.aliasName` renames the jj alias (default `"foyer"`).
`programs.foyer.installJjAlias = false` installs the CLI without touching your
jj config.

## Develop

```sh
nix develop        # elixir, erlang, elixir-ls, jj
mix test
nix build .#foyer  # the escript
nix flake check    # tests in the sandbox
```
