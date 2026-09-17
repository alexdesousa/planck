defmodule PlanckTestSidecar.Planck do
  use Planck.Agent.Sidecar

  @impl true
  def tools do
    [
      Planck.Agent.Tool.new(
        name: "echo",
        description: "Returns the message back.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "message" => %{"type" => "string", "description" => "The message to echo."}
          },
          "required" => ["message"]
        },
        execute_fn: fn _agent_id, _id, %{"message" => msg} -> {:ok, msg} end
      ),
      Planck.Agent.Tool.new(
        name: "tool_with_widget",
        description: "A tool paired with a widget.",
        parameters: %{"type" => "object", "properties" => %{}},
        execute_fn: fn _agent_id, _id, _args -> {:ok, "counter tool"} end,
        widget: PlanckTestSidecar.Widgets.Counter
      )
    ]
  end
end
