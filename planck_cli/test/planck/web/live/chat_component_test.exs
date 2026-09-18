defmodule Planck.Web.Live.ChatComponentTest do
  use ExUnit.Case, async: true

  alias Planck.Web.Live.ChatComponent

  # render_markdown/1 was Earmark, swapped for MDEx after Earmark was retired
  # upstream with an active XSS CVE (EEF-CVE-2026-48591). This text can be
  # agent- or tool-authored and reaches the chat DOM, so the escaping
  # behavior here is load-bearing, not incidental — see specs/drafts/v0.1.14-spec.md
  # Section 3.
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
end
