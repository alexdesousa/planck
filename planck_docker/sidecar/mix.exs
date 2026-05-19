defmodule Sidecar.MixProject do
  use Mix.Project

  def project do
    [
      app: :sidecar,
      version: "0.1.5",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: [plt_file: {:no_warn, "priv/plts/sidecar.plt"}],
      deps: deps()
    ]
  end

  def application do
    [mod: {Sidecar.Application, []}, extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      setup: ["deps.get", "cmd npm install --prefix assets"],
      check: [
        "format --dry-run --check-formatted",
        "compile --warnings-as-errors",
        "credo",
        "test"
      ]
    ]
  end

  defp deps do
    [
      {:planck_agent, "~> 0.1"},
      {:skogsra, "~> 2.5"},
      {:req, "~> 0.5"},
      {:erlexec, "~> 2.0"},
      {:file_system, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.2", only: :dev, runtime: false}
    ]
  end
end
