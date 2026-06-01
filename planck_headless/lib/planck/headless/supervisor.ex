defmodule Planck.Headless.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link() :: Supervisor.on_start()
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Planck.Agent.Supervisor is already started by the :planck_agent OTP
    # application before this supervisor starts. We only need the headless-owned
    # children here.
    proxy_child = Planck.Headless.ProxyPool.child_spec()

    children =
      [proxy_child, Planck.Headless.AppSupervisor]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
