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
      assert {:ok, "foyer 0.1.1"} = CLI.run(["version"], FakeRunner)
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

    # The recorded `jj workspace add` call, or nil if it never ran.
    defp add_call do
      Enum.find(FakeRunner.calls(), fn {c, a, _} ->
        c == "jj" and match?(["workspace", "add" | _], a)
      end)
    end

    test "--no-furnish skips the setup script" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start(files: ["/repo-feat/.foyer/setup.sh"])

      assert {:ok, out} = CLI.run(["create", "feat", "--no-furnish"], FakeRunner)
      assert out =~ "skipped (--no-furnish)"
    end
  end

  describe "create --branch" do
    test "bases the working copy on <branch>@origin by default" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start()

      assert {:ok, _} = CLI.run(["create", "feat", "--branch", "topic"], FakeRunner)

      assert {"jj", args, _} = add_call()
      assert args == ["workspace", "add", "--name", "feat", "--revision", "topic@origin", "/repo-feat"]
    end

    test "--remote selects the remote for the bookmark" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start()

      assert {:ok, _} =
               CLI.run(["create", "feat", "--branch", "topic", "--remote", "upstream"], FakeRunner)

      assert {"jj", args, _} = add_call()
      assert args == ["workspace", "add", "--name", "feat", "--revision", "topic@upstream", "/repo-feat"]
    end

    test "--branch and --rev are mutually exclusive" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start()

      assert {:error, out} =
               CLI.run(["create", "feat", "--branch", "topic", "--rev", "@-"], FakeRunner)

      assert out =~ "--branch and --rev are mutually exclusive"
      # nothing ran: the error is reached before jj is called
      assert FakeRunner.calls() == []
    end

    test "--remote without --branch is rejected" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start()

      assert {:error, out} =
               CLI.run(["create", "feat", "--remote", "upstream"], FakeRunner)

      assert out =~ "--remote requires --branch"
      assert FakeRunner.calls() == []
    end
  end

  describe "remove parsing" do
    test "missing name is an error" do
      FakeRunner.start()
      assert {:error, out} = CLI.run(["remove"], FakeRunner)
      assert out =~ "requires a workspace name"
    end

    test "more than one positional is an error" do
      FakeRunner.start()
      assert {:error, out} = CLI.run(["remove", "a", "b"], FakeRunner)
      assert out =~ "takes one name"
    end

    test "unknown option is reported" do
      FakeRunner.start()
      assert {:error, out} = CLI.run(["remove", "feat", "--rev", "@"], FakeRunner)
      assert out =~ "unknown option"
    end
  end

  describe "remove output rendering" do
    test "reports the teardown result and forgets via the resolved directory" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      script = "/repo-feat/.foyer/teardown.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:ok, ""}}
      )

      assert {:ok, out} = CLI.run(["remove", "feat"], FakeRunner)
      assert out =~ "forgot workspace 'feat'"
      assert out =~ "ran .foyer/teardown.sh"

      # forget precedes teardown
      assert [{"jj", ["workspace", "forget", "feat"], _}, {"bash", [^script], _}] =
               FakeRunner.calls()
    end

    test "reports nothing-to-do when no teardown script exists" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      FakeRunner.start()

      assert {:ok, out} = CLI.run(["remove", "feat"], FakeRunner)
      assert out =~ "forgot workspace 'feat'"
      assert out =~ "nothing to do (no .foyer/teardown.sh)"
    end

    test "surfaces a failed teardown script as a warning" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      script = "/repo-feat/.foyer/teardown.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:error, {3, "cleanup exploded"}}}
      )

      assert {:ok, out} = CLI.run(["remove", "feat"], FakeRunner)
      assert out =~ "WARNING"
      assert out =~ "cleanup exploded"
    end

    test "honors --to for the directory the teardown runs in" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      script = "/custom/.foyer/teardown.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:ok, ""}}
      )

      assert {:ok, _} = CLI.run(["remove", "feat", "--to", "/custom"], FakeRunner)

      assert {"bash", [^script], opts} = List.last(FakeRunner.calls())
      assert opts[:cd] == "/custom"
      assert opts[:env] == [{"JJ_WORKSPACE_ROOT", "/custom"}]
    end
  end
end
