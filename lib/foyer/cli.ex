defmodule Foyer.CLI do
  @moduledoc """
  Command-line entry point (the escript `main_module`).

  Usage:

      foyer create <name> [--to <dir>] [--rev <revset>] [-m <message>] [--no-furnish]
      foyer help
      foyer version

  Invoked either directly (`foyer create feature-x`) or through the jj alias
  `jj foyer create feature-x`, which runs `jj util exec -- foyer …` with
  JJ_WORKSPACE_ROOT set to the current workspace. foyer reads that variable to
  locate the repo; outside the alias it falls back to `jj workspace root`.
  """

  alias Foyer.Workspace

  @runner Foyer.Runner.System

  @doc "Escript entry point."
  @spec main([String.t()]) :: no_return()
  def main(argv), do: argv |> run(@runner) |> halt()

  @doc """
  Dispatch on argv with an explicit runner. Returns `{:ok, message}` or
  `{:error, message}` so tests drive the whole CLI without exiting the VM.
  """
  @spec run([String.t()], module()) :: {:ok, String.t()} | {:error, String.t()}
  def run(argv, runner)

  def run(["create" | rest], runner), do: create(rest, runner)
  def run(["help" | _], _runner), do: {:ok, usage()}
  def run(["--help" | _], _runner), do: {:ok, usage()}
  def run(["-h" | _], _runner), do: {:ok, usage()}
  def run(["version" | _], _runner), do: {:ok, "foyer #{version()}"}
  def run(["--version" | _], _runner), do: {:ok, "foyer #{version()}"}
  def run([], _runner), do: {:error, usage()}
  def run([other | _], _runner), do: {:error, "unknown command: #{other}\n\n#{usage()}"}

  defp create(args, runner) do
    {parsed, positional, invalid} =
      OptionParser.parse(args,
        strict: [to: :string, rev: :string, message: :string, furnish: :boolean],
        aliases: [m: :message]
      )

    cond do
      invalid != [] ->
        {:error, "unknown option: #{format_invalid(invalid)}\n\n#{usage()}"}

      positional == [] ->
        {:error, "create requires a workspace name\n\n#{usage()}"}

      length(positional) > 1 ->
        {:error, "create takes one name, got: #{Enum.join(positional, " ")}"}

      true ->
        [name] = positional
        do_create(runner, name, parsed)
    end
  end

  defp do_create(runner, name, parsed) do
    opts = %{
      name: name,
      destination: parsed[:to],
      revision: parsed[:rev],
      message: parsed[:message],
      furnish: Keyword.get(parsed, :furnish, true),
      repo_root: repo_root(runner)
    }

    case Workspace.create(runner, opts) do
      {:ok, result} -> {:ok, render_created(name, result)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The repo root: prefer JJ_WORKSPACE_ROOT (set by the `jj util exec` alias),
  # else ask jj. nil when neither is available — Workspace.create then requires
  # an explicit --to.
  defp repo_root(runner) do
    case System.get_env("JJ_WORKSPACE_ROOT") do
      root when is_binary(root) and root != "" ->
        root

      _ ->
        case runner.run("jj", ["workspace", "root"], []) do
          {:ok, out} -> String.trim(out)
          {:error, _} -> nil
        end
    end
  end

  defp render_created(name, %{destination: dest, furnish: furnish}) do
    base = "created workspace '#{name}' at #{dest}"

    case furnish do
      :ok -> base <> "\nfurnished: ran .foyer/setup.sh"
      :none -> base <> "\nfurnished: nothing to do (no .foyer/setup.sh)"
      :skipped -> base <> "\nfurnished: skipped (--no-furnish)"
      {:failed, msg} -> base <> "\nWARNING: .foyer/setup.sh failed:\n#{indent(msg)}"
    end
  end

  defp format_invalid(invalid) do
    invalid |> Enum.map(fn {opt, _} -> opt end) |> Enum.join(", ")
  end

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end

  defp version, do: "0.1.0"

  defp usage do
    """
    foyer — furnish a jj workspace on arrival

    Usage:
      foyer create <name> [options]   create a workspace and run its setup
      foyer help                      show this help
      foyer version                   print the version

    create options:
      --to <dir>        explicit destination (default: sibling <repo>-<name>)
      --rev <revset>    parent revision(s) for the new working copy
      -m, --message     description for the new working-copy commit
      --no-furnish      create the workspace but skip .foyer/setup.sh

    A project furnishes its rooms by committing an executable .foyer/setup.sh.
    foyer runs it in the new workspace with JJ_WORKSPACE_ROOT set.
    """
  end

  defp halt({:ok, message}) do
    IO.puts(message)
    System.halt(0)
  end

  defp halt({:error, message}) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
