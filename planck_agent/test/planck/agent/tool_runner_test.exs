defmodule Planck.Agent.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.ToolRunner

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
