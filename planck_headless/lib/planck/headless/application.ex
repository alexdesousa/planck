defmodule Planck.Headless.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Planck.Headless.Config.load()
    Planck.Headless.Supervisor.start_link()
  end
end
