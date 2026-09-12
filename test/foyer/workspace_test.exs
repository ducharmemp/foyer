defmodule Foyer.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Foyer.FakeRunner
  alias Foyer.Workspace

  setup do
    on_exit(&FakeRunner.stop/0)
    :ok
  end

  describe "add_args/3" do
    test "minimal: name and destination only" do
      assert Workspace.add_args("feat", "/repo-feat", %{}) ==
               ["workspace", "add", "--name", "feat", "/repo-feat"]
    end

    test "includes revision and message when present, destination stays last" do
      args =
        Workspace.add_args("feat", "/repo-feat", %{revision: "@", message: "start feat"})

      assert args ==
               ["workspace", "add", "--name", "feat", "--revision", "@", "--message",
                "start feat", "/repo-feat"]

      assert List.last(args) == "/repo-feat"
    end

    test "omits flags for nil or empty values" do
      assert Workspace.add_args("feat", "/d", %{revision: nil, message: ""}) ==
               ["workspace", "add", "--name", "feat", "/d"]
    end
  end

  describe "resolve_destination/1" do
    test "explicit destination wins and is expanded" do
      dest = Workspace.resolve_destination(%{name: "x", destination: "/tmp/here"})
      assert dest == "/tmp/here"
    end

    test "defaults to sibling <repo>-<name> of the repo root" do
      dest = Workspace.resolve_destination(%{name: "feat", repo_root: "/home/m/proj"})
      assert dest == "/home/m/proj-feat"
    end

    test "nil when neither destination nor repo_root is known" do
      assert Workspace.resolve_destination(%{name: "feat"}) == nil
    end
  end

  describe "create/2 name validation" do
    test "empty name is rejected" do
      FakeRunner.start()
      assert {:error, "workspace name is required"} = Workspace.create(FakeRunner, %{name: ""})
    end

    test "missing name is rejected" do
      FakeRunner.start()
      assert {:error, "workspace name is required"} = Workspace.create(FakeRunner, %{})
    end
  end

  describe "create/2 destination guards" do
    test "refuses when destination cannot be determined" do
      FakeRunner.start()
      assert {:error, msg} = Workspace.create(FakeRunner, %{name: "feat"})
      assert msg =~ "could not determine a destination"
    end

    test "refuses an existing destination without running jj" do
      FakeRunner.start(dirs: ["/repo-feat"])

      assert {:error, msg} =
               Workspace.create(FakeRunner, %{name: "feat", destination: "/repo-feat"})

      assert msg =~ "already exists"
      assert FakeRunner.calls() == []
    end
  end

  describe "create/2 happy path" do
    test "runs jj workspace add with the computed args" do
      FakeRunner.start()

      assert {:ok, result} =
               Workspace.create(FakeRunner, %{name: "feat", repo_root: "/home/m/proj"})

      assert result.destination == "/home/m/proj-feat"

      assert [{"jj", args, _opts}] = FakeRunner.calls()
      assert args == ["workspace", "add", "--name", "feat", "/home/m/proj-feat"]
    end

    test "reports :none when no setup script exists" do
      FakeRunner.start()

      assert {:ok, %{furnish: :none}} =
               Workspace.create(FakeRunner, %{name: "feat", destination: "/dest"})
    end
  end

  describe "create/2 furnishing" do
    test "runs .foyer/setup.sh with cwd and JJ_WORKSPACE_ROOT set" do
      script = "/dest/.foyer/setup.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:ok, "ok"}}
      )

      assert {:ok, %{furnish: :ok}} =
               Workspace.create(FakeRunner, %{name: "feat", destination: "/dest"})

      calls = FakeRunner.calls()
      assert {"bash", [^script], opts} = List.last(calls)
      assert opts[:cd] == "/dest"
      assert opts[:env] == [{"JJ_WORKSPACE_ROOT", "/dest"}]
    end

    test "reports {:failed, msg} when the setup script fails, but the workspace exists" do
      script = "/dest/.foyer/setup.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:error, {1, "boom\n"}}}
      )

      assert {:ok, %{destination: "/dest", furnish: {:failed, "boom"}}} =
               Workspace.create(FakeRunner, %{name: "feat", destination: "/dest"})
    end

    test "skips furnishing with furnish: false and never checks for the script" do
      FakeRunner.start(files: ["/dest/.foyer/setup.sh"])

      assert {:ok, %{furnish: :skipped}} =
               Workspace.create(FakeRunner, %{
                 name: "feat",
                 destination: "/dest",
                 furnish: false
               })

      # only the jj add ran; no bash call
      assert Enum.all?(FakeRunner.calls(), fn {cmd, _, _} -> cmd == "jj" end)
    end
  end

  describe "create/2 jj failure" do
    test "maps a non-zero jj exit to an error and does not furnish" do
      FakeRunner.start(
        files: ["/dest/.foyer/setup.sh"],
        results: %{{"jj", ["workspace", "add", "--name", "feat", "/dest"]} => {:error, {1, "nope"}}}
      )

      assert {:error, msg} =
               Workspace.create(FakeRunner, %{name: "feat", destination: "/dest"})

      assert msg =~ "jj workspace add failed"
      assert msg =~ "nope"
      # furnish must not run after a failed add
      refute Enum.any?(FakeRunner.calls(), fn {cmd, _, _} -> cmd == "bash" end)
    end
  end

  describe "remove/2 name validation" do
    test "empty name is rejected" do
      FakeRunner.start()
      assert {:error, "workspace name is required"} = Workspace.remove(FakeRunner, %{name: ""})
    end

    test "missing name is rejected" do
      FakeRunner.start()
      assert {:error, "workspace name is required"} = Workspace.remove(FakeRunner, %{})
    end
  end

  describe "remove/2 forget-then-teardown order" do
    test "forgets the workspace BEFORE running teardown" do
      script = "/dest/.foyer/teardown.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:ok, "bye"}}
      )

      assert {:ok, %{name: "feat", directory: "/dest", teardown: :ok}} =
               Workspace.remove(FakeRunner, %{name: "feat", destination: "/dest"})

      # order is load-bearing: jj forget must precede the teardown bash call so
      # the directory is untracked (and self-deletable) when teardown runs.
      calls = FakeRunner.calls()
      assert [{"jj", ["workspace", "forget", "feat"], _}, {"bash", [^script], _}] = calls
    end

    test "teardown runs with cwd and JJ_WORKSPACE_ROOT set to the directory" do
      script = "/dest/.foyer/teardown.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:ok, "ok"}}
      )

      assert {:ok, %{teardown: :ok}} =
               Workspace.remove(FakeRunner, %{name: "feat", destination: "/dest"})

      assert {"bash", [^script], opts} = List.last(FakeRunner.calls())
      assert opts[:cd] == "/dest"
      assert opts[:env] == [{"JJ_WORKSPACE_ROOT", "/dest"}]
    end
  end

  describe "remove/2 teardown outcomes" do
    test "reports :none when no teardown script exists" do
      FakeRunner.start()

      assert {:ok, %{teardown: :none}} =
               Workspace.remove(FakeRunner, %{name: "feat", destination: "/dest"})

      # forget still ran
      assert [{"jj", ["workspace", "forget", "feat"], _}] = FakeRunner.calls()
    end

    test "reports :none when the directory cannot be resolved, but still forgets" do
      FakeRunner.start()

      assert {:ok, %{directory: nil, teardown: :none}} =
               Workspace.remove(FakeRunner, %{name: "feat"})

      assert [{"jj", ["workspace", "forget", "feat"], _}] = FakeRunner.calls()
    end

    test "reports {:failed, msg} when teardown fails, workspace is still forgotten" do
      script = "/dest/.foyer/teardown.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"bash", [script]} => {:error, {1, "boom\n"}}}
      )

      assert {:ok, %{name: "feat", teardown: {:failed, "boom"}}} =
               Workspace.remove(FakeRunner, %{name: "feat", destination: "/dest"})
    end
  end

  describe "remove/2 jj failure" do
    test "a failed forget aborts and never runs teardown" do
      script = "/dest/.foyer/teardown.sh"

      FakeRunner.start(
        files: [script],
        results: %{{"jj", ["workspace", "forget", "feat"]} => {:error, {1, "no such workspace"}}}
      )

      assert {:error, msg} =
               Workspace.remove(FakeRunner, %{name: "feat", destination: "/dest"})

      assert msg =~ "jj workspace forget failed"
      assert msg =~ "no such workspace"
      refute Enum.any?(FakeRunner.calls(), fn {cmd, _, _} -> cmd == "bash" end)
    end
  end
end
