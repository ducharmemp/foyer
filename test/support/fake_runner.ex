defmodule Foyer.FakeRunner do
  @moduledoc false
  # A `Foyer.Runner` for tests. It records every command through an Agent and
  # answers filesystem questions and command results from a configured script.
  #
  # Configure per test with `start/1`:
  #
  #   Foyer.FakeRunner.start(
  #     dirs: ["/repo-existing"],           # paths dir?/1 returns true for
  #     files: ["/repo-x/.foyer/setup.sh"], # paths file?/1 returns true for
  #     executables: %{                      # dir => list_executables/1 result
  #       "/cfg/hooks/create" => ["/cfg/hooks/create/10-a", "/cfg/hooks/create/20-b"]
  #     },
  #     results: %{                          # {command, args} => run/3 result
  #       {"jj", ["workspace", "root"]} => {:ok, "/repo\n"},
  #       {"bash", ["/repo-x/.foyer/setup.sh"]} => {:error, {1, "boom"}}
  #     },
  #     default: {:ok, ""}                   # result for unlisted commands
  #   )
  #
  # `calls/0` returns the recorded commands, newest last, each as
  # `{command, args, opts}`.

  @behaviour Foyer.Runner

  @agent __MODULE__

  def start(config \\ []) do
    stop()

    state = %{
      dirs: MapSet.new(config[:dirs] || []),
      files: MapSet.new(config[:files] || []),
      executables: config[:executables] || %{},
      results: config[:results] || %{},
      default: Keyword.get(config, :default, {:ok, ""}),
      calls: []
    }

    {:ok, _pid} = Agent.start_link(fn -> state end, name: @agent)
    :ok
  end

  def stop do
    case Process.whereis(@agent) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: safe_stop(pid), else: :ok
    end
  end

  defp safe_stop(pid) do
    Agent.stop(pid)
  catch
    :exit, _ -> :ok
  end

  def calls do
    Agent.get(@agent, fn s -> Enum.reverse(s.calls) end)
  end

  @impl true
  def run(command, args, opts) do
    Agent.get_and_update(@agent, fn s ->
      state = %{s | calls: [{command, args, opts} | s.calls]}
      result = Map.get(s.results, {command, args}, s.default)
      {result, state}
    end)
  end

  @impl true
  def dir?(path) do
    Agent.get(@agent, fn s -> MapSet.member?(s.dirs, path) end)
  end

  @impl true
  def file?(path) do
    Agent.get(@agent, fn s -> MapSet.member?(s.files, path) end)
  end

  @impl true
  def list_executables(dir) do
    Agent.get(@agent, fn s -> Map.get(s.executables, dir, []) end)
  end
end
