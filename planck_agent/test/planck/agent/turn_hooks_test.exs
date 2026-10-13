defmodule Planck.Agent.TurnHooksTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.{Context, Hooks, Identity, Tool, Turn}
  alias Planck.AI.Model

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defp make_tool(name, fun, parameters \\ %{"type" => "object", "properties" => %{}}) do
    Tool.new(name: name, description: "test", parameters: parameters, execute_fn: fun)
  end

  defp identity, do: Identity.build(id: "a1", model: @model)

  defp prepare(call, tools, hook_opts \\ []) do
    turn = Turn.append_call(Turn.new(), call)
    ctx = Context.build(tools: tools)
    Turn.prepare_calls(turn, identity(), ctx, Hooks.build(hook_opts))
  end

  defmodule CountingDenyGate do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, _tool, _args) do
      if counter = :persistent_term.get({__MODULE__, :counter}, nil) do
        :counters.add(counter, 1, 1)
      end

      {:deny, "denied by gate"}
    end
  end

  defmodule ParkGate do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, _tool, _args), do: {:await_approval, "needs a human"}
  end

  defmodule UpperTransform do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, {:ok, text}), do: {:ok, String.upcase(text)}
    def transform(_agent_id, _tool, _args, result), do: result
  end

  defmodule ErrorUiTransform do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, {:error, reason}) do
      {:error, reason, %{ui: %{kind: :text, text: "fix it"}}}
    end

    def transform(_agent_id, _tool, _args, {:error, reason, _}) do
      {:error, reason, %{ui: %{kind: :text, text: "fix it"}}}
    end

    def transform(_agent_id, _tool, _args, result), do: result
  end

  defmodule SlowGate do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed_timeout, do: 50

    @impl true
    def proceed(_agent_id, _tool, _args) do
      Process.sleep(500)
      {:deny, "too slow"}
    end
  end

  setup do
    counter = :counters.new(1, [])
    :persistent_term.put({CountingDenyGate, :counter}, counter)

    on_exit(fn -> :persistent_term.erase({CountingDenyGate, :counter}) end)

    %{counter: counter}
  end

  describe "prepare_calls/4 with empty hooks" do
    test "unconfigured hooks register a runnable call" do
      tool = make_tool("echo", fn _, _, %{"msg" => msg} -> {:ok, msg} end)
      call = %{id: "c1", name: "echo", args: %{"msg" => "hi"}}

      turn = prepare(call, [tool])

      assert turn.buffer_calls == []
      assert %{approved: true, pid: nil} = turn.running["c1"]
      assert {:ok, "hi"} = turn.running["c1"].function.(nil)
    end
  end

  describe "validate-first ordering" do
    test "schema-invalid calls never consult the gate", %{counter: counter} do
      tool =
        make_tool("strict", fn _, _, _ -> {:ok, "ok"} end, %{
          "type" => "object",
          "properties" => %{"x" => %{"type" => "string"}},
          "required" => ["x"]
        })

      turn =
        prepare(%{id: "c1", name: "strict", args: %{}}, [tool], tool_start_hook: CountingDenyGate)

      assert {:error, _reason} = turn.running["c1"].function.(nil)
      assert :counters.get(counter, 1) == 0
    end

    test "unknown tools never consult the gate", %{counter: counter} do
      turn = prepare(%{id: "c1", name: "ghost", args: %{}}, [], tool_start_hook: CountingDenyGate)

      assert {:error, msg} = turn.running["c1"].function.(nil)
      assert msg =~ "unknown tool"
      assert :counters.get(counter, 1) == 0
    end
  end

  describe "ToolStart deny" do
    test "execute_fn never runs and the error carries the reason plus the notice" do
      parent = self()

      tool =
        make_tool("bash", fn _, _, _ ->
          send(parent, :executed)
          {:ok, "ran"}
        end)

      turn =
        prepare(
          %{id: "c1", name: "bash", args: %{"command" => "rm -rf /"}},
          [tool],
          tool_start_hook: CountingDenyGate
        )

      assert %{approved: true, metadata: %{kind: :deny}} = turn.running["c1"]
      assert {:error, msg} = turn.running["c1"].function.("denied by gate")
      assert msg =~ "denied by gate"
      assert msg =~ "work around"
      refute_received :executed
    end
  end

  describe "ToolStart await_approval" do
    test "parks the call for human approval" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)
      turn = prepare(%{id: "c1", name: "bash", args: %{}}, [tool], tool_start_hook: ParkGate)

      assert %{
               approved: false,
               pid: nil,
               metadata: %{reason: "needs a human", kind: :await_approval}
             } =
               turn.running["c1"]

      assert [%{approved: false}] = Turn.list_pending(turn)
    end

    test "approved parked calls run, denied ones return the human reason" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)
      turn = prepare(%{id: "c1", name: "bash", args: %{}}, [tool], tool_start_hook: ParkGate)

      assert {:ok, {_entry, approved}} = Turn.approve_pending(turn, "c1")
      assert {:ok, "ran"} = approved.running["c1"].function.(nil)

      turn = prepare(%{id: "c2", name: "bash", args: %{}}, [tool], tool_start_hook: ParkGate)
      assert {:ok, {_entry, denied}} = Turn.deny_pending(turn, "c2", "human says no")
      assert {:error, msg} = denied.running["c2"].function.("human says no")
      assert msg =~ "human says no"
    end
  end

  describe "ToolEnd transform" do
    test "rewrites ok text after execution" do
      tool = make_tool("echo", fn _, _, _ -> {:ok, "hi"} end)
      turn = prepare(%{id: "c1", name: "echo", args: %{}}, [tool], tool_end_hook: UpperTransform)

      assert {:ok, "HI"} = turn.running["c1"].function.(nil)
    end

    test "attaches UI to an error as an error triple" do
      tool = make_tool("bad", fn _, _, _ -> {:error, "nope"} end)
      turn = prepare(%{id: "c1", name: "bad", args: %{}}, [tool], tool_end_hook: ErrorUiTransform)

      assert {:error, "nope", %{ui: %{kind: :text, text: "fix it"}}} =
               turn.running["c1"].function.(nil)
    end

    test "denied errors pass through the transform" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)

      turn =
        prepare(%{id: "c1", name: "bash", args: %{}}, [tool],
          tool_start_hook: CountingDenyGate,
          tool_end_hook: ErrorUiTransform
        )

      assert {:error, msg, %{ui: %{kind: :text, text: "fix it"}}} =
               turn.running["c1"].function.("denied by gate")

      assert msg =~ "denied by gate"
    end
  end

  describe "fail-open" do
    test "a slow gate proceeds with the original args via RPC timeout" do
      parent = self()

      tool =
        make_tool("bash", fn _, _, args ->
          send(parent, {:args, args})
          {:ok, "ran"}
        end)

      turn =
        Turn.prepare_calls(
          Turn.append_call(Turn.new(), %{id: "c1", name: "bash", args: %{"command" => "ls"}}),
          identity(),
          Context.build(tools: [tool]),
          %Hooks{tool_start: SlowGate, sidecar_node: Node.self()}
        )

      assert %{approved: true} = turn.running["c1"]
      assert {:ok, "ran"} = turn.running["c1"].function.(nil)
      assert_received {:args, %{"command" => "ls"}}
    end

    test "an unreachable sidecar proceeds untransformed" do
      tool = make_tool("echo", fn _, _, _ -> {:ok, "hi"} end)

      turn =
        Turn.prepare_calls(
          Turn.append_call(Turn.new(), %{id: "c1", name: "echo", args: %{}}),
          identity(),
          Context.build(tools: [tool]),
          %Hooks{
            tool_start: CountingDenyGate,
            tool_end: UpperTransform,
            sidecar_node: :nonexistent@localhost
          }
        )

      assert %{approved: true} = turn.running["c1"]
      assert {:ok, "hi"} = turn.running["c1"].function.(nil)
    end
  end
end
