defmodule Planck.CLI.MixProject do
  use Mix.Project

  @version "0.1.0"
  @app :planck_cli
  @description "Planck coding agent CLI"
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
      name: "Planck CLI",
      description: @description,
      releases: releases()
    ]
  end

  def application do
    [
      mod: {Planck.CLI, []},
      extra_applications: [:logger]
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
      local_or_hex(:planck_headless, "~> 0.1"),
      {:burrito, "~> 1.0"},
      {:mox, "~> 1.2", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
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

  # ---------------------------------------------------------------------------
  # Releases
  # ---------------------------------------------------------------------------

  defp releases do
    [
      # Default: host platform only. Set PLANCK_BUILD_ALL=true for all targets.
      planck: burrito_release(build_targets())
    ]
  end

  defp burrito_release(targets) do
    [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: targets,
        debug: Mix.env() != :prod
      ]
    ]
  end

  defp build_targets do
    if System.get_env("PLANCK_BUILD_ALL") == "true",
      do: all_targets(),
      else: host_target()
  end

  defp host_target do
    case {:os.type(), :erlang.system_info(:system_architecture)} do
      {{:unix, :darwin}, arch} when arch in [~c"aarch64-apple-darwin", ~c"arm-apple-darwin"] ->
        [macos_arm: macos(:aarch64)]

      {{:unix, :darwin}, _} ->
        [macos: macos(:x86_64)]

      {{:unix, :linux}, arch}
      when arch in [~c"aarch64-unknown-linux-gnu", ~c"aarch64-linux-gnu"] ->
        [linux_arm: linux(:aarch64)]

      {{:unix, :linux}, _} ->
        [linux: linux(:x86_64)]

      {{:win32, _}, _} ->
        [windows: windows(:x86_64)]
    end
  end

  defp all_targets do
    [
      linux: linux(:x86_64),
      linux_arm: linux(:aarch64),
      macos: macos(:x86_64),
      macos_arm: macos(:aarch64),
      windows: windows(:x86_64)
    ]
  end

  defp linux(cpu), do: [os: :linux, cpu: cpu]
  defp macos(cpu), do: [os: :darwin, cpu: cpu]
  defp windows(cpu), do: [os: :windows, cpu: cpu]
end
