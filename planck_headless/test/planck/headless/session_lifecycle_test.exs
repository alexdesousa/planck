defmodule Planck.Headless.SessionLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import Mox
  setup :set_mox_global
  setup :verify_on_exit!

  alias Planck.Agent.{MockAI, Session}
  alias Planck.AI.Model
  alias Planck.Headless
  alias Planck.Headless.Config

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :ollama,
    context_window: 4_096,
    max_tokens: 2_048
  }

  setup %{tmp_dir: dir} do
    sessions_dir = Path.join(dir, "sessions")
    File.mkdir_p!(sessions_dir)

    original = Application.get_env(:planck, :sessions_dir)
    Application.put_env(:planck, :sessions_dir, sessions_dir)
    Config.reload_sessions_dir()

    on_exit(fn ->
      # Close any sessions left open by the test.
      Headless.list_sessions()
      |> Enum.filter(& &1.active)
      |> Enum.each(fn %{session_id: sid} -> Headless.close_session(sid) end)

      Application.delete_env(:planck, :sessions_dir)
      if original, do: Application.put_env(:planck, :sessions_dir, original)
      Config.reload_sessions_dir()
    end)

    stub(MockAI, :get_model, fn :ollama, "llama3.2" -> {:ok, @model} end)

    {:ok, sessions_dir: sessions_dir}
  end

  defp write_team(dir, alias_name) do
    team_dir = Path.join(dir, alias_name)
    File.mkdir_p!(team_dir)

    File.write!(
      Path.join(team_dir, "TEAM.json"),
      Jason.encode!(%{
        "name" => alias_name,
        "members" => [
          %{
            "type" => "orchestrator",
            "provider" => "ollama",
            "model_id" => "llama3.2",
            "system_prompt" => "You coordinate.",
            "tools" => ["read", "write", "edit", "bash"]
          }
        ]
      })
    )

    team_dir
  end

  # --- start_session/1 ---

  describe "start_session/1" do
    test "starts a session with a static team from path", %{
      tmp_dir: dir,
      sessions_dir: sessions_dir
    } do
      team_dir = write_team(dir, "my-team")

      assert {:ok, session_id} = Headless.start_session(template: team_dir)
      assert is_binary(session_id)

      # Session file was created
      assert {:ok, _path, _name} = Session.find_by_id(sessions_dir, session_id)

      # Session is active (Session GenServer is running)
      assert {:ok, _pid} = Session.whereis(session_id)

      # Orchestrator is running — get team_id from metadata
      {:ok, meta} = Session.get_metadata(session_id)
      assert is_binary(meta["team_id"])
      assert {:ok, _pid} = find_orchestrator(meta["team_id"])
    end

    test "session file uses <id>_<name>.db format", %{tmp_dir: dir, sessions_dir: sessions_dir} do
      team_dir = write_team(dir, "named-team")

      {:ok, session_id} = Headless.start_session(template: team_dir, name: "my-session")

      assert {:ok, path, "my-session"} = Session.find_by_id(sessions_dir, session_id)
      assert Path.basename(path) == "#{session_id}_my-session.db"
    end

    test "session name is auto-generated when not provided", %{tmp_dir: dir} do
      team_dir = write_team(dir, "auto-name-team")

      {:ok, session_id} = Headless.start_session(template: team_dir)

      {:ok, meta} = Session.get_metadata(session_id)
      assert meta["session_name"] =~ ~r/^[a-z]+-[a-z]+$/
    end

    test "AGENTS.md in cwd is prepended to the orchestrator system prompt", %{tmp_dir: dir} do
      team_dir = write_team(dir, "agents-md-team")
      File.write!(Path.join(dir, "AGENTS.md"), "Project conventions go here.")

      {:ok, session_id} = Headless.start_session(template: team_dir, cwd: dir)
      {:ok, meta} = Session.get_metadata(session_id)
      {:ok, orch_pid} = find_orchestrator(meta["team_id"])

      system_prompt = Planck.Agent.get_state(orch_pid).system_prompt
      assert String.starts_with?(system_prompt, "Project conventions go here.")
      assert system_prompt =~ "You coordinate."
    end

    test "AGENTS.md stops at .git boundary and is not found above it", %{tmp_dir: dir} do
      project_dir = Path.join(dir, "project")
      File.mkdir_p!(Path.join(project_dir, ".git"))
      team_dir = write_team(project_dir, "bounded-team")
      File.write!(Path.join(dir, "AGENTS.md"), "Should not be loaded.")

      {:ok, session_id} = Headless.start_session(template: team_dir, cwd: project_dir)
      {:ok, meta} = Session.get_metadata(session_id)
      {:ok, orch_pid} = find_orchestrator(meta["team_id"])

      system_prompt = Planck.Agent.get_state(orch_pid).system_prompt
      refute system_prompt =~ "Should not be loaded."
    end

    test "AGENTS.md is found by walking up to the git root", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      subdir = Path.join(dir, "src/components")
      File.mkdir_p!(subdir)
      team_dir = write_team(dir, "walk-up-team")
      File.write!(Path.join(dir, "AGENTS.md"), "Root conventions.")

      {:ok, session_id} = Headless.start_session(template: team_dir, cwd: subdir)
      {:ok, meta} = Session.get_metadata(session_id)
      {:ok, orch_pid} = find_orchestrator(meta["team_id"])

      system_prompt = Planck.Agent.get_state(orch_pid).system_prompt
      assert String.starts_with?(system_prompt, "Root conventions.")
    end

    test "no AGENTS.md means system prompt is unchanged", %{tmp_dir: dir} do
      team_dir = write_team(dir, "no-agents-md-team")
      File.mkdir_p!(Path.join(dir, ".git"))

      {:ok, session_id} = Headless.start_session(template: team_dir, cwd: dir)
      {:ok, meta} = Session.get_metadata(session_id)
      {:ok, orch_pid} = find_orchestrator(meta["team_id"])

      system_prompt = Planck.Agent.get_state(orch_pid).system_prompt
      assert system_prompt == "You coordinate."
    end

    test "orchestrator has built-in tools and inter-agent tools", %{tmp_dir: dir} do
      team_dir = write_team(dir, "builtin-tools-team")

      {:ok, session_id} = Headless.start_session(template: team_dir)
      {:ok, meta} = Session.get_metadata(session_id)
      {:ok, orch_pid} = find_orchestrator(meta["team_id"])

      tool_names = Planck.Agent.get_state(orch_pid).tools |> Map.keys()

      # Built-in file tools
      assert "read" in tool_names
      assert "write" in tool_names
      assert "edit" in tool_names
      assert "bash" in tool_names

      # Orchestrator inter-agent tools
      assert "spawn_agent" in tool_names
      assert "destroy_agent" in tool_names
      assert "list_team" in tool_names
    end

    test "returns error when no default model configured and template is nil" do
      assert {:error, {:no_default_model_configured, _}} = Headless.start_session(template: nil)
    end

    test "starts a dynamic team session when default model is configured", %{tmp_dir: _dir} do
      Application.put_env(:planck, :default_provider, :ollama)
      Application.put_env(:planck, :default_model, "llama3.2")
      Planck.Headless.Config.reload_default_provider()
      Planck.Headless.Config.reload_default_model()

      on_exit(fn ->
        Application.delete_env(:planck, :default_provider)
        Application.delete_env(:planck, :default_model)
        Planck.Headless.Config.reload_default_provider()
        Planck.Headless.Config.reload_default_model()
      end)

      assert {:ok, session_id} = Headless.start_session()

      {:ok, meta} = Session.get_metadata(session_id)
      {:ok, orch_pid} = find_orchestrator(meta["team_id"])

      tool_names = Planck.Agent.get_state(orch_pid).tools |> Map.keys()

      assert "read" in tool_names
      assert "write" in tool_names
      assert "bash" in tool_names
      assert "spawn_agent" in tool_names
    end

    test "starts a session by team alias from ResourceStore", %{tmp_dir: dir} do
      write_team(dir, "my-alias-team")

      Application.put_env(:planck, :teams_dirs, [dir])
      Config.reload_teams_dirs()
      Planck.Headless.ResourceStore.reload()

      on_exit(fn ->
        Application.delete_env(:planck, :teams_dirs)
        Config.reload_teams_dirs()
        Planck.Headless.ResourceStore.reload()
      end)

      assert {:ok, session_id} = Headless.start_session(template: "my-alias-team")
      {:ok, meta} = Session.get_metadata(session_id)
      assert meta["team_alias"] == "my-alias-team"
    end

    test "returns error for unknown team alias" do
      assert {:error, {:team_not_found, "no-such-team"}} =
               Headless.start_session(template: "no-such-team")
    end

    test "metadata is saved to the session SQLite file", %{tmp_dir: dir} do
      team_dir = write_team(dir, "meta-team")

      {:ok, session_id} = Headless.start_session(template: team_dir, name: "my-meta-session")

      {:ok, meta} = Session.get_metadata(session_id)
      assert meta["team_alias"] == team_dir
      assert meta["team_id"] |> is_binary()
      assert meta["session_name"] == "my-meta-session"
      assert is_binary(meta["cwd"])
    end
  end

  # --- close_session/1 ---

  describe "close_session/1" do
    test "terminates agents and session GenServer", %{tmp_dir: dir} do
      team_dir = write_team(dir, "close-team")
      {:ok, session_id} = Headless.start_session(template: team_dir)

      {:ok, meta} = Session.get_metadata(session_id)
      {:ok, orch_pid} = find_orchestrator(meta["team_id"])

      assert :ok = Headless.close_session(session_id)

      assert {:error, :not_found} = Session.whereis(session_id)
      refute Process.alive?(orch_pid)
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Headless.close_session("ghost-session")
    end

    test "SQLite file is retained after close", %{tmp_dir: dir, sessions_dir: sessions_dir} do
      team_dir = write_team(dir, "retain-team")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      Headless.close_session(session_id)

      assert {:ok, _path, _name} = Session.find_by_id(sessions_dir, session_id)
    end
  end

  # --- prompt/2 ---

  describe "prompt/2" do
    test "dispatches to the orchestrator", %{tmp_dir: dir} do
      team_dir = write_team(dir, "prompt-team")
      {:ok, session_id} = Headless.start_session(template: team_dir)

      assert :ok = Headless.prompt(session_id, "hello")
    end

    test "returns error for closed session" do
      assert {:error, :not_found} = Headless.prompt("no-session", "hi")
    end
  end

  # --- list_sessions/0 ---

  describe "list_sessions/0" do
    test "returns active sessions with active: true", %{tmp_dir: dir} do
      team_dir = write_team(dir, "list-team")
      {:ok, session_id} = Headless.start_session(template: team_dir)

      sessions = Headless.list_sessions()
      entry = Enum.find(sessions, &(&1.session_id == session_id))

      assert entry != nil
      assert entry.active == true
      assert is_binary(entry.name)
    end

    test "includes inactive sessions from disk", %{tmp_dir: dir, sessions_dir: sessions_dir} do
      team_dir = write_team(dir, "inactive-team")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      Headless.close_session(session_id)

      # File still exists
      assert {:ok, _path, _} = Session.find_by_id(sessions_dir, session_id)

      sessions = Headless.list_sessions()
      entry = Enum.find(sessions, &(&1.session_id == session_id))

      assert entry != nil
      assert entry.active == false
    end
  end

  # --- resume_session/1 ---

  describe "resume_session/1" do
    test "resumes by session_id", %{tmp_dir: dir} do
      team_dir = write_team(dir, "resume-team")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      Headless.close_session(session_id)

      assert {:ok, ^session_id} = Headless.resume_session(session_id)
      assert {:ok, _pid} = Session.whereis(session_id)
    end

    test "resumes by session name", %{tmp_dir: dir} do
      team_dir = write_team(dir, "resume-by-name")
      {:ok, session_id} = Headless.start_session(template: team_dir, name: "bright-mango")
      Headless.close_session(session_id)

      assert {:ok, ^session_id} = Headless.resume_session("bright-mango")
    end

    test "clean resume injects no recovery message", %{tmp_dir: dir} do
      team_dir = write_team(dir, "clean-resume")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      {:ok, meta} = Session.get_metadata(session_id)
      orch_id = orchestrator_id_for(meta["team_id"])
      count_before = message_count(session_id, orch_id)

      Headless.close_session(session_id)
      Headless.resume_session(session_id)

      # No extra message injected for a clean session (no in-flight work).
      assert message_count(session_id, orch_id) == count_before
    end

    test "resume injects recovery message for unresolved ask_agent", %{tmp_dir: dir} do
      team_dir = write_team(dir, "recovery-ask")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      {:ok, meta} = Session.get_metadata(session_id)
      old_orch_id = orchestrator_id_for(meta["team_id"])

      # Simulate an ask_agent call with no tool result (blocked, never resolved).
      ask_msg =
        Planck.Agent.Message.new(:assistant, [
          {:tool_call, "call-1", "ask_agent",
           %{"type" => "builder", "question" => "What is 2+2?"}}
        ])

      Session.append(session_id, old_orch_id, ask_msg)

      Headless.close_session(session_id)
      {:ok, ^session_id} = Headless.resume_session(session_id)

      # Agent IDs are preserved across resumes.
      {:ok, new_meta} = Session.get_metadata(session_id)
      new_orch_id = orchestrator_id_for(new_meta["team_id"])
      assert new_orch_id == old_orch_id

      # Recovery is appended as the last message under the (stable) orchestrator id.
      {:ok, rows} = Session.messages(session_id, agent_id: new_orch_id)
      recovery = List.last(rows).message
      assert recovery.role == :user
      assert hd(recovery.content) |> elem(1) =~ "ask_agent"
      assert hd(recovery.content) |> elem(1) =~ "What is 2+2?"
    end

    test "reconstructs dynamically-spawned workers from spawn_agent history", %{tmp_dir: dir} do
      team_dir = write_team(dir, "dynamic-workers")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      {:ok, meta} = Session.get_metadata(session_id)
      old_orch_id = orchestrator_id_for(meta["team_id"])

      # Simulate a completed spawn_agent call (tool_call + tool_result pair).
      call_id = "spawn-1"

      spawn_msg =
        Planck.Agent.Message.new(:assistant, [
          {:tool_call, call_id, "spawn_agent",
           %{
             "type" => "reviewer",
             "name" => "Reviewer",
             "description" => "Reviews code.",
             "system_prompt" => "You are a code reviewer.",
             "provider" => "ollama",
             "model_id" => "llama3.2",
             "tools" => []
           }}
        ])

      result_msg =
        Planck.Agent.Message.new(:tool_result, [
          {:tool_result, call_id, {:ok, "agent-id-abc"}}
        ])

      Session.append(session_id, old_orch_id, spawn_msg)
      Session.append(session_id, old_orch_id, result_msg)

      Headless.close_session(session_id)
      {:ok, ^session_id} = Headless.resume_session(session_id)

      {:ok, new_meta} = Session.get_metadata(session_id)
      team_id = new_meta["team_id"]

      # The "reviewer" worker should be registered in the team registry.
      assert [{_pid, _meta} | _] =
               Registry.lookup(Planck.Agent.Registry, {team_id, "reviewer"})
    end

    test "resume injects recovery message for unfinished delegate_task worker", %{tmp_dir: dir} do
      team_dir = write_team(dir, "recovery-delegate")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      {:ok, meta} = Session.get_metadata(session_id)
      old_orch_id = orchestrator_id_for(meta["team_id"])

      # Orchestrator delegates a task to a worker by type.
      delegate_msg =
        Planck.Agent.Message.new(:assistant, [
          {:tool_call, "d-1", "delegate_task",
           %{"type" => "builder", "task" => "Implement the login endpoint"}}
        ])

      Session.append(session_id, old_orch_id, delegate_msg)

      # Worker starts but never calls send_response.
      worker_id = "worker-old-#{System.unique_integer()}"

      worker_start =
        Planck.Agent.Message.new(:user, [{:text, "Implement the login endpoint"}])

      worker_partial =
        Planck.Agent.Message.new(:assistant, [{:text, "I'll start with the route…"}])

      Session.append(session_id, worker_id, worker_start)
      Session.append(session_id, worker_id, worker_partial)

      Headless.close_session(session_id)
      {:ok, ^session_id} = Headless.resume_session(session_id)

      {:ok, new_meta} = Session.get_metadata(session_id)
      new_orch_id = orchestrator_id_for(new_meta["team_id"])
      assert new_orch_id == old_orch_id

      {:ok, rows} = Session.messages(session_id, agent_id: new_orch_id)
      text = List.last(rows).message.content |> hd() |> elem(1)

      # Target and task text are both present in the recovery message.
      assert text =~ "builder"
      assert text =~ "Implement the login endpoint"
    end

    test "resume does not inject a second recovery message if one already exists", %{tmp_dir: dir} do
      team_dir = write_team(dir, "recovery-dedup")
      {:ok, session_id} = Headless.start_session(template: team_dir)
      {:ok, meta} = Session.get_metadata(session_id)
      old_orch_id = orchestrator_id_for(meta["team_id"])

      ask_msg =
        Planck.Agent.Message.new(:assistant, [
          {:tool_call, "c-1", "ask_agent", %{"type" => "builder", "question" => "Are you done?"}}
        ])

      Session.append(session_id, old_orch_id, ask_msg)

      # First resume — injects recovery.
      Headless.close_session(session_id)
      {:ok, ^session_id} = Headless.resume_session(session_id)

      {:ok, new_meta} = Session.get_metadata(session_id)
      new_orch_id = orchestrator_id_for(new_meta["team_id"])
      assert new_orch_id == old_orch_id

      {:ok, rows_after_first} = Session.messages(session_id, agent_id: new_orch_id)
      count_after_first = length(rows_after_first)
      assert List.last(rows_after_first).message.role == :user

      # Second resume — must NOT inject another recovery message.
      Headless.close_session(session_id)
      {:ok, ^session_id} = Headless.resume_session(session_id)

      {:ok, new_meta2} = Session.get_metadata(session_id)
      new_orch_id2 = orchestrator_id_for(new_meta2["team_id"])
      {:ok, rows_after_second} = Session.messages(session_id, agent_id: new_orch_id2)
      assert length(rows_after_second) == count_after_first
    end

    test "returns error for non-existent session" do
      assert {:error, _} = Headless.resume_session("ghost-session")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_orchestrator(team_id) do
    case Registry.lookup(Planck.Agent.Registry, {team_id, "orchestrator"}) do
      [{pid, _} | _] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp orchestrator_id_for(team_id) do
    {:ok, pid} = find_orchestrator(team_id)
    Planck.Agent.get_info(pid).id
  end

  defp message_count(session_id, agent_id) do
    {:ok, rows} = Session.messages(session_id, agent_id: agent_id)
    length(rows)
  end
end
