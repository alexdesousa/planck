defmodule Planck.Agent.ContextTest do
  use ExUnit.Case, async: false

  alias Planck.Agent.{Context, Hooks, Identity, Message, Session, Tool}
  alias Planck.AI.Model

  @model %Model{
    id: "llama3.2",
    name: "Llama 3.2",
    provider: :openai,
    context_window: 4_096,
    max_tokens: 2_048
  }

  defp unique_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp start_session do
    session_id = unique_id()
    dir = Path.join(System.tmp_dir!(), "planck_ctx_test_#{session_id}")
    {:ok, pid} = Session.start(session_id, name: "test", dir: dir)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Planck.Agent.SessionSupervisor, pid)
      end

      File.rm_rf!(dir)
    end)

    session_id
  end

  defp identity(opts \\ []) do
    %Identity{
      id: Keyword.get(opts, :id, "agent-1"),
      model: Keyword.get(opts, :model, @model),
      session_id: Keyword.get(opts, :session_id, nil)
    }
  end

  defp hooks(opts \\ []) do
    %Hooks{
      compactor: Keyword.get(opts, :compactor, Hooks.Compactor.Default),
      persistence: Keyword.get(opts, :persistence, nil),
      prompt: Keyword.get(opts, :prompt, nil),
      turn_end: Keyword.get(opts, :turn_end, nil),
      sidecar_node: Keyword.get(opts, :sidecar_node, nil)
    }
  end

  defp text_message(role, text) do
    Message.new(role, [{:text, text}])
  end

  defmodule AlwaysCompact do
    use Planck.Agent.Hooks.Compactor

    @impl true
    def compact?(_identity, _ai_context, _recent), do: true

    @impl true
    def compact(_identity, _ai_context, recent, _args) do
      summary = Message.new({:custom, :summary}, [{:text, "summary"}])
      {:compact, summary, Enum.take(recent, -1)}
    end
  end

  defp make_tool(name) do
    Tool.new(
      name: name,
      description: "test",
      parameters: %{"type" => "object", "properties" => %{}},
      execute_fn: fn _, _, _ -> {:ok, "ok"} end
    )
  end

  describe inspect(&Context.build/1) do
    test "should map a tool list to a name-keyed map with defaults" do
      ctx = Context.build(tools: [make_tool("bash")])

      assert Map.has_key?(ctx.tools, "bash")
      assert ctx.cwd == ""
      assert ctx.system_prompt == ""
      assert ctx.messages == []
      assert ctx.skills_top_n == 5
    end

    test "should pass cwd, system prompt, and usage opts through" do
      ctx =
        Context.build(
          cwd: "/work",
          system_prompt: "hi",
          cost: 1.5,
          usage: %{input_tokens: 3, output_tokens: 7}
        )

      assert ctx.cwd == "/work"
      assert ctx.system_prompt == "hi"
      assert ctx.usage.cost == 1.5
      assert ctx.usage.input_tokens == 3
      assert ctx.usage.output_tokens == 7
    end

    test "should pass a skill index opts through" do
      ctx =
        Context.build(
          skill_pool: [:pool],
          ranked_skill_names: ["a"],
          top_skills: 3,
          skill_names: ["a"],
          skill_refresh_fn: :refresh,
          skill_index_refresh_fn: :index_refresh
        )

      assert ctx.skills_pool == [:pool]
      assert ctx.skills_ranked == ["a"]
      assert ctx.skills_top_n == 3
      assert ctx.skills_names == ["a"]
      assert ctx.skills_refresh_fn == :refresh
      assert ctx.skills_index_refresh_fn == :index_refresh
    end
  end

  describe inspect(&Context.add_tool/2) do
    test "should add tools" do
      ctx =
        Context.build([])
        |> Context.add_tool(make_tool("bash"))

      assert Map.has_key?(ctx.tools, "bash")
    end

    test "should overwrite a tool with the same name" do
      ctx =
        Context.build([])
        |> Context.add_tool(make_tool("bash"))
        |> Context.add_tool(make_tool("bash"))

      assert map_size(ctx.tools) == 1
    end
  end

  describe inspect(&Context.remove_tool/2) do
    test "should remove tools by name" do
      ctx =
        Context.build([])
        |> Context.add_tool(make_tool("bash"))
        |> Context.remove_tool("bash")

      refute Map.has_key?(ctx.tools, "bash")
    end

    test "should be a no-op for an unknown tool" do
      ctx = Context.build([]) |> Context.add_tool(make_tool("bash"))

      assert Context.remove_tool(ctx, "missing") == ctx
    end
  end

  describe inspect(&Context.append_messages/4) do
    test "should add messages without persisting by default" do
      ctx = Context.build([])
      msgs = [text_message(:user, "hi")]

      ctx = Context.append_messages(ctx, identity(), hooks(), msgs)

      assert [message] = ctx.messages
      # Binary id means the message was not persisted
      assert is_binary(message.id)
      assert [{:text, "hi"}] == message.content
    end

    test "should append messages" do
      ctx = Context.build([])
      assert [] = ctx.messages

      one = text_message(:user, "one")
      ctx = Context.append_messages(ctx, identity(), hooks(), [one])
      assert [^one] = ctx.messages

      two = text_message(:user, "two")
      ctx = Context.append_messages(ctx, identity(), hooks(), [two])
      assert [^one, ^two] = ctx.messages
    end

    test "should append and persist messages when `persist: true` with a session" do
      session_id = start_session()
      ident = identity(session_id: session_id)

      ctx = Context.build([])
      assert [] = ctx.messages

      message = text_message(:user, "hi")
      ctx = Context.append_messages(ctx, ident, hooks(), [message], persist: true)
      assert [message] = ctx.messages

      # Integer id means the message was persisted
      assert is_integer(message.id)
      assert [{:text, "hi"}] == message.content

      {:ok, [row]} = Session.messages(session_id)
      assert row.message.content == [{:text, "hi"}]
    end

    test "should keep binary ids when `persist: true` without a session" do
      ctx = Context.build([])

      message = text_message(:user, "hi")
      ctx = Context.append_messages(ctx, identity(), hooks(), [message], persist: true)

      assert [message] = ctx.messages
      assert is_binary(message.id)
    end
  end

  describe inspect(&Context.replace_messages/4) do
    test "replace_messages swaps the list" do
      ctx = Context.build([])
      assert [] = ctx.messages

      one = text_message(:user, "one")
      ctx = Context.append_messages(ctx, identity(), hooks(), [one])
      assert [^one] = ctx.messages

      two = text_message(:user, "two")
      ctx = Context.replace_messages(ctx, identity(), hooks(), [two])
      assert [^two] = ctx.messages
    end

    test "should persist replacement messages when `persist: true` with a session" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      ctx = Context.build([])

      message = text_message(:user, "hi")
      ctx = Context.replace_messages(ctx, ident, hooks(), [message], persist: true)

      assert [message] = ctx.messages
      assert is_integer(message.id)

      {:ok, [row]} = Session.messages(session_id)
      assert row.message.content == [{:text, "hi"}]
    end
  end

  describe inspect(&Context.remove_unpersisted/2) do
    test "should remove messages with the matching id" do
      ctx = Context.build([])
      msg = text_message(:user, "hi")
      ctx = Context.append_messages(ctx, identity(), hooks(), [msg])

      ctx = Context.remove_unpersisted(ctx, msg.id)
      assert [] = ctx.messages
    end

    test "should keep messages with other ids" do
      ctx = Context.build([])
      one = text_message(:user, "one")
      two = text_message(:user, "two")
      ctx = Context.append_messages(ctx, identity(), hooks(), [one, two])

      ctx = Context.remove_unpersisted(ctx, one.id)
      assert [^two] = ctx.messages
    end
  end

  describe inspect(&Context.calculate_context/3) do
    test "should build an AI context and records token estimate" do
      ctx = Context.build(system_prompt: "Be helpful.")
      ctx = Context.append_messages(ctx, identity(), hooks(), [text_message(:user, "hi")])

      {updated, recent, ai_context} = Context.calculate_context(ctx, identity(), hooks())

      assert length(recent) == 1
      assert ai_context.system =~ "Be helpful."
      assert updated.context_tokens > 0
    end

    test "should have an empty system prompt when none provided" do
      ctx = Context.build([])
      {_updated, _recent, ai_context} = Context.calculate_context(ctx, identity(), hooks())

      assert ai_context.system == nil
    end

    test "should map tools into the AI context" do
      ctx = Context.build(tools: [make_tool("bash")])
      {_updated, _recent, ai_context} = Context.calculate_context(ctx, identity(), hooks())

      assert [%{name: "bash"}] = ai_context.tools
    end

    test "should only include messages since the last summary" do
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, identity(), hooks(), [
          text_message(:user, "old"),
          Message.new({:custom, :summary}, [{:text, "summary"}]),
          text_message(:user, "new")
        ])

      {updated, [summary, kept], _ai_context} =
        Context.calculate_context(ctx, identity(), hooks())

      assert [{:text, "summary"}] = summary.content
      assert [{:text, "new"}] = kept.content

      assert length(updated.messages) == 3
    end
  end

  describe inspect(&Context.drain_control_markers/3) do
    test "should return :none without markers" do
      ctx = Context.build([])

      ctx = Context.append_messages(ctx, identity(), hooks(), [text_message(:user, "hi")])

      assert Context.drain_control_markers(ctx, identity(), hooks()) == :none
    end

    test "should drain a queued :compact marker" do
      ctx = Context.build([])
      message = text_message(:user, "hi")
      compact = Message.new({:custom, :compact}, [], %{prompt: "keep it short"})

      ctx = Context.append_messages(ctx, identity(), hooks(), [message, compact])

      assert {:compact, updated, %{prompt: "keep it short"}} =
               Context.drain_control_markers(ctx, identity(), hooks())

      refute Enum.any?(updated.messages, &(&1.role == {:custom, :compact}))
      assert [^message] = updated.messages
    end

    test "should drain a queued :clear marker into a single message" do
      ctx = Context.build([])

      clear = Message.new({:custom, :clear}, [{:text, "clear"}])
      message = text_message(:user, "hi")
      ctx = Context.append_messages(ctx, identity(), hooks(), [message, clear])

      assert {:clear, updated} = Context.drain_control_markers(ctx, identity(), hooks())
      assert [%{role: {:custom, :clear}}] = updated.messages
    end

    test "should prefer :clear when both markers are queued" do
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, identity(), hooks(), [
          Message.new({:custom, :compact}, [], %{}),
          Message.new({:custom, :clear}, [{:text, "clear"}])
        ])

      assert {:clear, _} = Context.drain_control_markers(ctx, identity(), hooks())
    end

    test "should ignore persisted markers with integer ids" do
      ctx = Context.build([])
      persisted_clear = %{Message.new({:custom, :clear}, [{:text, "old"}]) | id: 99}

      ctx = Context.append_messages(ctx, identity(), hooks(), [persisted_clear])

      assert Context.drain_control_markers(ctx, identity(), hooks()) == :none
    end

    test "should pick the last :compact marker prompt" do
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, identity(), hooks(), [
          Message.new({:custom, :compact}, [], %{prompt: "first"}),
          Message.new({:custom, :compact}, [], %{prompt: "second"})
        ])

      assert {:compact, _updated, %{prompt: "second"}} =
               Context.drain_control_markers(ctx, identity(), hooks())
    end

    test "should persist the :clear message with a session" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, ident, hooks(), [
          text_message(:user, "hi"),
          Message.new({:custom, :clear}, [{:text, "clear"}])
        ])

      assert {:clear, updated} = Context.drain_control_markers(ctx, ident, hooks())
      assert [%{role: {:custom, :clear}}] = updated.messages
      assert is_integer(hd(updated.messages).id)

      {:ok, rows} = Session.messages(session_id)
      assert Enum.any?(rows, &(&1.message.role == {:custom, :clear}))
    end
  end

  describe inspect(&Context.update_usage/5) do
    test "should accumulate usage without a session" do
      ctx = Context.build([])

      ctx = Context.update_usage(ctx, identity(), hooks(), 10, 5)

      assert ctx.usage.input_tokens == 10
      assert ctx.usage.output_tokens == 5
    end

    test "should accumulate across turns" do
      ctx = Context.build([])

      ctx = Context.update_usage(ctx, identity(), hooks(), 10, 5)
      ctx = Context.update_usage(ctx, identity(), hooks(), 4, 2)

      assert ctx.usage.input_tokens == 14
      assert ctx.usage.output_tokens == 7
    end

    test "should persist usage to session metadata with a session" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      ctx = Context.build([])

      ctx = Context.update_usage(ctx, ident, hooks(), 10, 5)

      assert ctx.usage.input_tokens == 10
      assert ctx.usage.output_tokens == 5

      {:ok, meta} = Session.get_metadata(session_id)
      assert Map.has_key?(meta, "agent_usage:agent-1")
    end
  end

  describe inspect(&Context.persist_message/3) do
    test "should return the message unchanged without a session" do
      msg = text_message(:user, "hi")

      assert ^msg = Context.persist_message(identity(), hooks(), msg)
    end

    test "should assign an integer db id with a session" do
      session_id = start_session()
      msg = text_message(:user, "hi")

      persisted = Context.persist_message(identity(session_id: session_id), hooks(), msg)

      assert is_integer(persisted.id)
      assert persisted.content == msg.content

      {:ok, rows} = Session.messages(session_id)
      assert length(rows) == 1
    end
  end

  describe inspect(&Context.persist_usage/3) do
    test "should be a no-op without a session" do
      ctx = Context.build([])

      assert :ok = Context.persist_usage(ctx, identity(), hooks())
    end
  end

  describe inspect(&Context.flush_unpersisted/3) do
    test "should be a no-op without a session" do
      ctx = Context.build([])

      ctx = Context.append_messages(ctx, identity(), hooks(), [text_message(:user, "hi")])

      assert Context.flush_unpersisted(ctx, identity(), hooks()) == ctx
    end

    test "should return the context unchanged when everything is persisted" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, ident, hooks(), [text_message(:user, "hi")], persist: true)

      assert Context.flush_unpersisted(ctx, ident, hooks()) == ctx
    end

    test "should flush queued messages and reload with db ids" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, ident, hooks(), [text_message(:user, "saved")],
          persist: true
        )

      ctx = Context.append_messages(ctx, ident, hooks(), [text_message(:user, "queued")])
      assert Enum.any?(ctx.messages, &is_binary(&1.id))

      flushed = Context.flush_unpersisted(ctx, ident, hooks())

      assert Enum.all?(flushed.messages, &is_integer(&1.id))
      assert Enum.map(flushed.messages, &hd(&1.content)) == [text: "saved", text: "queued"]

      {:ok, rows} = Session.messages(session_id)
      assert length(rows) == 2
    end
  end

  describe inspect(&Context.load_messages/3) do
    test "should keep messages when there is no session to load from" do
      ctx = Context.build([])
      msg = text_message(:user, "hi")
      ctx = Context.append_messages(ctx, identity(), hooks(), [msg])

      assert Context.load_messages(ctx, identity(), hooks()) == ctx
    end

    test "should replace in-memory messages with session history" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, ident, hooks(), [text_message(:user, "one")], persist: true)

      # Diverge in-memory from the session, then reload
      ctx = Context.append_messages(ctx, ident, hooks(), [text_message(:user, "unsaved")])
      assert length(ctx.messages) == 2

      loaded = Context.load_messages(ctx, ident, hooks())

      assert Enum.map(loaded.messages, &hd(&1.content)) == [text: "one"]
      assert Enum.all?(loaded.messages, &is_integer(&1.id))
    end
  end

  describe inspect(&Context.reload_from_session/3) do
    test "should keep messages when there is no session to load from" do
      ctx = Context.build([])
      msg = text_message(:user, "hi")
      ctx = Context.append_messages(ctx, identity(), hooks(), [msg])

      assert Context.reload_from_session(ctx, identity(), hooks()) == ctx
    end

    test "should reload messages from the session" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, ident, hooks(), [text_message(:user, "saved")],
          persist: true
        )

      ctx = %{ctx | messages: []}

      reloaded = Context.reload_from_session(ctx, ident, hooks())

      assert [%{role: :user}] = reloaded.messages
      assert hd(hd(reloaded.messages).content) == {:text, "saved"}
    end
  end

  describe inspect(&Context.compact/4) do
    test "should skip when the context is small" do
      ctx = Context.build([])
      msgs = Enum.map(1..3, fn i -> text_message(:user, "short #{i}") end)
      ctx = Context.append_messages(ctx, identity(), hooks(), msgs)

      compacted = Context.compact(ctx, identity(), hooks(), [])

      assert compacted.messages == ctx.messages
    end

    test "should persist the summary and keep recent messages" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      hks = hooks(compactor: AlwaysCompact)
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, ident, hks, [text_message(:user, String.duplicate("x", 50))],
          persist: true
        )

      compacted = Context.compact(ctx, ident, hks, [])

      assert [%{role: {:custom, :summary}} | _] =
               Enum.drop(compacted.messages, length(ctx.messages) - 1)

      summary = Enum.find(compacted.messages, &(&1.role == {:custom, :summary}))
      assert is_integer(summary.id)
    end

    test "should refresh skills when skill_index_refresh_fn is set" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      hks = hooks(compactor: AlwaysCompact)
      ctx = Context.build(skill_index_refresh_fn: fn -> {[:new_pool], ["a"]} end)

      ctx =
        Context.append_messages(ctx, ident, hks, [text_message(:user, String.duplicate("x", 50))],
          persist: true
        )

      compacted = Context.compact(ctx, ident, hks, [])

      assert compacted.skills_pool == [:new_pool]
      assert compacted.skills_ranked == ["a"]
    end

    test "should leave skills untouched without skill_index_refresh_fn" do
      session_id = start_session()
      ident = identity(session_id: session_id)
      hks = hooks(compactor: AlwaysCompact)
      ctx = Context.build([])

      ctx =
        Context.append_messages(ctx, ident, hks, [text_message(:user, String.duplicate("x", 50))],
          persist: true
        )

      compacted = Context.compact(ctx, ident, hks, [])

      assert compacted.skills_pool == []
      assert compacted.skills_ranked == []
    end
  end
end
