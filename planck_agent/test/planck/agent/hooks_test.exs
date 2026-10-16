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
      assert hooks.turn_start == nil
      assert hooks.tool_start == nil
      assert hooks.tool_end == nil
      assert hooks.sidecar_node == nil
    end

    test "should pass explicit opts through" do
      hooks =
        Hooks.build(
          compactor: SomeCompactor,
          persistence: SomePersistence,
          prompt_hook: SomePrompt,
          turn_end_hook: SomeTurnEnd,
          turn_start_hook: SomeTurnStart,
          tool_start_hook: SomeToolStart,
          tool_end_hook: SomeToolEnd,
          sidecar_node: :sidecar@localhost
        )

      assert hooks.compactor == SomeCompactor
      assert hooks.persistence == SomePersistence
      assert hooks.prompt == SomePrompt
      assert hooks.turn_end == SomeTurnEnd
      assert hooks.turn_start == SomeTurnStart
      assert hooks.tool_start == SomeToolStart
      assert hooks.tool_end == SomeToolEnd
      assert hooks.sidecar_node == :sidecar@localhost
    end

    test "should fall back to Default when explicit nil compactor" do
      hooks = Hooks.build(compactor: nil)
      assert hooks.compactor == Compactor.Default
    end
  end

  describe "to_spec_args/1" do
    test "omits unset hooks and excludes sidecar_node" do
      hooks = Hooks.build([])
      assert Hooks.to_spec_args(hooks) == %{"compactor" => "Planck.Agent.Hooks.Compactor.Default"}
    end

    test "reduces module atoms to dotted names, round-tripping resolve_hook_module" do
      hooks =
        Hooks.build(
          prompt_hook: SomePrompt,
          persistence: SomePersistence,
          turn_start_hook: SomeTurnStart,
          sidecar_node: :sidecar@localhost
        )

      args = Hooks.to_spec_args(hooks)
      assert args["prompt_hook"] == "SomePrompt"
      assert args["persistence"] == "SomePersistence"
      assert args["turn_start_hook"] == "SomeTurnStart"
      refute Map.has_key?(args, "sidecar_node")

      # The dotted name is exactly what resolve_hook_module expects back (inverse check).
      assert :"Elixir.#{args["prompt_hook"]}" == SomePrompt
    end
  end
end
