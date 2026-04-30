defmodule PlanckTestSidecar.Application do
  use Application

  @impl true
  def start(_type, _args) do
    headless_node = System.get_env("PLANCK_HEADLESS_NODE") |> String.to_atom()

    children = [
      {Task, fn -> Node.connect(headless_node) end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PlanckTestSidecar.Supervisor)
  end
end
