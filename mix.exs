defmodule Foyer.MixProject do
  use Mix.Project

  # The entryway that furnishes a jj workspace on arrival. A thin wrapper the
  # user invokes as `jj foyer …` (via a `util exec` alias) or directly as
  # `foyer …`; it creates a workspace and then runs the project's own setup.
  def project do
    [
      app: :foyer,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Build a self-contained escript. `main_module` is the entrypoint invoked as
  # `Foyer.CLI.main(argv)`. No external deps, so the escript stays a single
  # file that runs on any Erlang runtime.
  defp escript do
    [main_module: Foyer.CLI, name: "foyer"]
  end

  defp deps, do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
