defmodule Planck.Agent.Hooks.PersistenceTest do
  use ExUnit.Case, async: false

  import Mox

  alias Planck.Agent
  alias Planck.Agent.Hooks.Persistence
  alias Planck.Agent.{Message, MockAI, Session}
  alias Planck.AI.Model

  setup :set_mox_global
  setup :verify_on_exit!

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp start_real_session do
    session_id = unique_id()
    dir = Path.join(System.tmp_dir!(), "planck_persistence_test_#{session_id}")
    {:ok, _} = Session.start(session_id, name: "test", dir: dir)

    on_exit(fn ->
      Session.stop(session_id)
      File.rm_rf!(dir)
    end)

    session_id
  end

  defp text_message(role, text), do: Message.new(role, [{:text, text}])

  # ---------------------------------------------------------------------------
  # use Planck.Agent.Hooks.Persistence — behaviour defaults
  # ---------------------------------------------------------------------------

  describe "use Planck.Agent.Hooks.Persistence" do
    defmodule MinimalPersistence do
      use Planck.Agent.Hooks.Persistence

      @impl true
      def persist_message(_session_id, _agent_id, message), do: message

      @impl true
      def persist_usage(_session_id, _agent_id, _usage), do: :ok

      @impl true
      def load_messages(_session_id, _agent_id, _opts), do: {:ok, []}

      @impl true
      def flush_unpersisted(_session_id, _agent_id, _messages), do: :noop

      @impl true
      def truncate_after(_session_id, _message_id), do: :ok

      @impl true
      def load_session_messages(_session_id, _opts), do: {:ok, []}
    end

    defmodule CustomTimeoutPersistence do
      use Planck.Agent.Hooks.Persistence

      @impl true
      def persist_message(_session_id, _agent_id, message), do: message
      @impl true
      def persist_usage(_session_id, _agent_id, _usage), do: :ok
      @impl true
      def load_messages(_session_id, _agent_id, _opts), do: {:ok, []}
      @impl true
      def flush_unpersisted(_session_id, _agent_id, _messages), do: :noop
      @impl true
      def truncate_after(_session_id, _message_id), do: :ok
      @impl true
      def load_session_messages(_session_id, _opts), do: {:ok, []}

      @impl true
      def persistence_timeout, do: 60_000
    end

    test "provides default persistence_timeout/0" do
      assert MinimalPersistence.persistence_timeout() == Persistence.default_timeout()
    end

    test "persistence_timeout/0 can be overridden" do
      assert CustomTimeoutPersistence.persistence_timeout() == 60_000
    end
  end

  # ---------------------------------------------------------------------------
  # A recording module used across the dispatch describes below
  # ---------------------------------------------------------------------------

  defmodule RecordingPersistence do
    use Planck.Agent.Hooks.Persistence

    @impl true
    def persist_message(session_id, agent_id, message) do
      notify({:persist_message, session_id, agent_id, message})
      %{message | id: 999}
    end

    @impl true
    def persist_usage(session_id, agent_id, usage) do
      notify({:persist_usage, session_id, agent_id, usage})
      :ok
    end

    @impl true
    def load_messages(session_id, agent_id, opts) do
      notify({:load_messages, session_id, agent_id, opts})
      {:ok, [text_message_for_test()]}
    end

    @impl true
    def flush_unpersisted(session_id, agent_id, messages) do
      notify({:flush_unpersisted, session_id, agent_id, messages})
      :flushed
    end

    @impl true
    def truncate_after(session_id, message_id) do
      notify({:truncate_after, session_id, message_id})
      :ok
    end

    @impl true
    def load_session_messages(session_id, opts) do
      notify({:load_session_messages, session_id, opts})

      {:ok,
       [%{db_id: 1, agent_id: "orchestrator", message: text_message_for_test(), inserted_at: 0}]}
    end

    defp text_message_for_test, do: Message.new(:user, [{:text, "from recording module"}])

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :parent}, nil) do
        nil -> :ok
        parent -> send(parent, msg)
      end
    end
  end

  setup do
    :persistent_term.put({RecordingPersistence, :parent}, self())
    on_exit(fn -> :persistent_term.erase({RecordingPersistence, :parent}) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # persist_message/5
  # ---------------------------------------------------------------------------

  describe "persist_message/5" do
    test "returns the message unchanged when session_id is nil, regardless of module" do
      msg = text_message(:user, "hi")
      assert Persistence.persist_message(RecordingPersistence, nil, "agent-1", msg, nil) == msg
      refute_received {:persist_message, _, _, _}
    end

    test "module: nil dispatches to Default (real SQLite)" do
      session_id = start_real_session()
      msg = text_message(:user, "hi")

      persisted = Persistence.persist_message(nil, session_id, "agent-1", msg, nil)
      assert is_integer(persisted.id)

      assert {:ok, [row]} = Session.messages(session_id)
      assert row.message.content == msg.content
    end

    test "dispatches to a custom module locally" do
      session_id = unique_id()
      msg = text_message(:user, "hi")

      persisted =
        Persistence.persist_message(RecordingPersistence, session_id, "agent-1", msg, nil)

      assert persisted.id == 999
      assert_received {:persist_message, ^session_id, "agent-1", ^msg}
    end

    test "dispatches via RPC on the same node" do
      session_id = unique_id()
      msg = text_message(:user, "hi")

      persisted =
        Persistence.persist_message(RecordingPersistence, session_id, "agent-1", msg, Node.self())

      assert persisted.id == 999
      assert_received {:persist_message, ^session_id, "agent-1", ^msg}
    end

    test "falls back to Default (real SQLite) when RPC fails" do
      session_id = start_real_session()
      msg = text_message(:user, "hi")

      persisted =
        Persistence.persist_message(
          RecordingPersistence,
          session_id,
          "agent-1",
          msg,
          :nonexistent@localhost
        )

      assert is_integer(persisted.id)
      refute_received {:persist_message, _, _, _}
      assert {:ok, [row]} = Session.messages(session_id)
      assert row.message.content == msg.content
    end
  end

  # ---------------------------------------------------------------------------
  # truncate_after/4 — representative of the simple :ok/:error-shaped callbacks
  # ---------------------------------------------------------------------------

  describe "truncate_after/4" do
    test "module: nil dispatches to Default (real SQLite)" do
      session_id = start_real_session()
      msg = text_message(:user, "hi")
      %{id: db_id} = Persistence.persist_message(nil, session_id, "agent-1", msg, nil)

      assert Persistence.truncate_after(nil, session_id, db_id, nil) == :ok
      assert {:ok, []} = Session.messages(session_id)
    end

    test "dispatches to a custom module locally" do
      session_id = unique_id()
      assert Persistence.truncate_after(RecordingPersistence, session_id, 42, nil) == :ok
      assert_received {:truncate_after, ^session_id, 42}
    end

    test "dispatches via RPC on the same node" do
      session_id = unique_id()
      assert Persistence.truncate_after(RecordingPersistence, session_id, 42, Node.self()) == :ok
      assert_received {:truncate_after, ^session_id, 42}
    end

    test "falls back to Default (real SQLite) when RPC fails" do
      session_id = start_real_session()
      msg = text_message(:user, "hi")
      %{id: db_id} = Persistence.persist_message(nil, session_id, "agent-1", msg, nil)

      assert Persistence.truncate_after(
               RecordingPersistence,
               session_id,
               db_id,
               :nonexistent@localhost
             ) ==
               :ok

      refute_received {:truncate_after, _, _}
      assert {:ok, []} = Session.messages(session_id)
    end
  end

  # ---------------------------------------------------------------------------
  # load_session_messages/3 — the one callback Planck.Agent itself never
  # calls; used by an external caller (planck_headless) for a cross-agent,
  # session-wide read.
  # ---------------------------------------------------------------------------

  describe "load_session_messages/3" do
    test "module: nil dispatches to Default (real SQLite), across agents" do
      session_id = start_real_session()
      Persistence.persist_message(nil, session_id, "orchestrator", text_message(:user, "hi"), nil)

      Persistence.persist_message(
        nil,
        session_id,
        "worker-1",
        text_message(:assistant, "hello"),
        nil
      )

      assert {:ok, rows} = Persistence.load_session_messages(nil, session_id, nil)
      assert Enum.map(rows, & &1.agent_id) == ["orchestrator", "worker-1"]
    end

    test "dispatches to a custom module locally" do
      session_id = unique_id()

      assert {:ok, [row]} =
               Persistence.load_session_messages(RecordingPersistence, session_id, nil)

      assert row.agent_id == "orchestrator"
      assert_received {:load_session_messages, ^session_id, []}
    end

    test "dispatches via RPC on the same node" do
      session_id = unique_id()

      assert {:ok, [_row]} =
               Persistence.load_session_messages(RecordingPersistence, session_id, Node.self())

      assert_received {:load_session_messages, ^session_id, []}
    end

    test "falls back to Default (real SQLite) when RPC fails" do
      session_id = start_real_session()
      Persistence.persist_message(nil, session_id, "orchestrator", text_message(:user, "hi"), nil)

      assert {:ok, rows} =
               Persistence.load_session_messages(
                 RecordingPersistence,
                 session_id,
                 :nonexistent@localhost
               )

      refute_received {:load_session_messages, _, _}
      assert Enum.map(rows, & &1.agent_id) == ["orchestrator"]
    end
  end

  # ---------------------------------------------------------------------------
  # persist_usage/5, load_messages/5, flush_unpersisted/5 — nil-session
  # bypass and local dispatch. Same dispatcher as above, so remote/:badrpc
  # coverage isn't repeated for each one.
  # ---------------------------------------------------------------------------

  describe "persist_usage/5" do
    test "no-ops when session_id is nil" do
      assert Persistence.persist_usage(RecordingPersistence, nil, "agent-1", %Agent.Usage{}, nil) ==
               :ok

      refute_received {:persist_usage, _, _, _}
    end

    test "dispatches to a custom module locally" do
      session_id = unique_id()
      usage = %Agent.Usage{input_tokens: 10, output_tokens: 5}

      assert Persistence.persist_usage(RecordingPersistence, session_id, "agent-1", usage, nil) ==
               :ok

      assert_received {:persist_usage, ^session_id, "agent-1", ^usage}
    end
  end

  describe "load_messages/5" do
    test "returns :error when session_id is nil" do
      assert Persistence.load_messages(RecordingPersistence, nil, "agent-1", [], nil) == :error
      refute_received {:load_messages, _, _, _}
    end

    test "dispatches to a custom module locally" do
      session_id = unique_id()

      assert {:ok, [_msg]} =
               Persistence.load_messages(RecordingPersistence, session_id, "agent-1", [], nil)

      assert_received {:load_messages, ^session_id, "agent-1", []}
    end
  end

  describe "flush_unpersisted/5" do
    test "returns :noop when session_id is nil" do
      assert Persistence.flush_unpersisted(RecordingPersistence, nil, "agent-1", [], nil) == :noop
      refute_received {:flush_unpersisted, _, _, _}
    end

    test "dispatches to a custom module locally" do
      session_id = unique_id()
      msgs = [text_message(:user, "hi")]

      assert Persistence.flush_unpersisted(RecordingPersistence, session_id, "agent-1", msgs, nil) ==
               :flushed

      assert_received {:flush_unpersisted, ^session_id, "agent-1", ^msgs}
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with Agent
  # ---------------------------------------------------------------------------

  defp start_agent_with_session(overrides \\ []) do
    session_id = unique_id()
    dir = Path.join(System.tmp_dir!(), "planck_persistence_integration_#{session_id}")
    {:ok, _} = Session.start(session_id, name: "test", dir: dir)

    on_exit(fn ->
      Session.stop(session_id)
      File.rm_rf!(dir)
    end)

    defaults = [id: unique_id(), model: @model, system_prompt: "helpful.", session_id: session_id]
    opts = Keyword.merge(defaults, overrides)
    {start_supervised!({Agent, opts}), session_id}
  end

  describe "integration with Agent" do
    test "default (no :persistence option) still writes to real SQLite, unchanged" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      {agent, session_id} = start_agent_with_session()
      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert {:ok, rows} = Session.messages(session_id)
      assert Enum.any?(rows, fn r -> match?([{:text, "hello"}], r.message.content) end)
    end

    test "a custom persistence module is used instead of SQLite for a real prompt cycle" do
      stub(MockAI, :stream, fn _model, _context, _opts ->
        [{:text_delta, "ok"}, {:done, %{}}]
      end)

      session_id = unique_id()

      agent =
        start_supervised!(
          {Agent,
           id: unique_id(),
           model: @model,
           system_prompt: "helpful.",
           session_id: session_id,
           persistence: RecordingPersistence}
        )

      Agent.subscribe(agent)
      Agent.prompt(agent, "hello")
      assert_receive {:agent_event, :turn_end, _}, 1_000

      assert_received {:persist_message, ^session_id, _agent_id, _msg}
      # Real SQLite was never touched — no Session GenServer was even started
      # for this session_id.
      assert Session.whereis(session_id) == {:error, :not_found}
    end
  end
end
