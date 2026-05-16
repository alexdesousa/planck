defmodule Planck.Web.Live.PromptInputTest do
  use Planck.Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Planck.Web.Live.PromptInput

  defp render_input(assigns) do
    render_component(PromptInput, Map.merge(%{id: "test"}, assigns))
  end

  describe "Send button visibility" do
    test "visible when idle" do
      html = render_input(%{streaming: false, waiting: false})
      assert html =~ ~r/<button[^>]*type="submit"/
    end

    test "visible while waiting (enqueue mode)" do
      html = render_input(%{streaming: false, waiting: true})
      assert html =~ ~r/<button[^>]*type="submit"/
    end

    test "visible while streaming" do
      html = render_input(%{streaming: true, waiting: false})
      assert html =~ ~r/<button[^>]*type="submit"/
    end
  end

  describe "textarea" do
    test "not disabled when idle" do
      html = render_input(%{streaming: false, waiting: false})
      refute html =~ ~r/<textarea[^>]*disabled/
    end

    test "not disabled while waiting" do
      html = render_input(%{streaming: false, waiting: true})
      refute html =~ ~r/<textarea[^>]*disabled/
    end

    test "not disabled while streaming" do
      html = render_input(%{streaming: true, waiting: false})
      refute html =~ ~r/<textarea[^>]*disabled/
    end
  end

  describe "Stop buttons" do
    test "hidden when idle" do
      html = render_input(%{streaming: false, waiting: false})
      refute html =~ "Stop All"
    end

    test "shown while waiting" do
      html = render_input(%{streaming: false, waiting: true})
      assert html =~ "Stop All"
    end

    test "shown while streaming" do
      html = render_input(%{streaming: true, waiting: false})
      assert html =~ "Stop All"
    end
  end
end
