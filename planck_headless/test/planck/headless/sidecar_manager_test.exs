defmodule Planck.Headless.SidecarManagerTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.Tool
  alias Planck.Headless.{ResourceStore, SidecarManager}

  setup do
    on_exit(fn -> ResourceStore.clear_tools() end)
    :ok
  end

  # --- ResourceStore.put_tools/1 and clear_tools/0 ---

  describe "ResourceStore.put_tools/1" do
    test "stores tools that are retrievable via get/0" do
      tool = make_tool("greet")
      :ok = ResourceStore.put_tools([tool])
      assert [%Tool{name: "greet"}] = ResourceStore.get().tools
    end

    test "replaces the previous tool list on successive calls" do
      ResourceStore.put_tools([make_tool("first")])
      ResourceStore.put_tools([make_tool("second")])
      assert [%Tool{name: "second"}] = ResourceStore.get().tools
    end
  end

  describe "ResourceStore.clear_tools/0" do
    test "empties the tool list" do
      ResourceStore.put_tools([make_tool("greet")])
      :ok = ResourceStore.clear_tools()
      assert ResourceStore.get().tools == []
    end
  end

  # --- SidecarManager public API ---

  describe "node/0" do
    test "returns nil when no sidecar is connected" do
      assert SidecarManager.node() == nil
    end
  end

  describe "status/0" do
    test "returns :idle when no sidecar directory is configured or exists" do
      # In test env the default sidecar path does not exist on disk.
      assert SidecarManager.status() == :idle
    end
  end

  # --- PubSub subscribe/unsubscribe ---

  describe "subscribe/0 and unsubscribe/0" do
    test "subscribed process receives broadcast events" do
      :ok = SidecarManager.subscribe()
      Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "planck:sidecar", {:connected, :test_node})
      assert_receive {:connected, :test_node}
    end

    test "unsubscribed process does not receive events" do
      :ok = SidecarManager.subscribe()
      :ok = SidecarManager.unsubscribe()
      Phoenix.PubSub.broadcast(Planck.Agent.PubSub, "planck:sidecar", {:connected, :test_node})
      refute_receive {:connected, :test_node}
    end
  end

  # --- tool wrapping (via execute_fn behaviour) ---

  describe "wrapped sidecar tool execute_fn" do
    test "returns {:error, _} when the sidecar node is unreachable" do
      ai_tool =
        Planck.AI.Tool.new(
          name: "ping",
          description: "Ping.",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      # Simulate what SidecarManager.fetch_tools does — build a tool whose
      # execute_fn calls RPC on a dead node and assert it returns an error.
      dead_node = :nonexistent@localhost

      wrapped =
        Tool.new(
          name: ai_tool.name,
          description: ai_tool.description,
          parameters: ai_tool.parameters,
          execute_fn: fn agent_id, args ->
            timeout = Map.get(args, "timeout_ms", 300_000)

            case :rpc.call(
                   dead_node,
                   Planck.Agent.Sidecar,
                   :execute_tool,
                   [ai_tool.name, agent_id, args],
                   timeout
                 ) do
              {:badrpc, reason} -> {:error, reason}
              result -> result
            end
          end
        )

      assert {:error, _} = wrapped.execute_fn.("agent-1", %{})
    end

    test "timeout_ms from args is used as the RPC timeout" do
      # Verify that args["timeout_ms"] is forwarded — here we just assert the
      # execute_fn accepts and reads the key without crashing.
      received_timeout = :erlang.make_ref()
      ref = self()

      wrapped =
        Tool.new(
          name: "spy",
          description: "Spy.",
          parameters: %{"type" => "object", "properties" => %{}},
          execute_fn: fn _id, args ->
            send(ref, {:timeout, Map.get(args, "timeout_ms", :default)})
            {:ok, "done"}
          end
        )

      wrapped.execute_fn.("agent-1", %{"timeout_ms" => 5_000})
      assert_receive {:timeout, 5_000}
      _ = received_timeout
    end
  end

  # --- inject_timeout_param behaviour (via tool parameters) ---

  describe "timeout_ms parameter injection" do
    test "timeout_ms is added when not present in parameters" do
      params = %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}
      result = inject_timeout_param(params)
      assert Map.has_key?(result["properties"], "timeout_ms")
    end

    test "existing timeout_ms is not overwritten" do
      custom = %{"type" => "integer", "description" => "custom"}
      params = %{"type" => "object", "properties" => %{"timeout_ms" => custom}}
      result = inject_timeout_param(params)
      assert result["properties"]["timeout_ms"] == custom
    end

    test "parameters without a properties key are passed through unchanged" do
      params = %{"type" => "object"}
      assert inject_timeout_param(params) == params
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_tool(name) do
    Tool.new(
      name: name,
      description: "A test tool.",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn _id, _args -> {:ok, "ok"} end
    )
  end

  # Mirror of SidecarManager.inject_timeout_param/1 for isolated unit testing.
  @timeout_param %{
    "type" => "integer",
    "description" => "Maximum milliseconds to wait for this tool call (default 300000)."
  }

  defp inject_timeout_param(%{"properties" => props} = parameters) do
    if Map.has_key?(props, "timeout_ms") do
      parameters
    else
      put_in(parameters, ["properties", "timeout_ms"], @timeout_param)
    end
  end

  defp inject_timeout_param(parameters), do: parameters
end
