defmodule Planck.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Message, Tool, Turn}

  defp make_tool(name, fun) do
    Tool.new(
      name: name,
      description: "test",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fun
    )
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
      assert turn.loop_counts == %{}
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

  describe inspect(&Turn.prepare_call/4) do
    test "should execute a known tool and return its result" do
      tool = make_tool("echo", fn _agent_id, _call_id, %{"msg" => msg} -> {:ok, msg} end)

      {_turn, wrapped} =
        Turn.prepare_call(Turn.new(), %{"echo" => tool}, "a1", %{
          id: "c1",
          name: "echo",
          args: %{"msg" => "hi"}
        })

      assert {:ok, "hi"} = wrapped.()
    end

    test "should return an error for an unknown tool" do
      {turn, wrapped} =
        Turn.prepare_call(Turn.new(), %{}, "a1", %{id: "c1", name: "noop", args: %{}})

      assert {:error, msg} = wrapped.()
      assert msg =~ "unknown tool"
      assert turn.loop_counts == %{{"noop", :erlang.phash2(%{})} => 1}
    end

    test "should increment loop counts and nudge from the third identical call" do
      tool = make_tool("echo", fn _, _, _ -> {:ok, "same"} end)
      tools = %{"echo" => tool}
      call = %{id: "c1", name: "echo", args: %{"x" => 1}}

      {turn1, w1} = Turn.prepare_call(Turn.new(), tools, "a1", call)
      assert {:ok, "same"} = w1.()

      {turn2, w2} = Turn.prepare_call(turn1, tools, "a1", call)
      assert {:ok, "same"} = w2.()

      {_turn3, w3} = Turn.prepare_call(turn2, tools, "a1", call)
      assert {:ok, nudged} = w3.()
      assert nudged =~ "you have called `echo`"
    end

    test "should preserve the ui payload when nudging" do
      ui = %{kind: :text, text: "note"}
      tool = make_tool("echo", fn _, _, _ -> {:ok, "same", %{ui: ui}} end)
      tools = %{"echo" => tool}
      call = %{id: "c1", name: "echo", args: %{}}

      {t1, _} = Turn.prepare_call(Turn.new(), tools, "a1", call)
      {t2, _} = Turn.prepare_call(t1, tools, "a1", call)
      {_t3, w3} = Turn.prepare_call(t2, tools, "a1", call)

      assert {:ok, text, %{ui: ^ui}} = w3.()
      assert text =~ "you have called `echo`"
    end

    test "should never nudge error results" do
      tool = make_tool("bad", fn _, _, _ -> {:error, "nope"} end)
      tools = %{"bad" => tool}
      call = %{id: "c1", name: "bad", args: %{}}

      {t1, _} = Turn.prepare_call(Turn.new(), tools, "a1", call)
      {t2, _} = Turn.prepare_call(t1, tools, "a1", call)
      {_t3, w3} = Turn.prepare_call(t2, tools, "a1", call)

      assert {:error, "nope"} = w3.()
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

      {_turn, wrapped} =
        Turn.prepare_call(Turn.new(), %{"strict" => tool}, "a1", %{
          id: "c1",
          name: "strict",
          args: %{}
        })

      assert {:error, _reason} = wrapped.()
    end

    test "should catch exceptions and return an error string" do
      tool = make_tool("boom", fn _a, _c, _args -> raise "kaboom" end)

      {_turn, wrapped} =
        Turn.prepare_call(Turn.new(), %{"boom" => tool}, "a1", %{
          id: "c1",
          name: "boom",
          args: %{}
        })

      assert {:error, msg} = wrapped.()
      assert msg =~ "kaboom"
    end

    test "should track separate loop counts for different args" do
      tool = make_tool("echo", fn _, _, _ -> {:ok, "same"} end)
      tools = %{"echo" => tool}

      {turn, _} =
        Turn.prepare_call(Turn.new(), tools, "a1", %{id: "c1", name: "echo", args: %{"x" => 1}})

      {turn, _} =
        Turn.prepare_call(turn, tools, "a1", %{id: "c2", name: "echo", args: %{"x" => 2}})

      assert map_size(turn.loop_counts) == 2
    end
  end

  describe inspect({&Turn.register_call/3, &Turn.mark_tool_done/3, &Turn.tool_done?/1}) do
    test "should register running entries and mark them done" do
      pid = self()
      turn = Turn.register_call(Turn.new(), %{id: "c1", name: "bash", args: %{}}, pid)

      assert turn.status == :executing_tools
      assert turn.running["c1"].name == "bash"
      assert turn.running["c1"].pid == pid
      refute Turn.tool_done?(turn)

      assert {:ok, updated} = Turn.mark_tool_done(turn, "c1", {:ok, "out"})
      assert updated.running == %{}
      assert [{"c1", {:ok, "out"}}] = updated.results
      assert Turn.tool_done?(updated)
    end

    test "should return :not_running for an unknown call id" do
      assert Turn.mark_tool_done(Turn.new(), "unknown", {:ok, "x"}) == :not_running
    end
  end

  describe inspect(&Turn.reset_streaming/1) do
    test "should clear buffers, running state, and loop counts" do
      turn =
        Turn.new()
        |> Turn.append_text("hi")
        |> Turn.append_thinking("think")
        |> Turn.append_call(%{id: "c1", name: "bash", args: %{}})
        |> Turn.register_call(%{id: "c1", name: "bash", args: %{}}, self())
        |> Turn.reset_streaming()

      assert turn.status == :idle
      assert turn.stream_task == nil
      assert turn.stream_ref == nil
      assert turn.buffer_text == ""
      assert turn.buffer_thinking == ""
      assert turn.buffer_calls == []
      assert turn.running == %{}
      assert turn.results == []
      assert turn.loop_counts == %{}
    end
  end

  describe inspect({&Turn.cancel_stream/1, &Turn.cancel_all_tools/1}) do
    test "should no-op without a stream task" do
      assert Turn.cancel_stream(Turn.new()) == :ok
    end

    test "should kill tracked tool processes" do
      pid = spawn(fn -> Process.sleep(5_000) end)
      turn = Turn.register_call(Turn.new(), %{id: "c1", name: "bash", args: %{}}, pid)

      assert :ok = Turn.cancel_all_tools(turn)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}, 1_000
    end
  end
end
