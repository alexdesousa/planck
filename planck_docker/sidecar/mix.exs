defmodule Sidecar.MixProject do
  use Mix.Project

  def project do
    [
      app: :sidecar,
      version: "0.1.13",
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

  defp local_or_hex(package, version) do
    # Env var: planck_agent -> PLANCK_AGENT_SRC, planck_ai -> PLANCK_AI_SRC
    suffix = package |> to_string() |> String.replace_prefix("planck_", "") |> String.upcase()
    env_path = System.get_env("PLANCK_#{suffix}_SRC")
    auto_path = Path.expand("../../#{package}", __DIR__)
    path = env_path || if(File.dir?(auto_path), do: auto_path)
    if path, do: {package, path: path}, else: {package, version}
  end

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
      local_or_hex(:planck_agent, "~> 0.1"),
      {:skogsra, "~> 2.5"},
      {:req, "~> 0.5"},
      {:ymlr, "~> 5.1"},
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
