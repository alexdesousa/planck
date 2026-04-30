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
        execute_fn: fn _id, %{"message" => msg} -> {:ok, msg} end
      )
    ]
  end
end
