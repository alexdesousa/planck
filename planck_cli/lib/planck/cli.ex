defmodule Planck.CLI do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Planck.CLI.Config.preload()
    Planck.CLI.Config.validate!()

    if System.get_env("__BURRITO") do
      # Running as a compiled binary — execute the CLI and halt when done.
      # Long-running modes (TUI, Web) will start their supervisor tree here
      # instead of halting.
      code = Planck.CLI.Main.run(System.argv())
      System.halt(code)
    else
      # Development: start the web server so http://localhost:4000 is always
      # available when running `iex -S mix` or `mix run --no-halt`.
      Planck.Web.Supervisor.start_link()
    end
  end
end
