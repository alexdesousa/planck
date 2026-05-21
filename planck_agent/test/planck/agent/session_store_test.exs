defmodule Planck.Agent.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.{Message, Session, SessionStore}

  defp setup_session(_) do
    session_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "planck_test_#{session_id}")
    {:ok, _} = Session.start(session_id, name: "test", dir: dir)

    on_exit(fn ->
      Session.stop(session_id)
      File.rm_rf!(dir)
    end)

    %{session_id: session_id}
  end

  describe "strip_orphaned_tool_call/2" do
    defp row(msg), do: %{message: msg, db_id: System.unique_integer([:positive])}

    test "returns empty list unchanged" do
      assert SessionStore.strip_orphaned_tool_call(nil, []) == []
    end

    test "returns rows unchanged when last message has no tool calls" do
      rows = [
        row(Message.new(:user, [{:text, "hi"}])),
        row(Message.new(:assistant, [{:text, "ok"}]))
      ]

      assert SessionStore.strip_orphaned_tool_call(nil, rows) == rows
    end

    test "strips last row when it is an orphaned tool-call turn" do
      orphan = Message.new(:assistant, [{:tool_call, "c1", "bash", %{}}])
      rows = [row(Message.new(:user, [{:text, "hi"}])), row(orphan)]
      result = SessionStore.strip_orphaned_tool_call(nil, rows)
      assert length(result) == 1
      assert hd(result).message.role == :user
    end

    test "does not strip when last message is a tool result" do
      tool_result = Message.new(:tool_result, [{:tool_result, "c1", "output"}])
      rows = [row(Message.new(:assistant, [{:tool_call, "c1", "bash", %{}}])), row(tool_result)]
      assert SessionStore.strip_orphaned_tool_call(nil, rows) == rows
    end
  end

  describe "persist_message/3" do
    setup :setup_session

    test "returns message unchanged for nil session_id" do
      msg = Message.new(:user, [{:text, "hello"}])
      assert SessionStore.persist_message(nil, "agent-1", msg) == msg
    end

    test "returns message with integer db_id after persisting", %{session_id: sid} do
      msg = Message.new(:user, [{:text, "hello"}])
      result = SessionStore.persist_message(sid, "agent-1", msg)
      assert is_integer(result.id)
    end
  end

  describe "load_messages/3" do
    setup :setup_session

    test "returns empty messages for a new session", %{session_id: sid} do
      assert {:ok, []} = SessionStore.load_messages(sid, "agent-1")
    end

    test "returns loaded messages", %{session_id: sid} do
      msg = Message.new(:user, [{:text, "hello"}])
      SessionStore.persist_message(sid, "agent-1", msg)
      assert {:ok, [loaded]} = SessionStore.load_messages(sid, "agent-1")
      assert loaded.role == :user
    end

    test "strips orphaned tool call when strip_orphans: true", %{session_id: sid} do
      user = Message.new(:user, [{:text, "hi"}])
      orphan = Message.new(:assistant, [{:tool_call, "c1", "bash", %{}}])
      SessionStore.persist_message(sid, "agent-1", user)
      SessionStore.persist_message(sid, "agent-1", orphan)

      assert {:ok, [loaded]} = SessionStore.load_messages(sid, "agent-1", strip_orphans: true)
      assert loaded.role == :user
    end
  end

  describe "flush_unpersisted/3" do
    setup :setup_session

    test "returns :noop for nil session_id" do
      msgs = [Message.new(:user, [{:text, "hi"}])]
      assert SessionStore.flush_unpersisted(nil, "agent-1", msgs) == :noop
    end

    test "returns :noop when all messages have integer ids", %{session_id: sid} do
      msg = %{Message.new(:user, [{:text, "hi"}]) | id: 1}
      assert SessionStore.flush_unpersisted(sid, "agent-1", [msg]) == :noop
    end

    test "returns :flushed and persists messages with binary ids", %{session_id: sid} do
      msg = Message.new(:user, [{:text, "hi"}])
      assert is_binary(msg.id)
      assert SessionStore.flush_unpersisted(sid, "agent-1", [msg]) == :flushed
      assert {:ok, [_]} = SessionStore.load_messages(sid, "agent-1")
    end
  end
end
