defmodule Planck.Agent.SidecarTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Sidecar

  defmodule TestSidecar do
    @behaviour Planck.Agent.Sidecar

    @impl true
    def tools do
      [
        Planck.Agent.Tool.new(
          name: "echo",
          description: "Echo the input.",
          parameters: %{"type" => "object", "properties" => %{}},
          execute_fn: fn _id, args -> {:ok, inspect(args)} end
        ),
        Planck.Agent.Tool.new(
          name: "fail",
          description: "Always fails.",
          parameters: %{"type" => "object", "properties" => %{}},
          execute_fn: fn _id, _args -> {:error, "intentional"} end
        )
      ]
    end
  end

  describe "tools/0 callback" do
    test "returns Planck.Agent.Tool structs with execute_fn" do
      tools = TestSidecar.tools()
      assert length(tools) == 2
      assert Enum.all?(tools, fn t -> match?(%Planck.Agent.Tool{}, t) end)
      assert hd(tools).name == "echo"
    end
  end

  describe "list_tools/1" do
    test "returns Planck.AI.Tool structs — no execute_fn, serialisable" do
      tools = Sidecar.list_tools(TestSidecar)
      assert [%Planck.AI.Tool{name: "echo"}, %Planck.AI.Tool{name: "fail"}] = tools
    end

    test "preserves name, description, and parameters" do
      [tool | _] = Sidecar.list_tools(TestSidecar)
      assert tool.name == "echo"
      assert tool.description == "Echo the input."
      assert is_map(tool.parameters)
    end
  end

  describe "execute_tool/4" do
    test "calls the matching tool's execute_fn on the sidecar side" do
      assert {:ok, result} = Sidecar.execute_tool(TestSidecar, "echo", "agent-1", %{"x" => 1})
      assert result =~ "x"
    end

    test "returns the tool's error result" do
      assert {:error, "intentional"} =
               Sidecar.execute_tool(TestSidecar, "fail", "agent-1", %{})
    end

    test "returns error for unknown tool" do
      assert {:error, "unknown tool: ghost"} =
               Sidecar.execute_tool(TestSidecar, "ghost", "agent-1", %{})
    end
  end
end
