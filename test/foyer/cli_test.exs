defmodule Foyer.CLITest do
  use ExUnit.Case, async: false

  alias Foyer.CLI
  alias Foyer.FakeRunner

  setup do
    saved =
      Map.new(["JJ_WORKSPACE_ROOT", "FOYER_CONFIG_HOME", "XDG_CONFIG_HOME"], fn k ->
        {k, System.get_env(k)}
      end)

    # Isolate every test from the environment's real config: no hooks unless a
    # test opts in with FOYER_CONFIG_HOME. XDG_CONFIG_HOME is cleared so it can
    # never point config_root/0 at the developer's real hooks.
    System.delete_env("JJ_WORKSPACE_ROOT")
    System.delete_env("FOYER_CONFIG_HOME")
    System.delete_env("XDG_CONFIG_HOME")

    on_exit(fn ->
      FakeRunner.stop()

      for {k, v} <- saved do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
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
      assert {:ok, "foyer 0.2.0"} = CLI.run(["version"], FakeRunner)
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

  describe "create global hooks rendering" do
    test "reports a successful create hook by basename" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      System.put_env("FOYER_CONFIG_HOME", "/cfg")
      hook = "/cfg/hooks/create/10-direnv"

      FakeRunner.start(
        executables: %{"/cfg/hooks/create" => [hook]},
        results: %{{"bash", [hook]} => {:ok, ""}}
      )

      assert {:ok, out} = CLI.run(["create", "feat"], FakeRunner)
      assert out =~ "hook: ran 10-direnv"

      # the hook ran in the new workspace directory
      assert {"bash", [^hook], opts} = List.last(FakeRunner.calls())
      assert opts[:cd] == "/repo-feat"
      assert opts[:env] == [{"JJ_WORKSPACE_ROOT", "/repo-feat"}]
    end

    test "surfaces a failed create hook as a non-fatal warning" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      System.put_env("FOYER_CONFIG_HOME", "/cfg")
      hook = "/cfg/hooks/create/10-direnv"

      FakeRunner.start(
        executables: %{"/cfg/hooks/create" => [hook]},
        results: %{{"bash", [hook]} => {:error, {1, "kaboom"}}}
      )

      assert {:ok, out} = CLI.run(["create", "feat"], FakeRunner)
      assert out =~ "WARNING: hook 10-direnv failed"
      assert out =~ "kaboom"
    end
  end

  describe "remove global hooks rendering" do
    test "reports a successful remove hook, run before teardown" do
      System.put_env("JJ_WORKSPACE_ROOT", "/repo")
      System.put_env("FOYER_CONFIG_HOME", "/cfg")
      hook = "/cfg/hooks/remove/10-cleanup"
      teardown = "/repo-feat/.foyer/teardown.sh"

      FakeRunner.start(
        files: [teardown],
        executables: %{"/cfg/hooks/remove" => [hook]},
        results: %{{"bash", [hook]} => {:ok, ""}, {"bash", [teardown]} => {:ok, ""}}
      )

      assert {:ok, out} = CLI.run(["remove", "feat"], FakeRunner)
      assert out =~ "hook: ran 10-cleanup"

      # order: forget, hook, teardown
      assert [
               {"jj", ["workspace", "forget", "feat"], _},
               {"bash", [^hook], _},
               {"bash", [^teardown], _}
             ] = FakeRunner.calls()
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
