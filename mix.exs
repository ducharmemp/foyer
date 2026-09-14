defmodule Foyer.MixProject do
  use Mix.Project

  @version "0.2.0"

  # The entryway that furnishes a jj workspace on arrival. A thin wrapper the
  # user invokes as `jj foyer …` (via a `util exec` alias) or directly as
  # `foyer …`; it creates a workspace and then runs the project's own setup.
  def project do
    [
      app: :foyer,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      releases: releases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  # `mod:` is set only in :prod. It makes the OTP application boot straight into
  # the CLI (Foyer.App), which is what the Burrito release needs. In :dev and
  # :test we must NOT auto-run the CLI — `mix test` boots the app, and a CLI
  # that reads argv and halts the VM would wreck the suite. So dev/test get a
  # plain application with no entry module; the escript's `main/1` is the entry
  # point there instead.
  def application do
    base = [extra_applications: [:logger]]

    if Mix.env() == :prod do
      # :prod boots straight into the CLI via Foyer.App, mirroring the working
      # Burrito CLI example: only :logger is listed here (mix release loads
      # burrito's modules via the dependency closure), and mod: points at the
      # entry app. dev/test have no mod:, so nothing auto-runs; they use the
      # escript entry (Foyer.CLI.main/1).
      [extra_applications: [:logger], mod: {Foyer.App, []}]
    else
      base
    end
  end

  # Build a self-contained escript. `main_module` is the entrypoint invoked as
  # `Foyer.CLI.main(argv)`. The escript needs Erlang at runtime; the Burrito
  # release (below) bundles ERTS for users who have no Erlang installed.
  defp escript do
    [main_module: Foyer.CLI, name: "foyer"]
  end

  # Burrito release: self-contained binaries that bundle the BEAM runtime, so a
  # user with no Erlang can download one file and run it. Targets are the set
  # foyer's users actually run. Build with `MIX_ENV=prod mix release`; output
  # lands in burrito_out/. scripts/build-release.sh drives this locally and in
  # CI alike.
  defp releases do
    [
      foyer: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_amd64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            macos_arm64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  defp deps do
    # Burrito is a :prod-only dependency, but Mix resolves the SCM of every
    # listed dep at boot — which needs Hex present and, in an offline sandbox,
    # fails for `mix test`. So it is only in the list when actually in :prod
    # (the release build). dev/test never see it, keeping `mix test` and the
    # hermetic nix escript build dependency-free. Foyer.App, its only caller,
    # lives in the :prod-only lib_prod path.
    if Mix.env() == :prod do
      [{:burrito, "~> 1.0"}]
    else
      []
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  # Foyer.App references Burrito (a :prod-only dep), so it must not compile in
  # dev/test where Burrito is absent. It lives under lib/prod, included only in
  # :prod. The escript and tests use Foyer.CLI directly and never need it.
  defp elixirc_paths(:prod), do: ["lib", "lib_prod"]
  defp elixirc_paths(_), do: ["lib"]
end
