defmodule Planck.Agent.Hooks.ToolStartTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.Hooks.ToolStart

  defmodule DefaultHook do
    use Planck.Agent.Hooks.ToolStart
  end

  defmodule CustomTimeoutHook do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed_timeout, do: 30_000
  end

  defmodule DenyHook do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, "bash", _args), do: {:deny, "destructive command"}
    def proceed(_agent_id, _tool, _args), do: :ok
  end

  defmodule ParkHook do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, _tool, _args), do: {:await_approval, "needs a human"}
  end

  defmodule RaisingHook do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed(_agent_id, _tool, _args), do: raise("boom")
  end

  defmodule SlowHook do
    use Planck.Agent.Hooks.ToolStart

    @impl true
    def proceed_timeout, do: 50

    @impl true
    def proceed(_agent_id, _tool, _args) do
      Process.sleep(500)
      {:deny, "too slow"}
    end
  end

  describe "use Planck.Agent.Hooks.ToolStart" do
    test "provides default proceed/3 returning :ok" do
      assert DefaultHook.proceed("a1", "bash", %{}) == :ok
    end

    test "provides default proceed_timeout/0" do
      assert DefaultHook.proceed_timeout() == ToolStart.default_timeout()
    end

    test "proceed_timeout/0 can be overridden" do
      assert CustomTimeoutHook.proceed_timeout() == 30_000
    end
  end

  describe "proceed/5 with nil module" do
    test "returns :ok" do
      assert ToolStart.proceed(nil, "a1", "bash", %{}, nil) == :ok
      assert ToolStart.proceed(nil, "a1", "bash", %{}, Node.self()) == :ok
    end
  end

  describe "proceed/5 local dispatch" do
    test "passes :ok through" do
      assert ToolStart.proceed(DefaultHook, "a1", "bash", %{}, nil) == :ok
    end

    test "passes {:deny, reason} through" do
      assert ToolStart.proceed(DenyHook, "a1", "bash", %{}, nil) == {:deny, "destructive command"}
      assert ToolStart.proceed(DenyHook, "a1", "read", %{}, nil) == :ok
    end

    test "passes {:await_approval, reason} through" do
      assert ToolStart.proceed(ParkHook, "a1", "bash", %{}, nil) ==
               {:await_approval, "needs a human"}
    end

    test "a raising hook fails open to :ok" do
      assert ToolStart.proceed(RaisingHook, "a1", "bash", %{}, nil) == :ok
    end
  end

  describe "proceed/5 remote dispatch" do
    test "dispatches via RPC on the same node" do
      assert ToolStart.proceed(DenyHook, "a1", "bash", %{}, Node.self()) ==
               {:deny, "destructive command"}
    end

    test "returns :ok when RPC fails (bad node)" do
      assert ToolStart.proceed(DenyHook, "a1", "bash", %{}, :nonexistent@localhost) == :ok
    end

    test "a slow gate fails open to :ok" do
      assert ToolStart.proceed(SlowHook, "a1", "bash", %{}, Node.self()) == :ok
    end
  end

  describe "blocked_error/1" do
    test "returns a plain error tuple with the work-around notice" do
      assert {:error, msg} = ToolStart.blocked_error("destructive command")
      assert msg =~ "destructive command"
      assert msg =~ "work around"
    end
  end
end
