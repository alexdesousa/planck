defmodule Planck.Agent.TeamIntegrationTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.{BuiltinTools, MockAI, Session, Tools}
  alias Planck.AI.{Context, Model}

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :ollama,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  # Starts an agent under AgentSupervisor (not ExUnit's supervisor) so it
  # appears in DynamicSupervisor.which_children and teardown works correctly.
  defp start_dynamic(opts) do
    {:ok, pid} = DynamicSupervisor.start_child(Planck.Agent.AgentSupervisor, {Agent, opts})

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Planck.Agent.AgentSupervisor, pid)
      end
    end)

    pid
  end

  defp start_worker(team_id, type, delegator_id, extra_opts \\ []) do
    id = unique_id()

    tools = Tools.worker_tools(team_id, delegator_id)

    start_dynamic(
      [
        id: id,
        type: type,
        model: @model,
        system_prompt: "You are the #{type}.",
        tools: tools,
        team_id: team_id,
        delegator_id: delegator_id
      ] ++ extra_opts
    )

    id
  end

  defp start_orchestrator(team_id) do
    id = unique_id()
    session_id = unique_id()
    dir = Path.join(System.tmp_dir!(), "planck_test_#{session_id}")

    {:ok, _} = Session.start(session_id, dir: dir)

    on_exit(fn ->
      Session.stop(session_id)
      File.rm_rf!(dir)
    end)

    tools =
      Tools.orchestrator_tools(session_id, team_id, id, [@model]) ++
        Tools.worker_tools(team_id, nil)

    pid =
      start_dynamic(
        id: id,
        model: @model,
        system_prompt: "You are the orchestrator.",
        tools: tools,
        session_id: session_id,
        team_id: team_id
      )

    {id, pid}
  end

  # ---------------------------------------------------------------------------
  # ask_agent
  # ---------------------------------------------------------------------------

  describe "ask_agent" do
    test "orchestrator blocks until worker answers and gets the reply as tool result" do
      team_id = unique_id()
      {orch_id, orch_pid} = start_orchestrator(team_id)
      _builder_id = start_worker(team_id, "builder", orch_id)

      stub(MockAI, :stream, fn _model, %Context{system: system, messages: msgs}, _opts ->
        has_tool_result = Enum.any?(msgs, &match?(%{role: :tool_result}, &1))

        cond do
          system =~ "orchestrator" and has_tool_result ->
            [{:text_delta, "Builder said: I am building."}, {:done, %{}}]

          system =~ "orchestrator" ->
            [
              {:tool_call_complete,
               %{
                 id: "tc1",
                 name: "ask_agent",
                 args: %{"type" => "builder", "question" => "What are you doing?"}
               }},
              {:done, %{}}
            ]

          system =~ "builder" ->
            [{:text_delta, "I am building."}, {:done, %{}}]
        end
      end)

      Agent.subscribe(orch_pid)
      Agent.prompt(orch_pid, "Ask the builder for status.")

      assert_receive {:agent_event, :turn_end,
                      %{message: %{content: [{:text, "Builder said: I am building."}]}}},
                     3_000
    end

    test "returns :not_found when target type does not exist in team" do
      team_id = unique_id()
      {_orch_id, orch_pid} = start_orchestrator(team_id)

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:text_delta, "Could not find agent."}, {:done, %{}}]
        else
          [
            {:tool_call_complete,
             %{
               id: "tc2",
               name: "ask_agent",
               args: %{"type" => "nonexistent", "question" => "hello?"}
             }},
            {:done, %{}}
          ]
        end
      end)

      Agent.subscribe(orch_pid)
      Agent.prompt(orch_pid, "Ask the nonexistent agent.")

      assert_receive {:agent_event, :turn_end, _}, 2_000

      state = Agent.get_state(orch_pid)
      tool_msg = Enum.find(state.messages, &(&1.role == :tool_result))
      assert tool_msg != nil
      [{:tool_result, _id, value}] = tool_msg.content
      assert value =~ "not found"
    end
  end

  # ---------------------------------------------------------------------------
  # delegate_task / send_response
  # ---------------------------------------------------------------------------

  describe "delegate_task + send_response" do
    test "worker sends response back to orchestrator which re-triggers" do
      team_id = unique_id()
      {orch_id, orch_pid} = start_orchestrator(team_id)
      _builder_id = start_worker(team_id, "builder", orch_id)

      stub(MockAI, :stream, fn _model, %Context{system: system, messages: msgs}, _opts ->
        has_tool_result = Enum.any?(msgs, &match?(%{role: :tool_result}, &1))
        has_agent_response = length(msgs) > 2 and Enum.any?(msgs, &match?(%{role: :user}, &1))

        cond do
          system =~ "orchestrator" and has_agent_response ->
            [{:text_delta, "Great work, builder!"}, {:done, %{}}]

          system =~ "orchestrator" and has_tool_result ->
            [{:text_delta, "Task delegated, waiting..."}, {:done, %{}}]

          system =~ "orchestrator" ->
            [
              {:tool_call_complete,
               %{
                 id: "tc3",
                 name: "delegate_task",
                 args: %{"type" => "builder", "task" => "Build the feature."}
               }},
              {:done, %{}}
            ]

          system =~ "builder" and has_tool_result ->
            [{:text_delta, "Done."}, {:done, %{}}]

          system =~ "builder" ->
            [
              {:tool_call_complete,
               %{
                 id: "tc4",
                 name: "send_response",
                 args: %{"response" => "Feature built successfully."}
               }},
              {:done, %{}}
            ]
        end
      end)

      Agent.subscribe(orch_pid)
      Agent.prompt(orch_pid, "Delegate the feature build to the builder.")

      assert_receive {:agent_event, :turn_end,
                      %{message: %{content: [{:text, "Great work, builder!"}]}}},
                     5_000
    end
  end

  # ---------------------------------------------------------------------------
  # Team teardown
  # ---------------------------------------------------------------------------

  describe "team teardown" do
    test "workers in the same team are terminated when orchestrator exits" do
      team_id = unique_id()
      {orch_id, orch_pid} = start_orchestrator(team_id)
      worker1_id = start_worker(team_id, "builder", orch_id)
      worker2_id = start_worker(team_id, "tester", orch_id)

      {:ok, w1_pid} = Agent.whereis(worker1_id)
      {:ok, w2_pid} = Agent.whereis(worker2_id)

      assert Process.alive?(w1_pid)
      assert Process.alive?(w2_pid)

      ref1 = Process.monitor(w1_pid)
      ref2 = Process.monitor(w2_pid)

      DynamicSupervisor.terminate_child(Planck.Agent.AgentSupervisor, orch_pid)

      assert_receive {:DOWN, ^ref1, :process, ^w1_pid, _}, 1_000
      assert_receive {:DOWN, ^ref2, :process, ^w2_pid, _}, 1_000
    end

    test "workers in a different team are not affected by orchestrator exit" do
      team_a = unique_id()
      team_b = unique_id()

      {_orch_a_id, orch_a_pid} = start_orchestrator(team_a)
      _worker_a_id = start_worker(team_a, "builder", nil)
      _worker_b_id = start_worker(team_b, "builder", nil)

      # Find a worker from team_b that is NOT in team_a
      # It stays alive after team_a orchestrator exits

      # Grab all children pids before teardown
      children_before =
        DynamicSupervisor.which_children(Planck.Agent.AgentSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
        |> Enum.reject(&(&1 == orch_a_pid))

      DynamicSupervisor.terminate_child(Planck.Agent.AgentSupervisor, orch_a_pid)

      # Allow teardown to propagate
      Process.sleep(100)

      # At least one child should still be alive (the team_b worker)
      still_alive = Enum.filter(children_before, &Process.alive?/1)
      assert still_alive != []
    end
  end

  # ---------------------------------------------------------------------------
  # destroy_agent
  # ---------------------------------------------------------------------------

  describe "destroy_agent" do
    test "orchestrator can terminate a worker via destroy_agent tool" do
      team_id = unique_id()
      {_orch_id, orch_pid} = start_orchestrator(team_id)
      builder_id = start_worker(team_id, "builder", nil)

      {:ok, builder_pid} = Agent.whereis(builder_id)
      ref = Process.monitor(builder_pid)

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:text_delta, "Builder destroyed."}, {:done, %{}}]
        else
          [
            {:tool_call_complete,
             %{id: "tc5", name: "destroy_agent", args: %{"type" => "builder"}}},
            {:done, %{}}
          ]
        end
      end)

      Agent.subscribe(orch_pid)
      Agent.prompt(orch_pid, "Destroy the builder.")

      assert_receive {:DOWN, ^ref, :process, ^builder_pid, _}, 2_000
      assert_receive {:agent_event, :turn_end, _}, 2_000
    end
  end

  # ---------------------------------------------------------------------------
  # interrupt_agent
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # spawn_agent grantable tools
  # ---------------------------------------------------------------------------

  describe "spawn_agent grantable tools" do
    defp call_spawn(spawn_tool, orch_id, extra_args \\ %{}) do
      base = %{
        "type" => "reviewer",
        "name" => "Reviewer",
        "description" => "Reviews code",
        "system_prompt" => "You are a reviewer.",
        "provider" => "ollama",
        "model_id" => "llama3.2"
      }

      {:ok, agent_id} = spawn_tool.execute_fn.(orch_id, Map.merge(base, extra_args))
      {:ok, pid} = Agent.whereis(agent_id)

      on_exit(fn ->
        if Process.alive?(pid),
          do: DynamicSupervisor.terminate_child(Planck.Agent.AgentSupervisor, pid)
      end)

      Agent.get_state(pid).tools
    end

    test "spawned agent always receives worker inter-agent tools" do
      team_id = unique_id()
      orch_id = unique_id()
      stub(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      spawn_tool = Tools.spawn_agent(unique_id(), team_id, orch_id, [])
      tools = call_spawn(spawn_tool, orch_id)

      assert Map.has_key?(tools, "ask_agent")
      assert Map.has_key?(tools, "delegate_task")
      assert Map.has_key?(tools, "send_response")
      assert Map.has_key?(tools, "list_team")
    end

    test "spawned agent receives requested tools from the grantable set" do
      team_id = unique_id()
      orch_id = unique_id()
      stub(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      spawn_tool = Tools.spawn_agent(unique_id(), team_id, orch_id, [BuiltinTools.read()])
      tools = call_spawn(spawn_tool, orch_id, %{"tools" => ["read"]})

      assert Map.has_key?(tools, "read")
    end

    test "tools not in the grantable set are silently ignored" do
      team_id = unique_id()
      orch_id = unique_id()
      stub(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      spawn_tool = Tools.spawn_agent(unique_id(), team_id, orch_id, [BuiltinTools.read()])
      tools = call_spawn(spawn_tool, orch_id, %{"tools" => ["bash", "write"]})

      refute Map.has_key?(tools, "bash")
      refute Map.has_key?(tools, "write")
      assert Map.has_key?(tools, "ask_agent")
    end

    test "spawned agent with no tools key gets only worker inter-agent tools" do
      team_id = unique_id()
      orch_id = unique_id()
      stub(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

      spawn_tool =
        Tools.spawn_agent(unique_id(), team_id, orch_id, [
          BuiltinTools.read(),
          BuiltinTools.bash()
        ])

      tools = call_spawn(spawn_tool, orch_id)

      refute Map.has_key?(tools, "read")
      refute Map.has_key?(tools, "bash")
      assert Map.has_key?(tools, "ask_agent")
    end
  end

  # ---------------------------------------------------------------------------
  # built-in tools exercised through a spawned worker
  # ---------------------------------------------------------------------------

  defp spawn_with_tool(tool) do
    team_id = unique_id()
    orch_id = unique_id()
    stub(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

    spawn_tool = Tools.spawn_agent(unique_id(), team_id, orch_id, [tool])

    {:ok, agent_id} =
      spawn_tool.execute_fn.(orch_id, %{
        "type" => "worker",
        "name" => "Worker",
        "description" => "A worker agent.",
        "system_prompt" => "You are a worker.",
        "provider" => "ollama",
        "model_id" => "llama3.2",
        "tools" => [tool.name]
      })

    {:ok, pid} = Agent.whereis(agent_id)

    on_exit(fn ->
      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Planck.Agent.AgentSupervisor, pid)
    end)

    pid
  end

  defp tool_result_value(pid) do
    msg = Enum.find(Agent.get_state(pid).messages, &(&1.role == :tool_result))
    [{:tool_result, _id, value}] = msg.content
    value
  end

  describe "spawned worker with read tool" do
    test "reads a file and receives its content as the tool result" do
      path = Path.join(System.tmp_dir!(), "planck_read_#{unique_id()}.txt")
      File.write!(path, "hello from file")
      on_exit(fn -> File.rm(path) end)

      worker = spawn_with_tool(BuiltinTools.read())

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:text_delta, "Got it."}, {:done, %{}}]
        else
          [
            {:tool_call_complete, %{id: "tc", name: "read", args: %{"path" => path}}},
            {:done, %{}}
          ]
        end
      end)

      Agent.subscribe(worker)
      Agent.prompt(worker, "Read the file.")
      assert_receive {:agent_event, :turn_end, _}, 2_000

      assert tool_result_value(worker) == "hello from file"
    end
  end

  describe "spawned worker with write tool" do
    test "writes content to a file" do
      path = Path.join(System.tmp_dir!(), "planck_write_#{unique_id()}.txt")
      on_exit(fn -> File.rm(path) end)

      worker = spawn_with_tool(BuiltinTools.write())

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:text_delta, "Written."}, {:done, %{}}]
        else
          [
            {:tool_call_complete,
             %{id: "tc", name: "write", args: %{"path" => path, "content" => "agent output"}}},
            {:done, %{}}
          ]
        end
      end)

      Agent.subscribe(worker)
      Agent.prompt(worker, "Write the file.")
      assert_receive {:agent_event, :turn_end, _}, 2_000

      assert File.read!(path) == "agent output"
    end
  end

  describe "spawned worker with edit tool" do
    test "replaces a string in an existing file" do
      path = Path.join(System.tmp_dir!(), "planck_edit_#{unique_id()}.txt")
      File.write!(path, "hello world")
      on_exit(fn -> File.rm(path) end)

      worker = spawn_with_tool(BuiltinTools.edit())

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:text_delta, "Edited."}, {:done, %{}}]
        else
          [
            {:tool_call_complete,
             %{
               id: "tc",
               name: "edit",
               args: %{"path" => path, "old_string" => "world", "new_string" => "elixir"}
             }},
            {:done, %{}}
          ]
        end
      end)

      Agent.subscribe(worker)
      Agent.prompt(worker, "Edit the file.")
      assert_receive {:agent_event, :turn_end, _}, 2_000

      assert File.read!(path) == "hello elixir"
    end
  end

  describe "spawned worker with bash tool" do
    test "runs a shell command and receives its output as the tool result" do
      worker = spawn_with_tool(BuiltinTools.bash())

      stub(MockAI, :stream, fn _model, %Context{messages: msgs}, _opts ->
        if Enum.any?(msgs, &match?(%{role: :tool_result}, &1)) do
          [{:text_delta, "Done."}, {:done, %{}}]
        else
          [
            {:tool_call_complete, %{id: "tc", name: "bash", args: %{"command" => "echo planck"}}},
            {:done, %{}}
          ]
        end
      end)

      Agent.subscribe(worker)
      Agent.prompt(worker, "Run the command.")
      assert_receive {:agent_event, :turn_end, _}, 2_000

      assert String.trim(tool_result_value(worker)) == "planck"
    end
  end

  describe "interrupt_agent" do
    test "orchestrator aborts a worker's turn via interrupt_agent tool" do
      team_id = unique_id()
      {_orch_id, orch_pid} = start_orchestrator(team_id)
      builder_id = start_worker(team_id, "builder", nil)
      {:ok, builder_pid} = Agent.whereis(builder_id)

      stub(MockAI, :stream, fn _model, %Context{system: system, messages: msgs}, _opts ->
        has_tool_result = Enum.any?(msgs, &match?(%{role: :tool_result}, &1))

        cond do
          system =~ "builder" ->
            Process.sleep(300)
            [{:text_delta, "slow response"}, {:done, %{}}]

          system =~ "orchestrator" and has_tool_result ->
            [{:text_delta, "Interrupted."}, {:done, %{}}]

          true ->
            [
              {:tool_call_complete,
               %{id: "tc6", name: "interrupt_agent", args: %{"type" => "builder"}}},
              {:done, %{}}
            ]
        end
      end)

      Agent.prompt(builder_pid, "Do something slow")
      Process.sleep(50)

      Agent.subscribe(orch_pid)
      Agent.prompt(orch_pid, "Interrupt the builder.")

      assert_receive {:agent_event, :turn_end, %{message: %{content: [{:text, "Interrupted."}]}}},
                     3_000

      assert Agent.get_state(builder_pid).status == :idle
    end
  end
end
