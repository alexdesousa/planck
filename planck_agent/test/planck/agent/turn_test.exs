defmodule Planck.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Context, Hooks, Identity, Message, Tool, Turn}
  alias Planck.AI.Model

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defmodule DenyGate do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, _tool, _args), do: {:deny, "denied by gate"}
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

  defp make_tool(name, fun) do
    Tool.new(
      name: name,
      description: "test",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fun
    )
  end

  defp identity, do: Identity.build(id: "a1", model: @model)

  defp context(tools) when is_list(tools), do: Context.build(tools: tools)
  defp context(tool_map) when is_map(tool_map), do: %Context{Context.build([]) | tools: tool_map}

  defp hooks(opts \\ []), do: Hooks.build(opts)

  defp prepare(buffer_calls, tools, hook_opts \\ []) do
    turn =
      Enum.reduce(buffer_calls, Turn.new(), fn call, acc ->
        Turn.append_call(acc, call)
      end)

    Turn.prepare_calls(turn, identity(), context(tools), hooks(hook_opts))
  end

  defp user_messages(count) do
    Enum.map(1..count, fn i -> Message.new(:user, [{:text, "msg #{i}"}]) end)
  end

  describe inspect(&Turn.new/0) do
    test "should return a zeroed turn" do
      turn = Turn.new()

      assert turn.status == :idle
      assert turn.index == 0
      assert turn.checkpoints == []
      assert turn.buffer_text == ""
      assert turn.buffer_thinking == ""
      assert turn.buffer_calls == []
      assert turn.running == %{}
      assert turn.results == []
    end
  end

  describe inspect({&Turn.start_turn/4, &Turn.continue_turn/3}) do
    test "should increment the index and set streaming state" do
      pid = self()
      ref = make_ref()
      turn = Turn.new() |> Turn.start_turn(pid, ref, user_messages(3))

      assert turn.index == 1
      assert turn.stream_task == pid
      assert turn.stream_ref == ref
      assert turn.stream_start == 3
      assert turn.status == :streaming
      assert turn.results == []
      assert turn.running == %{}
    end

    test "should keep the index and update the task" do
      pid = self()
      ref = make_ref()
      turn = Turn.new() |> Turn.start_turn(pid, ref, [])

      pid2 = spawn(fn -> :ok end)
      ref2 = make_ref()
      continued = Turn.continue_turn(turn, pid2, ref2)

      assert continued.index == turn.index
      assert continued.stream_task == pid2
      assert continued.stream_ref == ref2
      assert continued.status == :streaming
    end
  end

  describe inspect({&Turn.push_checkpoint/2, &Turn.rebuild_checkpoints/2}) do
    test "should prepend message length" do
      turn =
        Turn.new()
        |> Turn.push_checkpoint(user_messages(2))
        |> Turn.push_checkpoint(user_messages(5))

      assert turn.checkpoints == [5, 2]
    end

    test "should collect user indices and preserve the index" do
      msgs = [
        Message.new(:user, [{:text, "hi"}]),
        Message.new(:assistant, [{:text, "ok"}]),
        Message.new(:user, [{:text, "again"}])
      ]

      turn =
        Turn.new()
        |> Turn.start_turn(self(), make_ref(), [])
        |> Turn.rebuild_checkpoints(msgs)

      assert turn.checkpoints == [2, 0]
      assert turn.index == 1
    end

    test "should return an empty list without user messages" do
      msgs = [Message.new(:assistant, [{:text, "ok"}])]
      turn = Turn.rebuild_checkpoints(Turn.new(), msgs)
      assert turn.checkpoints == []
    end
  end

  describe inspect({&Turn.append_text/2, &Turn.append_thinking/2, &Turn.append_call/2}) do
    test "should concatenate text and thinking deltas" do
      turn = Turn.new() |> Turn.append_text("hel") |> Turn.append_text("lo")
      assert turn.buffer_text == "hello"

      turn = Turn.new() |> Turn.append_thinking("a") |> Turn.append_thinking("b")
      assert turn.buffer_thinking == "ab"
    end

    test "should accumulate calls in order" do
      turn =
        Turn.new()
        |> Turn.append_call(%{id: "c1", name: "bash", args: %{}})
        |> Turn.append_call(%{id: "c2", name: "bash", args: %{}})

      assert Enum.map(turn.buffer_calls, & &1.id) == ["c1", "c2"]
    end
  end

  describe inspect(&Turn.prepare_calls/4) do
    test "should execute a known tool and track it as runnable" do
      tool = make_tool("echo", fn _agent_id, _call_id, %{"msg" => msg} -> {:ok, msg} end)
      call = %{id: "c1", name: "echo", args: %{"msg" => "hi"}}

      turn = prepare([call], [tool])

      assert turn.buffer_calls == []
      assert turn.status == :executing_tools
      assert %{approved: true, pid: nil} = turn.running["c1"]
      assert {:ok, "hi"} = turn.running["c1"].function.(nil)
    end

    test "should register an error for an unknown tool without consulting the gate" do
      turn = prepare([%{id: "c1", name: "noop", args: %{}}], [])

      assert %{approved: true} = turn.running["c1"]
      assert {:error, msg} = turn.running["c1"].function.(nil)
      assert msg =~ "unknown tool"
    end

    test "should prepare multiple buffered calls in order" do
      tool = make_tool("echo", fn _, _, %{"msg" => msg} -> {:ok, msg} end)

      turn =
        prepare(
          [
            %{id: "c1", name: "echo", args: %{"msg" => "a"}},
            %{id: "c2", name: "echo", args: %{"msg" => "b"}}
          ],
          [tool]
        )

      assert Map.keys(turn.running) |> Enum.sort() == ["c1", "c2"]
      assert {:ok, "a"} = turn.running["c1"].function.(nil)
      assert {:ok, "b"} = turn.running["c2"].function.(nil)
    end

    test "should return an error when argument validation fails" do
      tool = make_tool("strict", fn _a, _c, _args -> {:ok, "ok"} end)

      tool = %{
        tool
        | parameters: %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "string"}},
            "required" => ["x"]
          }
      }

      turn = prepare([%{id: "c1", name: "strict", args: %{}}], [tool])

      assert {:error, _reason} = turn.running["c1"].function.(nil)
    end

    test "should catch exceptions and return an error string" do
      tool = make_tool("boom", fn _a, _c, _args -> raise "kaboom" end)
      turn = prepare([%{id: "c1", name: "boom", args: %{}}], [tool])

      assert {:error, msg} = turn.running["c1"].function.(nil)
      assert msg =~ "kaboom"
    end

    test "should park calls when the gate awaits approval" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)
      turn = prepare([%{id: "c1", name: "bash", args: %{}}], [tool], tool_start_hook: ParkGate)

      assert %{
               approved: false,
               pid: nil,
               metadata: %{reason: "needs a human", kind: :await_approval}
             } =
               turn.running["c1"]

      assert [%{approved: false}] = Turn.list_pending(turn)
      refute Turn.tool_done?(turn)
    end

    test "should register denied calls with a blocked error" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)
      turn = prepare([%{id: "c1", name: "bash", args: %{}}], [tool], tool_start_hook: DenyGate)

      assert %{approved: true, metadata: %{reason: "denied by gate", kind: :deny}} =
               turn.running["c1"]

      assert {:error, msg} = turn.running["c1"].function.("denied by gate")
      assert msg =~ "denied by gate"
      assert msg =~ "Do not attempt to work around"
      assert Turn.list_pending(turn) == []
    end

    test "should apply the ToolEnd transform to results" do
      tool = make_tool("echo", fn _, _, %{"msg" => msg} -> {:ok, msg} end)

      turn =
        prepare([%{id: "c1", name: "echo", args: %{"msg" => "hi"}}], [tool],
          tool_end_hook: UpperTransform
        )

      assert {:ok, "HI"} = turn.running["c1"].function.(nil)
    end
  end

  describe inspect({&Turn.approve_pending/2, &Turn.deny_pending/3}) do
    test "should approve a parked call one-shot" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)
      turn = prepare([%{id: "c1", name: "bash", args: %{}}], [tool], tool_start_hook: ParkGate)

      assert {:ok, {entry, approved}} = Turn.approve_pending(turn, "c1")
      assert entry.approved == true
      assert {:ok, "ran"} = approved.running["c1"].function.(nil)

      assert {:error, :not_found} = Turn.approve_pending(approved, "c1")
      assert {:error, :not_found} = Turn.deny_pending(approved, "c1", "nope")
    end

    test "should deny a parked call with a blocked error" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)
      turn = prepare([%{id: "c1", name: "bash", args: %{}}], [tool], tool_start_hook: ParkGate)

      assert {:ok, {_entry, denied}} = Turn.deny_pending(turn, "c1", "nope")
      assert {:error, msg} = denied.running["c1"].function.("nope")
      assert msg =~ "nope"

      assert {:error, :not_found} = Turn.approve_pending(denied, "c1")
    end

    test "should return :not_found for unknown call ids" do
      assert {:error, :not_found} = Turn.approve_pending(Turn.new(), "ghost")
      assert {:error, :not_found} = Turn.deny_pending(Turn.new(), "ghost", "reason")
    end

    test "should not approve already-runnable calls" do
      tool = make_tool("echo", fn _, _, _ -> {:ok, "ok"} end)
      turn = prepare([%{id: "c1", name: "echo", args: %{}}], [tool])

      assert {:error, :not_found} = Turn.approve_pending(turn, "c1")
      assert {:error, :not_found} = Turn.deny_pending(turn, "c1", "reason")
    end
  end

  describe inspect(
             {&Turn.list_pending/1, &Turn.register_running/3, &Turn.mark_tool_done/3,
              &Turn.tool_done?/1}
           ) do
    test "should list only parked entries" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)

      turn =
        prepare(
          [
            %{id: "c1", name: "bash", args: %{}},
            %{id: "c2", name: "bash", args: %{}}
          ],
          [tool],
          tool_start_hook: ParkGate
        )

      assert length(Turn.list_pending(turn)) == 2

      {:ok, {_entry, turn}} = Turn.approve_pending(turn, "c1")
      assert length(Turn.list_pending(turn)) == 1
    end

    test "should register running pids and mark them done in order" do
      tool = make_tool("echo", fn _, _, _ -> {:ok, "ok"} end)
      turn = prepare([%{id: "c1", name: "echo", args: %{}}], [tool])

      pid = spawn(fn -> Process.sleep(5_000) end)
      turn = Turn.register_running(turn, "c1", pid)
      assert turn.running["c1"].pid == pid
      assert turn.running["c1"].approved == true
      refute Turn.tool_done?(turn)

      assert {:ok, updated} = Turn.mark_tool_done(turn, "c1", {:ok, "out"})
      assert updated.running == %{}
      assert [{"c1", %{result: {:ok, "out"}}}] = updated.results
      assert Turn.tool_done?(updated)

      Process.exit(pid, :kill)
    end

    test "should return {:error, :not_running} for an unknown call id" do
      assert Turn.mark_tool_done(Turn.new(), "unknown", {:ok, "x"}) == {:error, :not_running}
    end
  end

  describe inspect(&Turn.reset_streaming/2) do
    test "should clear buffers and running state but keep calls by default" do
      tool = make_tool("bash", fn _, _, _ -> {:ok, "ran"} end)

      turn =
        Turn.new()
        |> Turn.append_text("hi")
        |> Turn.append_thinking("think")
        |> Turn.append_call(%{id: "c1", name: "bash", args: %{}})
        |> then(&Turn.prepare_calls(&1, identity(), context([tool]), hooks()))
        |> Turn.reset_streaming()

      assert turn.status == :idle
      assert turn.stream_task == nil
      assert turn.stream_ref == nil
      assert turn.buffer_text == ""
      assert turn.buffer_thinking == ""
      assert turn.buffer_calls == []
      assert turn.running == %{}
      assert turn.results == []
    end

    test "should drop buffered calls with include_calls" do
      turn =
        Turn.new()
        |> Turn.append_call(%{id: "c1", name: "bash", args: %{}})
        |> Turn.reset_streaming(include_calls: true)

      assert turn.buffer_calls == []
    end
  end

  describe inspect(&Turn.abort/1) do
    test "should kill running tool processes and reset streaming" do
      tool = make_tool("echo", fn _, _, _ -> {:ok, "ok"} end)
      turn = prepare([%{id: "c1", name: "echo", args: %{}}], [tool])

      pid = spawn(fn -> Process.sleep(5_000) end)
      turn = Turn.register_running(turn, "c1", pid)
      ref = Process.monitor(pid)

      aborted = Turn.abort(%{turn | stream_task: nil})
      assert aborted.status == :idle
      assert aborted.running == %{}

      assert_receive {:DOWN, ^ref, _, _, _}, 1_000
    end
  end
end
