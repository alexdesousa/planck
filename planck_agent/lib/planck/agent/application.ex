defmodule Planck.Agent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Planck.Agent.Supervisor.start_link()
  end
end
