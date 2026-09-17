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
end
