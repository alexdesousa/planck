defmodule Planck.AI.MixProject do
  use Mix.Project

  @version "0.1.0"
  @app :planck_ai
  @description "Typed LLM provider abstraction built on top of req_llm"
  @repo "https://github.com/alexdesousa/planck"
  @root "#{@repo}/tree/v#{@version}/planck_ai"

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
      name: "Planck.AI",
      description: @description,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
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
      {:req_llm, "~> 1.9"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:mox, "~> 1.2", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
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
    [
      plt_file: {:no_warn, "priv/plts/#{@app}.plt"},
      plt_add_apps: [:llm_db]
    ]
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
        "Changelog" => "#{@root}/CHANGELOG.md",
        "GitHub" => @root,
        "Sponsor" => "https://github.com/sponsors/alexdesousa"
      }
    ]
  end
end
