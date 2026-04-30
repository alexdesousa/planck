defmodule Planck.Headless.AppSupervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Planck.Headless.ResourceStore
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
