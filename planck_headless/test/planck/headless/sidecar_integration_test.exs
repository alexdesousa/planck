defmodule Planck.Headless.SidecarIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Planck.Agent
  alias Planck.Agent.Hooks.Compactor
  alias Planck.Agent.Message
  alias Planck.AI.{Context, Model}
  alias Planck.Headless.{Config, Locale, ResourceStore, SidecarManager, Widgets}

  @sidecar_dir Path.expand("../../../test_sidecar", __DIR__)

  # ---------------------------------------------------------------------------
  # Suite setup — let SidecarManager own the full lifecycle
  # ---------------------------------------------------------------------------

  setup_all do
    unless Node.alive?() do
      raise """
      Integration tests require a distributed node. Run with:

          mix test.integration
      """
    end

    # Pre-build the sidecar outside SidecarManager so the GenServer's own
    # build step is just a fast incremental compile (avoids blocking GenServer.stop).
    t0 = System.monotonic_time(:millisecond)
    pre_build_sidecar!(@sidecar_dir)
    IO.puts("pre_build took #{System.monotonic_time(:millisecond) - t0}ms")

    # Subscribe before restarting so we don't miss the :connected event.
    SidecarManager.subscribe()

    # Point SidecarManager at the test sidecar and restart it.
    Application.put_env(:planck, :sidecar, @sidecar_dir)
    Config.reload_sidecar()
    restart_sidecar_manager!()

    # Wait for SidecarManager to build, spawn, and connect (~5s after pre-build).
    receive do
      {:connected, _node} -> :ok
    after
      60_000 -> raise "SidecarManager did not reach :connected within 60s"
    end

    on_exit(fn ->
      Application.delete_env(:planck, :sidecar)
      Config.reload_sidecar()
      restart_sidecar_manager!()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tools in ResourceStore
  # ---------------------------------------------------------------------------

  describe "tools after sidecar connects" do
    test "echo tool is available in ResourceStore" do
      tools = ResourceStore.get().tools
      assert Enum.any?(tools, &(&1.name == "echo"))
    end

    test "timeout_ms is injected into tool parameters" do
      tool = Enum.find(ResourceStore.get().tools, &(&1.name == "echo"))
      assert Map.has_key?(tool.parameters["properties"], "timeout_ms")
    end

    test "SidecarManager reports :connected status" do
      assert SidecarManager.status() == :connected
    end

    test "SidecarManager.node/0 returns the sidecar node" do
      node = SidecarManager.node()
      assert is_atom(node)
      assert node |> Atom.to_string() |> String.starts_with?("planck_sidecar")
    end
  end

  # ---------------------------------------------------------------------------
  # Tool execution via wrapped execute_fn
  # ---------------------------------------------------------------------------

  describe "sidecar tool execution" do
    test "echo returns the message" do
      tool = Enum.find(ResourceStore.get().tools, &(&1.name == "echo"))
      assert {:ok, "hello"} = tool.execute_fn.("agent-1", "tc-1", %{"message" => "hello"})
    end

    test "timeout_ms in args is forwarded as the RPC timeout" do
      tool = Enum.find(ResourceStore.get().tools, &(&1.name == "echo"))

      assert {:ok, "fast"} =
               tool.execute_fn.("agent-1", "tc-2", %{"message" => "fast", "timeout_ms" => 5_000})
    end

    test "unknown tool returns an error via direct RPC" do
      node = SidecarManager.node()

      assert {:error, "unknown tool: ghost"} =
               :rpc.call(
                 node,
                 Planck.Agent.Sidecar,
                 :execute_tool,
                 ["ghost", "agent-1", "tc-3", %{}],
                 10_000
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Widgets via Planck.Headless.Widgets (real RPC to the connected sidecar)
  # ---------------------------------------------------------------------------

  describe "Widgets.list/0" do
    test "returns the widget module paired with tool_with_widget" do
      assert Widgets.list() == [PlanckTestSidecar.Widgets.Counter]
    end
  end

  describe "Widgets.render/2" do
    test "renders via the real sidecar-side widget module, passing myself through opaquely" do
      assert {:ok, rendered} = Widgets.render("counter", 42)
      assert rendered =~ "myself=42"
    end

    test "returns an error for an unknown widget" do
      assert {:error, "unknown widget: ghost"} = Widgets.render("ghost", nil)
    end
  end

  describe "Widgets.dispatch_action/3" do
    test "mutates the widget's state on the sidecar node" do
      {:ok, before_render} = Widgets.render("counter", nil)
      assert :ok = Widgets.dispatch_action("counter", "increment", %{})
      {:ok, after_render} = Widgets.render("counter", nil)
      refute before_render == after_render
    end

    test "returns the widget's error result" do
      assert {:error, "intentional"} = Widgets.dispatch_action("counter", "boom", %{})
    end

    test "returns an error for an unknown widget" do
      assert {:error, "unknown widget: ghost"} =
               Widgets.dispatch_action("ghost", "increment", %{})
    end
  end

  describe "Widgets.container/1" do
    test "defaults to :modal for a widget that doesn't implement container/0" do
      assert {:ok, :modal} = Widgets.container("counter")
    end

    test "returns an error for an unknown widget" do
      assert {:error, "unknown widget: ghost"} = Widgets.container("ghost")
    end
  end

  # ---------------------------------------------------------------------------
  # Locale.set/1 (real RPC to the connected sidecar)
  # ---------------------------------------------------------------------------

  describe "Locale.set/1" do
    test "the sidecar node's Planck.Agent.Sidecar.get_locale/0 reflects the pushed value" do
      node = SidecarManager.node()

      assert :ok = Locale.set("es")
      assert :rpc.call(node, Planck.Agent.Sidecar, :get_locale, []) == "es"

      assert :ok = Locale.set("en")
      assert :rpc.call(node, Planck.Agent.Sidecar, :get_locale, []) == "en"
    end
  end

  # ---------------------------------------------------------------------------
  # Remote compaction
  # ---------------------------------------------------------------------------

  describe "remote compaction" do
    @model %Model{
      id: "test",
      provider: :ollama,
      context_window: 1_000,
      max_tokens: 512
    }

    test "delegates compaction to the sidecar compactor" do
      module = :"Elixir.PlanckTestSidecar.Compactor"

      messages =
        Enum.map(1..20, &Message.new(:user, [{:text, String.duplicate("x", 200) <> " #{&1}"}]))

      state = %Agent{
        id: "test",
        model: @model,
        messages: messages,
        compactor: module,
        sidecar_node: SidecarManager.node()
      }

      context = %Context{messages: Message.to_ai_messages(messages)}

      assert {:compact, %Message{content: [{:text, "Test summary."}]}, kept} =
               Compactor.compact(state, context, messages)

      assert length(kept) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp pre_build_sidecar!(dir) do
    env =
      Enum.flat_map(["PATH", "MIX_ENV"], fn k ->
        case System.get_env(k) do
          nil -> []
          v -> [{to_charlist(k), to_charlist(v)}]
        end
      end)

    opts = [{:cd, to_charlist(dir)}, {:env, env}, :sync, :stdout, :stderr]

    case :exec.run("mix deps.get", opts) do
      {:ok, _} -> :ok
      {:error, d} -> raise "mix deps.get failed: #{inspect(d)}"
    end

    case :exec.run("mix compile", opts) do
      {:ok, _} -> :ok
      {:error, d} -> raise "mix compile failed: #{inspect(d)}"
    end
  end

  defp restart_sidecar_manager! do
    GenServer.stop(SidecarManager, :normal, :infinity)
    # Yield until the supervisor has restarted the GenServer.
    Stream.repeatedly(fn -> Process.sleep(100) end)
    |> Enum.find(fn _ -> Process.whereis(SidecarManager) != nil end)
  end
end
