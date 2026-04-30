defmodule Planck.AI.ToolTest do
  use ExUnit.Case, async: true

  alias Planck.AI.Tool

  defp tool_params,
    do: %{
      "type" => "object",
      "properties" => %{"command" => %{"type" => "string"}},
      "required" => ["command"]
    }

  describe "new/1" do
    test "builds a %Tool{} struct" do
      tool_params = tool_params()

      assert %Tool{} =
               Tool.new(name: "bash", description: "Run a command", parameters: tool_params)
    end

    test "sets all fields" do
      tool_params = tool_params()
      tool = Tool.new(name: "bash", description: "Run a command", parameters: tool_params)
      assert tool.name == "bash"
      assert tool.description == "Run a command"
      assert tool.parameters == tool_params
    end

    test "matches a hand-built struct" do
      tool_params = tool_params()

      assert Tool.new(name: "bash", description: "Run a command", parameters: tool_params) ==
               %Tool{name: "bash", description: "Run a command", parameters: tool_params}
    end
  end
end
