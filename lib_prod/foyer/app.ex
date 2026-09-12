defmodule Foyer.App do
  @moduledoc """
  OTP application entry point, used by the Burrito-wrapped binary.

  Burrito launches the release as an OTP application rather than an escript, so
  the CLI arguments arrive through `Burrito.Util.Args.get_arguments/0` instead
  of `main/1`. This module bridges that boot path to the same `Foyer.CLI.main/1`
  the escript uses, so both distribution formats share one code path and one
  exit-code policy.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # get_arguments/0 reads the plain arguments the Zig wrapper passes down. It
    # is the entry the working Burrito CLI examples use; unlike argv/0 it does
    # not route through Burrito.Util.running_standalone?/0.
    argv = Burrito.Util.Args.get_arguments()
    Foyer.CLI.main(argv)
    # main/1 halts the VM, so the lines below are never reached. A supervisor
    # with no children satisfies the Application.start/2 contract honestly in
    # the event halting is ever deferred.
    Supervisor.start_link([], strategy: :one_for_one, name: Foyer.Supervisor)
  end
end
