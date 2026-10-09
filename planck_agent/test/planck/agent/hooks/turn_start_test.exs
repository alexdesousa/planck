defmodule Planck.Agent.Hooks.TurnStartTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.Hooks.TurnStart

  defmodule DefaultHook do
    use Planck.Agent.Hooks.TurnStart
  end

  defmodule CustomTimeoutHook do
    use Planck.Agent.Hooks.TurnStart

    @impl true
    def notify_timeout, do: 60_000
  end

  defmodule RecordingHook do
    use Planck.Agent.Hooks.TurnStart

    @impl true
    def notify(agent_id, session_id) do
      if parent = :persistent_term.get({__MODULE__, :parent}, nil) do
        send(parent, {:turn_started, agent_id, session_id})
      end

      :ok
    end
  end

  defmodule SlowHook do
    use Planck.Agent.Hooks.TurnStart

    @impl true
    def notify_timeout, do: 50

    @impl true
    def notify(_agent_id, _session_id) do
      Process.sleep(500)
      :ok
    end
  end

  describe "use Planck.Agent.Hooks.TurnStart" do
    test "provides default notify/2 returning :ok" do
      assert DefaultHook.notify("a1", "s1") == :ok
    end

    test "provides default notify_timeout/0" do
      assert DefaultHook.notify_timeout() == TurnStart.default_timeout()
    end

    test "notify_timeout/0 can be overridden" do
      assert CustomTimeoutHook.notify_timeout() == 60_000
    end
  end

  describe "notify/4 with nil module" do
    test "returns :ok immediately" do
      assert TurnStart.notify(nil, "a1", "s1", nil) == :ok
    end
  end

  describe "notify/4 local dispatch" do
    setup do
      :persistent_term.put({RecordingHook, :parent}, self())

      on_exit(fn -> :persistent_term.erase({RecordingHook, :parent}) end)
    end

    test "forwards agent_id and session_id" do
      assert TurnStart.notify(RecordingHook, "a1", "s1", nil) == :ok
      assert_received {:turn_started, "a1", "s1"}
    end

    test "nil session_id is forwarded as nil" do
      assert TurnStart.notify(RecordingHook, "a1", nil, nil) == :ok
      assert_received {:turn_started, "a1", nil}
    end
  end

  describe "notify/4 remote dispatch" do
    test "dispatches via RPC on the same node" do
      assert TurnStart.notify(DefaultHook, "a1", "s1", Node.self()) == :ok
    end

    test "returns :ok when RPC fails (bad node)" do
      assert TurnStart.notify(DefaultHook, "a1", "s1", :nonexistent@localhost) == :ok
    end

    test "a slow observer still returns :ok" do
      assert TurnStart.notify(SlowHook, "a1", "s1", Node.self()) == :ok
    end
  end
end
