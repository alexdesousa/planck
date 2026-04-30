defmodule Planck.Headless.MixProject do
  use Mix.Project

  @version "0.1.0"
  @app :planck_headless
  @description "Headless core for the Planck coding agent — config, resources, and session lifecycle"
  @repo "https://github.com/alexdesousa/planck"
  @root "#{@repo}/tree/v#{@version}/planck_headless"

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
      name: "Planck.Headless",
      description: @description,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Planck.Headless.Application, []}
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
      local_or_hex(:planck_agent, "~> 0.1"),
      {:jason, "~> 1.4"},
      {:skogsra, "~> 2.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
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
        "Changelog" => "#{@repo}/blob/v#{@version}/planck_headless/CHANGELOG.md",
        "GitHub" => @root,
        "Sponsor" => "https://github.com/sponsors/alexdesousa"
      }
    ]
  end
end
