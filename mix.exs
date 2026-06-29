defmodule NatureWhistle.MixProject do
  use Mix.Project

  def project do
    [
      app: :nature_whistle,
      version: "0.2.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "Telemetry-based alerting for Elixir apps – Slack, Teams, custom webhooks, and console with spike/resolution alerts",
      package: package(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {NatureWhistle.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:telemetry, "~> 1.2"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:bypass, "~> 2.1", only: :test},
      {:plug, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :nature_whistle,
      description:
        "Telemetry-based alerting for Elixir apps – Slack, Teams, custom webhooks, and console with spike/resolution alerts",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/andrewinsoul/nature_whistle"
      },
      files: ["lib", "mix.exs", "README.md", "LICENSE", "assets/img/*"]
    ]
  end
end
