defmodule Sidecar.Tools.BeadsTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Sidecar.Tools.Beads

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "test",
    name: "Test",
    provider: :anthropic,
    context_window: 100_000,
    max_tokens: 1_024
  }

  defp unique_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  describe "resolve_actor/1" do
    test "returns team_name:name for the calling agent, not the ephemeral agent_id" do
      stub(MockAI, :stream, fn _m, _c, _o -> [{:text_delta, "ok"}, {:done, %{}}] end)
      id = unique_id()

      start_supervised!(
        {Agent,
         id: id, model: @model, system_prompt: "hi", name: "worker-1", team_name: "deep-thought"},
        id: id
      )

      assert Beads.resolve_actor(id) == "deep-thought:worker-1"
    end
  end

  describe "board_ui/0" do
    test "is the fixed payload opening the beads board widget" do
      assert Beads.board_ui() == %{
               kind: :widget,
               label: "View kanban board",
               widget: "beads-board",
               data: nil
             }
    end
  end

  describe "with_description/2" do
    test "appends the description on its own line when present and non-empty" do
      issue = %{"description" => "Full context."}
      assert Beads.with_description("bd-1: Fix it", issue) == "bd-1: Fix it\nFull context."
    end

    test "leaves the header unchanged when description is absent" do
      assert Beads.with_description("bd-1: Fix it", %{}) == "bd-1: Fix it"
    end

    test "leaves the header unchanged when description is an empty string" do
      assert Beads.with_description("bd-1: Fix it", %{"description" => ""}) == "bd-1: Fix it"
    end
  end
end
