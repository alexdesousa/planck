defmodule Planck.Agent.PromptHookTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.{MockAI, PromptHook}
  alias Planck.AI.Model

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "test-model",
    name: "Test",
    provider: :anthropic,
    context_window: 100_000,
    max_tokens: 1_024
  }

  # ---------------------------------------------------------------------------
  # Test hook modules
  # ---------------------------------------------------------------------------

  defmodule BothHooks do
    use PromptHook

    @impl true
    def prepend(_session_id), do: "prepended"

    @impl true
    def append(_session_id), do: "appended"
  end

  defmodule PrependOnly do
    use PromptHook

    @impl true
    def prepend(_session_id), do: "only prepend"
  end

  defmodule SessionAware do
    use PromptHook

    @impl true
    def append(session_id), do: "memory for #{session_id}"
  end

  defmodule NilHook do
    use PromptHook
  end

  defmodule CustomTimeout do
    use PromptHook

    @impl true
    def append(_session_id), do: "custom timeout hook"

    @impl true
    def hook_timeout, do: 30_000
  end

  # ---------------------------------------------------------------------------
  # __using__ / default implementations
  # ---------------------------------------------------------------------------

  describe "use Planck.Agent.PromptHook" do
    test "provides default hook_timeout/0" do
      assert NilHook.hook_timeout() == PromptHook.default_timeout()
    end

    test "hook_timeout/0 can be overridden" do
      assert CustomTimeout.hook_timeout() == 30_000
    end

    test "prepend/1 returns nil by default" do
      assert NilHook.prepend("session") == nil
    end

    test "append/1 returns nil by default" do
      assert NilHook.append("session") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — nil name
  # ---------------------------------------------------------------------------

  describe "build/2 with nil name" do
    test "returns empty keyword list" do
      assert PromptHook.build(nil, session_id: "s1") == []
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — local dispatch
  # ---------------------------------------------------------------------------

  describe "build/2 local" do
    test "returns prepend_fn and append_fn keys" do
      opts = PromptHook.build(inspect(BothHooks), session_id: "s1")
      assert Keyword.has_key?(opts, :system_prompt_prepend_fn)
      assert Keyword.has_key?(opts, :system_prompt_append_fn)
    end

    test "prepend_fn calls module's prepend/1" do
      opts = PromptHook.build(inspect(BothHooks), session_id: "s1")
      assert opts[:system_prompt_prepend_fn].() == "prepended"
    end

    test "append_fn calls module's append/1" do
      opts = PromptHook.build(inspect(BothHooks), session_id: "s1")
      assert opts[:system_prompt_append_fn].() == "appended"
    end

    test "nil-returning callback produces nil from the closure" do
      opts = PromptHook.build(inspect(PrependOnly), session_id: "s1")
      assert opts[:system_prompt_prepend_fn].() == "only prepend"
      assert opts[:system_prompt_append_fn].() == nil
    end

    test "session_id is forwarded to the callback" do
      opts = PromptHook.build(inspect(SessionAware), session_id: "abc-123")
      assert opts[:system_prompt_append_fn].() == "memory for abc-123"
    end

    test "nil session_id is forwarded as nil" do
      opts = PromptHook.build(inspect(SessionAware), session_id: nil)
      assert opts[:system_prompt_append_fn].() == "memory for "
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — remote dispatch (same-node simulation)
  # ---------------------------------------------------------------------------

  describe "build/2 remote" do
    test "sidecar_node: nil uses local dispatch" do
      opts = PromptHook.build(inspect(BothHooks), session_id: "s1", sidecar_node: nil)
      assert opts[:system_prompt_prepend_fn].() == "prepended"
      assert opts[:system_prompt_append_fn].() == "appended"
    end

    test "dispatches via rpc.call on the remote node (same-node)" do
      opts = PromptHook.build(inspect(BothHooks), session_id: "s1", sidecar_node: Node.self())
      assert opts[:system_prompt_prepend_fn].() == "prepended"
      assert opts[:system_prompt_append_fn].() == "appended"
    end

    test "session_id forwarded correctly over RPC (same-node)" do
      opts =
        PromptHook.build(inspect(SessionAware), session_id: "rpc-sess", sidecar_node: Node.self())

      assert opts[:system_prompt_append_fn].() == "memory for rpc-sess"
    end

    test "closure returns nil when RPC fails (bad node)" do
      opts =
        PromptHook.build(inspect(BothHooks),
          session_id: "s1",
          sidecar_node: :nonexistent@localhost
        )

      assert opts[:system_prompt_prepend_fn].() == nil
      assert opts[:system_prompt_append_fn].() == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with Agent
  # ---------------------------------------------------------------------------

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  describe "integration with Agent" do
    test "prepend hook content appears before the base system prompt" do
      parent = self()

      stub(MockAI, :stream, fn _model, context, _opts ->
        send(parent, {:system, context.system})
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "base prompt",
           system_prompt_prepend_fn: fn -> "PREPEND" end}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000

      prepend_pos = :binary.match(prompt, "PREPEND") |> elem(0)
      base_pos = :binary.match(prompt, "base prompt") |> elem(0)
      assert prepend_pos < base_pos
    end

    test "append hook content appears after the base system prompt" do
      parent = self()

      stub(MockAI, :stream, fn _model, context, _opts ->
        send(parent, {:system, context.system})
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "base prompt",
           system_prompt_append_fn: fn -> "APPEND" end}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000

      base_pos = :binary.match(prompt, "base prompt") |> elem(0)
      append_pos = :binary.match(prompt, "APPEND") |> elem(0)
      assert base_pos < append_pos
    end

    test "both hooks inject content in the correct order" do
      parent = self()

      stub(MockAI, :stream, fn _model, context, _opts ->
        send(parent, {:system, context.system})
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "base prompt",
           system_prompt_prepend_fn: fn -> "PREPEND" end,
           system_prompt_append_fn: fn -> "APPEND" end}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000

      prepend_pos = :binary.match(prompt, "PREPEND") |> elem(0)
      base_pos = :binary.match(prompt, "base prompt") |> elem(0)
      append_pos = :binary.match(prompt, "APPEND") |> elem(0)
      assert prepend_pos < base_pos
      assert base_pos < append_pos
    end

    test "nil-returning hooks do not alter the system prompt" do
      parent = self()

      stub(MockAI, :stream, fn _model, context, _opts ->
        send(parent, {:system, context.system})
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "base prompt",
           system_prompt_prepend_fn: fn -> nil end,
           system_prompt_append_fn: fn -> nil end}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000
      assert prompt =~ "base prompt"
      refute prompt =~ "nil"
    end

    test "hooks are called on every turn" do
      parent = self()
      counter = :counters.new(1, [])

      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "base",
           system_prompt_append_fn: fn ->
             :counters.add(counter, 1, 1)
             send(parent, :hook_called)
             "injected"
           end}
        )

      Agent.subscribe(agent)
      Agent.prompt(agent, "turn 1")
      assert_receive {:agent_event, :turn_end, _}, 1_000
      Agent.prompt(agent, "turn 2")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert :counters.get(counter, 1) >= 2
    end
  end
end
