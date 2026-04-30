defmodule Planck.Web.API.EventControllerTest do
  use Planck.Web.ConnCase, async: false

  @moduletag :tmp_dir

  import Mox
  setup :set_mox_global
  setup :verify_on_exit!

  alias Planck.Agent.MockAI
  alias Planck.AI.Model
  alias Planck.Headless
  alias Planck.Headless.Config

  @model %Model{
    id: "llama3.2",
    provider: :ollama,
    context_window: 4_096,
    max_tokens: 2_048
  }

  setup %{conn: conn, tmp_dir: dir} do
    sessions_dir = Path.join(dir, "sessions")
    File.mkdir_p!(sessions_dir)

    original = Application.get_env(:planck, :sessions_dir)
    Application.put_env(:planck, :sessions_dir, sessions_dir)
    Config.reload_sessions_dir()

    on_exit(fn ->
      Headless.list_sessions()
      |> Enum.filter(& &1.active)
      |> Enum.each(fn %{session_id: sid} -> Headless.close_session(sid) end)

      Application.delete_env(:planck, :sessions_dir)
      if original, do: Application.put_env(:planck, :sessions_dir, original)
      Config.reload_sessions_dir()
    end)

    stub(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

    {:ok, conn: conn, team_dir: write_team(dir)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_sse(conn, session_id) do
    task = Task.async(fn -> get(conn, "/api/sessions/#{session_id}/events") end)
    # Wait for the PubSub subscription to establish before prompting.
    Process.sleep(50)
    task
  end

  defp stop_sse(task) do
    send(task.pid, :stop)

    case Task.yield(task, 1_000) do
      {:ok, conn} -> parse_frames(conn.resp_body)
      _ -> flunk("SSE task did not stop within 1 second")
    end
  end

  # Subscribe once before the prompt. Each `wait_for_event` call drains one
  # occurrence from the test-process mailbox. Call `stop_watching/1` when done.
  defp start_watching(session_id) do
    Phoenix.PubSub.subscribe(Planck.Agent.PubSub, "session:#{session_id}")
    session_id
  end

  defp wait_for_event(session_id, event_type, timeout \\ 2_000) do
    assert_receive {:agent_event, ^event_type, payload},
                   timeout,
                   "Timed out waiting for #{event_type} on session #{session_id}"

    payload
  end

  defp stop_watching(session_id) do
    Phoenix.PubSub.unsubscribe(Planck.Agent.PubSub, "session:#{session_id}")
  end

  defp parse_frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(&parse_frame/1)
  end

  defp parse_frame(frame) do
    lines = String.split(frame, "\n")

    event =
      Enum.find_value(lines, fn l ->
        if String.starts_with?(l, "event: "), do: String.replace_prefix(l, "event: ", "")
      end)

    data =
      Enum.find_value(lines, fn l ->
        if String.starts_with?(l, "data: ") do
          l |> String.replace_prefix("data: ", "") |> Jason.decode!()
        end
      end)

    if event && data, do: [{event, data}], else: []
  end

  defp event_names(frames), do: Enum.map(frames, &elem(&1, 0))

  # ---------------------------------------------------------------------------
  # Real-session tests
  # ---------------------------------------------------------------------------

  test "turn_start, text_delta, turn_end, usage_delta from a basic text turn",
       %{conn: conn, team_dir: team_dir} do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      [
        {:text_delta, "Hello"},
        {:text_delta, " world"},
        {:done, %{usage: %{input_tokens: 10, output_tokens: 2}}}
      ]
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)
    start_watching(sid)
    task = start_sse(conn, sid)
    Headless.prompt(sid, "say hello")

    wait_for_event(sid, :turn_end)
    stop_watching(sid)
    # Give the SSE task time to drain its mailbox after turn_end arrived.
    Process.sleep(100)
    frames = stop_sse(task)
    names = event_names(frames)

    assert "turn_start" in names
    assert "turn_end" in names
    assert Enum.any?(frames, &match?({"text_delta", %{"text" => "Hello"}}, &1))
    assert Enum.any?(frames, &match?({"usage_delta", %{"total" => %{"input_tokens" => 10}}}, &1))
  end

  test "events arrive in order", %{conn: conn, team_dir: team_dir} do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      [{:text_delta, "A"}, {:text_delta, "B"}, {:done, %{}}]
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)
    start_watching(sid)
    task = start_sse(conn, sid)
    Headless.prompt(sid, "stream two chunks")

    wait_for_event(sid, :turn_end)
    stop_watching(sid)
    Process.sleep(100)
    names = event_names(stop_sse(task))

    turn_start_idx = Enum.find_index(names, &(&1 == "turn_start"))
    turn_end_idx = Enum.find_index(names, &(&1 == "turn_end"))

    text_indices =
      names
      |> Enum.with_index()
      |> Enum.filter(&match?({"text_delta", _}, &1))
      |> Enum.map(&elem(&1, 1))

    assert turn_start_idx < hd(text_indices)
    assert List.last(text_indices) < turn_end_idx
  end

  test "thinking_delta from a turn with extended thinking",
       %{conn: conn, team_dir: team_dir} do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      [{:thinking_delta, "Let me think…"}, {:text_delta, "Done."}, {:done, %{}}]
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)
    start_watching(sid)
    task = start_sse(conn, sid)
    Headless.prompt(sid, "think first")

    wait_for_event(sid, :turn_end)
    stop_watching(sid)
    Process.sleep(100)
    frames = stop_sse(task)

    assert Enum.any?(frames, &match?({"thinking_delta", %{"text" => "Let me think…"}}, &1))
  end

  test "tool_start and tool_end when the orchestrator calls a tool",
       %{conn: conn, team_dir: team_dir} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stub(MockAI, :stream, fn _model, _context, _opts ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n == 0 do
        [
          {:tool_call_complete, %{id: "tc1", name: "read", args: %{"path" => __ENV__.file}}},
          {:done, %{}}
        ]
      else
        [{:text_delta, "Done."}, {:done, %{}}]
      end
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)
    start_watching(sid)
    task = start_sse(conn, sid)
    Headless.prompt(sid, "read a file")

    # Wait for tool lifecycle and the final turn_end before stopping.
    wait_for_event(sid, :tool_start)
    wait_for_event(sid, :tool_end)
    wait_for_event(sid, :turn_end)
    stop_watching(sid)
    Process.sleep(100)
    frames = stop_sse(task)
    names = event_names(frames)

    assert "tool_start" in names
    assert "tool_end" in names
    assert Enum.any?(frames, &match?({"tool_start", %{"name" => "read", "id" => "tc1"}}, &1))
    assert Enum.any?(frames, &match?({"tool_end", %{"id" => "tc1", "error" => false}}, &1))
  end

  test "worker_spawned when orchestrator spawns a worker",
       %{conn: conn, team_dir: team_dir} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    spawn_args = %{
      "type" => "worker",
      "name" => "Helper",
      "description" => "A helper worker",
      "system_prompt" => "You help.",
      "provider" => "ollama",
      "model_id" => "llama3.2"
    }

    stub(MockAI, :stream, fn _model, _context, _opts ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n == 0 do
        [
          {:tool_call_complete, %{id: "tc1", name: "spawn_agent", args: spawn_args}},
          {:done, %{}}
        ]
      else
        [{:text_delta, "Worker spawned."}, {:done, %{}}]
      end
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)
    start_watching(sid)
    task = start_sse(conn, sid)
    Headless.prompt(sid, "spawn a helper")

    wait_for_event(sid, :worker_spawned)
    wait_for_event(sid, :turn_end)
    stop_watching(sid)
    Process.sleep(100)
    frames = stop_sse(task)

    assert Enum.any?(frames, &match?({"worker_spawned", _}, &1))
  end

  test "error event when the LLM stream returns an error", %{conn: conn, team_dir: team_dir} do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      [{:error, "simulated model failure"}, {:done, %{}}]
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)
    start_watching(sid)
    task = start_sse(conn, sid)
    Headless.prompt(sid, "trigger an error")

    wait_for_event(sid, :error)
    stop_watching(sid)
    Process.sleep(100)
    frames = stop_sse(task)

    assert Enum.any?(frames, &match?({"error", %{"agent_id" => _}}, &1))
  end

  # ---------------------------------------------------------------------------
  # Single-agent filter (?agent_id=)
  # ---------------------------------------------------------------------------

  test "?agent_id= streams only events for that agent and injects agent_id",
       %{conn: conn, team_dir: team_dir} do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      [{:text_delta, "hi"}, {:done, %{}}]
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)

    # Discover the orchestrator id from the session.
    {:ok, meta} = Planck.Agent.Session.get_metadata(sid)

    {orch_pid, _} =
      Registry.lookup(Planck.Agent.Registry, {meta["team_id"], "orchestrator"}) |> hd()

    orch_id = Planck.Agent.get_info(orch_pid).id

    # Subscribe filtered to just the orchestrator.
    task =
      Task.async(fn ->
        get(conn, "/api/sessions/#{sid}/events?agent_id=#{orch_id}")
      end)

    Process.sleep(50)

    start_watching(sid)
    Headless.prompt(sid, "hello")
    wait_for_event(sid, :turn_end)
    stop_watching(sid)
    Process.sleep(100)
    frames = stop_sse(task)

    # Every frame should carry the orchestrator's agent_id.
    assert frames != []

    assert Enum.all?(frames, fn {_event, data} ->
             data["agent_id"] == orch_id
           end)
  end

  test "?agent_id= returns 404 when agent does not belong to the session",
       %{conn: conn, team_dir: team_dir} do
    {:ok, sid} = Headless.start_session(template: team_dir)
    {:ok, sid2} = Headless.start_session(template: team_dir)

    {:ok, meta2} = Planck.Agent.Session.get_metadata(sid2)
    {pid2, _} = Registry.lookup(Planck.Agent.Registry, {meta2["team_id"], "orchestrator"}) |> hd()
    other_agent_id = Planck.Agent.get_info(pid2).id

    # Agent from session 2 — should be rejected when queried against session 1.
    conn = get(conn, "/api/sessions/#{sid}/events?agent_id=#{other_agent_id}")
    assert json_response(conn, 404)["error"]
  end

  test "?agent_id= does not receive events from other agents",
       %{conn: conn, team_dir: team_dir} do
    stub(MockAI, :stream, fn _model, _context, _opts ->
      [{:text_delta, "hi"}, {:done, %{}}]
    end)

    {:ok, sid} = Headless.start_session(template: team_dir)

    # Subscribe to a made-up agent id — should receive no events at all.
    task = Task.async(fn -> get(conn, "/api/sessions/#{sid}/events?agent_id=nonexistent") end)
    Process.sleep(50)

    start_watching(sid)
    Headless.prompt(sid, "hello")
    wait_for_event(sid, :turn_end)
    stop_watching(sid)
    Process.sleep(100)
    frames = stop_sse(task)

    assert frames == []
  end

  # ---------------------------------------------------------------------------
  # Direct-broadcast tests
  # (compacting/compacted require exceeding the context window — impractical
  # to trigger naturally in a unit test)
  # ---------------------------------------------------------------------------

  test "compacting and compacted events", %{conn: conn, team_dir: team_dir} do
    {:ok, sid} = Headless.start_session(template: team_dir)
    task = start_sse(conn, sid)

    Phoenix.PubSub.broadcast(
      Planck.Agent.PubSub,
      "session:#{sid}",
      {:agent_event, :compacting, %{agent_id: "orch"}}
    )

    Phoenix.PubSub.broadcast(
      Planck.Agent.PubSub,
      "session:#{sid}",
      {:agent_event, :compacted, %{agent_id: "orch"}}
    )

    Process.sleep(100)

    frames = stop_sse(task)
    names = event_names(frames)

    assert "compacting" in names
    assert "compacted" in names
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_team(dir) do
    team_dir = Path.join(dir, "test-team")
    File.mkdir_p!(team_dir)

    File.write!(
      Path.join(team_dir, "TEAM.json"),
      Jason.encode!(%{
        "name" => "test-team",
        "members" => [
          %{
            "type" => "orchestrator",
            "provider" => "ollama",
            "model_id" => "llama3.2",
            "system_prompt" => "You are a helpful orchestrator.",
            "tools" => ["read", "write", "edit", "bash"]
          }
        ]
      })
    )

    team_dir
  end
end
