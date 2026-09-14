defmodule Foyer.Runner.SystemTest do
  use ExUnit.Case, async: true

  alias Foyer.Runner.System, as: Runner

  describe "list_executables/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "foyer-hooks-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns only executable regular files, as absolute paths sorted by name", %{dir: dir} do
      exec_b = write(dir, "20-b", 0o755)
      exec_a = write(dir, "10-a", 0o755)
      _plain = write(dir, "15-plain", 0o644)

      assert Runner.list_executables(dir) == [exec_a, exec_b]
    end

    test "excludes subdirectories even when they are traversable", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "sub"))
      exec = write(dir, "10-a", 0o755)

      assert Runner.list_executables(dir) == [exec]
    end

    test "a missing directory yields an empty list, not an error", %{dir: dir} do
      assert Runner.list_executables(Path.join(dir, "does-not-exist")) == []
    end

    test "an empty directory yields an empty list", %{dir: dir} do
      assert Runner.list_executables(dir) == []
    end

    defp write(dir, name, mode) do
      path = Path.join(dir, name)
      File.write!(path, "#!/usr/bin/env bash\n")
      File.chmod!(path, mode)
      path
    end
  end
end
