defmodule Planck.Agent.HooksTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Hooks
  alias Planck.Agent.Hooks.Compactor

  describe inspect(&Context.build/1) do
    test "should default compactor to Default and the rest to nil" do
      hooks = Hooks.build([])

      assert hooks.compactor == Compactor.Default
      assert hooks.persistence == nil
      assert hooks.prompt == nil
      assert hooks.turn_end == nil
      assert hooks.sidecar_node == nil
    end

    test "should pass explicit opts through" do
      hooks =
        Hooks.build(
          compactor: SomeCompactor,
          persistence: SomePersistence,
          prompt_hook: SomePrompt,
          turn_end_hook: SomeTurnEnd,
          sidecar_node: :sidecar@localhost
        )

      assert hooks.compactor == SomeCompactor
      assert hooks.persistence == SomePersistence
      assert hooks.prompt == SomePrompt
      assert hooks.turn_end == SomeTurnEnd
      assert hooks.sidecar_node == :sidecar@localhost
    end

    test "should fall back to Default when explicit nil compactor" do
      hooks = Hooks.build(compactor: nil)
      assert hooks.compactor == Compactor.Default
    end
  end

  describe inspect({&Context.before_prompt/2, &Context.after_prompt/2}) do
    test "should return nil when no prompt hook is configured" do
      hooks = Hooks.build([])

      assert Hooks.before_prompt(hooks, "session-1") == nil
      assert Hooks.after_prompt(hooks, "session-1") == nil
    end

    test "should delegate to the configured prompt hook module" do
      defmodule TestPromptHook do
        use Planck.Agent.Hooks.Prompt

        @impl true
        def before_prompt(_session_id), do: "before-text"

        @impl true
        def after_prompt(_session_id), do: "after-text"
      end

      hooks = Hooks.build(prompt_hook: TestPromptHook)

      assert Hooks.before_prompt(hooks, "session-1") == "before-text"
      assert Hooks.after_prompt(hooks, "session-1") == "after-text"
    end
  end
end
