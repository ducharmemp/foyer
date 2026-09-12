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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: [{key, value} | opts]
end
