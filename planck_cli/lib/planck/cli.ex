defmodule Planck.CLI do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if System.get_env("__BURRITO") do
      # Running as a compiled binary — execute the CLI and halt when done.
      # Long-running modes (TUI, Web) will start their supervisor tree here
      # instead of halting.
      code = Planck.CLI.Main.run(System.argv())
      System.halt(code)
    else
      # Development: planck_headless is already started as a dependency.
      # Start an empty supervisor so the OTP app contract is satisfied.
      Supervisor.start_link([], strategy: :one_for_one, name: Planck.CLI.Supervisor)
    end
  end
end
