defmodule Planck.Agent.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Tool, ToolRunner}

  defp make_tool(name, fun) do
    Tool.new(
      name: name,
      description: "test",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fun
    )
  end

  describe "new/0" do
    test "returns empty runner" do
      r = ToolRunner.new()
      assert r.running == %{}
      assert r.results == []
    end
  end

  describe "start/1" do
    test "registers running entries" do
      pid = self()
      r = ToolRunner.start([{"c1", "bash", pid}])
      assert map_size(r.running) == 1
      assert r.running["c1"].name == "bash"
      assert r.running["c1"].pid == pid
    end
  end

  describe "mark_done/3" do
    test "removes from running and adds to results" do
      pid = self()
      r = ToolRunner.start([{"c1", "bash", pid}])
      assert {:ok, updated} = ToolRunner.mark_done(r, "c1", {:ok, "output"})
      assert map_size(updated.running) == 0
      assert [{"c1", {:ok, "output"}}] = updated.results
    end

    test "returns :not_running for unknown call_id" do
      r = ToolRunner.new()
      assert ToolRunner.mark_done(r, "unknown", {:ok, "x"}) == :not_running
    end
  end

  describe "next_batch/2" do
    test "resets running and results but preserves loop_counts" do
      pid = self()
      runner = ToolRunner.start([{"c1", "bash", pid}])
      {:ok, runner} = ToolRunner.mark_done(runner, "c1", {:ok, "x"})
      runner = %{runner | loop_counts: %{{"bash", 0} => 2}}

      runner = ToolRunner.next_batch(runner, [{"c2", "read", pid}])

      assert map_size(runner.running) == 1
      assert runner.results == []
      assert runner.loop_counts == %{{"bash", 0} => 2}
    end
  end

  describe "prepare_call/6" do
    test "executes a known tool and returns its result" do
      tool = make_tool("echo", fn _agent_id, _call_id, %{"msg" => msg} -> {:ok, msg} end)
      tools = %{"echo" => tool}

      {_runner, wrapped} =
        ToolRunner.prepare_call(ToolRunner.new(), tools, "a1", "echo", "c1", %{"msg" => "hi"})

      assert {:ok, "hi"} = wrapped.()
    end

    test "returns error for unknown tool" do
      {_runner, wrapped} = ToolRunner.prepare_call(ToolRunner.new(), %{}, "a1", "noop", "c1", %{})

      assert {:error, msg} = wrapped.()
      assert msg =~ "unknown tool"
    end

    test "returns error when argument validation fails" do
      tool = make_tool("strict", fn _a, _c, _args -> {:ok, "ok"} end)

      tool = %{
        tool
        | parameters: %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "string"}},
            "required" => ["x"]
          }
      }

      tools = %{"strict" => tool}

      {_runner, wrapped} =
        ToolRunner.prepare_call(ToolRunner.new(), tools, "a1", "strict", "c1", %{})

      assert {:error, _reason} = wrapped.()
    end

    test "catches exceptions and returns error string" do
      tool = make_tool("boom", fn _a, _c, _args -> raise "kaboom" end)
      tools = %{"boom" => tool}

      {_runner, wrapped} =
        ToolRunner.prepare_call(ToolRunner.new(), tools, "a1", "boom", "c1", %{})

      assert {:error, msg} = wrapped.()
      assert msg =~ "kaboom"
    end

    test "increments loop_counts on each call" do
      tool = make_tool("rep", fn _a, _c, _args -> {:ok, "x"} end)
      tools = %{"rep" => tool}
      args = %{}

      {runner, _} = ToolRunner.prepare_call(ToolRunner.new(), tools, "a1", "rep", "c1", args)
      {runner, _} = ToolRunner.prepare_call(runner, tools, "a1", "rep", "c2", args)
      {runner, _} = ToolRunner.prepare_call(runner, tools, "a1", "rep", "c3", args)

      key = {"rep", :erlang.phash2(args)}
      assert runner.loop_counts[key] == 3
    end

    test "appends nudge at threshold" do
      tool = make_tool("rep", fn _a, _c, _args -> {:ok, "result"} end)
      tools = %{"rep" => tool}
      args = %{}

      {runner, _} = ToolRunner.prepare_call(ToolRunner.new(), tools, "a1", "rep", "c1", args)
      {runner, _} = ToolRunner.prepare_call(runner, tools, "a1", "rep", "c2", args)
      {_runner, wrapped} = ToolRunner.prepare_call(runner, tools, "a1", "rep", "c3", args)

      assert {:ok, result} = wrapped.()
      assert result =~ "result"
      assert result =~ "3 times"
    end

    test "no nudge below threshold" do
      tool = make_tool("rep", fn _a, _c, _args -> {:ok, "result"} end)
      tools = %{"rep" => tool}
      args = %{}

      {runner, _} = ToolRunner.prepare_call(ToolRunner.new(), tools, "a1", "rep", "c1", args)
      {_runner, wrapped} = ToolRunner.prepare_call(runner, tools, "a1", "rep", "c2", args)

      assert {:ok, "result"} = wrapped.()
    end

    test "different args do not accumulate for loop detection" do
      tool = make_tool("rep", fn _a, _c, _args -> {:ok, "result"} end)
      tools = %{"rep" => tool}

      {runner, _} =
        ToolRunner.prepare_call(ToolRunner.new(), tools, "a1", "rep", "c1", %{"x" => 1})

      {runner, _} = ToolRunner.prepare_call(runner, tools, "a1", "rep", "c2", %{"x" => 2})
      {_runner, wrapped} = ToolRunner.prepare_call(runner, tools, "a1", "rep", "c3", %{"x" => 3})

      assert {:ok, "result"} = wrapped.()
    end
  end

  describe "done?/1" do
    test "returns true when running is empty" do
      assert ToolRunner.done?(ToolRunner.new())
    end

    test "returns false when tools are still running" do
      r = ToolRunner.start([{"c1", "bash", self()}])
      refute ToolRunner.done?(r)
    end

    test "returns true after all tools complete" do
      r = ToolRunner.start([{"c1", "bash", self()}])
      {:ok, r} = ToolRunner.mark_done(r, "c1", {:ok, "x"})
      assert ToolRunner.done?(r)
    end
  end
end
