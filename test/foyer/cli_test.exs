defmodule Foyer.CLITest do
  use ExUnit.Case, async: false

  alias Foyer.CLI
  alias Foyer.FakeRunner

  setup do
    prev = System.get_env("JJ_WORKSPACE_ROOT")
    System.delete_env("JJ_WORKSPACE_ROOT")

    on_exit(fn ->
      FakeRunner.stop()
      if prev, do: System.put_env("JJ_WORKSPACE_ROOT", prev), else: System.delete_env("JJ_WORKSPACE_ROOT")
    end)

    :ok
  end

  describe "help and version" do
    test "help returns usage" do
      assert {:ok, out} = CLI.run(["help"], FakeRunner)
      assert out =~ "foyer — furnish a jj workspace"
      assert out =~ "foyer create <name>"
    end

    test "--help and -h alias to help" do
      FakeRunner.start()
      assert {:ok, out1} = CLI.run(["--help"], FakeRunner)
      assert {:ok, out2} = CLI.run(["-h"], FakeRunner)
      assert out1 =~ "Usage:"
      assert out2 =~ "Usage:"
    end

    test "version prints the version" do
      assert {:ok, "foyer 0.1.0"} = CLI.run(["version"], FakeRunner)
    end
  end

  describe "dispatch errors" do
    test "no args is an error with usage" do
      assert {:error, out} = CLI.run([], FakeRunner)
      assert out =~ "Usage:"
    end

    test "unknown command is reported" do
      assert {:error, out} = CLI.run(["frobnicate"], FakeRunner)
      assert out =~ "unknown command: frobnicate"
    end
  end

  describe "create parsing" do
    test "missing name is an error" do
      FakeRunner.start()
      assert {:error, out} = CLI.run(["create"], FakeRunner)
      assert out =~ "requires a workspace name"
    end

    test "more than one positional is an error" do
      FakeRunner.start()
      assert {:error, out} = CLI.run(["create", "a", "b"], FakeRunner)
      assert out =~ "takes one name"
    end

    test "unknown option is reported" do
      FakeRunner.start()
      assert {:error, out} = CLI.run(["create", "feat", "--bogus", "x"], FakeRunner)
      assert out =~ "unknown option"
    end
  end

  describe "create repo-root resolution" do
    test "uses JJ_WORKSPACE_ROOT when set, without asking jj for the root" do
      System.put_env("JJ_WORKSPACE_ROOT", "/env/repo")
      FakeRunner.start()

      assert {:ok, out} = CLI.run(["create", "feat"], FakeRunner)
      assert out =~ "/env/repo-feat"

      # jj was only called for `workspace add`, never for `workspace root`
      refute Enum.any?(FakeRunner.calls(), fn {c, a, _} ->
               c == "jj" and a == ["workspace", "root"]
             end)
    end

    test "falls back to `jj workspace root` when the env var is unset" do
      FakeRunner.start(
        results: %{{"jj", ["workspace", "root"]} => {:ok, "/jj/repo\n"}}
      )

      assert {:ok, out} = CLI.run(["create", "feat"], FakeRunner)
      assert out =~ "/jj/repo-feat"

      assert Enum.any?(FakeRunner.calls(), fn {c, a, _} ->
               c == "jj" and a == ["workspace", "root"]
             end)
    end
  end

  describe "create output rendering" do
    test "reports the furnish result to the user" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      script = "/repo-feat/.foyer/setup.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:ok, ""}}
      )

      assert {:ok, out} = CLI.run(["create", "feat"], FakeRunner)
      assert out =~ "created workspace 'feat' at /repo-feat"
      assert out =~ "ran .foyer/setup.sh"
    end

    test "surfaces a failed setup script as a warning" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      script = "/repo-feat/.foyer/setup.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:error, {2, "kaboom"}}}
      )

      assert {:ok, out} = CLI.run(["create", "feat"], FakeRunner)
      assert out =~ "WARNING"
      assert out =~ "kaboom"
    end

    test "passes --rev, -m and --to through to jj add" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start()

      assert {:ok, _} =
               CLI.run(
                 ["create", "feat", "--to", "/custom", "--rev", "@-", "-m", "hi"],
                 FakeRunner
               )

      add_call =
        Enum.find(FakeRunner.calls(), fn {c, a, _} ->
          c == "jj" and match?(["workspace", "add" | _], a)
        end)

      assert {"jj", args, _} = add_call
      assert args == ["workspace", "add", "--name", "feat", "--revision", "@-", "--message", "hi", "/custom"]
    end

    test "--no-furnish skips the setup script" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start(files: ["/repo-feat/.foyer/setup.sh"])

      assert {:ok, out} = CLI.run(["create", "feat", "--no-furnish"], FakeRunner)
      assert out =~ "skipped (--no-furnish)"
    end
  end
end
