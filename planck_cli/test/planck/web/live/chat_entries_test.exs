defmodule Planck.Web.Live.ChatEntriesTest do
  use ExUnit.Case, async: true

  alias Planck.Agent.Message
  alias Planck.Web.Live.ChatEntries

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp row(agent_id, role, content) do
    %{agent_id: agent_id, message: Message.new(role, content), inserted_at: 0}
  end

  defp row_with_meta(agent_id, role, content, metadata) do
    %{agent_id: agent_id, message: Message.new(role, content, metadata), inserted_at: 0}
  end

  defp build(rows, perspective_id, agents) do
    ChatEntries.build(rows, perspective_id, agents)
  end

  defp find(entries, type), do: Enum.find(entries, &(&1.type == type))
  defp all(entries, type), do: Enum.filter(entries, &(&1.type == type))

  # Minimal agents map for orchestrator perspective tests
  @orch_agents %{"orch" => %{type: "orchestrator", name: "orchestrator"}}

  # ---------------------------------------------------------------------------
  # Orchestrator perspective (main chat)
  # ---------------------------------------------------------------------------

  describe "orchestrator perspective" do
    test "user message → right-side :user entry, author :user" do
      entries = build([row("orch", :user, [{:text, "hello"}])], "orch", @orch_agents)

      assert [%{type: :user, side: :right, author: :user, text: "hello"}] = entries
    end

    test "assistant text → left-side :text entry, author tagged with agent name" do
      entries = build([row("orch", :assistant, [{:text, "response"}])], "orch", @orch_agents)

      assert [
               %{
                 type: :text,
                 side: :left,
                 author: {:agent, "orch", "orchestrator"},
                 text: "response"
               }
             ] = entries
    end

    test "thinking block → left-side :thinking entry, collapsed by default" do
      entries =
        build([row("orch", :assistant, [{:thinking, "reasoning..."}])], "orch", @orch_agents)

      assert [%{type: :thinking, side: :left, expanded: false, text: "reasoning..."}] = entries
    end

    test "bash tool call → left-side :tool entry with subtitle" do
      entries =
        build(
          [row("orch", :assistant, [{:tool_call, "t1", "bash", %{"command" => "mix test"}}])],
          "orch",
          @orch_agents
        )

      assert [%{type: :tool, side: :left, tool_name: "bash", tool_subtitle: "mix test"}] = entries
    end

    test "inter-agent tool call (ask_agent) → left-side :tool entry in orchestrator view" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "ask_agent", %{"question" => "build this"}}
            ])
          ],
          "orch",
          @orch_agents
        )

      assert [%{type: :tool, side: :left, tool_name: "ask_agent"}] = entries
    end

    test "tool_result is paired with its tool_call" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "bash", %{"command" => "mix test"}},
              {:tool_result, "t1", "3 tests, 0 failures"}
            ])
          ],
          "orch",
          @orch_agents
        )

      tool = find(entries, :tool)
      assert tool.tool_result == "3 tests, 0 failures"
    end

    test "tool_result row is paired with matching tool_call row" do
      entries =
        build(
          [
            row("orch", :assistant, [{:tool_call, "t1", "bash", %{"command" => "ls"}}]),
            row("orch", :tool_result, [{:tool_result, "t1", "file.txt"}])
          ],
          "orch",
          @orch_agents
        )

      tool = find(entries, :tool)
      assert tool.tool_result == "file.txt"
    end

    test "tool_result with error result" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "bash", %{"command" => "mix test"}},
              {:tool_result, "t1", {:error, "command failed"}}
            ])
          ],
          "orch",
          @orch_agents
        )

      assert find(entries, :tool).tool_result =~ "command failed"
    end

    test "summary message → :summary entry" do
      entries =
        build(
          [row("orch", {:custom, :summary}, [{:text, "summary text"}])],
          "orch",
          @orch_agents
        )

      assert [%{type: :summary}] = entries
    end

    test "empty text parts are skipped" do
      entries =
        build(
          [row("orch", :assistant, [{:text, ""}, {:text, "hello"}])],
          "orch",
          @orch_agents
        )

      assert [%{type: :text, text: "hello"}] = entries
    end

    test "multiple content parts produce multiple entries" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:thinking, "reasoning"},
              {:text, "answer"},
              {:tool_call, "t1", "bash", %{"command" => "ls"}}
            ])
          ],
          "orch",
          @orch_agents
        )

      assert length(all(entries, :thinking)) == 1
      assert length(all(entries, :text)) == 1
      assert length(all(entries, :tool)) == 1
    end

    test "user and assistant rows produce entries in order" do
      entries =
        build(
          [
            row("orch", :user, [{:text, "first"}]),
            row("orch", :assistant, [{:text, "second"}])
          ],
          "orch",
          @orch_agents
        )

      assert [%{type: :user}, %{type: :text}] = entries
    end

    test "interleaved text and tool calls preserve content order" do
      entries =
        build(
          [
            row("orch", :user, [{:text, "go"}]),
            row("orch", :assistant, [
              {:text, "I'll run two commands."},
              {:tool_call, "t1", "bash", %{"command" => "echo hello"}},
              {:text, "And one more."},
              {:tool_call, "t2", "bash", %{"command" => "echo world"}},
              {:tool_result, "t1", "hello"},
              {:tool_result, "t2", "world"}
            ])
          ],
          "orch",
          @orch_agents
        )

      assert [
               %{type: :user, side: :right},
               %{type: :text, text: "I'll run two commands."},
               %{type: :tool, tool_name: "bash", tool_result: "hello"},
               %{type: :text, text: "And one more."},
               %{type: :tool, tool_name: "bash", tool_result: "world"}
             ] = entries
    end

    test "no entry is repeated across multiple rows" do
      entries =
        build(
          [
            row("orch", :user, [{:text, "start"}]),
            row("orch", :assistant, [{:tool_call, "t1", "bash", %{"command" => "ls"}}]),
            row("orch", :tool_result, [{:tool_result, "t1", "file.txt"}]),
            row("orch", :assistant, [{:text, "done"}])
          ],
          "orch",
          @orch_agents
        )

      ids = Enum.map(entries, & &1.id)
      assert ids == Enum.uniq(ids)
      assert length(entries) == 3
    end

    test "right-side entries only appear once even with matching delegation and user rows" do
      agents = %{
        "orch" => %{type: "orchestrator", name: "orchestrator"},
        "builder" => %{type: "worker", name: "builder"}
      }

      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "delegate_task", %{"type" => "worker", "task" => "build it"}}
            ]),
            row("builder", :user, [{:text, "build it"}]),
            row("builder", :assistant, [{:text, "done"}])
          ],
          "builder",
          agents
        )

      right = Enum.filter(entries, &(&1.side == :right))
      assert length(right) == 1
      assert hd(right).type == :inter_agent_in
    end
  end

  # ---------------------------------------------------------------------------
  # Worker perspective (agent overlay)
  # ---------------------------------------------------------------------------

  describe "worker perspective" do
    @agents %{
      "orch" => %{type: "orchestrator", name: "orchestrator"},
      "builder" => %{type: "worker", name: "builder"}
    }

    # Agents where the display name differs from their type
    @named_agents %{
      "orch" => %{type: "orchestrator", name: "Aria"},
      "builder" => %{type: "worker", name: "Bob"}
    }

    test "agent name takes priority over type in author label" do
      entries =
        build(
          [row("builder", :assistant, [{:text, "done"}])],
          "builder",
          @named_agents
        )

      assert [%{author: {:agent, "builder", "Bob"}}] = entries
    end

    test "orchestrator name (not type) is used when attributing a delegation" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "delegate_task", %{"task" => "implement it", "name" => "Bob"}}
            ])
          ],
          "builder",
          @named_agents
        )

      assert [%{type: :inter_agent_in, author: {:agent, "orch", "Aria"}}] = entries
    end

    test "orchestrator name (not type) is used in main chat entries" do
      entries =
        build(
          [row("orch", :assistant, [{:text, "hello"}])],
          "orch",
          @named_agents
        )

      assert [%{author: {:agent, "orch", "Aria"}}] = entries
    end

    test ":user message from worker row is skipped (it's a delegated task)" do
      entries =
        build(
          [row("builder", :user, [{:text, "build this"}])],
          "builder",
          @agents
        )

      assert entries == []
    end

    test "worker assistant text → left-side entry authored by worker" do
      entries =
        build(
          [row("builder", :assistant, [{:text, "done"}])],
          "builder",
          @agents
        )

      assert [%{type: :text, side: :left, author: {:agent, "builder", "builder"}}] = entries
    end

    test "orchestrator delegate_task targeting worker → right-side :inter_agent_in" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "delegate_task",
               %{"task" => "write the module", "type" => "worker"}}
            ])
          ],
          "builder",
          @agents
        )

      assert [
               %{
                 type: :inter_agent_in,
                 side: :right,
                 author: {:agent, "orch", "orchestrator"},
                 text: "write the module",
                 tool_name: "delegate_task"
               }
             ] = entries
    end

    test "orchestrator ask_agent targeting worker by name → right-side :inter_agent_in" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "ask_agent", %{"question" => "review this", "name" => "builder"}}
            ])
          ],
          "builder",
          @agents
        )

      assert [%{type: :inter_agent_in, side: :right, text: "review this"}] = entries
    end

    test "orchestrator inter-agent call targeting a different agent is hidden" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "delegate_task",
               %{"task" => "not for builder", "type" => "reviewer"}}
            ])
          ],
          "builder",
          @agents
        )

      assert entries == []
    end

    test "worker view: delegation shown once (not duplicated by :user row)" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "delegate_task", %{"task" => "build it", "type" => "worker"}}
            ]),
            row("builder", :user, [{:text, "build it"}]),
            row("builder", :assistant, [{:text, "built!"}])
          ],
          "builder",
          @agents
        )

      inter = all(entries, :inter_agent_in)
      user = all(entries, :user)

      assert length(inter) == 1
      assert user == []
    end
  end

  # ---------------------------------------------------------------------------
  # agent_response classification
  # ---------------------------------------------------------------------------

  describe "agent_response entries" do
    test "{:custom, :agent_response} with sender metadata → right-side :agent_response with correct author" do
      entries =
        build(
          [
            row_with_meta(
              "orch",
              {:custom, :agent_response},
              [{:text, "Work complete."}],
              %{sender_id: "builder-id", sender_name: "builder"}
            )
          ],
          "orch",
          @orch_agents
        )

      assert [
               %{
                 type: :agent_response,
                 side: :right,
                 author: {:agent, "builder-id", "builder"},
                 text: "Work complete."
               }
             ] = entries
    end

    test "{:custom, :agent_response} without sender metadata → right-side :agent_response with :user author" do
      entries =
        build(
          [
            row("orch", {:custom, :agent_response}, [{:text, "worker response"}])
          ],
          "orch",
          @orch_agents
        )

      assert [
               %{
                 type: :agent_response,
                 side: :right,
                 author: :user,
                 text: "worker response"
               }
             ] = entries
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-detect orchestrator (nil perspective)
  # ---------------------------------------------------------------------------

  describe "nil perspective → auto-detect orchestrator" do
    test "detects orchestrator from agents map" do
      agents = %{"orch" => %{type: "orchestrator", name: "orchestrator"}}

      entries =
        build(
          [
            row("orch", :user, [{:text, "go"}]),
            row("orch", :assistant, [{:text, "done"}])
          ],
          nil,
          agents
        )

      assert [%{type: :user, author: :user}, %{type: :text}] = entries
    end

    test "detects orchestrator from rows (inter-agent tool call)" do
      entries =
        build(
          [
            row("orch", :assistant, [
              {:tool_call, "t1", "ask_agent", %{"question" => "help"}}
            ])
          ],
          nil,
          %{}
        )

      # The orch row becomes a tool entry (left side)
      assert [%{type: :tool, side: :left}] = entries
    end
  end

  # ---------------------------------------------------------------------------
  # author_label/1
  # ---------------------------------------------------------------------------

  describe "author_label/1" do
    test ":user → \"you\"" do
      assert ChatEntries.author_label(:user) == "you"
    end

    test "{:agent, id, name} → name" do
      assert ChatEntries.author_label({:agent, "abc", "builder"}) == "builder"
    end
  end

  # ---------------------------------------------------------------------------
  # tool_subtitle/2
  # ---------------------------------------------------------------------------

  describe "tool_subtitle/2" do
    test "bash shows first line of command" do
      assert ChatEntries.tool_subtitle("bash", %{"command" => "mix test\nmix format"}) ==
               "mix test"
    end

    test "read shows path" do
      assert ChatEntries.tool_subtitle("read", %{"path" => "lib/app.ex"}) == "lib/app.ex"
    end

    test "ask_agent with name and question → name · question" do
      subtitle =
        ChatEntries.tool_subtitle("ask_agent", %{
          "name" => "Bob",
          "question" => "what's the status?"
        })

      assert subtitle == "Bob · what's the status?"
    end

    test "ask_agent with type and question → type · question" do
      subtitle =
        ChatEntries.tool_subtitle("ask_agent", %{"type" => "reviewer", "question" => "LGTM?"})

      assert subtitle == "reviewer · LGTM?"
    end

    test "ask_agent with id only (no name/type) → id · question" do
      subtitle =
        ChatEntries.tool_subtitle("ask_agent", %{"id" => "abc123", "question" => "done?"})

      assert subtitle == "abc123 · done?"
    end

    test "ask_agent with no target → just the question" do
      subtitle = ChatEntries.tool_subtitle("ask_agent", %{"question" => "what next?"})
      assert subtitle == "what next?"
    end

    test "ask_agent name takes priority over type" do
      subtitle =
        ChatEntries.tool_subtitle("ask_agent", %{
          "name" => "Bob",
          "type" => "worker",
          "question" => "go"
        })

      assert subtitle =~ "Bob"
      refute subtitle =~ "worker"
    end

    test "ask_agent truncates long question after agent name" do
      question = String.duplicate("x", 100)

      subtitle =
        ChatEntries.tool_subtitle("ask_agent", %{"name" => "Bob", "question" => question})

      assert String.starts_with?(subtitle, "Bob · ")
      assert String.length(subtitle) <= 70
    end

    test "delegate_task with name and task → name · task" do
      subtitle =
        ChatEntries.tool_subtitle("delegate_task", %{"name" => "Bob", "task" => "build auth"})

      assert subtitle == "Bob · build auth"
    end

    test "delegate_task with type only → type · task" do
      subtitle =
        ChatEntries.tool_subtitle("delegate_task", %{"type" => "worker", "task" => "build it"})

      assert subtitle == "worker · build it"
    end

    test "delegate_task with no target → just the task" do
      subtitle = ChatEntries.tool_subtitle("delegate_task", %{"task" => "do something"})
      assert subtitle == "do something"
    end

    test "send_response shows truncated response (no explicit target)" do
      subtitle = ChatEntries.tool_subtitle("send_response", %{"response" => "all done"})
      assert subtitle == "all done"
    end

    test "spawn_agent with name → name" do
      assert ChatEntries.tool_subtitle("spawn_agent", %{"name" => "Bob", "type" => "worker"}) ==
               "Bob"
    end

    test "spawn_agent without name → type" do
      assert ChatEntries.tool_subtitle("spawn_agent", %{"type" => "worker"}) == "worker"
    end

    test "external tool → nil (args may be irrelevant to the user)" do
      assert ChatEntries.tool_subtitle("my_sidecar_tool", %{"path" => "/tmp/out"}) == nil
      assert ChatEntries.tool_subtitle("my_sidecar_tool", %{}) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # format_args/2 (still on ChatComponent)
  # ---------------------------------------------------------------------------

  describe "format_args/2" do
    alias Planck.Web.Live.ChatComponent

    test "bash returns command directly" do
      assert ChatComponent.format_args("bash", %{"command" => "mix test"}) == "mix test"
    end

    test "read returns path label" do
      assert ChatComponent.format_args("read", %{"path" => "lib/app.ex"}) == "path: lib/app.ex"
    end

    test "unknown tool returns pretty JSON" do
      result = ChatComponent.format_args("custom", %{"key" => "val"})
      assert result =~ "key"
      assert result =~ "val"
    end
  end
end
