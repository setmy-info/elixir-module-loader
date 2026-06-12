defmodule SetmyInfo.ElixirModuleLoader.MixProject do
  use Mix.Project

  @coveralls_commands [
    :coveralls,
    :"coveralls.detail",
    :"coveralls.post",
    :"coveralls.html",
    :"coveralls.lcov"
  ]

  def project do
    [
      app: :elixir_module_loader,
      version: "1.1.0",
      elixir: "~> 1.17",
      name: "ElixirModuleLoader",
      description:
        "Dynamic Elixir module compilation, loading, 128-bit keyed registry and lifecycle management.",
      source_url: "https://github.com/setmy-info/elixir-module-loader",
      homepage_url: "https://github.com/setmy-info/elixir-module-loader",
      start_permanent: Mix.env() == :live,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      docs: [
        main: "readme",
        extras: ["README.md", "LICENSE"],
        groups_for_extras: [Guides: ["README.md"]],
        output: "_build/doc"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SetmyInfo.ElixirModuleLoader.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs:
        [
          "test.unit": :test,
          "test.integration": :test,
          "test.e2e": :test,
          "test.gherkin": :test,
          "test.all": :test,
          "test.coverage": :test,
          report: :test
        ] ++ preferred_cli_env()
    ]
  end

  defp preferred_cli_env do
    Enum.map(@coveralls_commands, &{&1, :test})
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", runtime: false},
      {:excoveralls, "~> 0.18", runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:white_bread, "4.4.0", only: [:test, :ci]},
      {:gherkin, "1.6.0", only: [:test, :ci], override: true}
    ]
  end

  defp package do
    [
      name: "elixir_module_loader",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/setmy-info/elixir-module-loader"},
      maintainers: ["Imre Tabur"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp elixirc_paths(env) when env in [:test, :ci],
    do: ["lib", "test/support", "test/fixtures"]

  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      build: ["deps.get", "compile"],
      validate: ["compile --warnings-as-errors", "format --check-formatted"],
      docs: ["docs"],
      "test.unit": ["test test/unit"],
      "test.integration": ["test test/integration"],
      "test.e2e": ["test test/e2e"],
      "test.gherkin": ["test test/e2e/module_loader_gherkin_test.exs"],
      "test.all": ["test"],
      "test.coverage": ["coveralls.html"],
      audit: ["deps.audit"],
      security: ["sobelow --config"],
      report: ["docs", "test.coverage", "deps.audit"]
    ]
  end
end
