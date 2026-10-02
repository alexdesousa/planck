defmodule Planck.Web.Live.ChatComponentTest do
  use ExUnit.Case, async: true

  alias Planck.Web.Live.ChatComponent

  # render_markdown/1 was Earmark, swapped for MDEx after Earmark was retired
  # upstream with an active XSS CVE (EEF-CVE-2026-48591). This text can be
  # agent- or tool-authored and reaches the chat DOM, so the escaping
  # behavior here is load-bearing, not incidental.
  describe "render_markdown/1" do
    test "renders basic markdown" do
      html = safe_to_string(ChatComponent.render_markdown("plain **bold** text"))
      assert html =~ "<strong>bold</strong>"
    end

    test "converts a single newline to a hard line break" do
      html = safe_to_string(ChatComponent.render_markdown("line one\nline two"))
      assert html =~ "<br"
    end

    test "renders GFM tables" do
      html = safe_to_string(ChatComponent.render_markdown("| a | b |\n|---|---|\n| 1 | 2 |"))
      assert html =~ "<table>"
    end

    test "autolinks bare URLs" do
      html = safe_to_string(ChatComponent.render_markdown("visit https://example.com now"))
      assert html =~ ~s(<a href="https://example.com")
    end

    test "neutralizes raw script tags instead of passing them through" do
      html = safe_to_string(ChatComponent.render_markdown("<script>alert(1)</script>"))
      refute html =~ "<script>"
    end

    test "neutralizes an inline raw HTML XSS attempt instead of passing it through" do
      html =
        safe_to_string(ChatComponent.render_markdown("before <img src=x onerror=alert(1)> after"))

      refute html =~ "onerror"
      refute html =~ "<img"
    end

    test "returns an empty safe string for non-binary input" do
      assert safe_to_string(ChatComponent.render_markdown(nil)) == ""
    end
  end

  defp safe_to_string(safe), do: safe |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  # ---------------------------------------------------------------------------
  # handle_event/3 "open_widget"
  # ---------------------------------------------------------------------------

  describe ~s(handle_event/3 "open_widget") do
    defp socket_with_entries(entries) do
      %Phoenix.LiveView.Socket{assigns: %{entries: entries, __changed__: %{}}}
    end

    test "forwards {:open_widget, %{widget_id: ...}} to the parent LiveView for a :ui_widget entry" do
      entries = [
        %{
          id: "ui-t1",
          type: :ui_widget,
          label: "View widget",
          widget: "counter",
          widget_data: nil
        }
      ]

      socket = socket_with_entries(entries)

      assert {:noreply, ^socket} =
               ChatComponent.handle_event("open_widget", %{"id" => "ui-t1"}, socket)

      assert_received {:open_widget, %{widget_id: "counter"}}
    end

    test "does nothing when the entry id doesn't match a :ui_widget entry" do
      socket = socket_with_entries([%{id: "text-1", type: :text}])

      assert {:noreply, ^socket} =
               ChatComponent.handle_event("open_widget", %{"id" => "text-1"}, socket)

      refute_received {:open_widget, _}
    end

    test "does nothing when the entry id doesn't exist at all" do
      socket = socket_with_entries([])

      assert {:noreply, ^socket} =
               ChatComponent.handle_event("open_widget", %{"id" => "ghost"}, socket)

      refute_received {:open_widget, _}
    end
  end

  # ---------------------------------------------------------------------------
  # update/2 {action: :event, event: {:agent_event, :tool_end, ...}}
  # ---------------------------------------------------------------------------

  describe ~s(update/2 "tool_end" — ui entry placement) do
    defp tool_entry(tool_id) do
      %{
        id: "tool-#{tool_id}",
        type: :tool,
        tool_id: tool_id,
        author: {:agent, "a1", "Agent"},
        tool_result: nil,
        tool_error: false
      }
    end

    defp widget_result do
      {:ok, "done",
       %{ui: %{kind: :widget, label: "View board", widget: "beads-board", data: nil}}}
    end

    # ChatEntries.insert_ui_entries/1 — the turn-end rebuild's own placement
    # logic — splices a ui entry right after its matching :tool entry, not
    # at the end of the list. This event fires immediately on tool
    # completion, well before turn-end's rebuild; if it appended instead of
    # splicing, the button would visibly jump to its final spot the moment
    # the turn ended and load_entries/2 replaced `entries` wholesale.
    test "splices the ui entry right after its tool entry, not appended to the end" do
      socket = socket_with_entries([tool_entry("t1"), tool_entry("t2")])

      {:ok, updated} =
        ChatComponent.update(
          %{
            action: :event,
            event: {:agent_event, :tool_end, %{id: "t1", result: widget_result(), error: false}}
          },
          socket
        )

      assert Enum.map(updated.assigns.entries, & &1.id) == ["tool-t1", "ui-t1", "tool-t2"]
    end

    test "adds no ui entry when the tool_id has no matching entry (author unresolvable)" do
      socket = socket_with_entries([tool_entry("other")])

      {:ok, updated} =
        ChatComponent.update(
          %{
            action: :event,
            event: {:agent_event, :tool_end, %{id: "t1", result: widget_result(), error: false}}
          },
          socket
        )

      assert Enum.map(updated.assigns.entries, & &1.id) == ["tool-other"]
    end

    test "still updates tool_result/tool_error on the matching entry" do
      socket = socket_with_entries([tool_entry("t1")])

      {:ok, updated} =
        ChatComponent.update(
          %{
            action: :event,
            event: {:agent_event, :tool_end, %{id: "t1", result: {:ok, "output"}, error: false}}
          },
          socket
        )

      assert [%{tool_result: "output", tool_error: false}] = updated.assigns.entries
    end
  end

  # ---------------------------------------------------------------------------
  # :message_queued role split
  # ---------------------------------------------------------------------------

  describe ":message_queued role split" do
    defp socket_for_queued do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, pending_entries: [], session_id: "test-session"}
      }
    end

    test "role: :command → pending command entry (deletable, not editable)" do
      socket = socket_for_queued()

      {:ok, updated} =
        ChatComponent.update(
          %{
            action: :event,
            event:
              {:agent_event, :message_queued,
               %{
                 id: "m1",
                 content: [{:text, "rendered body"}],
                 role: :command,
                 command_meta: %{
                   command: %{name: "review-checklist", args: ["src/auth"]},
                   invoked_by: :user
                 }
               }}
          },
          socket
        )

      [entry] = updated.assigns.pending_entries

      assert entry.type == :command
      assert entry.command.name == "review-checklist"
      assert entry.command.args == ["src/auth"]
      assert entry.deletable == true
      assert entry.text == "rendered body"
    end

    test "role: :clear → pending command chip 'clear', no body" do
      socket = socket_for_queued()

      {:ok, updated} =
        ChatComponent.update(
          %{
            action: :event,
            event: {:agent_event, :message_queued, %{id: "m1", content: [], role: :clear}}
          },
          socket
        )

      [entry] = updated.assigns.pending_entries

      assert entry.type == :command
      assert entry.command.name == "clear"
      assert entry.command.args == nil
      assert entry.text == nil
    end

    test "role: :compact with args → pending command chip 'compact' with args" do
      socket = socket_for_queued()

      {:ok, updated} =
        ChatComponent.update(
          %{
            action: :event,
            event:
              {:agent_event, :message_queued,
               %{id: "m1", content: [], role: :compact, args: %{prompt: "focus on API"}}}
          },
          socket
        )

      [entry] = updated.assigns.pending_entries

      assert entry.type == :command
      assert entry.command.name == "compact"
      assert entry.command.args == ["focus on API"]
    end

    test "no role → existing editable user pending entry (regression guard)" do
      socket = socket_for_queued()

      {:ok, updated} =
        ChatComponent.update(
          %{
            action: :event,
            event: {:agent_event, :message_queued, %{id: "m1", content: [{:text, "hello"}]}}
          },
          socket
        )

      [entry] = updated.assigns.pending_entries

      assert entry.type == :user
      assert entry.editable == true
      assert entry.text == "hello"
    end
  end

  # ---------------------------------------------------------------------------
  # delete_pending_command — removes from pending_entries immediately
  # ---------------------------------------------------------------------------

  describe ~s(handle_event/3 "delete_pending_command") do
    defp socket_with_pending(entries) do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, pending_entries: entries, session_id: "test-session"}
      }
    end

    test "removes the matching entry from pending_entries" do
      entries = [
        %{
          id: "m1",
          type: :command,
          command: %{name: "clear", args: nil},
          text: nil,
          deletable: true
        }
      ]

      socket = socket_with_pending(entries)

      assert {:noreply, updated} =
               ChatComponent.handle_event("delete_pending_command", %{"id" => "m1"}, socket)

      assert updated.assigns.pending_entries == []
    end

    test "no session_id → still removes from pending_entries" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, pending_entries: [], session_id: nil}
      }

      assert {:noreply, _} =
               ChatComponent.handle_event("delete_pending_command", %{"id" => "m1"}, socket)
    end
  end

  # ---------------------------------------------------------------------------
  # :message_cancelled
  # ---------------------------------------------------------------------------

  describe ":message_cancelled event" do
    test "removes the matching pending entry" do
      entries = [
        %{
          id: "m1",
          type: :command,
          command: %{name: "clear", args: nil},
          text: nil,
          deletable: true
        },
        %{
          id: "m2",
          type: :command,
          command: %{name: "compact", args: nil},
          text: nil,
          deletable: true
        }
      ]

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, pending_entries: entries, session_id: "test-session"}
      }

      {:ok, updated} =
        ChatComponent.update(
          %{action: :event, event: {:agent_event, :message_cancelled, %{id: "m1"}}},
          socket
        )

      assert length(updated.assigns.pending_entries) == 1
      assert hd(updated.assigns.pending_entries).id == "m2"
    end

    test "no matching id → unchanged" do
      entries = [
        %{
          id: "m1",
          type: :command,
          command: %{name: "clear", args: nil},
          text: nil,
          deletable: true
        }
      ]

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, pending_entries: entries, session_id: "test-session"}
      }

      {:ok, updated} =
        ChatComponent.update(
          %{action: :event, event: {:agent_event, :message_cancelled, %{id: "nope"}}},
          socket
        )

      assert updated.assigns.pending_entries == entries
    end

    test "empty pending_entries → no-op" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, pending_entries: [], session_id: "test-session"}
      }

      {:ok, updated} =
        ChatComponent.update(
          %{action: :event, event: {:agent_event, :message_cancelled, %{id: "m1"}}},
          socket
        )

      assert updated.assigns.pending_entries == []
    end
  end
end
