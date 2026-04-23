defmodule Planck.Agent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @app :planck_agent
  @description "OTP-based agent runtime built on top of planck_ai"
  @repo "https://github.com/alexdesousa/planck"
  @root "#{@repo}/tree/v#{@version}/planck_agent"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      name: "Planck.Agent",
      description: @description,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Planck.Agent.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp deps do
    [
      local_or_hex(:planck_ai, "~> 0.1"),
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:exqlite, "~> 0.23"},
      {:erlexec, "~> 2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:mox, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp local_or_hex(package, version) do
    if System.get_env("PLANCK_LOCAL") == "true" do
      {package, path: "../#{package}"}
    else
      {package, version}
    end
  end

  defp aliases do
    [
      check: [
        "format --dry-run --check-formatted",
        "compile --warnings-as-errors",
        "credo",
        "test"
      ]
    ]
  end

  defp dialyzer do
    [plt_file: {:no_warn, "priv/plts/#{@app}.plt"}]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @repo,
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      description: @description,
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", ".formatter.exs"],
      maintainers: ["Alexander de Sousa"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "#{@repo}/blob/v#{@version}/planck_agent/CHANGELOG.md",
        "GitHub" => @root,
        "Sponsor" => "https://github.com/sponsors/alexdesousa"
      }
    ]
  end
end
