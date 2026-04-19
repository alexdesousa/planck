defmodule Planck.Agent.ToolTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Tool

  defp params,
    do: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }

  defp execute_fn, do: fn _id, _args -> {:ok, :done} end

  describe "new/1" do
    test "builds a %Tool{} struct" do
      assert %Tool{} =
               Tool.new(
                 name: "read",
                 description: "Read a file",
                 parameters: params(),
                 execute_fn: execute_fn()
               )
    end

    test "sets all fields" do
      fun = execute_fn()

      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: fun
        )

      assert tool.name == "read"
      assert tool.description == "Read a file"
      assert tool.parameters == params()
      assert tool.execute_fn == fun
    end
  end

  describe "to_ai_tool/1" do
    test "returns a Planck.AI.Tool with matching name, description, parameters" do
      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: execute_fn()
        )

      ai_tool = Tool.to_ai_tool(tool)

      assert %Planck.AI.Tool{} = ai_tool
      assert ai_tool.name == tool.name
      assert ai_tool.description == tool.description
      assert ai_tool.parameters == tool.parameters
    end

    test "drops execute_fn" do
      tool =
        Tool.new(
          name: "read",
          description: "Read a file",
          parameters: params(),
          execute_fn: execute_fn()
        )

      ai_tool = Tool.to_ai_tool(tool)
      refute Map.has_key?(ai_tool, :execute_fn)
    end
  end
end
