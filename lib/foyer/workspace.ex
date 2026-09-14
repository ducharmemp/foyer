defmodule Foyer.Workspace do
  @moduledoc """
  The core of foyer: create a jj workspace, then furnish it.

  Pure decision logic where it can be — building the `jj workspace add`
  argument list, resolving the destination, choosing the furnish step — with
  every side effect pushed through a `Foyer.Runner`. That split is what makes
  the module testable: a fake runner records the commands foyer would run and
  answers filesystem questions, so a test asserts on behavior without a jj repo.
  """

  @type opts :: %{
          required(:name) => String.t(),
          optional(:destination) => String.t() | nil,
          optional(:revision) => String.t() | nil,
          optional(:message) => String.t() | nil,
          optional(:repo_root) => String.t() | nil,
          optional(:furnish) => boolean(),
          optional(:hooks_dir) => String.t() | nil
        }

  alias Foyer.Hooks

  @setup_rel ".foyer/setup.sh"
  @teardown_rel ".foyer/teardown.sh"

  @doc """
  Create a workspace and furnish it.

  `runner` is a module implementing `Foyer.Runner`. Returns
  `{:ok, %{destination: dest, furnish: status, hooks: results}}` or
  `{:error, reason}`. The furnish status is `:ok`, `:none`, `:skipped`, or
  `{:failed, message}`; `hooks` is the list of `{path, status}` from the global
  create hooks (see `Foyer.Hooks`), empty when none ran; reason is a
  human-readable string.

  The global create hooks run AFTER the project `.foyer/setup.sh`, so the
  project furnishes the room first and the user's hooks act on the finished
  workspace.
  """
  @spec create(module(), opts()) :: {:ok, map()} | {:error, String.t()}
  def create(runner, %{name: name} = opts) when is_binary(name) and name != "" do
    destination = resolve_destination(opts)

    cond do
      destination == nil ->
        {:error, "could not determine a destination for workspace '#{name}'"}

      runner.dir?(destination) ->
        {:error, "destination already exists: #{destination}"}

      true ->
        with :ok <- add_workspace(runner, name, destination, opts) do
          furnish = furnish(runner, destination, opts)
          hooks = Hooks.run(runner, Map.get(opts, :hooks_dir), destination)
          {:ok, %{destination: destination, furnish: furnish, hooks: hooks}}
        end
    end
  end

  def create(_runner, _opts), do: {:error, "workspace name is required"}

  @doc """
  Remove a workspace: `jj workspace forget`, then run its teardown.

  The order is deliberate. jj forgets the workspace first, so by the time
  `.foyer/teardown.sh` runs the directory is no longer a tracked workspace. A
  teardown script can therefore clean up freely — including deleting its own
  directory (`rm -rf "$JJ_WORKSPACE_ROOT"`) for self-removal — without leaving
  jj tracking a path that is gone. foyer itself never deletes files; whether the
  directory survives is the script's decision.

  The global remove hooks run BEFORE the project `.foyer/teardown.sh`. A
  teardown script may delete its own directory (self-removal); running the hooks
  first guarantees they see a directory that still exists.

  Returns `{:ok, %{name: name, directory: dir, hooks: results, teardown: status}}`
  or `{:error, reason}`. teardown status is `:ok`, `:none`, `:skipped`, or
  `{:failed, message}`; `hooks` is the list of `{path, status}` from the global
  remove hooks (see `Foyer.Hooks`), empty when none ran.
  """
  @spec remove(module(), opts()) :: {:ok, map()} | {:error, String.t()}
  def remove(runner, %{name: name} = opts) when is_binary(name) and name != "" do
    directory = resolve_destination(opts)

    with :ok <- forget_workspace(runner, name) do
      hooks = Hooks.run(runner, Map.get(opts, :hooks_dir), directory)
      teardown = teardown(runner, directory, opts)
      {:ok, %{name: name, directory: directory, hooks: hooks, teardown: teardown}}
    end
  end

  def remove(_runner, _opts), do: {:error, "workspace name is required"}

  @doc """
  The argument list foyer passes to `jj workspace add`. Public so tests can
  assert on it directly. Order is stable: flags first, destination last.
  """
  @spec add_args(String.t(), String.t(), opts()) :: [String.t()]
  def add_args(name, destination, opts) do
    ["workspace", "add", "--name", name]
    |> append_opt("--revision", Map.get(opts, :revision))
    |> append_opt("--message", Map.get(opts, :message))
    |> Kernel.++([destination])
  end

  @doc """
  Resolve the destination directory. An explicit `:destination` wins. Otherwise
  place the workspace as a sibling of the repo root named `<repo>-<name>`,
  matching open-floorplan's default layout. Returns nil when neither is known.
  """
  @spec resolve_destination(opts()) :: String.t() | nil
  def resolve_destination(%{destination: dest}) when is_binary(dest) and dest != "" do
    Path.expand(dest)
  end

  def resolve_destination(%{name: name, repo_root: root})
      when is_binary(root) and root != "" do
    base = Path.basename(root)
    parent = Path.dirname(root)
    Path.join(parent, "#{base}-#{name}")
  end

  def resolve_destination(_), do: nil

  # Run `jj workspace add`, mapping a non-zero exit to a readable error.
  defp add_workspace(runner, name, destination, opts) do
    args = add_args(name, destination, opts)

    case runner.run("jj", args, []) do
      {:ok, _output} -> :ok
      {:error, {_code, output}} -> {:error, "jj workspace add failed: #{String.trim(output)}"}
    end
  end

  # Run `jj workspace forget <name>`, mapping a non-zero exit to a readable
  # error. Runs before teardown so the directory is untracked when it runs.
  defp forget_workspace(runner, name) do
    case runner.run("jj", ["workspace", "forget", name], []) do
      {:ok, _output} -> :ok
      {:error, {_code, output}} -> {:error, "jj workspace forget failed: #{String.trim(output)}"}
    end
  end

  # Furnish the new room. If the project committed a `.foyer/setup.sh`, run it
  # with cwd = the new workspace and JJ_WORKSPACE_ROOT exported, exactly as jj
  # sets it for a `util exec` alias. Returns one of:
  #
  #   :skipped        — furnishing was disabled with furnish: false
  #   :none           — no setup script in the workspace, nothing to run
  #   :ok             — the setup script ran and succeeded
  #   {:failed, msg}  — the setup script ran and failed (reported, never hidden)
  #
  # A missing script is not a failure; furnishing is optional. A script that
  # runs and fails IS reported — the workspace exists, but setup did not finish.
  defp furnish(_runner, _destination, %{furnish: false}), do: :skipped

  defp furnish(runner, destination, _opts) do
    script = Path.join(destination, @setup_rel)

    if runner.file?(script) do
      env = [{"JJ_WORKSPACE_ROOT", destination}]

      case runner.run("bash", [script], cd: destination, env: env) do
        {:ok, _} -> :ok
        {:error, {_code, output}} -> {:failed, String.trim(output)}
      end
    else
      :none
    end
  end

  # Tear down a removed workspace. jj has already forgotten it, so the directory
  # is untracked when this runs. If the (now-untracked) directory still holds an
  # executable `.foyer/teardown.sh`, run it with cwd = that directory and
  # JJ_WORKSPACE_ROOT set to it, mirroring the furnish contract. Returns:
  #
  #   :none           — no directory could be resolved, or no teardown script
  #   :ok             — the teardown script ran and succeeded
  #   {:failed, msg}  — the teardown script ran and failed (reported)
  #
  # A teardown script may delete its own directory (self-removal); foyer never
  # deletes files itself.
  defp teardown(_runner, nil, _opts), do: :none

  defp teardown(runner, directory, _opts) do
    script = Path.join(directory, @teardown_rel)

    if runner.file?(script) do
      env = [{"JJ_WORKSPACE_ROOT", directory}]

      case runner.run("bash", [script], cd: directory, env: env) do
        {:ok, _} -> :ok
        {:error, {_code, output}} -> {:failed, String.trim(output)}
      end
    else
      :none
    end
  end

  defp append_opt(args, _flag, nil), do: args
  defp append_opt(args, _flag, ""), do: args
  defp append_opt(args, flag, value), do: args ++ [flag, value]
end
