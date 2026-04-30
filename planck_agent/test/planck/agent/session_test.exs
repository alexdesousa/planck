defmodule Planck.Agent.SessionTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Planck.Agent.{Message, Session}

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "planck_session_test_#{unique_id()}")
    File.mkdir_p!(dir)
    dir
  end

  defp start_session(opts \\ []) do
    id = unique_id()
    name = Keyword.get(opts, :name, "test-session")
    dir = Keyword.get(opts, :dir, tmp_dir())
    {:ok, pid} = Session.start(id, name: name, dir: dir)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Planck.Agent.SessionSupervisor, pid)
      end

      File.rm_rf!(dir)
    end)

    {id, pid}
  end

  defp user_msg(text), do: Message.new(:user, [{:text, text}])
  defp assistant_msg(text), do: Message.new(:assistant, [{:text, text}])
  defp summary_msg(text), do: Message.new({:custom, :summary}, [{:text, text}])

  describe "start/2 and whereis/1" do
    test "started session is findable by id" do
      {id, pid} = start_session()
      assert {:ok, ^pid} = Session.whereis(id)
    end

    test "unknown session returns :not_found" do
      assert {:error, :not_found} = Session.whereis("no-such-session")
    end

    test "stop/1 terminates the session" do
      {id, _pid} = start_session()
      :ok = Session.stop(id)
      Process.sleep(50)
      assert {:error, :not_found} = Session.whereis(id)
    end
  end

  describe "append/3 and messages/2" do
    test "appended messages are returned in order" do
      {id, _} = start_session()
      m1 = user_msg("hello")
      m2 = assistant_msg("hi there")

      Session.append(id, "a1", m1)
      Session.append(id, "a1", m2)

      # cast is async — give it a moment to land
      Process.sleep(50)

      {:ok, rows} = Session.messages(id)
      assert length(rows) == 2
      # id is set to the db row id on reload; compare content only
      assert Enum.at(rows, 0).message.content == m1.content
      assert Enum.at(rows, 0).message.role == m1.role
      assert Enum.at(rows, 1).message.content == m2.content
      assert Enum.at(rows, 1).message.role == m2.role
    end

    test "messages round-trip losslessly through binary serialization" do
      {id, _} = start_session()
      msg = Message.new(:assistant, [{:text, "ok"}, {:tool_call, "c1", "echo", %{"x" => 1}}])

      Session.append(id, "a1", msg)
      Process.sleep(50)

      {:ok, [row]} = Session.messages(id)
      # id is set to the db row id on reload; compare content/role
      assert row.message.content == msg.content
      assert row.message.role == msg.role
      assert is_integer(row.message.id)
    end

    test "messages from multiple agents are stored together" do
      {id, _} = start_session()
      Session.append(id, "agent-a", user_msg("from a"))
      Session.append(id, "agent-b", user_msg("from b"))
      Process.sleep(50)

      {:ok, rows} = Session.messages(id)
      assert length(rows) == 2
      assert Enum.map(rows, & &1.agent_id) == ["agent-a", "agent-b"]
    end

    test "agent_id filter returns only that agent's messages" do
      {id, _} = start_session()
      Session.append(id, "agent-a", user_msg("from a"))
      Session.append(id, "agent-b", user_msg("from b"))
      Session.append(id, "agent-a", assistant_msg("reply from a"))
      Process.sleep(50)

      {:ok, rows} = Session.messages(id, agent_id: "agent-a")
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.agent_id == "agent-a"))
    end

    test "messages/2 returns :not_found for unknown session" do
      assert {:error, :not_found} = Session.messages("ghost")
    end

    test "append/3 returns nil for unknown session" do
      assert nil == Session.append("ghost", "a1", user_msg("hi"))
    end
  end

  describe "messages_from_latest_checkpoint/2" do
    test "returns all messages when no checkpoint exists" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("first"))
      Session.append(id, "a1", assistant_msg("reply"))
      Process.sleep(50)

      {:ok, rows, checkpoint_id} = Session.messages_from_latest_checkpoint(id)
      assert length(rows) == 2
      assert checkpoint_id == nil
    end

    test "returns checkpoint + messages after it" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("old"))
      Session.append(id, "a1", summary_msg("summary of old"))
      Session.append(id, "a1", user_msg("new"))
      Process.sleep(50)

      {:ok, rows, checkpoint_id} = Session.messages_from_latest_checkpoint(id)
      assert length(rows) == 2
      assert Enum.at(rows, 0).message.role == {:custom, :summary}
      assert Enum.at(rows, 1).message.content == [text: "new"]
      assert is_integer(checkpoint_id)
    end

    test "returns only the latest checkpoint when multiple exist" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("chapter 1"))
      Session.append(id, "a1", summary_msg("summary 1"))
      Session.append(id, "a1", user_msg("chapter 2"))
      Session.append(id, "a1", summary_msg("summary 2"))
      Session.append(id, "a1", user_msg("chapter 3"))
      Process.sleep(50)

      {:ok, rows, _checkpoint_id} = Session.messages_from_latest_checkpoint(id)
      assert length(rows) == 2
      assert Enum.at(rows, 0).message.content == [text: "summary 2"]
      assert Enum.at(rows, 1).message.content == [text: "chapter 3"]
    end

    test "agent_id filter scopes checkpoint lookup" do
      {id, _} = start_session()
      Session.append(id, "a1", summary_msg("a1 summary"))
      Session.append(id, "a1", user_msg("a1 new"))
      Session.append(id, "a2", user_msg("a2 msg"))
      Process.sleep(50)

      {:ok, rows, _} = Session.messages_from_latest_checkpoint(id, agent_id: "a2")
      assert length(rows) == 1
      assert Enum.at(rows, 0).agent_id == "a2"
    end

    test "returns :not_found for unknown session" do
      assert {:error, :not_found} = Session.messages_from_latest_checkpoint("ghost")
    end
  end

  describe "truncate_after/2" do
    test "deletes all messages at and after the given db_id" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("first"))
      Session.append(id, "a1", user_msg("second"))
      Session.append(id, "a1", user_msg("third"))
      Process.sleep(50)

      {:ok, rows} = Session.messages(id)
      assert length(rows) == 3

      second_db_id = Enum.at(rows, 1).db_id

      :ok = Session.truncate_after(id, second_db_id)

      {:ok, rows_after} = Session.messages(id)
      assert length(rows_after) == 1
      assert Enum.at(rows_after, 0).message.content == [text: "first"]
    end

    test "rows include db_id as a positive integer" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("hello"))
      Process.sleep(50)

      {:ok, rows} = Session.messages(id)
      assert is_integer(hd(rows).db_id) and hd(rows).db_id > 0
    end

    test "deletes across all agents, not just the target agent" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("a1 first"))
      Session.append(id, "a2", user_msg("a2 first"))
      Session.append(id, "a1", user_msg("a1 second"))
      Process.sleep(50)

      {:ok, rows} = Session.messages(id)
      # db_id of a2's message — everything at and after it (including a1 second) should go
      a2_db_id = Enum.find(rows, &(&1.agent_id == "a2")).db_id

      :ok = Session.truncate_after(id, a2_db_id)

      {:ok, rows_after} = Session.messages(id)
      assert length(rows_after) == 1
      assert hd(rows_after).agent_id == "a1"
      assert hd(rows_after).message.content == [text: "a1 first"]
    end

    test "truncating at the first row leaves no messages" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("only"))
      Process.sleep(50)

      {:ok, [row]} = Session.messages(id)
      :ok = Session.truncate_after(id, row.db_id)

      {:ok, rows_after} = Session.messages(id)
      assert rows_after == []
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = Session.truncate_after("ghost-session", 1)
    end
  end

  describe "messages_before_checkpoint/3" do
    test "returns messages before a checkpoint with previous checkpoint as cursor" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("chapter 1"))
      Session.append(id, "a1", summary_msg("summary 1"))
      Session.append(id, "a1", user_msg("chapter 2"))
      Session.append(id, "a1", summary_msg("summary 2"))
      Session.append(id, "a1", user_msg("chapter 3"))
      Process.sleep(50)

      {:ok, _latest, checkpoint_id} = Session.messages_from_latest_checkpoint(id)

      {:ok, rows, prev_id} = Session.messages_before_checkpoint(id, checkpoint_id)
      assert length(rows) == 2
      assert Enum.at(rows, 0).message.content == [text: "summary 1"]
      assert Enum.at(rows, 1).message.content == [text: "chapter 2"]
      assert is_integer(prev_id)
    end

    test "returns nil prev_checkpoint_id when no earlier checkpoint exists" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("old"))
      Session.append(id, "a1", summary_msg("only summary"))
      Session.append(id, "a1", user_msg("new"))
      Process.sleep(50)

      {:ok, _latest, checkpoint_id} = Session.messages_from_latest_checkpoint(id)

      {:ok, rows, prev_id} = Session.messages_before_checkpoint(id, checkpoint_id)
      assert length(rows) == 1
      assert Enum.at(rows, 0).message.content == [text: "old"]
      assert prev_id == nil
    end

    test "returns :not_found for unknown session" do
      assert {:error, :not_found} = Session.messages_before_checkpoint("ghost", 1)
    end
  end

  describe "persistence" do
    test "messages survive a GenServer restart" do
      dir = tmp_dir()
      {id, pid} = start_session(name: "restart-test", dir: dir)

      msg = user_msg("before restart")
      Session.append(id, "a1", msg)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(Planck.Agent.SessionSupervisor, pid)
      Process.sleep(50)

      {:ok, _new_pid} = Session.start(id, name: "restart-test", dir: dir)

      {:ok, rows} = Session.messages(id)
      assert length(rows) == 1
      assert Enum.at(rows, 0).message.content == msg.content
      assert Enum.at(rows, 0).message.role == msg.role
    end
  end

  describe "find_by_id/2 and find_by_name/2" do
    test "find_by_id resolves path and name", %{tmp_dir: dir} do
      {id, _pid} = start_session(name: "crazy-mango", dir: dir)

      assert {:ok, path, "crazy-mango"} = Session.find_by_id(dir, id)
      assert Path.basename(path) == "#{id}_crazy-mango.db"
    end

    test "find_by_name resolves path and id", %{tmp_dir: dir} do
      {id, _pid} = start_session(name: "silent-papaya", dir: dir)

      assert {:ok, path, ^id} = Session.find_by_name(dir, "silent-papaya")
      assert Path.basename(path) == "#{id}_silent-papaya.db"
    end

    test "find_by_id returns :not_found for unknown id", %{tmp_dir: dir} do
      assert {:error, :not_found} = Session.find_by_id(dir, "deadbeef")
    end

    test "find_by_name returns :not_found for unknown name", %{tmp_dir: dir} do
      assert {:error, :not_found} = Session.find_by_name(dir, "no-such-name")
    end
  end

  describe "save_metadata/2 and get_metadata/1" do
    test "saves and retrieves metadata", %{tmp_dir: dir} do
      {id, _pid} = start_session(dir: dir)

      :ok = Session.save_metadata(id, %{"team_alias" => "elixir-team", "cwd" => "/app"})
      {:ok, meta} = Session.get_metadata(id)

      assert meta["team_alias"] == "elixir-team"
      assert meta["cwd"] == "/app"
    end

    test "save_metadata merges — later call overwrites individual keys", %{tmp_dir: dir} do
      {id, _pid} = start_session(dir: dir)

      :ok = Session.save_metadata(id, %{"a" => "1", "b" => "2"})
      :ok = Session.save_metadata(id, %{"b" => "updated", "c" => "3"})
      {:ok, meta} = Session.get_metadata(id)

      assert meta["a"] == "1"
      assert meta["b"] == "updated"
      assert meta["c"] == "3"
    end

    test "nil values are stored and returned as nil", %{tmp_dir: dir} do
      {id, _pid} = start_session(dir: dir)

      :ok = Session.save_metadata(id, %{"team_alias" => nil})
      {:ok, meta} = Session.get_metadata(id)

      assert meta["team_alias"] == nil
    end

    test "get_metadata returns empty map when no metadata saved", %{tmp_dir: dir} do
      {id, _pid} = start_session(dir: dir)

      {:ok, meta} = Session.get_metadata(id)
      assert meta == %{}
    end

    test "metadata persists across restart", %{tmp_dir: dir} do
      id = unique_id()
      {:ok, pid} = Session.start(id, name: "persist-meta", dir: dir)

      :ok = Session.save_metadata(id, %{"team_alias" => "my-team"})
      Process.sleep(50)

      DynamicSupervisor.terminate_child(Planck.Agent.SessionSupervisor, pid)
      Process.sleep(50)

      {:ok, _} = Session.start(id, name: "persist-meta", dir: dir)
      {:ok, meta} = Session.get_metadata(id)

      assert meta["team_alias"] == "my-team"

      Session.stop(id)
      File.rm_rf!(dir)
    end
  end
end
