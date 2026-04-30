defmodule Planck.Agent.SessionTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.{Message, Session}

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "planck_session_test_#{unique_id()}")
    File.mkdir_p!(dir)
    dir
  end

  defp start_session(opts \\ []) do
    id = unique_id()
    dir = Keyword.get(opts, :dir, tmp_dir())
    {:ok, pid} = Session.start(id, dir: dir)

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
      assert Enum.at(rows, 0).message == m1
      assert Enum.at(rows, 1).message == m2
    end

    test "messages round-trip losslessly through binary serialization" do
      {id, _} = start_session()
      msg = Message.new(:assistant, [{:text, "ok"}, {:tool_call, "c1", "echo", %{"x" => 1}}])

      Session.append(id, "a1", msg)
      Process.sleep(50)

      {:ok, [row]} = Session.messages(id)
      assert row.message == msg
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

    test "append/3 silently no-ops for unknown session" do
      assert :ok = Session.append("ghost", "a1", user_msg("hi"))
    end
  end

  describe "truncate_agent/3" do
    test "keeps first keep_count messages for that agent" do
      {id, _} = start_session()
      for i <- 1..5, do: Session.append(id, "a1", user_msg("msg #{i}"))
      Process.sleep(50)

      Session.truncate_agent(id, "a1", 3)
      Process.sleep(50)

      {:ok, rows} = Session.messages(id, agent_id: "a1")
      assert length(rows) == 3
      assert Enum.at(rows, 0).message.content == [text: "msg 1"]
      assert Enum.at(rows, 2).message.content == [text: "msg 3"]
    end

    test "keep_count of 0 deletes all messages for that agent" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("gone"))
      Session.append(id, "a2", user_msg("stays"))
      Process.sleep(50)

      Session.truncate_agent(id, "a1", 0)
      Process.sleep(50)

      {:ok, rows_a1} = Session.messages(id, agent_id: "a1")
      {:ok, rows_a2} = Session.messages(id, agent_id: "a2")
      assert rows_a1 == []
      assert length(rows_a2) == 1
    end

    test "does not affect other agents' messages" do
      {id, _} = start_session()
      Session.append(id, "a1", user_msg("a1 msg 1"))
      Session.append(id, "a1", user_msg("a1 msg 2"))
      Session.append(id, "a2", user_msg("a2 msg"))
      Process.sleep(50)

      Session.truncate_agent(id, "a1", 1)
      Process.sleep(50)

      {:ok, rows} = Session.messages(id)
      assert length(rows) == 2
    end

    test "silently no-ops for unknown session" do
      assert :ok = Session.truncate_agent("ghost", "a1", 0)
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
      {id, pid} = start_session(dir: dir)

      msg = user_msg("before restart")
      Session.append(id, "a1", msg)
      Process.sleep(50)

      DynamicSupervisor.terminate_child(Planck.Agent.SessionSupervisor, pid)
      Process.sleep(50)

      {:ok, _new_pid} = Session.start(id, dir: dir)

      {:ok, rows} = Session.messages(id)
      assert length(rows) == 1
      assert Enum.at(rows, 0).message == msg
    end
  end
end
