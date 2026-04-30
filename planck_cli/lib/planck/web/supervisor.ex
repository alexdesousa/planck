defmodule Planck.Web.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Planck.Web.Telemetry,
      Planck.Web.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
