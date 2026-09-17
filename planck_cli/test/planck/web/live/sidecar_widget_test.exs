defmodule Planck.Web.Live.SidecarWidgetTest do
  use Planck.Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Planck.Web.Live.SidecarWidget

  # SidecarWidget.render/1 tested as a plain function — flatten via
  # Phoenix.HTML.Safe, same technique used to spike this mechanism in the
  # first place. Decoupled from update/2's actual RPC call, so both branches
  # are reachable directly. Named render_widget/1, not render/1, to avoid
  # colliding with the imported Phoenix.LiveViewTest.render/1.
  defp render_widget(assigns) do
    assigns
    |> SidecarWidget.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  describe "render/1" do
    test "shows a fallback message when the sidecar is not connected" do
      html = render_widget(%{widget_id: "counter", error: :sidecar_not_connected, html: nil})
      assert html =~ "Sidecar not connected"
    end

    test "renders the widget's html verbatim when connected" do
      html = render_widget(%{widget_id: "counter", error: nil, html: "<div>count: 1</div>"})
      assert html =~ "<div>count: 1</div>"
    end
  end

  # update/2's RPC fallback is exercised for real here — no sidecar is
  # configured/connected in the test environment (same as
  # planck_headless's Widgets.list/render/dispatch_action tests), so this is
  # the actual code path, not a mock standing in for it. The success path
  # (a real {:ok, html} from a connected sidecar) is covered by
  # planck_headless's own mix test.integration suite, not here.
  describe "update/2 with %{widget_id: id} (real sidecar-not-connected fallback)" do
    test "assigns error: :sidecar_not_connected and the fallback renders" do
      html = render_component(SidecarWidget, %{id: "test", widget_id: "counter"})
      assert html =~ "Sidecar not connected"
    end

    # The parent template re-passes widget_id on every one of its own
    # re-renders, not just the first mount, so this guards against re-issuing
    # the RPC pull (and clobbering html pushed since via send_update) every
    # time. Proven here by seeding a sentinel html value under the same
    # widget_id and confirming a second update/2 call leaves it untouched —
    # if the pull-clause fired instead, sidecar-not-connected would overwrite
    # it with an error.
    test "a second update/2 call with the same widget_id is a no-op" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          widget_id: "counter",
          html: "<div>sentinel</div>",
          error: nil,
          myself: nil,
          __changed__: %{}
        }
      }

      assert {:ok, updated} = SidecarWidget.update(%{widget_id: "counter"}, socket)
      assert updated.assigns.html == "<div>sentinel</div>"
      assert updated.assigns.error == nil
    end
  end

  # This is the clause a future owning LiveView's handle_info/2 forwards a
  # PubSub broadcast into via send_update/3 — see the moduledoc.
  # Phoenix.LiveComponent has no handle_info/2 of its own (a component has no
  # process to receive messages), so this is deliberately update/2, not
  # handle_info/2 — the spec's original sketch had that wrong.
  describe "update/2 with %{html: html} (forwarded push)" do
    test "assigns the pushed html and clears any prior error" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          widget_id: "counter",
          html: nil,
          error: :sidecar_not_connected,
          myself: nil,
          __changed__: %{}
        }
      }

      assert {:ok, updated} = SidecarWidget.update(%{html: "<div>2</div>"}, socket)
      assert updated.assigns.html == "<div>2</div>"
      assert updated.assigns.error == nil
    end
  end

  describe "handle_event/3" do
    test "dispatches the action and returns {:noreply, socket} without crashing" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          widget_id: "counter",
          html: "<div/>",
          error: nil,
          myself: nil,
          __changed__: %{}
        }
      }

      params = %{"action" => "increment", "args" => %{}}
      assert {:noreply, ^socket} = SidecarWidget.handle_event("widget_action", params, socket)
    end
  end
end
