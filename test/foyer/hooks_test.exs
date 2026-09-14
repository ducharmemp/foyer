defmodule Foyer.HooksTest do
  use ExUnit.Case, async: false

  alias Foyer.FakeRunner
  alias Foyer.Hooks

  setup do
    saved = %{
      "FOYER_CONFIG_HOME" => System.get_env("FOYER_CONFIG_HOME"),
      "XDG_CONFIG_HOME" => System.get_env("XDG_CONFIG_HOME"),
      "HOME" => System.get_env("HOME")
    }

    for {k, _} <- saved, do: System.delete_env(k)

    on_exit(fn ->
      FakeRunner.stop()

      for {k, v} <- saved do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
    end)

    :ok
  end

  describe "config_root/0 precedence" do
    test "FOYER_CONFIG_HOME wins over everything" do
      System.put_env("FOYER_CONFIG_HOME", "/override")
      System.put_env("XDG_CONFIG_HOME", "/xdg")
      System.put_env("HOME", "/home/me")
      assert Hooks.config_root() == "/override"
    end

    test "falls back to XDG_CONFIG_HOME/foyer" do
      System.put_env("XDG_CONFIG_HOME", "/xdg")
      System.put_env("HOME", "/home/me")
      assert Hooks.config_root() == "/xdg/foyer"
    end

    test "falls back to HOME/.config/foyer when XDG is unset" do
      System.put_env("HOME", "/home/me")
      assert Hooks.config_root() == "/home/me/.config/foyer"
    end

    test "nil when nothing is resolvable" do
      assert Hooks.config_root() == nil
    end

    test "empty env values are treated as unset" do
      System.put_env("FOYER_CONFIG_HOME", "")
      System.put_env("XDG_CONFIG_HOME", "")
      System.put_env("HOME", "/home/me")
      assert Hooks.config_root() == "/home/me/.config/foyer"
    end
  end

  describe "dir/2" do
    test "builds hooks/<event> under the config root" do
      assert Hooks.dir("/cfg", :create) == "/cfg/hooks/create"
      assert Hooks.dir("/cfg", :remove) == "/cfg/hooks/remove"
    end

    test "nil config root yields nil" do
      assert Hooks.dir(nil, :create) == nil
    end
  end

  describe "run/3 discovery and execution" do
    test "runs each executable in listed order with cwd and JJ_WORKSPACE_ROOT set" do
      dir = "/cfg/hooks/create"
      a = "#{dir}/10-a"
      b = "#{dir}/20-b"

      FakeRunner.start(
        executables: %{dir => [a, b]},
        results: %{{"bash", [a]} => {:ok, ""}, {"bash", [b]} => {:ok, ""}}
      )

      assert Hooks.run(FakeRunner, dir, "/ws") == [{a, :ok}, {b, :ok}]

      assert [{"bash", [^a], opts_a}, {"bash", [^b], opts_b}] = FakeRunner.calls()
      assert opts_a[:cd] == "/ws"
      assert opts_a[:env] == [{"JJ_WORKSPACE_ROOT", "/ws"}]
      assert opts_b[:cd] == "/ws"
      assert opts_b[:env] == [{"JJ_WORKSPACE_ROOT", "/ws"}]
    end

    test "a failing hook is reported as {:failed, msg}, later hooks still run" do
      dir = "/cfg/hooks/remove"
      a = "#{dir}/10-a"
      b = "#{dir}/20-b"

      FakeRunner.start(
        executables: %{dir => [a, b]},
        results: %{{"bash", [a]} => {:error, {1, "boom\n"}}, {"bash", [b]} => {:ok, ""}}
      )

      assert Hooks.run(FakeRunner, dir, "/ws") == [{a, {:failed, "boom"}}, {b, :ok}]
    end

    test "empty when the directory holds no executables" do
      FakeRunner.start(executables: %{"/cfg/hooks/create" => []})
      assert Hooks.run(FakeRunner, "/cfg/hooks/create", "/ws") == []
      assert FakeRunner.calls() == []
    end

    test "empty and runs nothing when the hooks dir is nil" do
      FakeRunner.start()
      assert Hooks.run(FakeRunner, nil, "/ws") == []
      assert FakeRunner.calls() == []
    end

    test "empty and runs nothing when the workspace root is nil" do
      FakeRunner.start(executables: %{"/cfg/hooks/remove" => ["/cfg/hooks/remove/10-a"]})
      assert Hooks.run(FakeRunner, "/cfg/hooks/remove", nil) == []
      assert FakeRunner.calls() == []
    end
  end
end
