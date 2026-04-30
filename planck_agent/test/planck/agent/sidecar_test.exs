defmodule Planck.Agent.SidecarTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.Sidecar

  @pt_key {Planck.Agent.Sidecar, :entry_module}

  defmodule TestSidecar do
    use Planck.Agent.Sidecar

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

  setup do
    :persistent_term.erase(@pt_key)
    on_exit(fn -> :persistent_term.erase(@pt_key) end)
    :ok
  end

  # --- tools/0 callback ---

  describe "tools/0 callback" do
    test "returns Planck.Agent.Tool structs with execute_fn" do
      tools = TestSidecar.tools()
      assert length(tools) == 2
      assert Enum.all?(tools, fn t -> match?(%Planck.Agent.Tool{}, t) end)
      assert hd(tools).name == "echo"
    end
  end

  # --- list_tools/1 ---

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

  # --- execute_tool/4 ---

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

  # --- discover/0 ---

  describe "discover/0" do
    test "returns the cached value on subsequent calls" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert Sidecar.discover() == TestSidecar
    end

    test "returns nil and does not cache when no implementing module is found" do
      result = Sidecar.discover()
      assert result == nil
      # nil is not cached — next call will scan again
      assert :persistent_term.get(@pt_key, :miss) == :miss
    end

    test "does not re-scan once a module is cached" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert Sidecar.discover() == TestSidecar
    end
  end

  # --- list_tools/0 ---

  describe "list_tools/0" do
    test "returns AI tools via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      tools = Sidecar.list_tools()
      assert [%Planck.AI.Tool{name: "echo"}, %Planck.AI.Tool{name: "fail"}] = tools
    end

    test "returns [] when no module is discovered" do
      :persistent_term.put(@pt_key, nil)
      assert Sidecar.list_tools() == []
    end
  end

  # --- execute_tool/3 ---

  describe "execute_tool/3" do
    test "executes the tool via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:ok, _} = Sidecar.execute_tool("echo", "agent-1", %{"x" => 1})
    end

    test "returns the tool's error result via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:error, "intentional"} = Sidecar.execute_tool("fail", "agent-1", %{})
    end

    test "returns error for unknown tool via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:error, "unknown tool: ghost"} = Sidecar.execute_tool("ghost", "agent-1", %{})
    end

    test "returns error when no module is discovered" do
      :persistent_term.put(@pt_key, nil)

      assert {:error, "no sidecar entry module found"} =
               Sidecar.execute_tool("echo", "agent-1", %{})
    end
  end
end
