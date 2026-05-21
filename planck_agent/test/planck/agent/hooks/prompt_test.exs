defmodule Planck.Agent.Hooks.PromptTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.Hooks.Prompt
  alias Planck.Agent.{MockAI}
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
    use Planck.Agent.Hooks.Prompt

    @impl true
    def before_prompt(_session_id), do: "prepended"

    @impl true
    def after_prompt(_session_id), do: "appended"
  end

  defmodule BeforeOnly do
    use Planck.Agent.Hooks.Prompt

    @impl true
    def before_prompt(_session_id), do: "only before"
  end

  defmodule SessionAware do
    use Planck.Agent.Hooks.Prompt

    @impl true
    def after_prompt(session_id), do: "memory for #{session_id}"
  end

  defmodule NilHook do
    use Planck.Agent.Hooks.Prompt
  end

  defmodule CustomTimeout do
    use Planck.Agent.Hooks.Prompt

    @impl true
    def after_prompt(_session_id), do: "custom timeout hook"

    @impl true
    def hook_timeout, do: 30_000
  end

  # ---------------------------------------------------------------------------
  # use Planck.Agent.Hooks.Prompt — behaviour defaults
  # ---------------------------------------------------------------------------

  describe "use Planck.Agent.Hooks.Prompt" do
    test "provides default hook_timeout/0" do
      assert NilHook.hook_timeout() == Prompt.default_timeout()
    end

    test "hook_timeout/0 can be overridden" do
      assert CustomTimeout.hook_timeout() == 30_000
    end

    test "before_prompt/1 returns nil by default" do
      assert NilHook.before_prompt("session") == nil
    end

    test "after_prompt/1 returns nil by default" do
      assert NilHook.after_prompt("session") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # prepend/3 and append/3 — nil module
  # ---------------------------------------------------------------------------

  describe "before_prompt/3 and after_prompt/3 with nil module" do
    test "before_prompt returns nil" do
      assert Prompt.before_prompt(nil, "s1", nil) == nil
    end

    test "after_prompt returns nil" do
      assert Prompt.after_prompt(nil, "s1", nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # before_prompt/3 and after_prompt/3 — local dispatch
  # ---------------------------------------------------------------------------

  describe "before_prompt/3 and after_prompt/3 local" do
    test "before_prompt calls module's before_prompt/1" do
      assert Prompt.before_prompt(BothHooks, "s1", nil) == "prepended"
    end

    test "after_prompt calls module's after_prompt/1" do
      assert Prompt.after_prompt(BothHooks, "s1", nil) == "appended"
    end

    test "nil-returning callback returns nil" do
      assert Prompt.before_prompt(BeforeOnly, "s1", nil) == "only before"
      assert Prompt.after_prompt(BeforeOnly, "s1", nil) == nil
    end

    test "session_id is forwarded to the callback" do
      assert Prompt.after_prompt(SessionAware, "abc-123", nil) == "memory for abc-123"
    end

    test "nil session_id is forwarded as nil" do
      assert Prompt.after_prompt(SessionAware, nil, nil) == "memory for "
    end
  end

  # ---------------------------------------------------------------------------
  # before_prompt/3 and after_prompt/3 — remote dispatch (same-node simulation)
  # ---------------------------------------------------------------------------

  describe "before_prompt/3 and after_prompt/3 remote" do
    test "sidecar_node: nil uses local dispatch" do
      assert Prompt.before_prompt(BothHooks, "s1", nil) == "prepended"
      assert Prompt.after_prompt(BothHooks, "s1", nil) == "appended"
    end

    test "dispatches via RPC on the same node" do
      assert Prompt.before_prompt(BothHooks, "s1", Node.self()) == "prepended"
      assert Prompt.after_prompt(BothHooks, "s1", Node.self()) == "appended"
    end

    test "session_id forwarded correctly over RPC" do
      assert Prompt.after_prompt(SessionAware, "rpc-sess", Node.self()) == "memory for rpc-sess"
    end

    test "returns nil when RPC fails (bad node)" do
      assert Prompt.before_prompt(BothHooks, "s1", :nonexistent@localhost) == nil
      assert Prompt.after_prompt(BothHooks, "s1", :nonexistent@localhost) == nil
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
           id: unique_id(), model: @model, system_prompt: "base prompt", prompt_hook: BothHooks}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000

      prepend_pos = :binary.match(prompt, "prepended") |> elem(0)
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
           id: unique_id(), model: @model, system_prompt: "base prompt", prompt_hook: BothHooks}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000

      base_pos = :binary.match(prompt, "base prompt") |> elem(0)
      append_pos = :binary.match(prompt, "appended") |> elem(0)
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
           id: unique_id(), model: @model, system_prompt: "base prompt", prompt_hook: BothHooks}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000

      prepend_pos = :binary.match(prompt, "prepended") |> elem(0)
      base_pos = :binary.match(prompt, "base prompt") |> elem(0)
      append_pos = :binary.match(prompt, "appended") |> elem(0)
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
           id: unique_id(), model: @model, system_prompt: "base prompt", prompt_hook: NilHook}
        )

      Agent.prompt(agent, "hi")
      assert_receive {:system, prompt}, 1_000
      assert prompt =~ "base prompt"
      refute prompt =~ "nil"
    end

    test "hooks are called on every turn" do
      counter = :counters.new(1, [])

      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      defmodule CountingHook do
        use Planck.Agent.Hooks.Prompt

        @impl true
        def after_prompt(_session_id) do
          :counters.add(:persistent_term.get({__MODULE__, :counter}), 1, 1)
          "injected"
        end
      end

      :persistent_term.put({CountingHook, :counter}, counter)

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(), model: @model, system_prompt: "base", prompt_hook: CountingHook}
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
