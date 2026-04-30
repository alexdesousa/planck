defmodule PlanckTestSidecar.MixProject do
  use Mix.Project

  def project do
    [
      app: :planck_test_sidecar,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: true,
      deps: deps()
    ]
  end

  def application do
    [mod: {PlanckTestSidecar.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:planck_agent, path: "../../planck_agent"}
    ]
  end
end
