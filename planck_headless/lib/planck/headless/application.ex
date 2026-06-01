defmodule Planck.Headless.Application do
  @moduledoc false

  use Application

  alias Planck.Headless.{Config, Supervisor}

  @impl true
  def start(_type, _args) do
    Config.preload()
    Config.validate!()
    Planck.Headless.ProxyPool.configure_os_env()
    Supervisor.start_link()
  end
end
