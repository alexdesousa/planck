defmodule Planck.Agent.Hooks.ToolEndTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.Hooks.ToolEnd

  defmodule DefaultHook do
    use Planck.Agent.Hooks.ToolEnd
  end

  defmodule CustomTimeoutHook do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform_timeout, do: 30_000
  end

  defmodule UpperHook do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, {:ok, text}), do: {:ok, String.upcase(text)}
    def transform(_agent_id, _tool, _args, result), do: result
  end

  defmodule UiHook do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, {:ok, text}) do
      {:ok, text, %{ui: %{kind: :text, text: "note"}}}
    end

    def transform(_agent_id, _tool, _args, {:error, reason}) do
      {:error, reason, %{ui: %{kind: :text, text: "failed"}}}
    end
  end

  defmodule RaisingHook do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, _result), do: raise("boom")
  end

  defmodule UnexpectedHook do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform(_agent_id, _tool, _args, _result), do: {:weird, "shape"}
  end

  defmodule SlowHook do
    use Planck.Agent.Hooks.ToolEnd

    @impl true
    def transform_timeout, do: 50

    @impl true
    def transform(_agent_id, _tool, _args, _result) do
      Process.sleep(500)
      {:ok, "too slow"}
    end
  end

  describe "use Planck.Agent.Hooks.ToolEnd" do
    test "provides default transform/4 as identity" do
      assert DefaultHook.transform("a1", "bash", %{}, {:ok, "x"}) == {:ok, "x"}
      assert DefaultHook.transform("a1", "bash", %{}, {:error, "nope"}) == {:error, "nope"}
    end

    test "provides default transform_timeout/0" do
      assert DefaultHook.transform_timeout() == ToolEnd.default_timeout()
    end

    test "transform_timeout/0 can be overridden" do
      assert CustomTimeoutHook.transform_timeout() == 30_000
    end
  end

  describe "transform/6 with nil module" do
    test "returns the result unchanged" do
      assert ToolEnd.transform(nil, "a1", "bash", %{}, {:ok, "x"}, nil) == {:ok, "x"}
      assert ToolEnd.transform(nil, "a1", "bash", %{}, {:error, "nope"}, nil) == {:error, "nope"}

      triple = {:error, "nope", %{ui: %{kind: :text, text: "t"}}}
      assert ToolEnd.transform(nil, "a1", "bash", %{}, triple, nil) == triple
    end
  end

  describe "transform/6 local dispatch" do
    test "rewrites result text" do
      assert ToolEnd.transform(UpperHook, "a1", "bash", %{}, {:ok, "hi"}, nil) == {:ok, "HI"}
    end

    test "attaches UI to ok and error results" do
      assert ToolEnd.transform(UiHook, "a1", "bash", %{}, {:ok, "hi"}, nil) ==
               {:ok, "hi", %{ui: %{kind: :text, text: "note"}}}

      assert ToolEnd.transform(UiHook, "a1", "bash", %{}, {:error, "bad"}, nil) ==
               {:error, "bad", %{ui: %{kind: :text, text: "failed"}}}
    end

    test "a raising hook keeps the result" do
      assert ToolEnd.transform(RaisingHook, "a1", "bash", %{}, {:ok, "x"}, nil) == {:ok, "x"}
    end

    test "an unexpected return keeps the result" do
      assert ToolEnd.transform(UnexpectedHook, "a1", "bash", %{}, {:ok, "x"}, nil) == {:ok, "x"}
    end
  end

  describe "transform/6 remote dispatch" do
    test "dispatches via RPC on the same node" do
      assert ToolEnd.transform(UpperHook, "a1", "bash", %{}, {:ok, "hi"}, Node.self()) ==
               {:ok, "HI"}
    end

    test "returns the result unchanged when RPC fails (bad node)" do
      assert ToolEnd.transform(UpperHook, "a1", "bash", %{}, {:ok, "hi"}, :nonexistent@localhost) ==
               {:ok, "hi"}
    end

    test "a slow transform keeps the result" do
      assert ToolEnd.transform(SlowHook, "a1", "bash", %{}, {:ok, "hi"}, Node.self()) ==
               {:ok, "hi"}
    end
  end
end
