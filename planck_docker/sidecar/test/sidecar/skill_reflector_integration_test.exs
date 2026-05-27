defmodule Sidecar.SkillReflectorIntegrationTest do
  use ExUnit.Case, async: false

  import Mox

  @moduletag :tmp_dir

  alias Planck.Agent
  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Sidecar.SkillReflector

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "test",
    name: "Test",
    provider: :anthropic,
    context_window: 100_000,
    max_tokens: 1_024
  }

  setup %{tmp_dir: dir} do
    Application.put_env(:sidecar, :workspace_dir, dir)
    Sidecar.Config.reload_workspace_dir()

    on_exit(fn ->
      Application.delete_env(:sidecar, :workspace_dir)
      Sidecar.Config.reload_workspace_dir()
    end)

    :ok
  end

  defp unique_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp start_parent do
    stub(MockAI, :stream, fn _m, _c, _o -> [{:text_delta, "ok"}, {:done, %{}}] end)
    id = unique_id()

    pid =
      start_supervised!({Agent, id: id, model: @model, system_prompt: "hi", name: "orchestrator"},
        id: id
      )

    {id, pid}
  end

  defp skill_file(dir, name) do
    Path.join([dir, ".planck", "skills", name, "SKILL.md"])
  end

  defp tool_call_messages(count) do
    alias Planck.Agent.Message
    calls = Enum.map(1..count, fn i -> {:tool_call, "id-#{i}", "bash", %{}} end)
    results = Enum.map(1..count, fn i -> {:tool_result, "id-#{i}", "ok"} end)
    [Message.new(:assistant, calls), Message.new(:tool_result, results)]
  end

  # ---------------------------------------------------------------------------

  describe "full reflector flow" do
    test "creates a skill file and injects create_skill into the parent agent", %{tmp_dir: dir} do
      {parent_id, parent_pid} = start_parent()

      # Three-phase stream: list_skills → write_skill → done
      call_count = :counters.new(1, [])

      stub(MockAI, :stream, fn _model, _context, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case n do
          0 ->
            # Mini-agent first turn: call list_skills
            [
              {:tool_call_complete, %{id: "tc1", name: "list_skills", args: %{}}},
              {:done, %{}}
            ]

          1 ->
            # After list_skills ("No agent-created skills yet."): call write_skill
            [
              {:tool_call_complete,
               %{
                 id: "tc2",
                 name: "write_skill",
                 args: %{
                   "name" => "test-workflow",
                   "description" => "A test workflow.",
                   "content" =>
                     "## When to Use\nWhen testing.\n\n## Procedure\n1. Run tests.\n\n## Pitfalls\nNone."
                 }
               }},
              {:done, %{}}
            ]

          _ ->
            # After write_skill result: final response
            [{:text_delta, "Skill captured."}, {:done, %{}}]
        end
      end)

      # Start the Runner directly so we can monitor completion
      {:ok, runner_pid} = Sidecar.SkillReflector.Runner.start(parent_id, [])
      ref = Process.monitor(runner_pid)

      # Wait for the Runner to finish (mini-agent completes + injection done)
      assert_receive {:DOWN, ^ref, :process, ^runner_pid, :normal}, 5_000

      # Skill file was written to the workspace
      assert File.exists?(skill_file(dir, "test-workflow"))
      content = File.read!(skill_file(dir, "test-workflow"))
      assert content =~ "test-workflow"
      assert content =~ "creator: agent"

      # create_skill was injected into the parent's message history
      state = Agent.get_state(parent_pid)

      assert Enum.any?(state.messages, fn msg ->
               msg.role == :assistant and
                 Enum.any?(msg.content, fn
                   {:tool_call, _, "create_skill", _} -> true
                   _ -> false
                 end)
             end)
    end

    test "does not inject when mini-agent decides no skill is needed", %{tmp_dir: _dir} do
      {parent_id, parent_pid} = start_parent()

      # Mini-agent calls list_skills then decides to skip
      call_count = :counters.new(1, [])

      stub(MockAI, :stream, fn _model, _context, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case n do
          0 ->
            [
              {:tool_call_complete, %{id: "tc1", name: "list_skills", args: %{}}},
              {:done, %{}}
            ]

          _ ->
            # Decides not to write a skill
            [{:text_delta, "No skill needed for this turn."}, {:done, %{}}]
        end
      end)

      {:ok, runner_pid} = Sidecar.SkillReflector.Runner.start(parent_id, [])
      ref = Process.monitor(runner_pid)

      assert_receive {:DOWN, ^ref, :process, ^runner_pid, :normal}, 5_000

      # No tool_call injection in parent
      state = Agent.get_state(parent_pid)

      refute Enum.any?(state.messages, fn msg ->
               msg.role == :assistant and
                 Enum.any?(msg.content, fn
                   {:tool_call, _, action, _} -> action in ["create_skill", "update_skill"]
                   _ -> false
                 end)
             end)
    end

    test "reflect/2 returns :ok and eventually injects create_skill", %{tmp_dir: dir} do
      {parent_id, parent_pid} = start_parent()
      call_count = :counters.new(1, [])

      stub(MockAI, :stream, fn _model, _context, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case n do
          0 ->
            [
              {:tool_call_complete, %{id: "tc1", name: "list_skills", args: %{}}},
              {:done, %{}}
            ]

          1 ->
            [
              {:tool_call_complete,
               %{
                 id: "tc2",
                 name: "write_skill",
                 args: %{
                   "name" => "reflect-skill",
                   "description" => "A skill.",
                   "content" => "## Procedure\n1. Do it."
                 }
               }},
              {:done, %{}}
            ]

          _ ->
            [{:text_delta, "Done."}, {:done, %{}}]
        end
      end)

      # Pass enough tool calls to meet @tool_threshold (5)
      turn_messages = tool_call_messages(5)

      # Test through the public Hooks.TurnEnd interface
      assert :ok = SkillReflector.reflect(parent_id, turn_messages)

      # Wait for the skill file to appear (Runner is async)
      assert_eventually(fn -> File.exists?(skill_file(dir, "reflect-skill")) end, 5_000)

      state = Agent.get_state(parent_pid)

      assert Enum.any?(state.messages, fn msg ->
               msg.role == :assistant and
                 Enum.any?(msg.content, fn
                   {:tool_call, _, "create_skill", _} -> true
                   _ -> false
                 end)
             end)
    end
  end

  # Poll until `fun.()` returns truthy or timeout expires.
  defp assert_eventually(fun, timeout, interval \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> poll(fun, deadline, interval) end)
    |> Enum.find(&(&1 == :done))
  end

  defp poll(fun, deadline, interval) do
    if fun.() do
      :done
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: raise("assert_eventually timed out"), else: Process.sleep(interval)
      :retry
    end
  end
end
