defmodule Planck.Agent.SidecarTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.Sidecar

  @pt_key {Planck.Agent.Sidecar, :entry_module}

  defmodule TestWidget do
    use Planck.Agent.Widget

    @impl true
    def id, do: "counter"

    @impl true
    def render(myself), do: "<div myself=\"#{inspect(myself)}\">rendered</div>"

    @impl true
    def handle_action("increment", _args), do: :ok
    def handle_action("boom", _args), do: {:error, "intentional"}
  end

  defmodule TestSidecar do
    use Planck.Agent.Sidecar

    alias Planck.Agent.Tool

    @impl true
    def tools do
      [
        Tool.new(
          name: "echo",
          description: "Echo the input.",
          parameters: %{"type" => "object", "properties" => %{}},
          execute_fn: fn _agent_id, _id, args -> {:ok, inspect(args)} end
        ),
        Tool.new(
          name: "fail",
          description: "Always fails.",
          parameters: %{"type" => "object", "properties" => %{}},
          execute_fn: fn _agent_id, _id, _args -> {:error, "intentional"} end
        ),
        Tool.new(
          name: "tool_with_widget",
          description: "A tool paired with a widget.",
          parameters: %{"type" => "object", "properties" => %{}},
          execute_fn: fn _agent_id, _id, _args -> {:ok, "done"} end,
          widget: TestWidget
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
      assert length(tools) == 3
      assert Enum.all?(tools, fn t -> match?(%Planck.Agent.Tool{}, t) end)
      assert hd(tools).name == "echo"
    end
  end

  # --- list_tools/1 ---

  describe "list_tools/1" do
    test "returns Planck.AI.Tool structs — no execute_fn, serialisable" do
      tools = Sidecar.list_tools(TestSidecar)

      assert [
               %Planck.AI.Tool{name: "echo"},
               %Planck.AI.Tool{name: "fail"},
               %Planck.AI.Tool{name: "tool_with_widget"}
             ] = tools
    end

    test "preserves name, description, and parameters" do
      [tool | _] = Sidecar.list_tools(TestSidecar)
      assert tool.name == "echo"
      assert tool.description == "Echo the input."
      assert is_map(tool.parameters)
    end
  end

  # --- execute_tool/5 ---

  describe "execute_tool/5" do
    test "calls the matching tool's execute_fn on the sidecar side" do
      assert {:ok, result} =
               Sidecar.execute_tool(TestSidecar, "echo", "agent-1", "tc1", %{"x" => 1})

      assert result =~ "x"
    end

    test "returns the tool's error result" do
      assert {:error, "intentional"} =
               Sidecar.execute_tool(TestSidecar, "fail", "agent-1", "tc1", %{})
    end

    test "returns error for unknown tool" do
      assert {:error, "unknown tool: ghost"} =
               Sidecar.execute_tool(TestSidecar, "ghost", "agent-1", "tc1", %{})
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

      assert [
               %Planck.AI.Tool{name: "echo"},
               %Planck.AI.Tool{name: "fail"},
               %Planck.AI.Tool{name: "tool_with_widget"}
             ] = tools
    end

    test "returns [] when no module is discovered" do
      :persistent_term.put(@pt_key, nil)
      assert Sidecar.list_tools() == []
    end
  end

  # --- execute_tool/4 ---

  describe "execute_tool/4" do
    test "executes the tool via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:ok, _} = Sidecar.execute_tool("echo", "agent-1", "tc1", %{"x" => 1})
    end

    test "returns the tool's error result via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:error, "intentional"} = Sidecar.execute_tool("fail", "agent-1", "tc1", %{})
    end

    test "returns error for unknown tool via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)

      assert {:error, "unknown tool: ghost"} =
               Sidecar.execute_tool("ghost", "agent-1", "tc1", %{})
    end

    test "returns error when no module is discovered" do
      :persistent_term.put(@pt_key, nil)

      assert {:error, "no sidecar entry module found"} =
               Sidecar.execute_tool("echo", "agent-1", "tc1", %{})
    end
  end

  # --- list_widgets/1 ---

  describe "list_widgets/1" do
    test "returns only the widget modules of tools that set :widget" do
      assert Sidecar.list_widgets(TestSidecar) == [TestWidget]
    end
  end

  # --- list_widgets/0 ---

  describe "list_widgets/0" do
    test "returns widget modules via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert Sidecar.list_widgets() == [TestWidget]
    end

    test "returns [] when no module is discovered" do
      :persistent_term.put(@pt_key, nil)
      assert Sidecar.list_widgets() == []
    end
  end

  # --- widget_render/2 ---

  describe "widget_render/2" do
    test "renders the widget via the discovered module, passing myself through opaquely" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:ok, html} = Sidecar.widget_render("counter", 42)
      assert html =~ "42"
    end

    test "returns error for unknown widget" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:error, "unknown widget: ghost"} = Sidecar.widget_render("ghost", nil)
    end
  end

  # --- widget_action/3 ---

  describe "widget_action/3" do
    test "dispatches the action via the discovered module" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert :ok = Sidecar.widget_action("counter", "increment", %{})
    end

    test "returns the widget's error result" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:error, "intentional"} = Sidecar.widget_action("counter", "boom", %{})
    end

    test "returns error for unknown widget" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:error, "unknown widget: ghost"} = Sidecar.widget_action("ghost", "increment", %{})
    end
  end

  # --- widget_container/1 ---

  describe "widget_container/1" do
    test "returns :modal for a widget that doesn't override container/0" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:ok, :modal} = Sidecar.widget_container("counter")
      # Same default, called directly — proves it's a real injected function,
      # not something only widget_container/1 papers over.
      assert TestWidget.container() == :modal
    end

    test "returns error for unknown widget" do
      :persistent_term.put(@pt_key, TestSidecar)
      assert {:error, "unknown widget: ghost"} = Sidecar.widget_container("ghost")
    end
  end
end
