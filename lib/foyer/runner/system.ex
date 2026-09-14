defmodule Foyer.Runner.System do
  @moduledoc """
  The production runner: shells out with `System.cmd/3` and checks the real
  filesystem. `opts` accepts `:cd` (working directory) and `:env` (a list of
  `{"NAME", "value"}` pairs). stderr is folded into stdout so a failure carries
  its message in one string.
  """

  @behaviour Foyer.Runner

  @impl true
  def run(command, args, opts \\ []) do
    cmd_opts =
      [stderr_to_stdout: true]
      |> maybe_put(:cd, opts[:cd])
      |> maybe_put(:env, opts[:env])

    case System.cmd(command, args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  rescue
    e in ErlangError ->
      # command not found etc. surfaces as an :enoent ErlangError from :erlang.
      {:error, {-1, "could not execute #{command}: #{Exception.message(e)}"}}
  end

  @impl true
  def dir?(path), do: File.dir?(path)

  @impl true
  def file?(path), do: File.regular?(path)

  @impl true
  def list_executables(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&executable?/1)

      # A missing hooks directory is the common case, not an error: the user
      # simply configured no hooks. Any other error (permissions, etc.) also
      # yields "nothing to run" rather than crashing a workspace operation.
      {:error, _reason} ->
        []
    end
  end

  # True for a regular file with any execute bit set. Symlinks are followed
  # (File.stat/1 default), so a symlink to an executable script counts.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]
end
