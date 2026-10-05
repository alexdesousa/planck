defmodule Planck.Agent.IdentityTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Identity, Tool}
  alias Planck.AI.Model

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defp spawn_tool do
    Tool.new(
      name: "spawn_agent",
      description: "spawn",
      parameters: %{},
      execute_fn: fn _, _, _ -> {:ok, "ok"} end
    )
  end

  describe inspect(&Context.build/1) do
    test "should build a worker identity when no tools are given" do
      identity = Identity.build(id: "a1", model: @model)

      assert identity.id == "a1"
      assert identity.model == @model
      assert identity.role == :worker
      assert identity.name == nil
      assert identity.session_id == nil
    end

    test "should copie display and association fields" do
      identity =
        Identity.build(
          id: "a1",
          model: @model,
          name: "Alice",
          description: "helper",
          type: "worker",
          team_id: "t1",
          team_name: "default",
          session_id: "s1",
          delegator_id: "d1"
        )

      assert identity.name == "Alice"
      assert identity.description == "helper"
      assert identity.type == "worker"
      assert identity.team_id == "t1"
      assert identity.team_name == "default"
      assert identity.session_id == "s1"
      assert identity.delegator_id == "d1"
    end

    test "should derive :orchestrator role from spawn_agent tool presence" do
      identity = Identity.build(id: "a1", model: @model, tools: [spawn_tool()])
      assert identity.role == :orchestrator
    end

    test "other tools should not trigger orchestrator role" do
      tool =
        Tool.new(
          name: "bash",
          description: "run",
          parameters: %{},
          execute_fn: fn _, _, _ -> {:ok, "ok"} end
        )

      identity = Identity.build(id: "a1", model: @model, tools: [tool])
      assert identity.role == :worker
    end

    test "should raise when :id or :model is missing" do
      assert_raise KeyError, fn -> Identity.build(model: @model) end
      assert_raise KeyError, fn -> Identity.build(id: "a1") end
    end
  end

  describe inspect(&Context.set_model/2) do
    test "should replace the model and leaves other fields intact" do
      identity = Identity.build(id: "a1", model: @model)
      new_model = %Model{id: "other", provider: :openai, context_window: 1_000, max_tokens: 512}

      updated = Identity.set_model(identity, new_model)

      assert updated.model == new_model
      assert updated.id == "a1"
      assert updated.role == :worker
    end
  end
end
