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
          optional(:furnish) => boolean()
        }

  @setup_rel ".foyer/setup.sh"

  @doc """
  Create a workspace and furnish it.

  `runner` is a module implementing `Foyer.Runner`. Returns
  `{:ok, %{destination: dest, furnish: status}}` or `{:error, reason}`. The
  furnish status is `:ok`, `:none`, `:skipped`, or `{:failed, message}`, and
  reason is a human-readable string.
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
          {:ok, %{destination: destination, furnish: furnish}}
        end
    end
  end

  def create(_runner, _opts), do: {:error, "workspace name is required"}

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

  defp append_opt(args, _flag, nil), do: args
  defp append_opt(args, _flag, ""), do: args
  defp append_opt(args, flag, value), do: args ++ [flag, value]
end
