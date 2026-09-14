defmodule Foyer.Hooks do
  @moduledoc """
  User-global hooks: scripts a user runs on every workspace, independent of any
  project.

  Where `.foyer/setup.sh` is committed to a repo and shared by everyone who
  clones it, hooks are the reverse — per-user, not per-project. A user drops
  executable scripts into

      $XDG_CONFIG_HOME/foyer/hooks/create/     (run on every `foyer create`)
      $XDG_CONFIG_HOME/foyer/hooks/remove/     (run on every `foyer remove`)

  and foyer runs every executable there, in file-name order, with cwd set to the
  workspace directory and `JJ_WORKSPACE_ROOT` exported — exactly the environment
  the project script gets. The home-manager module writes these scripts from
  `programs.foyer.hooks.{create,remove}`, so the whole set lives in one Nix
  config.

  Ordering relative to the project script is deliberate and differs by event:

    * create — the project `.foyer/setup.sh` runs first, then the create hooks.
    * remove — the remove hooks run first, then the project `.foyer/teardown.sh`.

  The remove order matters. A teardown script may delete its own workspace
  directory (documented self-removal). Running the remove hooks BEFORE teardown
  guarantees they see a directory that still exists, so a self-deleting teardown
  never strands a hook with a cwd that is gone.

  Like the project script, a failing hook is non-fatal: it is reported, never
  hidden, and the command still succeeds. Discovery and execution both go
  through a `Foyer.Runner`, so the core is exercised in tests without touching
  the real filesystem.
  """

  @doc """
  Resolve foyer's config root, honoring the standard overrides. Precedence:

    1. `$FOYER_CONFIG_HOME` — an explicit override (used by tests, and by a user
       who wants foyer's config somewhere non-standard).
    2. `$XDG_CONFIG_HOME/foyer` — the XDG base directory.
    3. `$HOME/.config/foyer` — the XDG default when `$XDG_CONFIG_HOME` is unset.

  Returns nil only when none of these can be resolved (no HOME and no override),
  in which case there is no place to look for hooks.
  """
  @spec config_root() :: String.t() | nil
  def config_root do
    cond do
      override = env("FOYER_CONFIG_HOME") -> override
      xdg = env("XDG_CONFIG_HOME") -> Path.join(xdg, "foyer")
      home = env("HOME") -> Path.join([home, ".config", "foyer"])
      true -> nil
    end
  end

  @doc """
  The hooks directory for an event, under a config root. `event` is `:create` or
  `:remove`. Returns nil when `config_root` is nil.
  """
  @spec dir(String.t() | nil, :create | :remove) :: String.t() | nil
  def dir(nil, _event), do: nil
  def dir(config_root, event) when event in [:create, :remove] do
    Path.join([config_root, "hooks", Atom.to_string(event)])
  end

  @doc """
  Run the hooks in `hooks_dir` against `workspace_root`.

  Each executable in `hooks_dir` (file-name order) is run as `bash <path>` with
  cwd = `workspace_root` and `JJ_WORKSPACE_ROOT` set to it, mirroring the project
  script contract. Returns a list of `{path, status}` in run order, where status
  is `:ok` or `{:failed, message}`. An empty list means nothing ran — no hooks
  directory, or no executables in it.

  Returns `[]` without running anything when `hooks_dir` or `workspace_root` is
  nil: with no config root there is nowhere to look, and with no workspace
  directory there is nowhere for a hook to run.
  """
  @spec run(module(), String.t() | nil, String.t() | nil) :: [{String.t(), :ok | {:failed, String.t()}}]
  def run(_runner, nil, _workspace_root), do: []
  def run(_runner, _hooks_dir, nil), do: []

  def run(runner, hooks_dir, workspace_root) do
    env = [{"JJ_WORKSPACE_ROOT", workspace_root}]

    runner.list_executables(hooks_dir)
    |> Enum.map(fn script ->
      case runner.run("bash", [script], cd: workspace_root, env: env) do
        {:ok, _} -> {script, :ok}
        {:error, {_code, output}} -> {script, {:failed, String.trim(output)}}
      end
    end)
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
